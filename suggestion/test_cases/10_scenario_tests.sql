SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @r int, @ev bigint, @run bigint, @n int, @op decimal(18,0), @wi bigint, @msg nvarchar(400);

-- FK check on mock OMSI
IF (SELECT COUNT(*) FROM OMSI.sys.foreign_keys) < 3 THROW 60000, 'mock OMSI FKs missing', 1;

/* ---- S1: create still unsent + newer revision -> newest snapshot is promoted to the create ---- */
DECLARE @p1 nvarchar(max) = N'{"shipmentNumber":4171753,"equipmentTypeCode":"V53","shipperRef":"SO-1","weightUom":"LBS","currency":"CAD","readyDate":"2026-10-30T08:00:00",
 "stops":[{"seq":1,"isPickup":1,"company":"Mill A","city":"Grand Forks","province":"BC","postal":"V0H1H0","country":"CA","earlyDate":"2026-10-31T08:00:00"},
          {"seq":2,"isPickup":0,"company":"Cust B","city":"Seattle","province":"WA","postal":"98101","country":"US","earlyDate":"2026-11-01T08:00:00"}]}';
EXEC @r = integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'4171753', @EventType='ShipmentReady', @NewState='Ready', @PayloadJson=@p1;
IF @r <> 0 THROW 60001, 'S1 publish new', 1;
DECLARE @p2 nvarchar(max) = REPLACE(@p1, 'SO-1', 'SO-2');
DECLARE @p3 nvarchar(max) = REPLACE(@p1, 'SO-1', 'SO-3');
DECLARE @p4 nvarchar(max) = REPLACE(@p1, 'SO-1', 'SO-4');
EXEC @r = integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'4171753', @EventType='ShipmentModified', @PayloadJson=@p2;
IF (SELECT COUNT(*) FROM integ.WorkItem WHERE OrderingKey = N'Shipment:4171753' AND OperationCode = 100 AND Status = 'Superseded') <> 1
   OR (SELECT COUNT(*) FROM integ.WorkItem WHERE OrderingKey = N'Shipment:4171753' AND OperationCode = 100 AND Status = 'Pending') <> 1
   OR EXISTS (SELECT 1 FROM integ.WorkItem WHERE OrderingKey = N'Shipment:4171753' AND OperationCode = 200)
    THROW 60003, 'S1 newer revision should be promoted to the (unsent) create', 1;

/* ---- S2: dispatch the create (latest snapshot), then modifies coalesce; identical one suppressed ---- */
EXEC omsi_adp.usp_DispatchOutbound @MaxBatches = 1;
IF (SELECT COUNT(*) FROM integ.WorkItem WHERE OperationCode = 100 AND Status = 'Dispatched') <> 1 THROW 60010, 'S2 new not dispatched', 1;
SELECT @op = TRY_CONVERT(decimal(18,0), ExternalRef) FROM integ.WorkItem WHERE OperationCode = 100 AND ExternalRef IS NOT NULL;
IF (SELECT shipper_ref_number FROM OMSI.dbo.shipment WHERE operation_id = @op) <> N'SO-2' THROW 60011, 'S2 create must carry the newest snapshot', 1;
IF NOT EXISTS (SELECT 1 FROM OMSI.dbo.operation WHERE operation_id = @op AND is_ready = 1) THROW 60012, 'S2 is_ready', 1;
IF (SELECT weight_uom FROM OMSI.dbo.shipment WHERE operation_id = @op) <> N'LB' THROW 60013, 'S2 UOM mapping', 1;
IF (SELECT COUNT(*) FROM OMSI.dbo.stop WHERE operation_id = @op) <> 2 THROW 60014, 'S2 stops', 1;
EXEC @r = integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'4171753', @EventType='ShipmentModified', @PayloadJson=@p3;
EXEC @r = integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'4171753', @EventType='ShipmentModified', @PayloadJson=@p4;
EXEC @r = integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'4171753', @EventType='ShipmentModified', @PayloadJson=@p4;
IF @r <> 2 THROW 60002, 'S2 unchanged payload should be suppressed', 1;
IF (SELECT COUNT(*) FROM integ.WorkItem WHERE OperationCode = 200 AND Status = 'Superseded') <> 1
   OR (SELECT COUNT(*) FROM integ.WorkItem WHERE OperationCode = 200 AND Status = 'Pending') <> 1
    THROW 60015, 'S2 modifies after delivered create must coalesce, not promote', 1;

/* ---- S3: modify fails with deadlock -> RetryWait with backoff, then succeeds ---- */
EXEC integ.usp_Run_Start N'TEST', @run OUTPUT;
DECLARE @c TABLE (WorkItemId bigint, OperationCode int, OperationName varchar(60), TargetSystem varchar(20), AdapterProcedure sysname NULL,
                  OrderingKey nvarchar(100), IdempotencyKey nvarchar(200), AttemptCount int, PayloadJson nvarchar(max),
                  CorrelationId uniqueidentifier NULL, EntityType varchar(30) NULL, SourceKey nvarchar(100) NULL);
