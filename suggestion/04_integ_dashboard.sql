/* =====================================================================
   OMSI Integration Ledger - reference design (part 4 of 4)
   BACKLOG DASHBOARD: views (read model for Power BI / SSRS / Grafana),
   alert evaluation, trend snapshots, retention.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* 1. Backlog by operation and status, with SLA breach counts --------- */
CREATE OR ALTER VIEW integ.vw_Backlog
AS
SELECT w.TargetSystem, w.OperationCode, o.Name AS OperationName, w.Status,
       COUNT(*)                                                         AS ItemCount,
       MAX(DATEDIFF(MINUTE, w.CreatedAt, SYSDATETIME()))                AS OldestAgeMinutes,
       SUM(IIF(DATEDIFF(MINUTE, w.CreatedAt, SYSDATETIME()) > s.MaxPendingMinutes, 1, 0)) AS SlaBreaches,
       s.MaxPendingMinutes
  FROM integ.WorkItem w
  JOIN integ.OperationCatalog o ON o.OperationCode = w.OperationCode
  LEFT JOIN integ.SlaThreshold s ON s.OperationCode = w.OperationCode
 WHERE w.Status IN ('Pending','Leased','RetryWait','DeadLetter')
 GROUP BY w.TargetSystem, w.OperationCode, o.Name, w.Status, s.MaxPendingMinutes;
GO

/* 2. Sent to OMSI but not acknowledged - replaces ispOrphanOperationsMonitor
      and ispUnacknowldgedMessagesMonitor WITHOUT touching vendor flags.
      Diagnoses WHERE it is stuck: not picked up vs picked up/no reply. --- */
CREATE OR ALTER VIEW integ.vw_AwaitingAck
AS
SELECT w.WorkItemId, w.OperationCode, o.Name AS OperationName, w.OrderingKey, w.ExternalRef AS OmsiOperationId,
       w.DispatchedAt, DATEDIFF(MINUTE, w.DispatchedAt, SYSDATETIME()) AS MinutesWaiting, s.MaxAckMinutes,
       CASE WHEN op.operation_id IS NULL THEN 'Missing in OMSI'
            WHEN op.is_ready = 0        THEN 'Not released (is_ready = 0)'
            WHEN op.is_read  = 0        THEN 'Not picked up by OMSI connector'
            ELSE                             'Picked up - no response yet' END AS Diagnosis
  FROM integ.WorkItem w
  JOIN integ.OperationCatalog o ON o.OperationCode = w.OperationCode
  LEFT JOIN integ.SlaThreshold s ON s.OperationCode = w.OperationCode
  LEFT JOIN omsi_adp.operation op ON op.operation_id = TRY_CONVERT(decimal(18,0), w.ExternalRef)
 WHERE w.Status = 'Dispatched' AND w.TargetSystem = 'OMSI';
GO

/* 3. Dead letters with business meaning, owner, and what they block ---- */
CREATE OR ALTER VIEW integ.vw_DeadLetter
AS
SELECT w.WorkItemId, w.TargetSystem, w.OperationCode, o.Name AS OperationName, w.OrderingKey,
       w.AttemptCount, w.LastErrorClass, w.LastErrorMessage, w.StatusReason,
       ec.BusinessMeaning, ec.ResolutionHint, ec.OwnerTeam,
       w.CreatedAt, DATEDIFF(MINUTE, w.CreatedAt, SYSDATETIME()) AS AgeMinutes,
       (SELECT COUNT(*) FROM integ.WorkItem f
         WHERE f.OrderingKey = w.OrderingKey AND f.TargetSystem = w.TargetSystem
           AND f.WorkItemId > w.WorkItemId AND f.Status IN ('Pending','RetryWait')) AS BlockedFollowers
  FROM integ.WorkItem w
  JOIN integ.OperationCatalog o ON o.OperationCode = w.OperationCode
  LEFT JOIN integ.ErrorCatalog ec ON ec.ErrorCatalogId = w.LastErrorCatalogId
 WHERE w.Status = 'DeadLetter';
GO

