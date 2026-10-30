/* =====================================================================
   OMSI Integration Ledger - example configuration (BA-owned data)
   Values marked TBD must be confirmed against your OMSI version and
   LumberTrack API catalogue before production use.
   ===================================================================== */
SET NOCOUNT ON;

INSERT integ.ContractVersion (TargetSystem, ContractVersion, EffectiveFrom, Notes) VALUES
 ('OMSI',   '22.04', '2022-05-01', 'Vendor interface DB; operation/log_entry contract'),
 ('LT_API', 'v1',    '2020-04-29', 'Custom LumberTrack API invoked by SSIS');

-- PayloadSemantics / SupersedeScope / PromoteToOperationCode: BA-owned business rules
--   ShipmentModify is a full LumberTrack snapshot: the newest revision replaces older undelivered
--   modifies, including dead-lettered ones, and is sent as the create if the create never got through.
--   Payments/accruals are Events: every one is a distinct financial fact and is never replaced.
INSERT integ.OperationCatalog (OperationCode, Direction, TargetSystem, Name, EntityType, ContractVersion, AdapterProcedure,
                               DefaultPriority, PayloadSemantics, SupersedeScope, PromoteToOperationCode, IsTerminal, RequiresAck) VALUES
 ( 100, 'OUT', 'OMSI',   'ShipmentNew',            'Shipment',         '22.04', 'omsi_adp.usp_SendShipment', 3, 'Snapshot', 'None',                NULL, 0, 1),
 ( 200, 'OUT', 'OMSI',   'ShipmentModify',         'Shipment',         '22.04', 'omsi_adp.usp_SendShipment', 5, 'Snapshot', 'UnsentAndDeadLetter',  100, 0, 1),
 ( 300, 'OUT', 'OMSI',   'ShipmentCancel',         'Shipment',         '22.04', 'omsi_adp.usp_SendShipment', 1, 'Event',    'None',                NULL, 1, 1),
 (5800, 'OUT', 'OMSI',   'FreightPayment',         'Shipment',         '22.04', NULL /* TBD adapter */,     5, 'Event',    'None',                NULL, 0, 1),
 (7500, 'OUT', 'OMSI',   'CarrierInsuranceUpdate', 'CarrierInsurance', '22.04', NULL /* TBD adapter */,     4, 'Snapshot', 'UnsentAndDeadLetter', NULL, 0, 1),
 (9101, 'OUT', 'LT_API', 'ErpFreightAccrual',      'Shipment',         'v1',    NULL /* SSIS HTTP */,       4, 'Event',    'None',                NULL, 0, 0),
 (9102, 'OUT', 'LT_API', 'ErpMarkReadyToPay',      'Shipment',         'v1',    NULL /* SSIS HTTP */,       4, 'Event',    'None',                NULL, 0, 0);

INSERT integ.EventRoute (EventType, OperationCode) VALUES
 ('ShipmentReady',           100),
 ('ShipmentModified',        200),
 ('ShipmentCancelled',       300),
 ('FreightInvoiceApproved', 5800),
 ('InsuranceChanged',       7500),
 ('ShipmentAwarded',        9101),   -- accrue freight in ERP when TMS awards a carrier
 ('ReadyToPayReported',     9102);

-- OMSI echoes the outbound operation code with operation_id on acknowledgement (see ispShipmentRecordAcknowledgement)
INSERT integ.InboundRoute (SourceSystem, MessageType, EntityType, ResultingState, IsAcknowledgement, FollowUpEventType) VALUES
 ('OMSI',  100, 'Shipment', 'TmsAccepted', 1, NULL),
 ('OMSI',  200, 'Shipment', NULL,          1, NULL),
 ('OMSI',  300, 'Shipment', 'Cancelled',   1, NULL),
 ('OMSI', 7500, 'CarrierInsurance', 'Synced', 1, NULL),
 ('OMSI', 6800, 'Shipment', 'ReadyToPay',  0, 'ReadyToPayReported');
 -- TBD: market complete / award, pickup (POPU), delivery (POD), freight bill, appointment codes

INSERT integ.LifecycleTransition (EntityType, FromState, ToState) VALUES
 ('Shipment', 'Ready',       'TmsAccepted'),
 ('Shipment', 'TmsAccepted', 'Awarded'),
 ('Shipment', 'Awarded',     'PickedUp'),
 ('Shipment', 'PickedUp',    'Delivered'),
 ('Shipment', 'Delivered',   'ReadyToPay'),
 ('Shipment', 'ReadyToPay',  'Accrued'),
 ('Shipment', '*',           'Cancelled'),
 ('Shipment', '*',           'OnHold'),
 ('Shipment', 'OnHold',      'Ready'),
 ('CarrierInsurance', '*',   'Changed'),
 ('CarrierInsurance', 'Changed', 'Synced');

