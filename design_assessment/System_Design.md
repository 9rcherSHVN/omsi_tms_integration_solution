flowchart TB
  subgraph SQL["SQL Server instance - one instance is a hard requirement for atomic hand-off"]
    subgraph LTDB["LumberTrack DB - ERP, vendor-owned, read-only for us"]
      LTT[("shp_hdr, shp_ord, ord_hdr<br/>shp_rev, ord_rev (revision history)")]
    end
    subgraph AUX["LTInterforAux DB - middle layer, we own"]
      CFG[("integ CONFIG<br/>OperationCatalog, EventRoute, InboundRoute,<br/>LifecycleTransition, ValueMap, RetryPolicy, ErrorCatalog")]
      LED[("integ LEDGER<br/>EntityRevision*, BusinessEntity, OutboxEvent,<br/>WorkItem, WorkItemAttempt, InboxMessage")]
      MON[("integ MONITORING<br/>ProcessRun, Alert, BacklogSnapshot, vw_*")]
      ADP["omsi_adp ADAPTER<br/>synonyms + dispatch / harvest / process procs"]
    end
    subgraph OMSIDB["OMSI DB - TMS interface, vendor-owned contract"]
      OUTT[("operation + shipment, stop ...")]
      INT[("log_entry + *_log_entry")]
    end
  end
  subgraph JOBS["Schedulers"]
    J1["SSIS Detect and Publish"]
    J2["SSIS OMSI Dispatch"]
    J3["SSIS Inbound Harvest and Process"]
    J4["SSIS LT API caller"]
    J5["SQL Agent Monitor and Purge"]
  end
  CONN["OMSI connector - vendor, polls 5 min"]
  TMS["TMS cloud - tendering, carriers"]
  API["LumberTrack custom API - enforces Idempotency-Key"]
  BI["Power BI dashboard"]
  MAIL["Database Mail / Teams"]

  LTT -- "read committed or Change Tracking" --> J1
  J1 -- "usp_Outbox_Publish" --> LED
  CFG -. "rules" .-> LED
  J2 --> ADP
  ADP -- "one local transaction" --> OUTT
  ADP -- "same transaction" --> LED
  OUTT --> CONN
  CONN <--> TMS
  CONN --> INT
  J3 --> ADP
  INT -- "harvest" --> ADP
  J4 -- "claim LT_API work" --> LED
  J4 -- "HTTP + Idempotency-Key" --> API
  API --> LTT
  J5 --> MON
  LED --> MON
  MON --> BI
  MON --> MAIL