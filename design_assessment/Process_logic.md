flowchart TD
  A["Incoming snapshot + LumberTrack revision"] --> B["Lock BusinessEntity row"]
  B --> C{"Revision older than<br/>entity high-water mark?"}
  C -- yes --> S["Stale: record EntityRevision*, no work"]
  C -- no --> D{"Same revision<br/>already received?"}
  D -- "yes, same hash" --> DU["Duplicate"]
  D -- "yes, different hash" --> CF["Conflict: alert (same-second edit)"]
  D -- no --> E{"Payload hash equals<br/>last published?"}
  E -- yes --> UN["Unchanged: advance high-water mark"]
  E -- no --> F["Insert OutboxEvent, route to WorkItems"]
  F --> G{"Snapshot op and create<br/>never delivered?"}
  G -- "yes" --> H["Send as create; supersede undelivered create + snapshots"]
  G -- no --> I{"SupersedeScope"}
  I -- "UnsentAndDeadLetter" --> K["Supersede older Pending / RetryWait / DeadLetter; close alerts"]
  I -- "Unsent" --> J["Supersede older Pending / RetryWait"]
  I -- "None (Event)" --> L["Keep all: every fact is delivered"]
  H --> T{"Cancel?"}
  J --> T
  K --> T
  L --> T
  T -- yes --> U["Supersede all open; if nothing delivered, Cancelled, not sent"]
  T -- no --> V["Update high-water mark, hash, lifecycle state"]
  U --> V
  V --> W["COMMIT: Published"]