INSERT integ.LifecycleSla (EntityType, State, MaxMinutesInState, Severity) VALUES
 ('Shipment', 'Ready',       30,    'Critical'),   -- TMS has not accepted it
 ('Shipment', 'TmsAccepted', 2880,  'Warning'),    -- not awarded within 2 days
 ('Shipment', 'Delivered',   10080, 'Warning'),    -- not ready-to-pay within 7 days
 ('CarrierInsurance', 'Changed', 60, 'Critical');

-- Fixes today's LB/LBS drift: one translation, used by every operation
INSERT integ.ValueMap (Domain, SourceSystem, SourceValue, TargetSystem, TargetValue) VALUES
 ('WeightUOM', 'LT', N'',    'OMSI', N'LB'),
 ('WeightUOM', 'LT', N'LB',  'OMSI', N'LB'),
 ('WeightUOM', 'LT', N'LBS', 'OMSI', N'LB'),
 ('WeightUOM', 'LT', N'KG',  'OMSI', N'KG');

INSERT integ.RetryPolicy (OperationCode, ErrorClass, MaxAttempts, BaseDelaySeconds, BackoffFactor, MaxDelaySeconds) VALUES
 (NULL, 'Transient', 10, 30,  2.0, 1800),
 (NULL, 'Unknown',    3, 60,  2.0, 900),
 (NULL, 'Auth',       5, 300, 2.0, 3600),
 (NULL, 'Data',       1, 0,   1.0, 0),
 (NULL, 'Mapping',    1, 0,   1.0, 0),
 (NULL, 'Contract',   1, 0,   1.0, 0),
 ( 300, 'Transient', 20, 15,  1.5, 300);   -- cancellations: retry harder and faster

INSERT integ.ErrorCatalog (MatchOrder, MatchErrorNumber, MatchPattern, ErrorClass, IsRetryable, BusinessMeaning, ResolutionHint, OwnerTeam) VALUES
 (10, 1205, NULL,               'Transient', 1, N'Database deadlock; resolves on retry.',                         N'None unless repeating.',                               N'Integration'),
 (11, 1222, NULL,               'Transient', 1, N'Lock timeout; a long transaction is blocking.',                  N'Check blocking sessions in OMSI/LTInterforAux.',       N'DBA'),
 (12,   -2, NULL,               'Transient', 1, N'Command timeout.',                                               N'Check server load.',                                   N'DBA'),
 -- Duplicate-key errors INSIDE the OMSI write are data errors (e.g. repeated stop sequence), NOT idempotent replays.
 -- Only explicit target signals (HTTP 409, adapter-raised "Duplicate:") are treated as already-applied.
 (20, 2627, NULL,               'Data',      0, N'Shipment payload has a duplicate key (e.g. repeated stop sequence).', N'Correct the shipment in LumberTrack; a new revision resends it.', N'Logistics'),
 (21, 2601, NULL,               'Data',      0, N'Shipment payload has a duplicate key.',                      N'Correct the shipment in LumberTrack; a new revision resends it.', N'Logistics'),
 (22, NULL, N'Duplicate:%',     'Duplicate', 0, N'Target already has this record.',                                N'Treated as success (idempotent).',                     N'Integration'),
 (30,  547, NULL,               'Data',      0, N'Shipment data violates OMSI referential rules (e.g. commodity on a missing stop).', N'Correct the shipment in LumberTrack; a new revision resends it.', N'Logistics'),
 (40, NULL, N'No mapping:%',    'Mapping',   0, N'A LumberTrack code has no OMSI translation.',                    N'Add the value in integ.ValueMap, then Retry.',          N'Integration BA'),
 (50, NULL, N'Contract:%',      'Contract',  0, N'Shipment is incomplete for the TMS contract.',                   N'Complete the shipment in LumberTrack (stops, keys).',  N'Logistics'),
 (60, NULL, N'HTTP 409%',       'Duplicate', 0, N'ERP API reports the transaction already exists.',               N'Treated as success (idempotent).',                     N'Integration'),
 (61, NULL, N'HTTP 401%',       'Auth',      1, N'ERP API credentials rejected.',                                  N'Rotate/verify the SSIS API credential.',               N'Integration'),
 (62, NULL, N'HTTP 5%',         'Transient', 1, N'ERP API unavailable.',                                           N'None unless repeating.',                               N'ERP Support'),
 (99, NULL, NULL,               'Unknown',   1, N'Unclassified error.',                                            N'Investigate; add an ErrorCatalog rule.',               N'Integration');

INSERT integ.SlaThreshold (OperationCode, MaxPendingMinutes, MaxAckMinutes) VALUES
 ( 100, 20, 30), ( 200, 20, 30), ( 300, 10, 20), (5800, 60, 60), (7500, 30, 60), (9101, 30, NULL), (9102, 30, NULL);