/* 4. Is each job alive? (SSIS stopped = silent outage today) ---------- */
CREATE OR ALTER VIEW integ.vw_ProcessHealth
AS
SELECT r.ProcessName, r.RunId AS LastRunId, r.Status AS LastStatus, r.StartedAt AS LastStartedAt,
       r.HeartbeatAt AS LastHeartbeatAt, DATEDIFF(MINUTE, r.HeartbeatAt, SYSDATETIME()) AS MinutesSinceHeartbeat,
       r.ItemsClaimed, r.ItemsSucceeded, r.ItemsFailed,
       (SELECT COUNT(*) FROM integ.ProcessRun x
         WHERE x.ProcessName = r.ProcessName AND x.Status = 'Failed'
           AND x.StartedAt > DATEADD(HOUR, -24, SYSDATETIME())) AS FailedRuns24h
  FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY ProcessName ORDER BY StartedAt DESC) AS rn
          FROM integ.ProcessRun) r
 WHERE r.rn = 1;
GO

/* 5. Business view: entities stuck in a lifecycle state too long ------- */
CREATE OR ALTER VIEW integ.vw_EntityStuck
AS
SELECT be.EntityType, be.SourceKey, be.CurrentState, be.StateChangedAt,
       DATEDIFF(MINUTE, be.StateChangedAt, SYSDATETIME()) AS MinutesInState,
       ls.MaxMinutesInState, ls.Severity
  FROM integ.BusinessEntity be
  JOIN integ.LifecycleSla ls ON ls.EntityType = be.EntityType AND ls.State = be.CurrentState
 WHERE DATEDIFF(MINUTE, be.StateChangedAt, SYSDATETIME()) > ls.MaxMinutesInState;
GO

/* 6. Business view: out-of-sequence lifecycle events (data quality) ---- */
CREATE OR ALTER VIEW integ.vw_LifecycleAnomalies
AS
SELECT h.StateHistoryId, be.EntityType, be.SourceKey, h.FromState, h.ToState, h.TriggerKind, h.TriggerId, h.ChangedAt
  FROM integ.EntityStateHistory h
  JOIN integ.BusinessEntity be ON be.EntityId = h.EntityId
 WHERE h.IsExpected = 0;
GO

/* 7. Throughput and end-to-end latency, last 24h ---------------------- */
CREATE OR ALTER VIEW integ.vw_Throughput24h
AS
SELECT DISTINCT w.TargetSystem, w.OperationCode,
       COUNT(*) OVER (PARTITION BY w.TargetSystem, w.OperationCode) AS Completed,
       AVG(CAST(DATEDIFF(SECOND, w.CreatedAt, w.CompletedAt) AS float)) OVER (PARTITION BY w.TargetSystem, w.OperationCode) / 60.0 AS AvgMinutes,
       PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY DATEDIFF(SECOND, w.CreatedAt, w.CompletedAt))
           OVER (PARTITION BY w.TargetSystem, w.OperationCode) / 60.0 AS P95Minutes
  FROM integ.WorkItem w
 WHERE w.Status = 'Succeeded' AND w.CompletedAt > DATEADD(HOUR, -24, SYSDATETIME());
GO

/* 8. Full trace of one business entity (support / BA drill-down) ------ */
CREATE OR ALTER VIEW integ.vw_EntityTimeline
AS
SELECT be.EntityType, be.SourceKey, h.ChangedAt AS At, 'STATE' AS Kind,
       CONCAT(COALESCE(h.FromState, '(new)'), ' -> ', h.ToState, IIF(h.IsExpected = 0, ' [UNEXPECTED]', '')) AS Detail,
       CAST(NULL AS bigint) AS WorkItemId
  FROM integ.EntityStateHistory h JOIN integ.BusinessEntity be ON be.EntityId = h.EntityId
UNION ALL
SELECT be.EntityType, be.SourceKey, e.CreatedAt, 'EVENT', e.EventType, NULL
  FROM integ.OutboxEvent e JOIN integ.BusinessEntity be ON be.EntityId = e.EntityId
UNION ALL
SELECT be.EntityType, be.SourceKey, a.StartedAt, 'ATTEMPT',
       CONCAT('op ', w.OperationCode, ' attempt ', a.AttemptNo, ': ', COALESCE(a.Outcome, 'InProgress'),
              IIF(a.ErrorMessage IS NULL, '', CONCAT(' - ', a.ErrorClass, ': ', LEFT(a.ErrorMessage, 200)))),
       w.WorkItemId
  FROM integ.WorkItemAttempt a
  JOIN integ.WorkItem w ON w.WorkItemId = a.WorkItemId
  JOIN integ.OutboxEvent e ON e.EventId = w.EventId
  JOIN integ.BusinessEntity be ON be.EntityId = e.EntityId
