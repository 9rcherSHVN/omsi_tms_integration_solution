Besides the lease, the reference number (idempotency) and the version check (OCC), about 20 other mechanisms come up regularly in integration design. They fall into five groups based on the problem each one solves.

A few are already in your design, judging from the guide and our earlier sessions: the outbox, dead-letter and replay, heartbeats, and reconciliation against a projection. These are marked ✅. Everything else here is general integration practice, not something I found in your documents.

## 1. Getting each message delivered once

| Mechanism | Plain meaning | Everyday comparison | Use when | Watch out for |
| --- | --- | --- | --- | --- |
| Transactional outbox ✅ | Save the business change and the "message to send" together, then send it later | Writing the parcel label in the same moment you pack the box | A database change must reliably trigger a message | You need a sender process that reads the outbox |
| Inbox / dedupe table | The receiver records which message IDs it has already processed | A guest list at the door | You own the receiving side and the sender may repeat messages | The list grows and needs a cleanup policy |
| Saga with compensation | A multi-step process where each step has an "undo" step | Cancelling the hotel booking if the flight booking fails | A business process spans several systems, for example PO → receipt → AP | Undo steps are business rules, not technical rollbacks. Some actions can't be undone. |
| Two-phase commit | All systems commit together or none do | Everyone signs the contract at the same table | Only for databases inside one server or cluster | Fragile across networks and APIs. Generally avoid it. |

## 2. Keeping order and controlling flow

| Mechanism | Plain meaning | Use when | Watch out for |
| --- | --- | --- | --- |
| Per-entity ordering (partition or session key) | Messages for the same PO or shipment go through one lane, in order. Different POs move in parallel. | Order matters per business object, not globally | One stuck item blocks its whole lane |
| Sequence or revision check at the target | The target ignores anything older than what it already has | Messages can arrive late or out of order | The source must provide a reliable revision number |
| Throttling / rate limiting | Cap how fast you send | The target API has limits, such as OIC or Oracle Fusion REST | Backlogs during peaks |
| Backpressure | The sender slows down when the receiver falls behind | Producers are faster than consumers | Needs a feedback signal, such as queue depth |
| Batching / micro-batching | Group many small changes into one send | High volume with acceptable delay | A larger blast radius when one batch fails |

## 3. Handling failure

| Mechanism | Plain meaning | Everyday comparison | Use when |
| --- | --- | --- | --- |
| Retry with backoff + jitter | Retry with growing waits, plus a little randomness | Waiting a bit longer before each redial | Temporary errors such as timeouts or 503s. The jitter stops all workers retrying at the same second. |
| Timeout | Give up waiting after a fixed time | Hanging up a call that rings forever | Every remote call. Without one, a worker can hang until its lease expires. |
| Circuit breaker | After repeated failures, stop calling the target for a while and fail fast | The electrical breaker in your house | The target is down. It avoids burning through retries and the target's capacity. |
| Bulkhead | Separate worker pools per target or interface | Watertight compartments in a ship | One slow interface (say LumberTrack) shouldn't stall another (say OMSI) |
| Dead-letter + replay ✅ | Park items that keep failing; an operator fixes and resends them | The "returned mail" shelf | Bad data, or failures that need a person to decide |
| Poison-message detection | Stop retrying an item that crashes the worker | Removing the one jammed item from the conveyor | Repeated "Abandoned" attempts (D4 from my first review) |

## 4. Making sure the data is right

| Mechanism | Plain meaning | Use when | Watch out for |
| --- | --- | --- | --- |
| Change data capture / change tracking | The database tells you which rows changed | Pulling changes from SQL Server or Oracle without full scans | Schema changes and retention windows |
| Watermark (high-water mark) | Remember "last processed up to time or ID X" | Incremental extraction | Late-arriving rows and clock problems: use UTC and an overlap window |
| Hash / checksum comparison | Fingerprint each payload; send only when the fingerprint changes | The source sends many "updates" that don't actually change anything (common with EAM PO updates) | Pick the fields that go into the hash carefully |
| Snapshot vs delta messages | Send the full current state, or only what changed | Snapshots make retries and replays safe; deltas are smaller | A lost or reordered delta corrupts the target |
| Source-of-truth / field ownership rules | Each field has one owning system | Several systems can edit the same object | Has to be agreed with the business |
| Reconciliation against a projection ✅ | Compare expected state with actual state and fix any drift | Every serious integration. It's the safety net for every mechanism above. | Needs clear tolerance and matching rules |

## 5. How systems talk to each other

| Mechanism | Plain meaning | Use when |
| --- | --- | --- |
| Sync request–reply vs async | Wait for the answer now, or get it later | Use sync only when a user is waiting. Async is more resilient. |
| Correlation ID | One tracking number that follows a transaction across all systems | Always. It's essential for troubleshooting and for evidence in support tickets. |
| Claim check | Store a large payload (PDF, big file) and pass only a link to it | Large documents, such as POD or BOL images in document processing |
| Canonical data model + translator | One common internal format, with mapping at each edge | Many systems exchange the same object, for example Shipment across OMSI, LumberTrack and Oracle |
| Content-based routing | Send each message to a target based on its content | Different plants or carriers go to different endpoints |
| Aggregator / scatter-gather | Combine several messages into one, or ask several systems and merge the answers | PO header + lines → one Oracle payload; rate shopping across carriers |
| Heartbeat / health signal ✅ | Each run reports "I'm alive" regularly | Detecting dead workers faster than waiting for a lease to expire |


## 6. How they fit together

You can think of them as layers. Each one covers a gap the others leave:

 1. Capture the change: change tracking or a watermark, plus a hash to skip non-changes 
 2. Record it reliably: outbox
 3. Assign the work: lease, per-entity ordering, batching
 4. Send it safely: timeout, retry with backoff, circuit breaker, bulkhead, throttling
 5. Make the effect happen once: reference number, plus an inbox at the target
 6. Accept it in the right order: revision check at the target, version check (OCC) for people
 7. Handle failures: dead-letter, poison detection, replay
 8. Prove it's correct: reconciliation, correlation ID, audit

## 7. What I'd add first to your design

These are suggestions, in priority order:

 1. Hash comparison at publish. It cuts the many no-op EAM/PO updates before they ever become tasks.
 2. Timeout + circuit breaker on LumberTrack and other HTTP targets, so an outage doesn't burn through retries and leases.
 3. Revision check at the target. It makes ordering safe even after a message is handed off.
 4. A correlation ID end to end: source → ledger → OIC → Oracle.
 5. Bulkheads, meaning separate worker settings per target, so OMSI and the API don't slow each other down.
