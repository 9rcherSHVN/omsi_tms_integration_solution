sequenceDiagram
  autonumber
  participant LT as LumberTrack
  participant DET as SSIS Detect
  participant PUB as usp_Outbox_Publish
  participant LED as Ledger
  participant DSP as SSIS Dispatch + omsi_adp
  participant OM as OMSI DB
  participant CN as OMSI connector / TMS
  participant INB as Harvest + ProcessInbound
  participant API as SSIS + LT API

  LT->>DET: shp_rev / ord_rev change (revdate, revtime, row key)
  DET->>LT: read full shipment snapshot (no NOLOCK)
  DET->>PUB: snapshot + revision
  PUB->>LED: lock entity, revision guard, record EntityRevision*
  PUB->>LED: OutboxEvent + WorkItem (supersede / promote / terminal rules)
  DSP->>LED: claim (READPAST, lease, per-entity FIFO)
  DSP->>DSP: validate contract, map values
  DSP->>OM: BEGIN TRAN, operation is_ready=0, payload rows
  DSP->>LED: WorkItem Dispatched, ExternalRef = operation_id
  DSP->>OM: is_ready = 1, COMMIT
  CN->>OM: poll is_ready=1 and is_read=0
  CN->>OM: log_entry (ack, award, POPU, POD, 6800 ...)
  INB->>OM: harvest log_entry (watermark minus look-back)
  INB->>LED: InboxMessage (exactly once), correlate ack, lifecycle state
  INB->>PUB: follow-up event (e.g. ReadyToPayReported)
  INB->>OM: log_entry.is_read = 1 (same transaction)
  API->>LED: claim LT_API work
  API->>LT: POST with Idempotency-Key
  API->>LED: Complete (2xx / 409) or Fail (classified, retry / dead-letter)