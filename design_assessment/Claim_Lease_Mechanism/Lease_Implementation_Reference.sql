/* Lease_Implementation_Reference.sql
   Teaching version of the integ work-item lease (claim + time limit).
   Extracted from Lease_Implementation_Guide.md in deployment order.
   [REF]=reference logic, [FIX]=review fix applied, [NEW]=proposed. TEST DATABASE FIRST.
   Section 13.1 (seed) is test-only. */
SET XACT_ABORT ON;
GO
-- [script] 3.1 integ.WorkItem (teaching subset)
IF SCHEMA_ID('integ') IS NULL EXEC ('CREATE SCHEMA integ');
GO
CREATE TABLE integ.WorkItem
(
    WorkItemId       bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_WorkItem PRIMARY KEY,
    OperationCode    varchar(50)    NOT NULL,          -- what to do, e.g. 'OMSI.ShipmentUpsert'
    TargetSystem     varchar(30)    NOT NULL,          -- where, e.g. 'OMSI', 'LT_API'
    OrderingKey      nvarchar(200)  NOT NULL,          -- which business object, e.g. 'Shipment:4171753'
    Priority         tinyint        NOT NULL CONSTRAINT DF_WI_Priority DEFAULT (5),
    IdempotencyKey   nvarchar(200)  NOT NULL,          -- reference number: set ONCE, never changed (Fix D3)
    PayloadJson      nvarchar(max)  NULL,

    -- State
    Status           varchar(20)    NOT NULL CONSTRAINT DF_WI_Status DEFAULT ('Pending'),
    StatusReason     nvarchar(400)  NULL,
    NextAttemptAt    datetime2(3)   NOT NULL CONSTRAINT DF_WI_Next DEFAULT (SYSUTCDATETIME()),  -- UTC

    -- Lease (the name + due time on the card)
    LeaseOwner       nvarchar(128)  NULL,              -- '<Process>#<RunId>[.<Thread>]'
    LeaseExpiresAt   datetime2(3)   NULL,              -- UTC

    -- Counters
    AttemptCount     int            NOT NULL CONSTRAINT DF_WI_Attempt DEFAULT (0),  -- also the fencing token
    AbandonCount     int            NOT NULL CONSTRAINT DF_WI_Abandon DEFAULT (0),  -- [NEW] Fix D4
    RetryBudgetBase  int            NOT NULL CONSTRAINT DF_WI_Budget  DEFAULT (0),  -- reset point after manual retry

    -- Results
    ExternalRef      nvarchar(200)  NULL,
    DispatchedAt     datetime2(3)   NULL,
    CompletedAt      datetime2(3)   NULL,
    CreatedAt        datetime2(3)   NOT NULL CONSTRAINT DF_WI_Created DEFAULT (SYSUTCDATETIME()),
    RowVer           rowversion,

    CONSTRAINT CK_WI_Status CHECK (Status IN
        ('Pending','Leased','RetryWait','Dispatched','Succeeded','DeadLetter','Superseded','Cancelled')),
    CONSTRAINT CK_WI_LeaseShape CHECK (
        (Status =  'Leased' AND LeaseOwner IS NOT NULL AND LeaseExpiresAt IS NOT NULL) OR
        (Status <> 'Leased' AND LeaseOwner IS NULL     AND LeaseExpiresAt IS NULL)),
    CONSTRAINT UQ_WI_Idem UNIQUE (IdempotencyKey)
);
GO
-- Finds claimable cards quickly (small: only open rows)
CREATE INDEX IX_WI_Claim ON integ.WorkItem (Priority, WorkItemId)
    INCLUDE (Status, NextAttemptAt, LeaseExpiresAt, OrderingKey, TargetSystem)
    WHERE Status IN ('Pending','RetryWait','Leased');
-- Answers "is an earlier card for the same object still open?" (the in-order check)
CREATE INDEX IX_WI_Ordering ON integ.WorkItem (OrderingKey, TargetSystem, WorkItemId)
    INCLUDE (Status)
    WHERE Status IN ('Pending','Leased','RetryWait','DeadLetter');
GO

