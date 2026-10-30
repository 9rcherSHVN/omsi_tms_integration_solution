flowchart LR
  E1["E1 LumberTrack ERP"]
  E2["E2 OMSI / TMS vendor"]
  E3["E3 LumberTrack API"]
  E4["E4 Ops, Support, BAs"]
  P1(("P1 Detect"))
  P2(("P2 Publish + guard"))
  P3(("P3 Dispatch adapter"))
  P4(("P4 Harvest inbound"))
  P5(("P5 Process inbound"))
  P6(("P6 Call ERP API"))
  P7(("P7 Monitor + operate"))
  D0[("D0 Config catalog")]
  D1[("D1 EntityRevision*")]
  D2[("D2 BusinessEntity + StateHistory")]
  D3[("D3 OutboxEvent")]
  D4[("D4 WorkItem + Attempt + OperatorAction")]
  D5[("D5 InboxMessage + Watermark")]
  D6[("D6 ProcessRun, Alert, Snapshot")]

  E1 -- "revision rows, snapshot" --> P1
  P1 -- "snapshot JSON + revision" --> P2
  D0 -- "routes, scopes, transitions" --> P2
  P2 -- "every revision + disposition" --> D1
  P2 -- "state, high-water, hash" --> D2
  P2 -- "immutable event" --> D3
  P2 -- "routed work" --> D4
  D4 -- "claimed items" --> P3
  D3 -- "payload" --> P3
  P3 -- "operation + payload rows" --> E2
  P3 -- "Dispatched, attempts, errors" --> D4
  E2 -- "log_entry + detail" --> P4
  P4 -- "inbound messages" --> D5
  D5 -- "unprocessed" --> P5
  P5 -- "ack status" --> D4
  P5 -- "lifecycle state" --> D2
  P5 -- "follow-up events" --> P2
  P5 -- "is_read = 1" --> E2
  D4 -- "LT_API items" --> P6
  P6 -- "idempotent request" --> E3
  E3 -- "response" --> P6
  P6 -- "result" --> D4
  D2 --> P7
  D4 --> P7
  D5 --> P7
  P7 -- "alerts, snapshots, heartbeats" --> D6
  D6 -- "dashboard, notifications" --> E4
  E4 -- "Retry / Cancel / Replay" --> P7
  P7 -- "operator actions" --> D4