UNION ALL
SELECT be.EntityType, be.SourceKey, i.ReceivedAt, 'INBOX',
       CONCAT(i.SourceSystem, ' msg ', i.SourceMessageId, ' type ', i.MessageType, ' -> ', i.Status), NULL
  FROM integ.InboxMessage i JOIN integ.BusinessEntity be ON be.EntityId = i.EntityId;
GO

/* ---------------------------------------------------------------------
   MONITOR: run every 5 min (SQL Agent). Snapshots backlog, raises and
   auto-resolves deduplicated alerts, returns alerts not yet notified
   (caller sends ONE mail per new alert, not one per poll).
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE integ.usp_Monitor_Evaluate
    @ProcessStaleMinutes int = 30, @MarkNotified bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now datetime2(0) = SYSDATETIME();
    DECLARE @Current TABLE (AlertKey nvarchar(200) PRIMARY KEY, Category varchar(30), Severity varchar(10), Message nvarchar(2000));

    INSERT integ.BacklogSnapshot (SnapshotAt, TargetSystem, OperationCode, Status, ItemCount, OldestAgeMinutes)
    SELECT @Now, TargetSystem, OperationCode, Status, SUM(ItemCount), MAX(OldestAgeMinutes)
      FROM integ.vw_Backlog GROUP BY TargetSystem, OperationCode, Status;

    INSERT @Current
    SELECT CONCAT(N'SLA:PENDING:', TargetSystem, N':', OperationCode), 'SlaBreach', 'Warning',
           CONCAT(SUM(SlaBreaches), N' ', MAX(OperationName), N' item(s) older than ', MAX(MaxPendingMinutes), N' min (oldest ', MAX(OldestAgeMinutes), N' min)')
      FROM integ.vw_Backlog WHERE Status IN ('Pending','RetryWait','Leased')
     GROUP BY TargetSystem, OperationCode HAVING SUM(SlaBreaches) > 0;

    INSERT @Current
    SELECT CONCAT(N'SLA:ACK:', OperationCode), 'AckOverdue', 'Critical',
           CONCAT(COUNT(*), N' ', MAX(OperationName), N' operation(s) unacknowledged by OMSI; worst ',
                  MAX(MinutesWaiting), N' min; ', MAX(Diagnosis))
      FROM integ.vw_AwaitingAck WHERE MinutesWaiting > MaxAckMinutes
     GROUP BY OperationCode;

    INSERT @Current
    SELECT CONCAT(N'STUCK:', EntityType, N':', CurrentState), 'EntityStuck', MAX(Severity),
           CONCAT(COUNT(*), N' ', EntityType, N'(s) in state ', CurrentState, N' longer than ', MAX(MaxMinutesInState), N' min')
      FROM integ.vw_EntityStuck GROUP BY EntityType, CurrentState;

    INSERT @Current
    SELECT CONCAT(N'PROCESS:STALE:', ProcessName), 'ProcessDown', 'Critical',
           CONCAT(ProcessName, N' has not reported for ', MinutesSinceHeartbeat, N' min (last status ', LastStatus, N')')
      FROM integ.vw_ProcessHealth WHERE MinutesSinceHeartbeat > @ProcessStaleMinutes;

    -- raise / refresh
    DECLARE @k nvarchar(200), @c varchar(30), @s varchar(10), @m nvarchar(2000);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT AlertKey, Category, Severity, Message FROM @Current;
    OPEN cur; FETCH NEXT FROM cur INTO @k, @c, @s, @m;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC integ.usp_Alert_Raise @k, @c, @s, @m;
        FETCH NEXT FROM cur INTO @k, @c, @s, @m;
    END;
    CLOSE cur; DEALLOCATE cur;

    -- auto-resolve condition-based alerts that cleared (dead letters resolve via operator action)
    UPDATE a SET ResolvedAt = @Now
      FROM integ.Alert a
     WHERE a.ResolvedAt IS NULL
       AND a.Category IN ('SlaBreach','AckOverdue','EntityStuck','ProcessDown')
       AND NOT EXISTS (SELECT 1 FROM @Current c WHERE c.AlertKey = a.AlertKey);
    UPDATE a SET ResolvedAt = @Now
      FROM integ.Alert a
     WHERE a.ResolvedAt IS NULL AND a.Category = 'DeadLetter'
       AND NOT EXISTS (SELECT 1 FROM integ.WorkItem w
                        WHERE a.AlertKey = CONCAT(N'DEADLETTER:WI:', w.WorkItemId) AND w.Status = 'DeadLetter');

    -- new alerts to notify (exactly once)
    DECLARE @ToNotify TABLE (AlertId bigint);
    INSERT @ToNotify SELECT AlertId FROM integ.Alert WHERE ResolvedAt IS NULL AND NotifiedAt IS NULL;
    SELECT a.AlertId, a.Severity, a.Category, a.AlertKey, a.Message, a.FirstSeenAt, a.Occurrences
      FROM integ.Alert a JOIN @ToNotify n ON n.AlertId = a.AlertId
     ORDER BY CASE a.Severity WHEN 'Critical' THEN 1 WHEN 'Warning' THEN 2 ELSE 3 END, a.AlertId;
    IF @MarkNotified = 1
        UPDATE a SET NotifiedAt = @Now FROM integ.Alert a JOIN @ToNotify n ON n.AlertId = a.AlertId;
END;
GO

/* ---------------------------------------------------------------------
   RETENTION: purge completed history in small batches; never purge open,
   dead-lettered, or not-yet-processed records.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE integ.usp_Ledger_Purge
    @RetainDays int = 180, @BatchSize int = 4000, @Deleted int = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Cutoff datetime2(3) = DATEADD(DAY, -ABS(@RetainDays), SYSDATETIME()), @n int = 1;
    SET @Deleted = 0;
    CREATE TABLE #wi (WorkItemId bigint PRIMARY KEY);

    WHILE @n > 0
    BEGIN
        TRUNCATE TABLE #wi;
        INSERT #wi
        SELECT TOP (@BatchSize) w.WorkItemId FROM integ.WorkItem w
         WHERE w.Status IN ('Succeeded','Superseded','Cancelled') AND w.CompletedAt < @Cutoff
           AND NOT EXISTS (SELECT 1 FROM integ.WorkItem c
                            WHERE (c.ParentWorkItemId = w.WorkItemId OR c.SupersededById = w.WorkItemId)
                              AND c.Status NOT IN ('Succeeded','Superseded','Cancelled'));
        SET @n = @@ROWCOUNT;
        IF @n = 0 BREAK;

        BEGIN TRANSACTION;
        UPDATE integ.WorkItem SET SupersededById = NULL WHERE SupersededById IN (SELECT WorkItemId FROM #wi);
        UPDATE integ.WorkItem SET ParentWorkItemId = NULL WHERE ParentWorkItemId IN (SELECT WorkItemId FROM #wi);
        DELETE integ.WorkItemAttempt WHERE WorkItemId IN (SELECT WorkItemId FROM #wi);
        DELETE integ.OperatorAction  WHERE WorkItemId IN (SELECT WorkItemId FROM #wi);
        DELETE integ.WorkItem        WHERE WorkItemId IN (SELECT WorkItemId FROM #wi);
        COMMIT;
        SET @Deleted += @n;
    END;

    -- events / inbox messages no longer referenced by any work item
    DELETE TOP (@BatchSize) e FROM integ.OutboxEvent e
     WHERE e.CreatedAt < @Cutoff AND NOT EXISTS (SELECT 1 FROM integ.WorkItem w WHERE w.EventId = e.EventId);
    SET @Deleted += @@ROWCOUNT;
    DELETE TOP (@BatchSize) i FROM integ.InboxMessage i
     WHERE i.ReceivedAt < @Cutoff AND i.Status IN ('Processed','Ignored')
       AND NOT EXISTS (SELECT 1 FROM integ.WorkItem w WHERE w.InboxMessageId = i.InboxMessageId);
    SET @Deleted += @@ROWCOUNT;
    DELETE integ.BacklogSnapshot WHERE SnapshotAt < @Cutoff;
    DELETE integ.Alert WHERE ResolvedAt < @Cutoff;
END;
GO
