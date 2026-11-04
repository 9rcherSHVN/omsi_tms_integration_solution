/* =====================================================================
   OMSI Integration Ledger - reference design (part 3 of 4)
   VENDOR ADAPTER (anti-corruption layer) for the OMSI interface database.
   - Only objects in schema omsi_adp touch OMSI. Everything else talks to
     the canonical model (integ.*). Relocating OMSI = re-point synonyms.
   - Outbound: payload rows first, operation.is_ready = 1 LAST, ledger
     completion in the SAME transaction (same instance => atomic, no DTC).
   - Inbound : harvest log_entry -> integ.InboxMessage (exactly once),
     then process: acknowledge, apply lifecycle, trigger follow-ups.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---- Synonyms: the ONLY place the OMSI database name appears ---------- */
IF OBJECT_ID(N'omsi_adp.operation')          IS NULL CREATE SYNONYM omsi_adp.operation          FOR OMSI.dbo.operation;
IF OBJECT_ID(N'omsi_adp.shipment')           IS NULL CREATE SYNONYM omsi_adp.shipment           FOR OMSI.dbo.shipment;
IF OBJECT_ID(N'omsi_adp.stop')               IS NULL CREATE SYNONYM omsi_adp.stop               FOR OMSI.dbo.stop;
IF OBJECT_ID(N'omsi_adp.log_entry')          IS NULL CREATE SYNONYM omsi_adp.log_entry          FOR OMSI.dbo.log_entry;
IF OBJECT_ID(N'omsi_adp.shipment_log_entry') IS NULL CREATE SYNONYM omsi_adp.shipment_log_entry FOR OMSI.dbo.shipment_log_entry;
GO

/* ---- Effective-dated code translation -------------------------------- */
CREATE OR ALTER FUNCTION integ.fn_MapValue
    (@Domain varchar(40), @SourceSystem varchar(20), @SourceValue nvarchar(100), @TargetSystem varchar(20), @AsOf date)
RETURNS nvarchar(100)
AS
BEGIN
    RETURN (SELECT TOP (1) TargetValue
              FROM integ.ValueMap
             WHERE Domain = @Domain AND SourceSystem = @SourceSystem AND TargetSystem = @TargetSystem
               AND SourceValue = COALESCE(@SourceValue, N'')
               AND EffectiveFrom <= @AsOf AND (EffectiveTo IS NULL OR EffectiveTo > @AsOf)
             ORDER BY EffectiveFrom DESC);
END;
GO

