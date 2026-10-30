/* =====================================================================
   OMSI Integration Ledger - reference design (part 2 of 4)
   Core procedures: lifecycle, outbox publish, queue claim/complete/fail,
   operator reprocessing, run tracking, alerts.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------------------------------------------------------------------
   Alerts (deduplicated: one open alert per key)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE integ.usp_Alert_Raise
    @AlertKey nvarchar(200), @Category varchar(30), @Severity varchar(10), @Message nvarchar(2000)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE integ.Alert
       SET LastSeenAt = SYSDATETIME(), Occurrences += 1, Message = @Message, Severity = @Severity
     WHERE AlertKey = @AlertKey AND ResolvedAt IS NULL;
    IF @@ROWCOUNT = 0
        INSERT integ.Alert (AlertKey, Category, Severity, Message)
        VALUES (@AlertKey, @Category, @Severity, @Message);
END;
GO

CREATE OR ALTER PROCEDURE integ.usp_Alert_Resolve @AlertKey nvarchar(200)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE integ.Alert SET ResolvedAt = SYSDATETIME() WHERE AlertKey = @AlertKey AND ResolvedAt IS NULL;
END;
GO

/* ---------------------------------------------------------------------
   Process runs (SSIS package / job heartbeat)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE integ.usp_Run_Start @ProcessName nvarchar(128), @RunId bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT integ.ProcessRun (ProcessName) VALUES (@ProcessName);
    SET @RunId = SCOPE_IDENTITY();
END;
GO

CREATE OR ALTER PROCEDURE integ.usp_Run_End
    @RunId bigint, @Status varchar(10) = 'Succeeded', @Message nvarchar(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE integ.ProcessRun
       SET EndedAt = SYSDATETIME(), HeartbeatAt = SYSDATETIME(), Status = @Status, Message = @Message
     WHERE RunId = @RunId;
END;
GO

/* ---------------------------------------------------------------------
   Lifecycle: apply a state. Reality wins - an unexpected transition is
   applied (the event did happen) but flagged IsExpected = 0 for review.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE integ.usp_Entity_ApplyState
    @EntityId bigint, @ToState varchar(30), @TriggerKind varchar(10), @TriggerId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @EntityType varchar(30), @FromState varchar(30);

    SELECT @EntityType = EntityType, @FromState = CurrentState
      FROM integ.BusinessEntity WITH (UPDLOCK, HOLDLOCK)
     WHERE EntityId = @EntityId;

    IF @ToState IS NULL OR @FromState = @ToState RETURN 0;

    DECLARE @IsExpected bit =
        CASE WHEN EXISTS (SELECT 1 FROM integ.LifecycleTransition
                           WHERE EntityType = @EntityType
                             AND FromState IN (@FromState, '*')
                             AND ToState = @ToState) THEN 1 ELSE 0 END;

    UPDATE integ.BusinessEntity
       SET CurrentState = @ToState, StateChangedAt = SYSDATETIME(), UpdatedAt = SYSDATETIME()
     WHERE EntityId = @EntityId;

    INSERT integ.EntityStateHistory (EntityId, FromState, ToState, IsExpected, TriggerKind, TriggerId)
    VALUES (@EntityId, @FromState, @ToState, @IsExpected, @TriggerKind, @TriggerId);

    RETURN 1;
END;
GO

/* ---------------------------------------------------------------------
   OUTBOX PUBLISH
   One atomic transaction: entity upsert + immutable event + routed work
   items + coalescing/supersede rules + lifecycle state.
   Return: 0 = published, 1 = duplicate (idempotent no-op), 2 = unchanged payload suppressed
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE integ.usp_Outbox_Publish
    @EntityType          varchar(30),
    @SourceSystem        varchar(20) = 'LT',
    @SourceKey           nvarchar(100),
    @EventType           varchar(40),
    @NewState            varchar(30) = NULL,
    @PayloadJson         nvarchar(max),
    @SourceChangeVersion bigint = NULL,
    @CorrelationId       uniqueidentifier = NULL,
    @IdempotencyKey      nvarchar(200) = NULL,
    @SuppressIfUnchanged bit = 1,
    @EventId             bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OwnTran bit = IIF(@@TRANCOUNT = 0, 1, 0);
    DECLARE @EntityId bigint, @PrevHash varbinary(32), @Hash varbinary(32) = HASHBYTES('SHA2_256', @PayloadJson);
    DECLARE @EventUid uniqueidentifier, @Result int = 0;
    DECLARE @New TABLE (WorkItemId bigint, OperationCode int, TargetSystem varchar(20), OrderingKey nvarchar(100));
    DECLARE @Promoted TABLE (WorkItemId bigint, OldOp int, NewOp int);
    DECLARE @Superseded TABLE (WorkItemId bigint);
    DECLARE @OrderingKey nvarchar(100) = CONCAT(@EntityType, ':', @SourceKey);

    SET @EventId = NULL;
    IF @OwnTran = 1 BEGIN TRANSACTION;

    -- Serialise all publishes for the same business entity
    SELECT @EntityId = EntityId, @PrevHash = LastContentHash
      FROM integ.BusinessEntity WITH (UPDLOCK, HOLDLOCK)
     WHERE EntityType = @EntityType AND SourceSystem = @SourceSystem AND SourceKey = @SourceKey;

    IF @EntityId IS NULL
    BEGIN
        INSERT integ.BusinessEntity (EntityType, SourceSystem, SourceKey, CurrentState, StateChangedAt)
        VALUES (@EntityType, @SourceSystem, @SourceKey, COALESCE(@NewState, 'Unknown'), SYSDATETIME());
        SET @EntityId = SCOPE_IDENTITY();
        INSERT integ.EntityStateHistory (EntityId, FromState, ToState, IsExpected, TriggerKind)
        VALUES (@EntityId, NULL, COALESCE(@NewState, 'Unknown'), 1, 'EVENT');
    END;

    -- No-op suppression: ERP revision noise that does not change what the TMS receives
    IF @SuppressIfUnchanged = 1 AND @PrevHash = @Hash
    BEGIN
        IF @OwnTran = 1 COMMIT;
        RETURN 2;
    END;

    SET @IdempotencyKey = COALESCE(@IdempotencyKey,
        CONCAT('EVT|', @EntityType, '|', @SourceKey, '|', @EventType, '|',
               COALESCE(CONVERT(varchar(20), @SourceChangeVersion),
                        CONCAT(CONVERT(varchar(64), @PrevHash, 2), '>', CONVERT(varchar(64), @Hash, 2)))));

    SELECT @EventId = EventId FROM integ.OutboxEvent WHERE IdempotencyKey = @IdempotencyKey;
    IF @EventId IS NOT NULL
    BEGIN
        IF @OwnTran = 1 COMMIT;
        RETURN 1;
    END;

    -- Stale guard: LumberTrack revisions are monotonic per shipment. A revision older than one
    -- already published (late/out-of-order detection) must never replace newer state.
    IF @SourceChangeVersion IS NOT NULL
       AND @SourceChangeVersion < (SELECT MAX(SourceChangeVersion) FROM integ.OutboxEvent WHERE EntityId = @EntityId)
    BEGIN
        IF @OwnTran = 1 COMMIT;
        RETURN 3;
    END;

    SET @CorrelationId = COALESCE(@CorrelationId, NEWID());
    INSERT integ.OutboxEvent (EntityId, EventType, SourceChangeVersion, PayloadJson, PayloadHash, IdempotencyKey, CorrelationId)
    VALUES (@EntityId, @EventType, @SourceChangeVersion, @PayloadJson, @Hash, @IdempotencyKey, @CorrelationId);
    SET @EventId = SCOPE_IDENTITY();
    SELECT @EventUid = EventUid FROM integ.OutboxEvent WHERE EventId = @EventId;

    -- Route the event to one or more target operations
    INSERT integ.WorkItem (EventId, OperationCode, TargetSystem, OrderingKey, Priority, IdempotencyKey)
    OUTPUT inserted.WorkItemId, inserted.OperationCode, inserted.TargetSystem, inserted.OrderingKey INTO @New
    SELECT @EventId, o.OperationCode, o.TargetSystem, @OrderingKey, o.DefaultPriority,
           CONCAT(o.TargetSystem, '|', o.OperationCode, '|', CONVERT(varchar(36), @EventUid))
      FROM integ.EventRoute r
      JOIN integ.OperationCatalog o ON o.OperationCode = r.OperationCode
     WHERE r.EventType = @EventType AND r.IsActive = 1 AND o.IsActive = 1 AND o.Direction = 'OUT';

    -- Promotion (snapshot semantics): if the entity's create was never delivered (still open or
    -- dead-lettered), the newest snapshot is sent AS the create, replacing the stale create.
    -- Not while a create is in flight (Leased) or already delivered (Dispatched/Succeeded).
    UPDATE w
       SET OperationCode = o.PromoteToOperationCode, Priority = p.DefaultPriority,
           IdempotencyKey = CONCAT(w.TargetSystem, '|', o.PromoteToOperationCode, '|', CONVERT(varchar(36), @EventUid)),
           StatusReason = CONCAT('Promoted from op ', w.OperationCode, ': earlier create was never delivered')
    OUTPUT inserted.WorkItemId, deleted.OperationCode, inserted.OperationCode INTO @Promoted
      FROM integ.WorkItem w
      JOIN @New n ON n.WorkItemId = w.WorkItemId
      JOIN integ.OperationCatalog o ON o.OperationCode = n.OperationCode AND o.PromoteToOperationCode IS NOT NULL
      JOIN integ.OperationCatalog p ON p.OperationCode = o.PromoteToOperationCode
     WHERE EXISTS (SELECT 1 FROM integ.WorkItem c
                    WHERE c.OrderingKey = w.OrderingKey AND c.TargetSystem = w.TargetSystem AND c.WorkItemId < w.WorkItemId
                      AND c.OperationCode = o.PromoteToOperationCode AND c.Status IN ('Pending','RetryWait','DeadLetter'))
       AND NOT EXISTS (SELECT 1 FROM integ.WorkItem c
                        WHERE c.OrderingKey = w.OrderingKey AND c.TargetSystem = w.TargetSystem AND c.WorkItemId < w.WorkItemId
                          AND c.OperationCode = o.PromoteToOperationCode AND c.Status IN ('Leased','Dispatched','Succeeded'));

    -- A promoted snapshot replaces the undelivered create AND any undelivered snapshots behind it
    UPDATE w
       SET Status = 'Superseded', SupersededById = pr.WorkItemId, CompletedAt = SYSDATETIME(),
           StatusReason = CONCAT('Replaced by newer revision (promoted to op ', pr.NewOp, ')')
    OUTPUT inserted.WorkItemId INTO @Superseded
      FROM integ.WorkItem w
      JOIN integ.WorkItem nw ON nw.OrderingKey = w.OrderingKey AND nw.TargetSystem = w.TargetSystem
      JOIN @Promoted pr ON pr.WorkItemId = nw.WorkItemId
     WHERE w.WorkItemId < nw.WorkItemId
       AND w.OperationCode IN (pr.OldOp, pr.NewOp) AND w.Status IN ('Pending','RetryWait','DeadLetter');

    -- Supersede: a newer snapshot replaces older undelivered items of the same operation, per SupersedeScope
    UPDATE w
       SET Status = 'Superseded', SupersededById = n.WorkItemId, CompletedAt = SYSDATETIME(),
           StatusReason = IIF(w.Status = 'DeadLetter', 'Dead letter replaced by newer revision',
                                                       'Replaced by newer revision before delivery')
    OUTPUT inserted.WorkItemId INTO @Superseded
      FROM integ.WorkItem w
      JOIN @New n ON n.OrderingKey = w.OrderingKey AND n.TargetSystem = w.TargetSystem AND n.OperationCode = w.OperationCode
      JOIN integ.OperationCatalog o ON o.OperationCode = n.OperationCode AND o.SupersedeScope <> 'None'
     WHERE w.WorkItemId < n.WorkItemId
       AND n.WorkItemId NOT IN (SELECT WorkItemId FROM @Promoted)
       AND (w.Status IN ('Pending','RetryWait')
            OR (w.Status = 'DeadLetter' AND o.SupersedeScope = 'UnsentAndDeadLetter'));

    -- Terminal (cancel): everything still open for the entity becomes irrelevant
    UPDATE w
       SET Status = 'Superseded', SupersededById = n.WorkItemId, CompletedAt = SYSDATETIME(),
           StatusReason = 'Superseded by terminal operation'
    OUTPUT inserted.WorkItemId INTO @Superseded
      FROM integ.WorkItem w
      JOIN @New n ON n.OrderingKey = w.OrderingKey AND n.TargetSystem = w.TargetSystem
      JOIN integ.OperationCatalog o ON o.OperationCode = n.OperationCode AND o.IsTerminal = 1
     WHERE w.WorkItemId < n.WorkItemId AND w.Status IN ('Pending','RetryWait','DeadLetter');

    -- Terminal op with nothing ever delivered to that target: no need to send it
    UPDATE w
       SET Status = 'Cancelled', CompletedAt = SYSDATETIME(),
           StatusReason = 'Nothing was delivered to target; terminal operation not required'
      FROM integ.WorkItem w
      JOIN @New n ON n.WorkItemId = w.WorkItemId
      JOIN integ.OperationCatalog o ON o.OperationCode = n.OperationCode AND o.IsTerminal = 1
     WHERE NOT EXISTS (SELECT 1 FROM integ.WorkItem p
                        WHERE p.OrderingKey = w.OrderingKey AND p.TargetSystem = w.TargetSystem
                          AND p.WorkItemId < w.WorkItemId
                          AND (p.Status IN ('Dispatched','Succeeded','Leased')));

    -- A replaced dead letter needs no human any more: close its alert now
    UPDATE a SET ResolvedAt = SYSDATETIME()
      FROM integ.Alert a
      JOIN @Superseded s ON a.AlertKey = CONCAT(N'DEADLETTER:WI:', s.WorkItemId)
     WHERE a.ResolvedAt IS NULL;

    UPDATE integ.BusinessEntity SET LastContentHash = @Hash, UpdatedAt = SYSDATETIME() WHERE EntityId = @EntityId;
    EXEC integ.usp_Entity_ApplyState @EntityId, @NewState, 'EVENT', @EventId;

    IF @OwnTran = 1 COMMIT;
    RETURN @Result;
END;
GO

/* ---------------------------------------------------------------------
   CLAIM (competing consumers, lease-based, per-entity FIFO)
   - READPAST: concurrent workers skip each other's rows (no double send)
   - expired leases are reclaimed (crashed SSIS run)
   - an item waits while an earlier item for the same entity is open,
     including DeadLetter: a broken "new" blocks only ITS shipment's modifies
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE integ.usp_WorkItem_Claim
    @RunId         bigint,
    @LeaseOwner    nvarchar(128),
    @BatchSize     int = 20,
    @LeaseSeconds  int = 300,
    @TargetSystem  varchar(20) = NULL,
    @OperationCode int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Now datetime2(3) = SYSDATETIME();
    DECLARE @Claimed TABLE (WorkItemId bigint PRIMARY KEY, AttemptNo int, PrevStatus varchar(12));

    BEGIN TRANSACTION;

    WITH c AS (
        SELECT TOP (@BatchSize) w.WorkItemId, w.Status, w.LeaseOwner, w.LeaseExpiresAt, w.AttemptCount
          FROM integ.WorkItem w WITH (UPDLOCK, READPAST, ROWLOCK)
         WHERE (   (w.Status IN ('Pending','RetryWait') AND w.NextAttemptAt <= @Now)
                OR (w.Status = 'Leased' AND w.LeaseExpiresAt < @Now))
           AND (@TargetSystem IS NULL OR w.TargetSystem = @TargetSystem)
           AND (@OperationCode IS NULL OR w.OperationCode = @OperationCode)
           AND NOT EXISTS (SELECT 1 FROM integ.WorkItem p
                            WHERE p.OrderingKey = w.OrderingKey AND p.TargetSystem = w.TargetSystem
                              AND p.WorkItemId < w.WorkItemId
                              AND p.Status IN ('Pending','Leased','RetryWait','DeadLetter'))
         ORDER BY w.Priority, w.WorkItemId
    )
    UPDATE c
       SET Status = 'Leased', LeaseOwner = @LeaseOwner,
           LeaseExpiresAt = DATEADD(SECOND, @LeaseSeconds, @Now), AttemptCount = AttemptCount + 1
    OUTPUT inserted.WorkItemId, inserted.AttemptCount, deleted.Status INTO @Claimed;

    -- Previous holder lost its lease: close its attempt as abandoned
    UPDATE a SET Outcome = 'Abandoned', EndedAt = @Now, ErrorMessage = 'Lease expired before completion'
      FROM integ.WorkItemAttempt a
      JOIN @Claimed c ON c.WorkItemId = a.WorkItemId AND c.PrevStatus = 'Leased'
     WHERE a.EndedAt IS NULL;

    INSERT integ.WorkItemAttempt (WorkItemId, AttemptNo, RunId, LeaseOwner)
    SELECT WorkItemId, AttemptNo, @RunId, @LeaseOwner FROM @Claimed;

    UPDATE integ.ProcessRun SET ItemsClaimed += (SELECT COUNT(*) FROM @Claimed), HeartbeatAt = @Now WHERE RunId = @RunId;

    COMMIT;

    SELECT w.WorkItemId, w.OperationCode, o.Name AS OperationName, w.TargetSystem, o.AdapterProcedure,
           w.OrderingKey, w.IdempotencyKey, w.AttemptCount,
           COALESCE(e.PayloadJson, i.PayloadJson) AS PayloadJson,
           e.CorrelationId, be.EntityType, be.SourceKey
      FROM @Claimed c
      JOIN integ.WorkItem w          ON w.WorkItemId = c.WorkItemId
      JOIN integ.OperationCatalog o  ON o.OperationCode = w.OperationCode
      LEFT JOIN integ.OutboxEvent e  ON e.EventId = w.EventId
      LEFT JOIN integ.InboxMessage i ON i.InboxMessageId = w.InboxMessageId
      LEFT JOIN integ.BusinessEntity be ON be.EntityId = COALESCE(e.EntityId, i.EntityId)
     ORDER BY w.Priority, w.WorkItemId;
END;
GO

/* ---------------------------------------------------------------------
   COMPLETE - fenced by lease owner. Async targets (OMSI) -> Dispatched
   (awaiting acknowledgement); synchronous targets (API) -> Succeeded.
   Safe to call inside the adapter's transaction (same-instance atomicity).
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE integ.usp_WorkItem_Complete
    @WorkItemId bigint, @LeaseOwner nvarchar(128), @ExternalRef nvarchar(100) = NULL,
    @RequestSnapshot nvarchar(max) = NULL, @ResponseSnapshot nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Now datetime2(3) = SYSDATETIME(), @Outcome varchar(12), @RunId bigint;

    SELECT @RunId = RunId FROM integ.WorkItemAttempt WHERE WorkItemId = @WorkItemId AND EndedAt IS NULL;

    UPDATE w
       SET @Outcome = Status = IIF(o.RequiresAck = 1, 'Dispatched', 'Succeeded'),
           ExternalRef = COALESCE(@ExternalRef, w.ExternalRef),
           DispatchedAt = @Now,
           CompletedAt = IIF(o.RequiresAck = 1, NULL, @Now),
           LeaseOwner = NULL, LeaseExpiresAt = NULL, StatusReason = NULL
      FROM integ.WorkItem w
      JOIN integ.OperationCatalog o ON o.OperationCode = w.OperationCode
     WHERE w.WorkItemId = @WorkItemId AND w.Status = 'Leased' AND w.LeaseOwner = @LeaseOwner;

    IF @@ROWCOUNT = 0
        THROW 52001, 'Lease lost: work item is no longer leased by this owner (another worker may have reclaimed it).', 1;

    UPDATE a SET EndedAt = @Now, Outcome = @Outcome,
                 RequestSnapshot = COALESCE(@RequestSnapshot, RequestSnapshot),
                 ResponseSnapshot = COALESCE(@ResponseSnapshot, ResponseSnapshot)
      FROM integ.WorkItemAttempt a
     WHERE a.WorkItemId = @WorkItemId AND a.EndedAt IS NULL;

    UPDATE integ.ProcessRun SET ItemsSucceeded += 1, HeartbeatAt = @Now WHERE RunId = @RunId;
END;
GO

/* ---------------------------------------------------------------------
   FAIL - classify, decide retry vs dead-letter, record attempt.
   Call AFTER rolling back the business transaction.
   Return: 0 = RetryWait, 1 = DeadLetter, 2 = treated as success (Duplicate), -1 = lease lost
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE integ.usp_WorkItem_Fail
    @WorkItemId bigint, @LeaseOwner nvarchar(128),
    @ErrorNumber int = NULL, @ErrorMessage nvarchar(4000),
    @ErrorProcedure nvarchar(128) = NULL, @ErrorLine int = NULL,
    @ErrorClass varchar(20) = NULL,
    @RequestSnapshot nvarchar(max) = NULL, @ResponseSnapshot nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Now datetime2(3) = SYSDATETIME();
    DECLARE @Op int, @Attempts int, @CatalogId int, @IsRetryable bit = 1,
            @MaxAttempts int, @Base int, @Factor decimal(4,2), @MaxDelay int, @Delay int,
            @NewStatus varchar(12), @Ret int, @Key nvarchar(100);

    SET @ErrorMessage = COALESCE(@ErrorMessage, N'(no error message supplied)');

    SELECT @Op = OperationCode, @Attempts = AttemptCount, @Key = OrderingKey
      FROM integ.WorkItem WHERE WorkItemId = @WorkItemId AND Status = 'Leased' AND LeaseOwner = @LeaseOwner;
    IF @Op IS NULL RETURN -1;
    DECLARE @RunId bigint = (SELECT RunId FROM integ.WorkItemAttempt WHERE WorkItemId = @WorkItemId AND EndedAt IS NULL);

    SELECT TOP (1) @CatalogId = ErrorCatalogId, @IsRetryable = IsRetryable,
                   @ErrorClass = COALESCE(@ErrorClass, ErrorClass)
      FROM integ.ErrorCatalog
     WHERE (@ErrorClass IS NULL OR ErrorClass = @ErrorClass)
       AND (MatchErrorNumber IS NULL OR MatchErrorNumber = @ErrorNumber)
       AND (MatchPattern IS NULL OR @ErrorMessage LIKE MatchPattern)
     ORDER BY MatchOrder;
    SET @ErrorClass = COALESCE(@ErrorClass, 'Unknown');

    SELECT TOP (1) @MaxAttempts = MaxAttempts, @Base = BaseDelaySeconds, @Factor = BackoffFactor, @MaxDelay = MaxDelaySeconds
      FROM integ.RetryPolicy
     WHERE ErrorClass = @ErrorClass AND (OperationCode = @Op OR OperationCode IS NULL)
     ORDER BY IIF(OperationCode IS NULL, 1, 0);

    IF @ErrorClass = 'Duplicate'
        SELECT @NewStatus = 'Succeeded', @Ret = 2;      -- target already has it: idempotent replay
    ELSE IF @IsRetryable = 1 AND @Attempts < COALESCE(@MaxAttempts, 0)
    BEGIN
        -- exponential backoff with up to 10% jitter to avoid retry storms
        SET @Delay = CAST(@Base * POWER(CAST(@Factor AS float), @Attempts - 1) AS int);
        SET @Delay = IIF(@Delay > @MaxDelay OR @Delay < 0, @MaxDelay, @Delay);
        SET @Delay += ABS(CHECKSUM(NEWID())) % (@Delay / 10 + 1);
        SELECT @NewStatus = 'RetryWait', @Ret = 0;
    END
    ELSE
        SELECT @NewStatus = 'DeadLetter', @Ret = 1;

    BEGIN TRANSACTION;

    UPDATE integ.WorkItem
       SET Status = @NewStatus,
           NextAttemptAt = IIF(@NewStatus = 'RetryWait', DATEADD(SECOND, @Delay, @Now), NextAttemptAt),
           CompletedAt = IIF(@NewStatus = 'Succeeded', @Now, NULL),
           LeaseOwner = NULL, LeaseExpiresAt = NULL,
           LastErrorClass = @ErrorClass, LastErrorMessage = @ErrorMessage, LastErrorCatalogId = @CatalogId,
           StatusReason = CASE @NewStatus WHEN 'Succeeded' THEN 'Target reported duplicate - already applied'
                                          WHEN 'DeadLetter' THEN CONCAT(@ErrorClass, ' error after ', @Attempts, ' attempt(s)')
                                          ELSE NULL END
     WHERE WorkItemId = @WorkItemId;

    UPDATE integ.WorkItemAttempt
       SET EndedAt = @Now, Outcome = IIF(@NewStatus = 'Succeeded', 'Succeeded', 'Failed'),
           ErrorClass = @ErrorClass, ErrorNumber = @ErrorNumber, ErrorProcedure = @ErrorProcedure,
           ErrorLine = @ErrorLine, ErrorMessage = @ErrorMessage,
           RequestSnapshot = COALESCE(@RequestSnapshot, RequestSnapshot),
           ResponseSnapshot = COALESCE(@ResponseSnapshot, ResponseSnapshot)
     WHERE WorkItemId = @WorkItemId AND EndedAt IS NULL;

    UPDATE integ.ProcessRun
       SET ItemsFailed += IIF(@NewStatus = 'Succeeded', 0, 1),
           ItemsSucceeded += IIF(@NewStatus = 'Succeeded', 1, 0), HeartbeatAt = @Now
     WHERE RunId = @RunId;

    IF @NewStatus = 'DeadLetter'
    BEGIN
        DECLARE @AlertKey nvarchar(200) = CONCAT(N'DEADLETTER:WI:', @WorkItemId);
        DECLARE @Msg nvarchar(2000) = LEFT(CONCAT(N'Work item ', @WorkItemId, N' (op ', @Op, N', ', @Key,
                                       N') dead-lettered: ', @ErrorClass, N' - ', @ErrorMessage), 2000);
        EXEC integ.usp_Alert_Raise @AlertKey, 'DeadLetter', 'Critical', @Msg;
    END;

    COMMIT;
    RETURN @Ret;
END;
GO

/* ---------------------------------------------------------------------
   OPERATOR REPROCESSING (audited). Exposed to support UI / runbook.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE integ.usp_WorkItem_Retry @WorkItemId bigint, @Reason nvarchar(400)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    UPDATE integ.WorkItem
       SET Status = 'Pending', NextAttemptAt = SYSDATETIME(), StatusReason = CONCAT('Manual retry: ', @Reason)
     WHERE WorkItemId = @WorkItemId AND Status IN ('DeadLetter','RetryWait');
    IF @@ROWCOUNT = 0 THROW 52010, 'Only DeadLetter or RetryWait work items can be retried.', 1;
    INSERT integ.OperatorAction (WorkItemId, Action, Reason) VALUES (@WorkItemId, 'Retry', @Reason);
    DECLARE @k nvarchar(200) = CONCAT(N'DEADLETTER:WI:', @WorkItemId);
    EXEC integ.usp_Alert_Resolve @k;
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE integ.usp_WorkItem_Cancel @WorkItemId bigint, @Reason nvarchar(400)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    UPDATE integ.WorkItem
       SET Status = 'Cancelled', CompletedAt = SYSDATETIME(), StatusReason = CONCAT('Manual cancel: ', @Reason)
     WHERE WorkItemId = @WorkItemId AND Status IN ('Pending','RetryWait','DeadLetter');
    IF @@ROWCOUNT = 0 THROW 52011, 'Only Pending, RetryWait or DeadLetter work items can be cancelled.', 1;
    INSERT integ.OperatorAction (WorkItemId, Action, Reason) VALUES (@WorkItemId, 'Cancel', @Reason);
    DECLARE @k nvarchar(200) = CONCAT(N'DEADLETTER:WI:', @WorkItemId);
    EXEC integ.usp_Alert_Resolve @k;
    COMMIT;
END;
GO

-- Re-send something that already completed (e.g. TMS lost it). New work item, new idempotency key, linked to parent.
CREATE OR ALTER PROCEDURE integ.usp_WorkItem_Replay
    @WorkItemId bigint, @Reason nvarchar(400), @NewWorkItemId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    DECLARE @n int = 1 + (SELECT COUNT(*) FROM integ.WorkItem WHERE ParentWorkItemId = @WorkItemId);
    INSERT integ.WorkItem (EventId, InboxMessageId, ParentWorkItemId, OperationCode, TargetSystem, OrderingKey, Priority, IdempotencyKey, StatusReason)
    SELECT EventId, InboxMessageId, WorkItemId, OperationCode, TargetSystem, OrderingKey, Priority,
           CONCAT(IdempotencyKey, '|R', @n), CONCAT('Replay: ', @Reason)
      FROM integ.WorkItem
     WHERE WorkItemId = @WorkItemId AND Status IN ('Succeeded','Dispatched','Cancelled','Superseded');
    IF @@ROWCOUNT = 0 THROW 52012, 'Only completed work items can be replayed; use Retry for failed ones.', 1;
    SET @NewWorkItemId = SCOPE_IDENTITY();
    INSERT integ.OperatorAction (WorkItemId, Action, Reason, ResultWorkItemId) VALUES (@WorkItemId, 'Replay', @Reason, @NewWorkItemId);
    COMMIT;
END;
GO
