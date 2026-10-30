/* Mid-process failure isolation tests. Run after 00/01-05 on a test instance (fresh ledger). */
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @ok nvarchar(max) = N'{"shipmentNumber":0,"weightUom":"LB","stops":[{"seq":1,"isPickup":1},{"seq":2,"isPickup":0}]}';
DECLARE @bad nvarchar(max) = N'{"shipmentNumber":8000001,"weightUom":"LB","stops":[{"seq":1,"isPickup":1},{"seq":1,"isPickup":0}]}';
DECLARE @p nvarchar(max), @run bigint, @ops int, @r int;

/* T1: failure IN THE MIDDLE of the OMSI write (operation + shipment rows written, stop insert fails).
       Expect: whole OMSI write rolled back (no orphan rows), item dead-lettered as Data,
       later shipments in the SAME run still dispatched. */
SELECT @ops = COUNT(*) FROM OMSI.dbo.operation;
EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000001', @EventType='ShipmentReady', @NewState='Ready', @PayloadJson=@bad;
SET @p = REPLACE(@ok, ':0,', ':8000002,'); EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000002', @EventType='ShipmentReady', @NewState='Ready', @PayloadJson=@p;
SET @p = REPLACE(@ok, ':0,', ':8000003,'); EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000003', @EventType='ShipmentReady', @NewState='Ready', @PayloadJson=@p;
EXEC omsi_adp.usp_DispatchOutbound @ProcessName = N'T1', @MaxBatches = 1;
IF (SELECT Status FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000001') <> 'DeadLetter' THROW 61001, 'T1 failing shipment should be DeadLetter', 1;
IF (SELECT LastErrorClass FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000001') <> 'Data' THROW 61002, 'T1 duplicate stop must be Data, not Duplicate-success', 1;
IF (SELECT COUNT(*) FROM integ.WorkItem WHERE OrderingKey IN (N'Shipment:8000002', N'Shipment:8000003') AND Status = 'Dispatched') <> 2 THROW 61003, 'T1 other shipments blocked', 1;
IF (SELECT COUNT(*) FROM OMSI.dbo.operation) <> @ops + 2 THROW 61004, 'T1 orphan OMSI rows left by the failed shipment', 1;
IF (SELECT Status FROM integ.ProcessRun WHERE ProcessName = N'T1') <> 'Succeeded' THROW 61005, 'T1 run should complete', 1;

/* T2: error the adapter cannot catch in its own scope (missing adapter procedure, error 2812).
       Expect: recorded on that item only; run continues; other shipment dispatched. */
INSERT integ.OperationCatalog (OperationCode, Direction, TargetSystem, Name, EntityType, AdapterProcedure, DefaultPriority, RequiresAck)
VALUES (9990, 'OUT', 'OMSI', 'BrokenAdapterTest', 'Shipment', 'omsi_adp.usp_DoesNotExist', 1, 1);
INSERT integ.EventRoute (EventType, OperationCode) VALUES ('BrokenTest', 9990);
SET @p = REPLACE(@ok, ':0,', ':8000004,'); EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000004', @EventType='BrokenTest', @NewState='Ready', @PayloadJson=@p;
SET @p = REPLACE(@ok, ':0,', ':8000005,'); EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000005', @EventType='ShipmentReady', @NewState='Ready', @PayloadJson=@p;
EXEC omsi_adp.usp_DispatchOutbound @ProcessName = N'T2', @MaxBatches = 1;
IF (SELECT Status FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000004') NOT IN ('RetryWait','DeadLetter') THROW 61010, 'T2 broken item not recorded', 1;
IF (SELECT Status FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000005') <> 'Dispatched' THROW 61011, 'T2 other shipment blocked', 1;
IF (SELECT Status FROM integ.ProcessRun WHERE ProcessName = N'T2') <> 'Succeeded' THROW 61012, 'T2 run aborted', 1;

/* T3: worker dies mid-process (claimed, never completed - e.g. SSIS killed).
       Expect: other shipments proceed immediately; the abandoned one is reclaimed after lease expiry. */
SET @p = REPLACE(@ok, ':0,', ':8000006,'); EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000006', @EventType='ShipmentReady', @NewState='Ready', @PayloadJson=@p;
EXEC integ.usp_Run_Start N'T3-crashed', @run OUTPUT;
DECLARE @c TABLE (WorkItemId bigint, OperationCode int, OperationName varchar(60), TargetSystem varchar(20), AdapterProcedure sysname NULL,
                  OrderingKey nvarchar(100), IdempotencyKey nvarchar(200), AttemptCount int, PayloadJson nvarchar(max),
                  CorrelationId uniqueidentifier NULL, EntityType varchar(30) NULL, SourceKey nvarchar(100) NULL);
INSERT @c EXEC integ.usp_WorkItem_Claim @RunId = @run, @LeaseOwner = N'T3-crashed', @LeaseSeconds = 2, @TargetSystem = 'OMSI';
SET @p = REPLACE(@ok, ':0,', ':8000007,'); EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000007', @EventType='ShipmentReady', @NewState='Ready', @PayloadJson=@p;
EXEC omsi_adp.usp_DispatchOutbound @ProcessName = N'T3a', @MaxBatches = 1;
IF (SELECT Status FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000006') <> 'Leased' THROW 61020, 'T3 abandoned item should still be leased', 1;
IF (SELECT Status FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000007') <> 'Dispatched' THROW 61021, 'T3 other shipment blocked by abandoned lease', 1;
WAITFOR DELAY '00:00:03';
EXEC omsi_adp.usp_DispatchOutbound @ProcessName = N'T3b', @MaxBatches = 1;
IF (SELECT Status FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000006') <> 'Dispatched' THROW 61022, 'T3 abandoned item not reclaimed', 1;
IF NOT EXISTS (SELECT 1 FROM integ.WorkItemAttempt a JOIN integ.WorkItem w ON w.WorkItemId = a.WorkItemId
                WHERE w.OrderingKey = N'Shipment:8000006' AND a.Outcome = 'Abandoned') THROW 61023, 'T3 abandoned attempt not recorded', 1;

/* T4: create dead-lettered (bad data) + newer LumberTrack revision STILL bad.
       Expect: newest snapshot replaces the dead-lettered create and is sent AS the create;
       it fails again -> new dead letter with a new alert; the old alert is closed.
       A healthy shipment's modify is unaffected. */
DECLARE @oldCreate bigint = (SELECT WorkItemId FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000001' AND OperationCode = 100);
SET @p = REPLACE(@bad, '"isPickup":0', '"isPickup":0,"rev":2');
EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000001', @EventType='ShipmentModified', @PayloadJson=@p;
IF (SELECT Status FROM integ.WorkItem WHERE WorkItemId = @oldCreate) <> 'Superseded' THROW 61030, 'T4 dead-lettered create should be replaced', 1;
IF NOT EXISTS (SELECT 1 FROM integ.Alert WHERE AlertKey = CONCAT(N'DEADLETTER:WI:', @oldCreate) AND ResolvedAt IS NOT NULL) THROW 61031, 'T4 old alert should close', 1;
SET @p = REPLACE(REPLACE(@ok, ':0,', ':8000002,'), '"LB"', '"LBS"');
EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000002', @EventType='ShipmentModified', @PayloadJson=@p;
EXEC omsi_adp.usp_DispatchOutbound @ProcessName = N'T4', @MaxBatches = 1;
DECLARE @t4 bigint = (SELECT MAX(WorkItemId) FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000001');
IF (SELECT CONCAT(OperationCode, ':', Status, ':', LastErrorClass) FROM integ.WorkItem WHERE WorkItemId = @t4) <> '100:DeadLetter:Data' THROW 61032, 'T4 still-bad snapshot should dead-letter as a create', 1;
IF NOT EXISTS (SELECT 1 FROM integ.Alert WHERE AlertKey = CONCAT(N'DEADLETTER:WI:', @t4) AND ResolvedAt IS NULL) THROW 61033, 'T4 new alert expected', 1;
IF (SELECT Status FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000002' AND OperationCode = 200) <> 'Dispatched' THROW 61034, 'T4 healthy shipment modify blocked', 1;

/* T5: user fixes the shipment in LumberTrack -> next revision replaces the dead letter and goes through as the create. */
SET @p = REPLACE(@ok, ':0,', ':8000001,');
EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000001', @EventType='ShipmentModified', @PayloadJson=@p;
EXEC omsi_adp.usp_DispatchOutbound @ProcessName = N'T5', @MaxBatches = 1;
IF (SELECT Status FROM integ.WorkItem WHERE WorkItemId = @t4) <> 'Superseded' THROW 61040, 'T5 dead letter should be replaced', 1;
IF (SELECT CONCAT(OperationCode, ':', Status) FROM integ.WorkItem
     WHERE WorkItemId = (SELECT MAX(WorkItemId) FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000001')) <> '100:Dispatched' THROW 61041, 'T5 fixed snapshot should be dispatched as create', 1;
IF EXISTS (SELECT 1 FROM integ.vw_DeadLetter WHERE OrderingKey = N'Shipment:8000001') THROW 61042, 'T5 no dead letters should remain', 1;

/* T6: create already delivered; a MODIFY dead-letters; newer revision replaces that modify and is sent as a modify. */
SET @p = REPLACE(@bad, '8000001', '8000003');
EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000003', @EventType='ShipmentModified', @PayloadJson=@p;
EXEC omsi_adp.usp_DispatchOutbound @ProcessName = N'T6a', @MaxBatches = 1;
DECLARE @badMod bigint = (SELECT WorkItemId FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000003' AND OperationCode = 200);
IF (SELECT Status FROM integ.WorkItem WHERE WorkItemId = @badMod) <> 'DeadLetter' THROW 61050, 'T6 bad modify should dead-letter', 1;
SET @p = REPLACE(REPLACE(@ok, ':0,', ':8000003,'), '"isPickup":0', '"isPickup":0,"rev":3');
EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000003', @EventType='ShipmentModified', @PayloadJson=@p;
EXEC omsi_adp.usp_DispatchOutbound @ProcessName = N'T6b', @MaxBatches = 1;
IF (SELECT Status FROM integ.WorkItem WHERE WorkItemId = @badMod) <> 'Superseded' THROW 61051, 'T6 dead-lettered modify should be replaced', 1;
IF (SELECT CONCAT(OperationCode, ':', Status) FROM integ.WorkItem
     WHERE WorkItemId = (SELECT MAX(WorkItemId) FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000003')) <> '200:Dispatched' THROW 61052, 'T6 newer modify should be sent as modify (create was delivered)', 1;

/* T7: Event semantics - freight payments are distinct facts: a newer one NEVER replaces a dead-lettered one. */
EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000005', @EventType='FreightInvoiceApproved', @PayloadJson=N'{"invoice":"INV-1","amount":1200.00}', @SuppressIfUnchanged=0;
EXEC omsi_adp.usp_DispatchOutbound @ProcessName = N'T7', @MaxBatches = 1;   -- 5800 has no adapter yet -> Contract dead letter
EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000005', @EventType='FreightInvoiceApproved', @PayloadJson=N'{"invoice":"INV-2","amount":300.00}', @SuppressIfUnchanged=0;
IF (SELECT COUNT(*) FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000005' AND OperationCode = 5800 AND Status = 'DeadLetter') <> 1
   OR (SELECT COUNT(*) FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000005' AND OperationCode = 5800 AND Status = 'Pending') <> 1
    THROW 61060, 'T7 event must not be replaced', 1;
IF (SELECT BlockedFollowers FROM integ.vw_DeadLetter WHERE OrderingKey = N'Shipment:8000005') <> 1 THROW 61061, 'T7 follower should wait', 1;

/* T8: LumberTrack revision guard - a late, OLDER revision never replaces a newer one. */
SET @p = REPLACE(REPLACE(@ok, ':0,', ':8000007,'), '"isPickup":0', '"isPickup":0,"rev":20');
EXEC @r = integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000007', @EventType='ShipmentModified', @PayloadJson=@p, @SourceChangeVersion=20;
IF @r <> 0 THROW 61070, 'T8 rev 20 should publish', 1;
SET @p = REPLACE(REPLACE(@ok, ':0,', ':8000007,'), '"isPickup":0', '"isPickup":0,"rev":19');
EXEC @r = integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'8000007', @EventType='ShipmentModified', @PayloadJson=@p, @SourceChangeVersion=19;
IF @r <> 3 THROW 61071, 'T8 older revision should be rejected as stale', 1;
IF (SELECT COUNT(*) FROM integ.WorkItem WHERE OrderingKey = N'Shipment:8000007' AND OperationCode = 200) <> 1 THROW 61072, 'T8 stale revision must not create work', 1;

PRINT 'ALL MID-PROCESS FAILURE TESTS PASSED';
SELECT OrderingKey, OperationCode, Status, AttemptCount, LastErrorClass, LEFT(LastErrorMessage, 90) AS LastError
  FROM integ.WorkItem WHERE OrderingKey LIKE N'Shipment:800000%' ORDER BY WorkItemId;