/* ---------------------------------------------------------------------
   OUTBOUND ADAPTER: shipment new / modify / cancel (OMSI ops 100/200/300)
   Canonical payload (integ.OutboxEvent.PayloadJson):
   { "shipmentNumber":4171753, "equipmentTypeCode":"V53", "shipperRef":"SO-1",
     "weightUom":"LBS", "currency":"CAD", "readyDate":"2026-10-30T08:00:00",
     "stops":[{"seq":1,"isPickup":1,"company":"..","city":"..","province":"BC",
               "postal":"..","country":"CA","earlyDate":"2026-10-31T08:00:00"}, ...] }
   Return 0 = dispatched, 1 = failed (already recorded in ledger).
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE omsi_adp.usp_SendShipment
    @WorkItemId bigint, @LeaseOwner nvarchar(128)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Op int, @Payload nvarchar(max), @OperationId decimal(18,0), @WeightUom nvarchar(20), @SrcUom nvarchar(100);

    SELECT @Op = w.OperationCode, @Payload = e.PayloadJson
      FROM integ.WorkItem w JOIN integ.OutboxEvent e ON e.EventId = w.EventId
     WHERE w.WorkItemId = @WorkItemId;

    BEGIN TRY
        -- Contract validation BEFORE touching the vendor database
        IF @Op NOT IN (100, 200, 300)
            THROW 53000, 'Contract: omsi_adp.usp_SendShipment supports operations 100/200/300 only.', 1;
        IF JSON_VALUE(@Payload, '$.shipmentNumber') IS NULL
            THROW 53001, 'Contract: shipmentNumber is required.', 1;
        IF @Op IN (100, 200) AND (SELECT COUNT(*) FROM OPENJSON(@Payload, '$.stops')) < 2
            THROW 53002, 'Contract: a shipment requires at least one pickup and one delivery stop.', 1;

        SET @SrcUom = JSON_VALUE(@Payload, '$.weightUom');
        SET @WeightUom = integ.fn_MapValue('WeightUOM', 'LT', @SrcUom, 'OMSI', CAST(SYSDATETIME() AS date));
        IF @WeightUom IS NULL AND @Op IN (100, 200)
        BEGIN
            DECLARE @m nvarchar(400) = CONCAT(N'No mapping: WeightUOM "', @SrcUom, N'" (LT -> OMSI).');
            THROW 53010, @m, 1;
        END;

        BEGIN TRANSACTION;

        -- 1) header NOT ready yet: the vendor poller must never see a partial shipment
        INSERT omsi_adp.operation (operation, is_ready, is_read, creation_timestamp)
        VALUES (@Op, 0, 0, GETDATE());
        SET @OperationId = SCOPE_IDENTITY();

        -- 2) payload. Single-row VALUES + OPTION (LOOP JOIN): OPENJSON's fixed 50-row estimate
        --    otherwise makes FK validation SCAN operation/shipment and deadlock with concurrent
        --    writers holding uncommitted rows (reproduced with 6 parallel dispatchers).
        INSERT omsi_adp.shipment (operation_id, client_key_1, equipment_type_code, shipper_ref_number,
                                  weight_uom, currency_type, market_start_date)
        VALUES (@OperationId,
                JSON_VALUE(@Payload, '$.shipmentNumber'),
                JSON_VALUE(@Payload, '$.equipmentTypeCode'),
                JSON_VALUE(@Payload, '$.shipperRef'),
                @WeightUom,
                JSON_VALUE(@Payload, '$.currency'),
                TRY_CONVERT(datetime, JSON_VALUE(@Payload, '$.readyDate'), 126));

        IF @Op IN (100, 200)
            INSERT omsi_adp.stop (operation_id, sequence_number, is_pickup, addr_company_name, addr_city,
                                  addr_state_province, addr_postal_code, addr_country_code, early_stop_date)
            SELECT @OperationId, s.seq, s.isPickup, s.company, s.city, s.province, s.postal, s.country, s.earlyDate
              FROM OPENJSON(@Payload, '$.stops') WITH (
                     seq       int          '$.seq',
                     isPickup  int          '$.isPickup',
                     company   nvarchar(50) '$.company',
                     city      nvarchar(30) '$.city',
                     province  nvarchar(25) '$.province',
                     postal    nvarchar(15) '$.postal',
                     country   nvarchar(20) '$.country',
                     earlyDate datetime     '$.earlyDate') s
            OPTION (LOOP JOIN);

        -- 3) ledger: Dispatched + correlation key (OMSI operation_id), same transaction
        DECLARE @Ref nvarchar(100) = CONVERT(nvarchar(100), @OperationId);
        EXEC integ.usp_WorkItem_Complete @WorkItemId = @WorkItemId, @LeaseOwner = @LeaseOwner, @ExternalRef = @Ref;

        -- 4) release to the vendor as the LAST statement before COMMIT: nothing that can fail
        --    follows it, so even a NOLOCK reader cannot pick up an operation that is rolled back.
        UPDATE omsi_adp.operation SET is_ready = 1 WHERE operation_id = @OperationId;

        COMMIT;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        DECLARE @en int = ERROR_NUMBER(), @em nvarchar(4000) = ERROR_MESSAGE(),
                @ep nvarchar(128) = ERROR_PROCEDURE(), @el int = ERROR_LINE();
        EXEC integ.usp_WorkItem_Fail @WorkItemId = @WorkItemId, @LeaseOwner = @LeaseOwner,
             @ErrorNumber = @en, @ErrorMessage = @em, @ErrorProcedure = @ep, @ErrorLine = @el,
             @RequestSnapshot = @Payload;
        RETURN 1;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   OUTBOUND DISPATCHER: what the SSIS job calls every N minutes for OMSI.
   One bad item never stops the batch (failure is recorded per item).
   Synchronous API targets (LT_API) are claimed by SSIS directly with
   integ.usp_WorkItem_Claim @TargetSystem = 'LT_API' and finished with
   usp_WorkItem_Complete / usp_WorkItem_Fail around the HTTP call.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE omsi_adp.usp_DispatchOutbound
    @ProcessName nvarchar(128) = N'SSIS.OmsiOutbound', @BatchSize int = 50, @MaxBatches int = 20
AS
BEGIN
    SET NOCOUNT ON;
    -- Thin wrapper: the claim/adapter/fail loop is the reusable integ.usp_Dispatch
    EXEC integ.usp_Dispatch @TargetSystem = 'OMSI', @ProcessName = @ProcessName,
                            @BatchSize = @BatchSize, @MaxBatches = @MaxBatches;
END;
GO

/* ---------------------------------------------------------------------
   INBOUND HARVEST: OMSI log_entry -> integ.InboxMessage, exactly once.
   Re-scans a small look-back window behind the watermark because an
   identity value can commit AFTER a higher one (long vendor transaction);
   the unique key (SourceSystem, SourceMessageId) makes re-scans harmless.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE omsi_adp.usp_HarvestInbound
    @BatchSize int = 1000, @LookbackIds int = 200, @Harvested int = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @From decimal(20,0), @Max decimal(20,0);

    BEGIN TRANSACTION;
    SELECT @From = LastValue FROM integ.HarvestWatermark WITH (UPDLOCK, HOLDLOCK) WHERE SourceName = 'OMSI.log_entry';
    IF @From IS NULL
    BEGIN
        INSERT integ.HarvestWatermark (SourceName, LastValue) VALUES ('OMSI.log_entry', 0);
        SET @From = 0;
    END;

    DECLARE @Rows TABLE (log_entry_id decimal(18,0) PRIMARY KEY);
    INSERT @Rows
    SELECT TOP (@BatchSize) le.log_entry_id
      FROM omsi_adp.log_entry le
     WHERE le.log_entry_id > @From - @LookbackIds
       AND NOT EXISTS (SELECT 1 FROM integ.InboxMessage i
                        WHERE i.SourceSystem = 'OMSI' AND i.SourceMessageId = CONVERT(nvarchar(100), le.log_entry_id))
     ORDER BY le.log_entry_id;

    INSERT integ.InboxMessage (SourceSystem, SourceMessageId, MessageType, EntityId, CorrelationRef, PayloadJson, ResultCode, ResultMessage)
    SELECT 'OMSI', CONVERT(nvarchar(100), le.log_entry_id), le.operation, be.EntityId,
           CONVERT(nvarchar(100), le.operation_id),
           (SELECT sle.client_key_1, sle.carrier_scac_code, sle.carrier_name, sle.bid_total, sle.currency_type,
                   sle.is_completed, sle.is_cancelled, sle.time_awarded, sle.pickup_date, sle.delivery_date
              FROM omsi_adp.shipment_log_entry sle WHERE sle.log_entry_id = le.log_entry_id
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           le.result_code, le.result_message
      FROM @Rows r
      JOIN omsi_adp.log_entry le ON le.log_entry_id = r.log_entry_id
      LEFT JOIN omsi_adp.shipment_log_entry sle ON sle.log_entry_id = le.log_entry_id
      LEFT JOIN integ.BusinessEntity be
             ON be.EntityType = 'Shipment' AND be.SourceSystem = 'LT' AND be.SourceKey = sle.client_key_1;
    SET @Harvested = @@ROWCOUNT;

    SELECT @Max = MAX(log_entry_id) FROM @Rows;
    IF @Max > @From
        UPDATE integ.HarvestWatermark SET LastValue = @Max, UpdatedAt = SYSDATETIME() WHERE SourceName = 'OMSI.log_entry';
    COMMIT;
END;
GO

/* ---------------------------------------------------------------------
   INBOUND PROCESSOR: one message = one transaction. A failing message is
   marked Failed (with reason) and the loop continues - no global stall.
   OMSI log_entry.is_read = 1 is set only when the message is processed.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE omsi_adp.usp_ProcessInbound
    @BatchSize int = 500, @MaxProcessAttempts int = 5, @Processed int = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Processed = 0;

    DECLARE @Ids TABLE (InboxMessageId bigint PRIMARY KEY);
    INSERT @Ids
    SELECT TOP (@BatchSize) InboxMessageId FROM integ.InboxMessage
     WHERE Status = 'Received' OR (Status = 'Failed' AND ProcessAttempts < @MaxProcessAttempts)
     ORDER BY InboxMessageId;

    DECLARE @Id bigint;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT InboxMessageId FROM @Ids ORDER BY InboxMessageId;
    OPEN cur; FETCH NEXT FROM cur INTO @Id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            DECLARE @Src varchar(20), @SrcMsg nvarchar(100), @Type int, @EntityId bigint, @Corr nvarchar(100),
                    @Payload nvarchar(max), @ResultCode int, @ResultMsg nvarchar(4000),
                    @State varchar(30), @IsAck bit, @FollowUp varchar(40), @HasRoute bit,
                    @WiId bigint, @EntityType varchar(30), @SourceKey nvarchar(100);

            SELECT @Src = SourceSystem, @SrcMsg = SourceMessageId, @Type = MessageType, @EntityId = EntityId,
                   @Corr = CorrelationRef, @Payload = PayloadJson, @ResultCode = ResultCode, @ResultMsg = ResultMessage
              FROM integ.InboxMessage WHERE InboxMessageId = @Id;

            SELECT @State = NULL, @IsAck = 0, @FollowUp = NULL, @HasRoute = 0, @WiId = NULL;
            SELECT @State = ResultingState, @IsAck = IsAcknowledgement, @FollowUp = FollowUpEventType, @HasRoute = 1
              FROM integ.InboundRoute WHERE SourceSystem = @Src AND MessageType = @Type AND IsActive = 1;

            BEGIN TRANSACTION;

            IF @HasRoute = 0
                UPDATE integ.InboxMessage SET Status = 'Ignored', ProcessedAt = SYSDATETIME(),
                       ProcessingError = 'No InboundRoute configured' WHERE InboxMessageId = @Id;
            ELSE
            BEGIN
                -- Correlate acknowledgement to the outbound work item (OMSI echoes operation_id)
                IF @IsAck = 1 AND @Corr IS NOT NULL
                BEGIN
                    SELECT @WiId = WorkItemId, @EntityId = COALESCE(@EntityId, e.EntityId)
                      FROM integ.WorkItem w JOIN integ.OutboxEvent e ON e.EventId = w.EventId
                     WHERE w.TargetSystem = @Src AND w.ExternalRef = @Corr;

                    IF COALESCE(@ResultCode, 0) = 0
                        UPDATE integ.WorkItem SET Status = 'Succeeded', CompletedAt = SYSDATETIME()
                         WHERE WorkItemId = @WiId AND Status = 'Dispatched';
                    ELSE
                    BEGIN
                        -- Business rejection by the TMS: not retryable automatically
                        UPDATE integ.WorkItem
                           SET Status = 'DeadLetter', LastErrorClass = 'Contract',
                               LastErrorMessage = LEFT(CONCAT(N'Rejected by ', @Src, N': ', @ResultMsg), 4000),
                               StatusReason = 'Rejected by target system'
                         WHERE WorkItemId = @WiId AND Status = 'Dispatched';
                        DECLARE @k nvarchar(200) = CONCAT(N'DEADLETTER:WI:', @WiId),
                                @am nvarchar(2000) = LEFT(CONCAT(N'OMSI rejected operation ', @Corr, N': ', @ResultMsg), 2000);
                        EXEC integ.usp_Alert_Raise @k, 'DeadLetter', 'Critical', @am;
                        SET @State = NULL;
                    END;
                END;

                IF @EntityId IS NOT NULL AND @State IS NOT NULL
                    EXEC integ.usp_Entity_ApplyState @EntityId, @State, 'INBOX', @Id;

                -- Follow-up business event (e.g. ready-to-pay -> ERP API call), idempotent per inbound message
                IF @FollowUp IS NOT NULL AND @EntityId IS NOT NULL
                BEGIN
                    SELECT @EntityType = EntityType, @SourceKey = SourceKey FROM integ.BusinessEntity WHERE EntityId = @EntityId;
                    DECLARE @IdemKey nvarchar(200) = CONCAT('INBOX|', @Src, '|', @SrcMsg, '|', @FollowUp);
                    DECLARE @Body nvarchar(max) = COALESCE(@Payload, N'{}');
                    EXEC integ.usp_Outbox_Publish @EntityType = @EntityType, @SourceKey = @SourceKey,
                         @EventType = @FollowUp, @PayloadJson = @Body,
                         @IdempotencyKey = @IdemKey, @SuppressIfUnchanged = 0;
                END;

                UPDATE integ.InboxMessage
                   SET Status = 'Processed', ProcessedAt = SYSDATETIME(), EntityId = COALESCE(EntityId, @EntityId),
                       ProcessAttempts += 1, ProcessingError = NULL
                 WHERE InboxMessageId = @Id;
            END;

            IF @Src = 'OMSI'
                UPDATE omsi_adp.log_entry SET is_read = 1 WHERE log_entry_id = CONVERT(decimal(18,0), @SrcMsg);

            COMMIT;
            SET @Processed += 1;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            DECLARE @err nvarchar(4000) = CONCAT(N'Error ', ERROR_NUMBER(), N' at ', ERROR_PROCEDURE(), N':', ERROR_LINE(), N' - ', ERROR_MESSAGE());
            UPDATE integ.InboxMessage SET Status = 'Failed', ProcessAttempts += 1, ProcessingError = @err WHERE InboxMessageId = @Id;
            IF (SELECT ProcessAttempts FROM integ.InboxMessage WHERE InboxMessageId = @Id) >= @MaxProcessAttempts
            BEGIN
                DECLARE @ik nvarchar(200) = CONCAT(N'INBOX:FAILED:', @Id);
                EXEC integ.usp_Alert_Raise @ik, 'InboxFailed', 'Critical', @err;
            END;
        END CATCH;
        FETCH NEXT FROM cur INTO @Id;
    END;
    CLOSE cur; DEALLOCATE cur;
END;
GO