-- [script] 3.2 Supporting tables
CREATE TABLE integ.WorkItemAttempt          -- [REF] one row per claim
(
    WorkItemId    bigint         NOT NULL,
    AttemptNo     int            NOT NULL,
    RunId         bigint         NOT NULL,
    LeaseOwner    nvarchar(128)  NOT NULL,
    StartedAt     datetime2(3)   NOT NULL,
    EndedAt       datetime2(3)   NULL,           -- NULL = still open
    Outcome       varchar(20)    NULL,
    ErrorClass    varchar(20)    NULL,           -- 'Transient' | 'Permanent'
    ErrorCode     int            NULL,
    ErrorMessage  nvarchar(2000) NULL,
    CONSTRAINT PK_WorkItemAttempt PRIMARY KEY (WorkItemId, AttemptNo),
    CONSTRAINT FK_WIA_WorkItem FOREIGN KEY (WorkItemId) REFERENCES integ.WorkItem (WorkItemId),
    CONSTRAINT CK_WIA_Outcome CHECK (Outcome IS NULL OR Outcome IN
        ('Succeeded','Dispatched','Duplicate','Failed','Abandoned'))
);
CREATE INDEX IX_WIA_Open ON integ.WorkItemAttempt (WorkItemId) WHERE EndedAt IS NULL;
GO
CREATE TABLE integ.OperationCatalog         -- [REF] subset
(
    OperationCode  varchar(50) NOT NULL CONSTRAINT PK_OperationCatalog PRIMARY KEY,
    RequiresAck    bit         NOT NULL CONSTRAINT DF_OC_Ack DEFAULT (0)   -- 1 = target confirms later
);
GO
CREATE TABLE integ.RetryPolicy              -- [NEW] column set proposed for this guide
(
    OperationCode     varchar(50) NOT NULL CONSTRAINT PK_RetryPolicy PRIMARY KEY,
    MaxAttempts       int NOT NULL,   -- attempts allowed (incl. the first) before DeadLetter
    BaseDelaySeconds  int NOT NULL,   -- first wait; doubles each retry
    MaxDelaySeconds   int NOT NULL,   -- cap for one wait
    MaxAbandons       int NOT NULL,   -- worker crashes allowed before "PoisonSuspected"
    LeaseSeconds      int NOT NULL,   -- recommended lease for this operation
    CONSTRAINT CK_RP_Values CHECK (MaxAttempts >= 1 AND BaseDelaySeconds >= 1
        AND MaxDelaySeconds >= BaseDelaySeconds AND MaxAbandons >= 1 AND LeaseSeconds BETWEEN 30 AND 3600)
);
GO
CREATE TABLE integ.ProcessRun               -- [REF] subset
(
    RunId        bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProcessRun PRIMARY KEY,
    ProcessName  nvarchar(100) NOT NULL,
    StartedAt    datetime2(3)  NOT NULL,
    HeartbeatAt  datetime2(3)  NOT NULL,
    EndedAt      datetime2(3)  NULL,
    RunStatus    varchar(20)   NOT NULL CONSTRAINT DF_PR_Status DEFAULT ('Running')
);
GO

-- [script] 3.3 Starting configuration
INSERT integ.OperationCatalog (OperationCode, RequiresAck) VALUES
    ('OMSI.ShipmentUpsert', 0),
    ('LT.FreightAccrual',   0);

INSERT integ.RetryPolicy (OperationCode, MaxAttempts, BaseDelaySeconds, MaxDelaySeconds, MaxAbandons, LeaseSeconds) VALUES
--   operation              tries  first wait  max wait  crashes  lease
    ('OMSI.ShipmentUpsert',  6,     60,         1800,     3,       300),   -- same server, sub-second work
    ('LT.FreightAccrual',    8,     60,         3600,     3,       300);   -- HTTP, ~10 s per call, renew per item
GO

-- [script] 4 usp_WorkItem_Enqueue
CREATE OR ALTER PROCEDURE integ.usp_WorkItem_Enqueue
    @OperationCode   varchar(50),
    @TargetSystem    varchar(30),
    @EntityType      varchar(30),        -- 'Shipment'
    @SourceKey       nvarchar(100),      -- '4171753'
    @SourceRevision  bigint,             -- source revision number (monotonic)
    @PayloadJson     nvarchar(max),
    @Priority        tinyint = 5,
    @WorkItemId      bigint  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Reference number = object + revision + operation. Deterministic: the same change always
    -- gets the same number, so even a duplicate detection produces the same key.
    DECLARE @Key nvarchar(200) =
        CONCAT(@EntityType, N':', @SourceKey, N':REV', @SourceRevision, N':', @OperationCode);

    INSERT integ.WorkItem (OperationCode, TargetSystem, OrderingKey, Priority, IdempotencyKey, PayloadJson)
    SELECT @OperationCode, @TargetSystem, CONCAT(@EntityType, N':', @SourceKey), @Priority, @Key, @PayloadJson
     WHERE NOT EXISTS (SELECT 1 FROM integ.WorkItem WITH (UPDLOCK, HOLDLOCK) WHERE IdempotencyKey = @Key);

    IF @@ROWCOUNT = 1
        SET @WorkItemId = SCOPE_IDENTITY();
    ELSE
        SELECT @WorkItemId = WorkItemId FROM integ.WorkItem WHERE IdempotencyKey = @Key;   -- already queued
END;
GO