INSERT @c EXEC integ.usp_WorkItem_Claim @RunId = @run, @LeaseOwner = N'TEST', @TargetSystem = 'OMSI';
SELECT @wi = WorkItemId FROM @c WHERE OperationCode = 200;
IF @wi IS NULL THROW 60020, 'S3 modify not claimable after new dispatched', 1;
EXEC @r = integ.usp_WorkItem_Fail @WorkItemId = @wi, @LeaseOwner = N'TEST', @ErrorNumber = 1205, @ErrorMessage = N'Transaction was deadlocked';
IF @r <> 0 OR (SELECT Status FROM integ.WorkItem WHERE WorkItemId = @wi) <> 'RetryWait' THROW 60021, 'S3 retrywait', 1;
IF (SELECT NextAttemptAt FROM integ.WorkItem WHERE WorkItemId = @wi) <= SYSDATETIME() THROW 60022, 'S3 backoff', 1;
UPDATE integ.WorkItem SET NextAttemptAt = SYSDATETIME() WHERE WorkItemId = @wi;   -- fast-forward time
EXEC omsi_adp.usp_DispatchOutbound @MaxBatches = 1;
IF (SELECT Status FROM integ.WorkItem WHERE WorkItemId = @wi) <> 'Dispatched' THROW 60023, 'S3 retry dispatch', 1;
IF (SELECT COUNT(*) FROM integ.WorkItemAttempt WHERE WorkItemId = @wi) <> 2 THROW 60024, 'S3 attempts', 1;

/* ---- S4: OMSI acknowledgement + ready-to-pay inbound -> lifecycle + ERP follow-up ---- */
INSERT OMSI.dbo.log_entry (operation_id, operation, result_code, is_read, process_time) VALUES (@op, 100, 0, 0, GETDATE());
INSERT OMSI.dbo.shipment_log_entry (log_entry_id, client_key_1) VALUES (SCOPE_IDENTITY(), N'4171753');
INSERT OMSI.dbo.log_entry (operation_id, operation, result_code, is_read, process_time) VALUES (NULL, 6800, 0, 0, GETDATE());
INSERT OMSI.dbo.shipment_log_entry (log_entry_id, client_key_1) VALUES (SCOPE_IDENTITY(), N'4171753');
EXEC omsi_adp.usp_HarvestInbound @Harvested = @n OUTPUT;   IF @n <> 2 THROW 60030, 'S4 harvest', 1;
EXEC omsi_adp.usp_HarvestInbound @Harvested = @n OUTPUT;   IF @n <> 0 THROW 60031, 'S4 harvest must be idempotent', 1;
EXEC omsi_adp.usp_ProcessInbound @Processed = @n OUTPUT;   IF @n <> 2 THROW 60032, 'S4 process', 1;
IF (SELECT Status FROM integ.WorkItem WHERE OperationCode = 100 AND ExternalRef IS NOT NULL) <> 'Succeeded' THROW 60033, 'S4 ack correlation', 1;
IF (SELECT CurrentState FROM integ.BusinessEntity WHERE SourceKey = N'4171753') <> 'ReadyToPay' THROW 60034, 'S4 lifecycle', 1;
IF NOT EXISTS (SELECT 1 FROM integ.vw_LifecycleAnomalies WHERE SourceKey = N'4171753' AND ToState = 'ReadyToPay') THROW 60035, 'S4 anomaly flag', 1;
IF EXISTS (SELECT 1 FROM OMSI.dbo.log_entry WHERE is_read = 0) THROW 60036, 'S4 is_read', 1;

/* ---- S5: ERP API follow-up; API answers 409 -> treated as success (idempotent) ---- */
DELETE @c;
INSERT @c EXEC integ.usp_WorkItem_Claim @RunId = @run, @LeaseOwner = N'TEST', @TargetSystem = 'LT_API';
SELECT @wi = WorkItemId FROM @c WHERE OperationCode = 9102;
IF @wi IS NULL THROW 60040, 'S5 follow-up 9102 not created', 1;
EXEC @r = integ.usp_WorkItem_Fail @WorkItemId = @wi, @LeaseOwner = N'TEST', @ErrorMessage = N'HTTP 409 Conflict: already marked';
IF @r <> 2 OR (SELECT Status FROM integ.WorkItem WHERE WorkItemId = @wi) <> 'Succeeded' THROW 60041, 'S5 duplicate as success', 1;

