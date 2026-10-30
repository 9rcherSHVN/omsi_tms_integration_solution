flowchart TD
  A["SSIS run starts: ProcessRun"] --> B["Claim TOP n: UPDLOCK + READPAST, lease, per-entity FIFO, priority"]
  B --> C{"Items?"}
  C -- no --> Z["Run ends: heartbeat recorded"]
  C -- yes --> D["Per-item TRY"]
  D --> E{"Contract valid and values mapped?"}
  E -- no --> F2["Fail: classify via ErrorCatalog"]
  E -- yes --> G["BEGIN TRAN: operation is_ready=0, payload rows"]
  G --> H["Ledger Complete (lease fenced): Dispatched"]
  H --> I["is_ready = 1, COMMIT"]
  G -- error --> R["ROLLBACK: no OMSI rows remain"]
  H -- error --> R
  R --> F2
  F2 --> X{"Class"}
  X -- Duplicate --> OK["Succeeded (already applied)"]
  X -- "Retryable, attempts left" --> RW["RetryWait: backoff + jitter"]
  X -- "Non-retryable or exhausted" --> DL["DeadLetter + alert: meaning, hint, owner"]
  I --> N["Next item"]
  OK --> N
  RW --> N
  DL --> N
  N --> C