-- [script] 5 usp_WorkItem_Claim
CREATE OR ALTER PROCEDURE integ.usp_WorkItem_Claim
    @RunId          bigint,
    @LeaseOwner     nvarchar(128),
    @BatchSize      int          = 10,
    @LeaseSeconds   int          = 300,
    @TargetSystem   varchar(30)  = NULL,   -- optional: claim for one target only
    @ReturnRows     bit          = 1,      -- 0 = caller reads its cards from the table instead
    @ClaimedCount   int          = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ----------------------------------------------------------------------------------
    -- 0. Validate inputs
    ----------------------------------------------------------------------------------
    IF @LeaseOwner IS NULL OR LTRIM(RTRIM(@LeaseOwner)) = N''
        THROW 52030, 'LeaseOwner is required.', 1;
    IF @BatchSize IS NULL OR @BatchSize NOT BETWEEN 1 AND 500
        THROW 52031, 'BatchSize must be between 1 and 500.', 1;
    IF @LeaseSeconds IS NULL OR @LeaseSeconds NOT BETWEEN 30 AND 3600
        THROW 52032, 'LeaseSeconds must be between 30 and 3600.', 1;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();                -- Fix D2: one clock, UTC

    DECLARE @Claimed TABLE
    (
        WorkItemId     bigint        NOT NULL PRIMARY KEY,
        AttemptNo      int           NOT NULL,
        PrevStatus     varchar(20)   NOT NULL,      -- 'Leased' here means "taken over from a dead/slow worker"
        PrevOwner      nvarchar(128) NULL,
        AbandonCount   int           NOT NULL,
        OperationCode  varchar(50)   NOT NULL
    );

    BEGIN TRANSACTION;

    ----------------------------------------------------------------------------------
    -- 1. Find + lease in ONE statement (rule 1)
    ----------------------------------------------------------------------------------
    WITH Eligible AS
    (
        SELECT TOP (@BatchSize)
               w.WorkItemId, w.Status, w.LeaseOwner, w.LeaseExpiresAt,
               w.AttemptCount, w.AbandonCount, w.OperationCode
          FROM integ.WorkItem AS w WITH (UPDLOCK, READPAST, ROWLOCK)
               -- UPDLOCK : I intend to change this row; no one else can take it in parallel
               -- READPAST: skip rows another claimer holds right now (don't wait in line)
               -- ROWLOCK : lock single rows, so READPAST skips only what it must
         WHERE (    (w.Status IN ('Pending','RetryWait') AND w.NextAttemptAt  <= @Now)   -- free
                 OR (w.Status = 'Leased'                 AND w.LeaseExpiresAt <  @Now) ) -- overdue
           AND (@TargetSystem IS NULL OR w.TargetSystem = @TargetSystem)
           AND NOT EXISTS                                                 -- in-order rule
               (
                 SELECT 1
                   FROM integ.WorkItem AS p WITH (READCOMMITTEDLOCK)
                        -- Fix D1: read the LIVE row, not a snapshot copy. Do NOT add READPAST here:
                        -- skipping a locked predecessor would wrongly look like "no predecessor".
                  WHERE p.OrderingKey  = w.OrderingKey
                    AND p.TargetSystem = w.TargetSystem
                    AND p.WorkItemId   < w.WorkItemId
                    AND p.Status IN ('Pending','Leased','RetryWait','DeadLetter')
               )
         ORDER BY w.Priority, w.WorkItemId
    )
    UPDATE Eligible
       SET Status         = 'Leased',
           LeaseOwner     = @LeaseOwner,
           LeaseExpiresAt = DATEADD(SECOND, @LeaseSeconds, @Now),
           AttemptCount   = AttemptCount + 1,                    -- new fencing token
           AbandonCount   = AbandonCount + IIF(Status = 'Leased', 1, 0)   -- right side = old value
    OUTPUT inserted.WorkItemId, inserted.AttemptCount, deleted.Status, deleted.LeaseOwner,
           inserted.AbandonCount, inserted.OperationCode
      INTO @Claimed (WorkItemId, AttemptNo, PrevStatus, PrevOwner, AbandonCount, OperationCode);

    ----------------------------------------------------------------------------------
    -- 2. Close the attempts of workers that never came back
    ----------------------------------------------------------------------------------
    UPDATE a
       SET EndedAt      = @Now,
           Outcome      = 'Abandoned',
           ErrorMessage = CONCAT(N'Lease expired; taken over by ', @LeaseOwner)
      FROM integ.WorkItemAttempt AS a
      JOIN @Claimed              AS c ON c.WorkItemId = a.WorkItemId
     WHERE c.PrevStatus = 'Leased'
       AND a.EndedAt IS NULL;

    ----------------------------------------------------------------------------------
    -- 3. Poison guard (Fix D4): too many crashes -> park it, don't hand it out again
    ----------------------------------------------------------------------------------
    UPDATE w
       SET Status         = 'DeadLetter',
           LeaseOwner     = NULL,
           LeaseExpiresAt = NULL,
           AttemptCount   = w.AttemptCount - 1,      -- this claim never started work
           StatusReason   = CONCAT(N'PoisonSuspected: worker lost the lease ', c.AbandonCount, N' times')
      FROM integ.WorkItem    AS w
      JOIN @Claimed          AS c  ON c.WorkItemId = w.WorkItemId
      LEFT JOIN integ.RetryPolicy AS rp ON rp.OperationCode = c.OperationCode
     WHERE c.AbandonCount >= COALESCE(rp.MaxAbandons, 3);

    DELETE c
      FROM @Claimed AS c
      LEFT JOIN integ.RetryPolicy AS rp ON rp.OperationCode = c.OperationCode
     WHERE c.AbandonCount >= COALESCE(rp.MaxAbandons, 3);

    ----------------------------------------------------------------------------------
    -- 4. Open one attempt row per card I now hold
    ----------------------------------------------------------------------------------
    INSERT integ.WorkItemAttempt (WorkItemId, AttemptNo, RunId, LeaseOwner, StartedAt)
    SELECT WorkItemId, AttemptNo, @RunId, @LeaseOwner, @Now
      FROM @Claimed;

    UPDATE integ.ProcessRun SET HeartbeatAt = @Now WHERE RunId = @RunId;

    COMMIT;

    ----------------------------------------------------------------------------------
    -- 5. Hand the cards to the caller
    ----------------------------------------------------------------------------------
    SELECT @ClaimedCount = COUNT(*) FROM @Claimed;

    IF @ReturnRows = 1
        SELECT w.WorkItemId,
               c.AttemptNo,                       -- the caller MUST pass this back on every report
               w.OperationCode, w.TargetSystem, w.OrderingKey,
               w.IdempotencyKey, w.PayloadJson, w.LeaseExpiresAt,
               IIF(c.PrevStatus = 'Leased', 'TakeOver', 'Fresh') AS ClaimKind
          FROM @Claimed       AS c
          JOIN integ.WorkItem AS w ON w.WorkItemId = c.WorkItemId
         ORDER BY w.Priority, w.WorkItemId;
END;
GO

-- [script] 6 usp_WorkItem_RenewLease
CREATE OR ALTER PROCEDURE integ.usp_WorkItem_RenewLease
    @WorkItemId     bigint,
    @LeaseOwner     nvarchar(128),
    @AttemptNo      int          = NULL,    -- pass it! (NULL only for legacy callers)
    @LeaseSeconds   int          = 300,
    @NewExpiresAt   datetime2(3) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LeaseSeconds IS NULL OR @LeaseSeconds NOT BETWEEN 30 AND 3600
        THROW 52032, 'LeaseSeconds must be between 30 and 3600.', 1;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    SET @NewExpiresAt = DATEADD(SECOND, @LeaseSeconds, @Now);

    UPDATE integ.WorkItem
       SET LeaseExpiresAt = @NewExpiresAt
     WHERE WorkItemId     = @WorkItemId
       AND Status         = 'Leased'
       AND LeaseOwner     = @LeaseOwner                              -- still mine?
       AND (@AttemptNo IS NULL OR AttemptCount = @AttemptNo)         -- same attempt? (Fix L8)
       AND LeaseExpiresAt > @Now;                                    -- not late? (rule 3)

    IF @@ROWCOUNT = 0
    BEGIN
        SET @NewExpiresAt = NULL;
        THROW 52002, 'Lease lost or expired: stop processing this work item.', 1;
    END;
END;
GO

-- [script] 6.3 Run start / heartbeat / end
CREATE OR ALTER PROCEDURE integ.usp_Run_Start
    @ProcessName nvarchar(100),
    @RunId       bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    INSERT integ.ProcessRun (ProcessName, StartedAt, HeartbeatAt) VALUES (@ProcessName, @Now, @Now);
    SET @RunId = SCOPE_IDENTITY();
END;
GO
CREATE OR ALTER PROCEDURE integ.usp_Run_Heartbeat
    @RunId bigint
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE integ.ProcessRun SET HeartbeatAt = SYSUTCDATETIME() WHERE RunId = @RunId AND EndedAt IS NULL;
END;
GO
CREATE OR ALTER PROCEDURE integ.usp_Run_End
    @RunId     bigint,
    @RunStatus varchar(20) = 'Succeeded'
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE integ.ProcessRun
       SET EndedAt = SYSUTCDATETIME(), HeartbeatAt = SYSUTCDATETIME(), RunStatus = @RunStatus
     WHERE RunId = @RunId;
END;
GO

-- [script] 7.1 usp_WorkItem_Complete
CREATE OR ALTER PROCEDURE integ.usp_WorkItem_Complete
    @WorkItemId    bigint,
    @LeaseOwner    nvarchar(128),
    @AttemptNo     int           = NULL,
    @ExternalRef   nvarchar(200) = NULL,
    @WasDuplicate  bit           = 0,          -- 1 = target said "already have it" (still success)
    @NewStatus     varchar(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;      -- if the fence fails, the caller's whole transaction rolls back

    DECLARE @Now     datetime2(3) = SYSUTCDATETIME();
    DECLARE @OwnTran bit = IIF(@@TRANCOUNT = 0, 1, 0);   -- join the adapter's transaction if there is one
    DECLARE @Done TABLE (NewStatus varchar(20), AttemptNo int);

    IF @OwnTran = 1 BEGIN TRANSACTION;

    UPDATE w
       SET Status         = IIF(o.RequiresAck = 1, 'Dispatched', 'Succeeded'),
           ExternalRef    = COALESCE(@ExternalRef, w.ExternalRef),
           DispatchedAt   = @Now,
           CompletedAt    = IIF(o.RequiresAck = 1, NULL, @Now),
           LeaseOwner     = NULL,
           LeaseExpiresAt = NULL,
           StatusReason   = IIF(@WasDuplicate = 1, N'Target reported duplicate (already processed)', NULL)
    OUTPUT inserted.Status, inserted.AttemptCount INTO @Done (NewStatus, AttemptNo)
      FROM integ.WorkItem         AS w
      JOIN integ.OperationCatalog AS o ON o.OperationCode = w.OperationCode
     WHERE w.WorkItemId = @WorkItemId
       AND w.Status     = 'Leased'
       AND w.LeaseOwner = @LeaseOwner                                 -- fence: owner
       AND (@AttemptNo IS NULL OR w.AttemptCount = @AttemptNo);       -- fence: attempt (Fix L8)
       -- Deliberately NO time check (rule 4)

    IF @@ROWCOUNT = 0
        THROW 52001, 'Lease lost: work item is no longer leased by this owner (another worker may have taken it over).', 1;

    UPDATE a
       SET EndedAt = @Now,
           Outcome = CASE WHEN @WasDuplicate = 1 THEN 'Duplicate' ELSE d.NewStatus END
      FROM integ.WorkItemAttempt AS a
      JOIN @Done                 AS d ON d.AttemptNo = a.AttemptNo
     WHERE a.WorkItemId = @WorkItemId
       AND a.EndedAt IS NULL;

    SELECT @NewStatus = NewStatus FROM @Done;

    IF @OwnTran = 1 COMMIT;
END;
GO

-- [script] 7.2 usp_WorkItem_Fail
CREATE OR ALTER PROCEDURE integ.usp_WorkItem_Fail
    @WorkItemId    bigint,
    @LeaseOwner    nvarchar(128),
    @AttemptNo     int            = NULL,
    @ErrorClass    varchar(20)    = 'Transient',   -- 'Transient' | 'Permanent'
    @ErrorCode     int            = NULL,
    @ErrorMessage  nvarchar(2000) = NULL,
    @NewStatus     varchar(20)    = NULL OUTPUT
    -- RETURN  0 = RetryWait,  1 = DeadLetter,  -1 = not owner (stop, change nothing)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ErrorClass NOT IN ('Transient','Permanent') SET @ErrorClass = 'Transient';

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();

    ----------------------------------------------------------------------------------
    -- 1. Read the counters and policy (advisory: only used to DECIDE, not to protect)
    ----------------------------------------------------------------------------------
    DECLARE @Attempts int, @BudgetBase int, @MaxAttempts int, @BaseDelay int, @MaxDelay int;

    SELECT @Attempts    = w.AttemptCount,
           @BudgetBase  = w.RetryBudgetBase,
           @MaxAttempts = COALESCE(rp.MaxAttempts, 6),
           @BaseDelay   = COALESCE(rp.BaseDelaySeconds, 60),
           @MaxDelay    = COALESCE(rp.MaxDelaySeconds, 3600)
      FROM integ.WorkItem AS w
      LEFT JOIN integ.RetryPolicy AS rp ON rp.OperationCode = w.OperationCode
     WHERE w.WorkItemId = @WorkItemId
       AND w.Status = 'Leased' AND w.LeaseOwner = @LeaseOwner;

    IF @@ROWCOUNT = 0 RETURN -1;                          -- early exit; the real fence is step 3

    ----------------------------------------------------------------------------------
    -- 2. Decide: retry later or park
    ----------------------------------------------------------------------------------
    DECLARE @Used int = @Attempts - @BudgetBase;          -- attempts since the last manual retry
    SET @NewStatus = CASE WHEN @ErrorClass = 'Permanent' OR @Used >= @MaxAttempts
                          THEN 'DeadLetter' ELSE 'RetryWait' END;

    DECLARE @Exp       int    = IIF(@Used - 1 > 16, 16, IIF(@Used - 1 < 0, 0, @Used - 1));   -- no overflow
    DECLARE @DelaySec  bigint = CAST(@BaseDelay AS bigint) * POWER(CAST(2 AS bigint), @Exp);
    IF @DelaySec > @MaxDelay SET @DelaySec = @MaxDelay;
    SET @DelaySec += ABS(CHECKSUM(NEWID())) % (@DelaySec / 5 + 1);                        -- jitter

    ----------------------------------------------------------------------------------
    -- 3. Write - the fence is INSIDE the UPDATE (Fix L9)
    ----------------------------------------------------------------------------------
    BEGIN TRANSACTION;

    UPDATE integ.WorkItem
       SET Status         = @NewStatus,
           NextAttemptAt  = IIF(@NewStatus = 'RetryWait', DATEADD(SECOND, CAST(@DelaySec AS int), @Now), NextAttemptAt),
           StatusReason   = LEFT(CONCAT(@ErrorClass, N' error ', @ErrorCode, N': ', @ErrorMessage), 400),
           LeaseOwner     = NULL,
           LeaseExpiresAt = NULL
     WHERE WorkItemId = @WorkItemId
       AND Status     = 'Leased'
       AND LeaseOwner = @LeaseOwner
       AND AttemptCount = COALESCE(@AttemptNo, @Attempts);     -- Fix L8 + L9

    IF @@ROWCOUNT = 0
    BEGIN
        ROLLBACK;
        SET @NewStatus = NULL;
        RETURN -1;                     -- lost the card between step 1 and step 3: change nothing
    END;

    UPDATE integ.WorkItemAttempt
       SET EndedAt      = @Now,
           Outcome      = 'Failed',
           ErrorClass   = @ErrorClass,
           ErrorCode    = @ErrorCode,
           ErrorMessage = @ErrorMessage
     WHERE WorkItemId = @WorkItemId
       AND AttemptNo  = COALESCE(@AttemptNo, @Attempts)        -- close MY attempt only
       AND EndedAt IS NULL;

    COMMIT;

    RETURN IIF(@NewStatus = 'DeadLetter', 1, 0);
END;
GO

-- [script] 7.3 fn_ClassifySqlError
CREATE OR ALTER FUNCTION integ.fn_ClassifySqlError (@ErrorNumber int)
RETURNS varchar(20)
AS
BEGIN
    RETURN CASE
        WHEN @ErrorNumber IN (1205, 1222, -2, 4060, 40613, 40501, 49918, 49919, 49920)
             THEN 'Transient'      -- deadlock, lock timeout, timeout, DB unavailable / throttled
        WHEN @ErrorNumber IN (2627, 2601, 547, 515, 245, 8114, 8115, 2628, 8152)
             THEN 'Permanent'      -- duplicate key, FK, NOT NULL, conversion, overflow, truncation
        WHEN @ErrorNumber BETWEEN 50000 AND 59999
             THEN 'Permanent'      -- our own validation errors (THROW 5xxxx)
        ELSE 'Transient'           -- unknown: retry, the budget will stop it
    END;
END;
GO

-- [script] 8.3 usp_Lease_ReleaseDeadRuns
CREATE OR ALTER PROCEDURE integ.usp_Lease_ReleaseDeadRuns
    @StaleAfterSeconds int = 180,          -- must be > the worker's heartbeat interval
    @Released          int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @StaleAfterSeconds IS NULL OR @StaleAfterSeconds < 60 SET @StaleAfterSeconds = 60;
    DECLARE @Now datetime2(3) = SYSUTCDATETIME();

    UPDATE w
       SET LeaseExpiresAt = DATEADD(MILLISECOND, -1, @Now)   -- overdue now; Claim does the rest
      FROM integ.WorkItem AS w
     WHERE w.Status = 'Leased'
       AND w.LeaseExpiresAt > @Now
       AND EXISTS (SELECT 1
                     FROM integ.WorkItemAttempt AS a
                     JOIN integ.ProcessRun      AS r ON r.RunId = a.RunId
                    WHERE a.WorkItemId = w.WorkItemId
                      AND a.AttemptNo  = w.AttemptCount
                      AND a.EndedAt IS NULL
                      AND (   r.EndedAt IS NOT NULL
                           OR r.HeartbeatAt < DATEADD(SECOND, -@StaleAfterSeconds, @Now)));

    SET @Released = @@ROWCOUNT;
END;
GO

-- [script] 9.1a Demo target + adapter
IF SCHEMA_ID('omsi_demo') IS NULL EXEC ('CREATE SCHEMA omsi_demo');
GO
CREATE TABLE omsi_demo.ShipmentInbound
(
    InboundId       bigint IDENTITY(1,1) PRIMARY KEY,
    IdempotencyKey  nvarchar(200) NOT NULL CONSTRAINT UQ_SI_Idem UNIQUE,
    OrderingKey     nvarchar(200) NOT NULL,
    PayloadJson     nvarchar(max) NULL,
    ReceivedAt      datetime2(3)  NOT NULL DEFAULT (SYSUTCDATETIME())
);
GO
CREATE OR ALTER PROCEDURE integ.usp_Adapter_OMSI_ShipmentUpsert
    @WorkItemId    bigint,
    @WasDuplicate  bit = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- Must run INSIDE the caller's transaction (the dispatcher opens it).
    IF @@TRANCOUNT = 0 THROW 52040, 'Adapter must be called inside the dispatcher transaction.', 1;

    INSERT omsi_demo.ShipmentInbound (IdempotencyKey, OrderingKey, PayloadJson)
    SELECT w.IdempotencyKey, w.OrderingKey, w.PayloadJson
      FROM integ.WorkItem AS w
     WHERE w.WorkItemId = @WorkItemId
       AND NOT EXISTS (SELECT 1 FROM omsi_demo.ShipmentInbound AS s WITH (UPDLOCK, HOLDLOCK)
                        WHERE s.IdempotencyKey = w.IdempotencyKey);

    SET @WasDuplicate = IIF(@@ROWCOUNT = 0, 1, 0);
END;
GO

-- [script] 9.1b usp_Dispatch_SameServer
CREATE OR ALTER PROCEDURE integ.usp_Dispatch_SameServer
    @ProcessName   nvarchar(100) = N'Dispatch',
    @TargetSystem  varchar(30)   = 'OMSI',
    @BatchSize     int           = 50,
    @LeaseSeconds  int           = 300
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RunId bigint, @LeaseOwner nvarchar(128), @Claimed int;
    EXEC integ.usp_Run_Start @ProcessName, @RunId OUTPUT;
    SET @LeaseOwner = CONCAT(@ProcessName, N'#', @RunId);          -- unique per run (single-threaded loop)

    BEGIN TRY
        -- 1. CLAIM ---------------------------------------------------------------------
        EXEC integ.usp_WorkItem_Claim
             @RunId = @RunId, @LeaseOwner = @LeaseOwner, @BatchSize = @BatchSize,
             @LeaseSeconds = @LeaseSeconds, @TargetSystem = @TargetSystem,
             @ReturnRows = 0, @ClaimedCount = @Claimed OUTPUT;

        -- My cards, in claim order. AttemptNo is my fencing token for each card.
        DECLARE @Work TABLE (Seq int IDENTITY(1,1) PRIMARY KEY, WorkItemId bigint, AttemptNo int, OperationCode varchar(50));
        INSERT @Work (WorkItemId, AttemptNo, OperationCode)
        SELECT WorkItemId, AttemptCount, OperationCode
          FROM integ.WorkItem
         WHERE Status = 'Leased' AND LeaseOwner = @LeaseOwner
         ORDER BY Priority, WorkItemId;

        DECLARE @Seq int = 0, @Id bigint, @Attempt int, @Op varchar(50),
                @Dup bit, @Err int, @Msg nvarchar(2000), @Rc int;

        WHILE 1 = 1
        BEGIN
            SELECT TOP (1) @Seq = Seq, @Id = WorkItemId, @Attempt = AttemptNo, @Op = OperationCode
              FROM @Work WHERE Seq > @Seq ORDER BY Seq;
            IF @@ROWCOUNT = 0 BREAK;

            BEGIN TRY
                -- 2. WORK + 3. REPORT in ONE transaction (same-server rule)
                BEGIN TRANSACTION;

                IF @Op = 'OMSI.ShipmentUpsert'
                    EXEC integ.usp_Adapter_OMSI_ShipmentUpsert @WorkItemId = @Id, @WasDuplicate = @Dup OUTPUT;
                ELSE
                    THROW 52041, 'No adapter registered for this operation.', 1;   -- Permanent

                EXEC integ.usp_WorkItem_Complete
                     @WorkItemId = @Id, @LeaseOwner = @LeaseOwner, @AttemptNo = @Attempt,
                     @WasDuplicate = @Dup;                     -- throws 52001 if I'm a zombie

                COMMIT;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0 ROLLBACK;                    -- undoes the OMSI write too
                SELECT @Err = ERROR_NUMBER(), @Msg = ERROR_MESSAGE();

                IF @Err IN (52001, 52002)
                BEGIN
                    -- Lease lost: someone else owns the card. Do NOT call Fail, do NOT retry.
                    PRINT CONCAT('Lease lost on WorkItem ', @Id, ' - skipped.');
                END
                ELSE
                BEGIN
                    DECLARE @Class varchar(20) = integ.fn_ClassifySqlError(@Err);
                    EXEC @Rc = integ.usp_WorkItem_Fail
                         @WorkItemId = @Id, @LeaseOwner = @LeaseOwner, @AttemptNo = @Attempt,
                         @ErrorClass = @Class, @ErrorCode = @Err, @ErrorMessage = @Msg;
                    -- @Rc: 0 RetryWait, 1 DeadLetter, -1 lease lost (nothing changed)
                END;
            END CATCH;

            IF @Seq % 10 = 0 EXEC integ.usp_Run_Heartbeat @RunId;
        END;

        EXEC integ.usp_Run_End @RunId, 'Succeeded';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        EXEC integ.usp_Run_End @RunId, 'Failed';
        THROW;            -- cards still Leased will be taken over after their due time
    END CATCH;
END;
GO

-- [script] 10 Operator procedures
CREATE OR ALTER PROCEDURE integ.usp_WorkItem_Retry
    @WorkItemId bigint,
    @Reason     nvarchar(300)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE integ.WorkItem
       SET Status          = 'Pending',
           NextAttemptAt   = SYSUTCDATETIME(),
           RetryBudgetBase = AttemptCount,         -- fresh retry budget
           AbandonCount    = 0,                    -- fresh crash budget (Fix D4)
           StatusReason    = LEFT(CONCAT(N'Manual retry: ', @Reason), 400)
     WHERE WorkItemId = @WorkItemId
       AND Status IN ('DeadLetter','RetryWait');
    IF @@ROWCOUNT = 0
        THROW 52010, 'Only DeadLetter or RetryWait work items can be retried.', 1;
END;
GO
CREATE OR ALTER PROCEDURE integ.usp_WorkItem_Cancel
    @WorkItemId bigint,
    @Reason     nvarchar(300)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE integ.WorkItem
       SET Status       = 'Cancelled',
           CompletedAt  = SYSUTCDATETIME(),
           StatusReason = LEFT(CONCAT(N'Cancelled: ', @Reason), 400)
     WHERE WorkItemId = @WorkItemId
       AND Status IN ('Pending','RetryWait','DeadLetter');   -- never a card someone is working on
    IF @@ROWCOUNT = 0
        THROW 52011, 'Only Pending, RetryWait or DeadLetter work items can be cancelled.', 1;
END;
GO

-- [script] 12 Monitoring
-- 12.1 Abandoned rate per operation, last 24 h  (> 1% -> review lease / batch size)
SELECT w.OperationCode,
       SUM(IIF(a.Outcome = 'Abandoned', 1, 0)) AS Abandoned,
       COUNT(*)                                AS Attempts,
       CAST(100.0 * SUM(IIF(a.Outcome = 'Abandoned', 1, 0)) / NULLIF(COUNT(*), 0) AS decimal(5,2)) AS AbandonedPct
  FROM integ.WorkItemAttempt AS a
  JOIN integ.WorkItem        AS w ON w.WorkItemId = a.WorkItemId
 WHERE a.StartedAt >= DATEADD(HOUR, -24, SYSUTCDATETIME())
 GROUP BY w.OperationCode
 ORDER BY AbandonedPct DESC;

-- 12.2 Leases expiring within 60 s or already overdue
SELECT WorkItemId, OperationCode, OrderingKey, LeaseOwner, AttemptCount, LeaseExpiresAt,
       DATEDIFF(SECOND, SYSUTCDATETIME(), LeaseExpiresAt) AS SecondsLeft
  FROM integ.WorkItem
 WHERE Status = 'Leased'
   AND LeaseExpiresAt < DATEADD(SECOND, 60, SYSUTCDATETIME())
 ORDER BY LeaseExpiresAt;

-- 12.3 Work duration vs lease (input for sizing; P99 per operation, last 7 days)
SELECT DISTINCT w.OperationCode,
       PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY DATEDIFF(MILLISECOND, a.StartedAt, a.EndedAt))
           OVER (PARTITION BY w.OperationCode) AS P99Ms,
       MAX(DATEDIFF(MILLISECOND, a.StartedAt, a.EndedAt)) OVER (PARTITION BY w.OperationCode) AS MaxMs
  FROM integ.WorkItemAttempt AS a
  JOIN integ.WorkItem        AS w ON w.WorkItemId = a.WorkItemId
 WHERE a.EndedAt IS NOT NULL AND a.Outcome <> 'Abandoned'
   AND a.StartedAt >= DATEADD(DAY, -7, SYSUTCDATETIME());

-- 12.4 Poison suspects and dead letters that block later cards of the same object
SELECT d.WorkItemId, d.OperationCode, d.OrderingKey, d.StatusReason, d.AttemptCount,
       (SELECT COUNT(*) FROM integ.WorkItem AS f
         WHERE f.OrderingKey = d.OrderingKey AND f.TargetSystem = d.TargetSystem
           AND f.WorkItemId > d.WorkItemId AND f.Status IN ('Pending','RetryWait')) AS BlockedFollowers
  FROM integ.WorkItem AS d
 WHERE d.Status = 'DeadLetter'
 ORDER BY BlockedFollowers DESC, d.WorkItemId;

-- 12.5 Retry backlog: what is waiting, and until when
SELECT OperationCode, COUNT(*) AS Waiting, MIN(NextAttemptAt) AS NextDue, MAX(AttemptCount) AS MaxAttempts
  FROM integ.WorkItem
 WHERE Status = 'RetryWait'
 GROUP BY OperationCode;
GO

-- [script] 13.1 Test seed (test DB only)
DECLARE @i int = 1, @id bigint;
WHILE @i <= 400
BEGIN
    EXEC integ.usp_WorkItem_Enqueue
         @OperationCode = 'OMSI.ShipmentUpsert', @TargetSystem = 'OMSI',
         @EntityType = 'Shipment', @SourceKey = @i, @SourceRevision = 1,
         @PayloadJson = N'{"test":true}', @WorkItemId = @id OUTPUT;
    SET @i += 1;
END;
GO