/* ---- S6: bad UOM -> Mapping dead letter blocks ONLY its own shipment; cancel cleans up ---- */
DECLARE @b1 nvarchar(max) = REPLACE(REPLACE(@p1, '4171753', '5000001'), '"LBS"', '"XX"');
EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'5000001', @EventType='ShipmentReady', @NewState='Ready', @PayloadJson=@b1;
DECLARE @g1 nvarchar(max) = REPLACE(@p1, '4171753', '5000002');
EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'5000002', @EventType='ShipmentReady', @NewState='Ready', @PayloadJson=@g1;
EXEC omsi_adp.usp_DispatchOutbound @MaxBatches = 1;
IF NOT EXISTS (SELECT 1 FROM integ.vw_DeadLetter WHERE OrderingKey = N'Shipment:5000001' AND LastErrorClass = 'Mapping' AND OwnerTeam = N'Integration BA') THROW 60050, 'S6 mapping dead letter', 1;
IF (SELECT Status FROM integ.WorkItem w JOIN integ.OutboxEvent e ON e.EventId = w.EventId JOIN integ.BusinessEntity b ON b.EntityId = e.EntityId WHERE b.SourceKey = N'5000002') <> 'Dispatched'
    THROW 60051, 'S6 other shipment must not be blocked', 1;
DECLARE @b2 nvarchar(max) = REPLACE(@b1, 'SO-1', 'SO-9');
EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'5000001', @EventType='ShipmentModified', @PayloadJson=@b2;
-- newer revision replaces the dead-lettered create and is itself sent as the create; its alert closes
IF (SELECT COUNT(*) FROM integ.WorkItem WHERE OrderingKey = N'Shipment:5000001' AND OperationCode = 100 AND Status = 'Pending') <> 1
   OR EXISTS (SELECT 1 FROM integ.vw_DeadLetter WHERE OrderingKey = N'Shipment:5000001') THROW 60052, 'S6 promotion over dead letter', 1;
IF EXISTS (SELECT 1 FROM integ.Alert WHERE Category = 'DeadLetter' AND ResolvedAt IS NULL) THROW 60053, 'S6 replaced dead letter alert should be resolved', 1;
DECLARE @b3 nvarchar(max) = REPLACE(@b1, 'SO-1', 'SO-CXL');
EXEC integ.usp_Outbox_Publish @EntityType='Shipment', @SourceKey=N'5000001', @EventType='ShipmentCancelled', @NewState='Cancelled', @PayloadJson=@b3;
IF EXISTS (SELECT 1 FROM integ.WorkItem WHERE OrderingKey = N'Shipment:5000001' AND Status IN ('Pending','DeadLetter')) THROW 60054, 'S6 cancel supersede', 1;
IF (SELECT Status FROM integ.WorkItem WHERE OrderingKey = N'Shipment:5000001' AND OperationCode = 300) <> 'Cancelled' THROW 60055, 'S6 nothing-to-cancel', 1;

/* ---- S7: operator retry/replay + monitor ---- */
DECLARE @new bigint;
SELECT @wi = WorkItemId FROM integ.WorkItem WHERE OperationCode = 100 AND OrderingKey = N'Shipment:4171753' AND ExternalRef IS NOT NULL;
EXEC integ.usp_WorkItem_Replay @WorkItemId = @wi, @Reason = N'TMS lost the load', @NewWorkItemId = @new OUTPUT;
IF (SELECT Status FROM integ.WorkItem WHERE WorkItemId = @new) <> 'Pending' THROW 60060, 'S7 replay', 1;
UPDATE integ.WorkItem SET DispatchedAt = DATEADD(MINUTE, -45, DispatchedAt) WHERE Status = 'Dispatched';
UPDATE integ.ProcessRun SET HeartbeatAt = DATEADD(MINUTE, -60, HeartbeatAt) WHERE ProcessName = N'TEST';
EXEC integ.usp_Monitor_Evaluate;
IF NOT EXISTS (SELECT 1 FROM integ.Alert WHERE Category = 'AckOverdue' AND ResolvedAt IS NULL) THROW 60061, 'S7 ack alert', 1;
IF NOT EXISTS (SELECT 1 FROM integ.Alert WHERE AlertKey = N'PROCESS:STALE:TEST' AND ResolvedAt IS NULL) THROW 60062, 'S7 process alert', 1;
IF NOT EXISTS (SELECT 1 FROM integ.Alert WHERE Category = 'DeadLetter' AND ResolvedAt IS NOT NULL) THROW 60063, 'S7 dead-letter auto-resolve after cancel', 1;

PRINT 'ALL SCENARIOS PASSED';
SELECT 'vw_AwaitingAck' v, OperationName, OrderingKey, MinutesWaiting, Diagnosis FROM integ.vw_AwaitingAck;
SELECT TOP 20 SourceKey, At, Kind, Detail FROM integ.vw_EntityTimeline WHERE SourceKey = N'4171753' ORDER BY At, Kind;
