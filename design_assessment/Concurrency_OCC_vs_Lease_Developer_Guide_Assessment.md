I reviewed Concurrency_OCC_vs_Lease_Developer_Guide.md as an integration architect. The design is sound. It correctly separates three concerns that are often mixed up: OCC protects the correctness of a value, the lease controls who may execute a task, and idempotency removes duplicate effects. Your own L9 finding is a real defect.

I found six more correctness issues that the guide doesn't yet cover, plus several design gaps and some document fixes. I've marked each finding as[Doc] (stated in the guide),[Inferred] (my reasoning from the code shown), or[Verify] (it depends on code in 02_integ_core_procs.sql, which I couldn't see).

## 1. What the design gets right
 - The core split is correct. The guide states plainly that OCC only finds a conflict after the side effect has happened, so it can't control dispatch. It also says a lease is a poor fit for a person who may leave an edit screen open. That's the most important design decision here, and it's well argued.
 - The V1–V5 vocabulary is the strongest section. It keeps the local row version (V1) apart from the source system's revision number (V3). That matches what you argued on Oct 26: the business object's own version counter is what protects concurrent updates, not the order of events in history.
 - The pattern is pessimistic when claiming and optimistic when reporting. The claim takes a short SQL lock, and every later step checks ownership in the same statement that writes. That's the standard competing-consumer pattern in SQL Server.
 - Complete and RenewLease differ on purpose, and both are right. Complete doesn't check expiry because ownership is what makes it safe. RenewLease can never bring an expired lease back.
 - Publish takes a short pessimistic lock instead of OCC (§3.6), and that choice is justified. The work is a few milliseconds, all in one database, across several tables, with no human waiting in the middle.

## 2. Correctness defects not yet in the guide

| Defect	| Severity	| Finding	| Fix |
| --- | --- | --- | --- | 
| D1	| High [Inferred]	| The claim is only partly a locking read under RCSI. §4.3 says the claim behaves the same with or without RCSI. That holds only for alias w. The FIFO NOT EXISTS subquery on alias p has no hint, so under RCSI it reads the last committed version. Example: an operator's Replay/Retry moves predecessor n back to Pending but hasn't committed yet. A claimer still sees n as finished and claims n+1, which breaks ordering.	| Add WITH (READCOMMITTEDLOCK) on p. Don't add READPAST to p: skipping a locked predecessor makes NOT EXISTS true, which is exactly the ordering break you want to avoid. Short blocking on p is the cost of keeping order correct. |
| D2	| High [Inferred]	| Leases use the server's local clock. SYSDATETIME() is local time, and the jobs run on a Pacific-time schedule. The guide flags daylight-saving risk for source revisions (O7) but not for its own LeaseExpiresAt and NextAttemptAt. When clocks go back an hour, retry backoff and leases stretch by an hour. When clocks go forward, they all expire at once. | Use SYSUTCDATETIME() for all lease and scheduling math. Convert existing values at cutover. Keep local time for display only. The current job window (about 4 am–4 pm) avoids the 2 am change, so the risk today is mostly retry timestamps, but the rule should still be UTC.|
| D3	| High [Verify]	| The idempotency key may not stay the same across attempts. Table V5 lists the key's owner as "Publish / Claim". If WorkItem.IdempotencyKey is created or changed at Claim, every retry sends a new key, and the target's duplicate check (L1's main mitigation) silently stops working.	| Create the key once at Publish and never change it. Write that down as an invariant. Also decide whether an intentional Replay reuses the key (the target treats it as a duplicate) or gets a new one (it is sent again). |
| D4	| Medium [Inferred]	| Crashes don't count toward any retry limit. Every reclaim adds 1 to AttemptCount and marks the old attempt Abandoned. Nothing says repeated Abandoned attempts lead to DeadLetter. A payload that crashes the SSIS host every time will be reclaimed forever, and because of FIFO it blocks all later items for that entity.	| Count Abandoned attempts against the retry budget. After N abandons, set the item to DeadLetter with reason PoisonSuspected instead of re-leasing it.
| D5	| Medium [Verify]	| Supersede vs. Leased. Publish supersedes open work items for the entity. If "open" includes Leased, the worker's Complete fails with 52001. That's safe for OMSI on the same instance (the insert rolls back), but an HTTP call has already gone out.	| Supersede should only touch Pending and RetryWait. A newer snapshot of a Leased item should wait behind it in FIFO order.
| D6	| Medium [Verify]	| No lock order is defined, so deadlocks are possible. Publish locks BusinessEntity, then OutboxEvent, then WorkItem. If Complete or the adapter then calls usp_Entity_ApplyState, it locks WorkItem first and BusinessEntity second, which is the opposite order. You've already had production deadlocks in a related OIC flow, so this is a real risk.	| Write down one global lock order (for example: BusinessEntity → WorkItem → WorkItemAttempt). Machine paths should retry on error 1205 (deadlock) a limited number of times; operator OCC paths should not.

## 3. Design gaps (things the guide should cover)

1. The recovery-time math ignores the job window. The formula says the worst case is the lease length plus one 10-minute schedule interval, about 15 minutes. But the outbound job only runs every 10 minutes from about 4:01 am to 4:05 pm PT. A crash near 4 pm actually means a delay until the next morning, roughly 12 hours. That schedule comes from a 2022 infrastructure document, so please confirm it's still current. Rewrite L4 to include the window, or require an always-on dispatcher for operations where latency matters.
2. Use a real fencing token, not just a recommended one. §4.7 is right, but leave it optional and nobody will build it. Have Claim return AttemptNo, and require it on every report:
   ```SQL
   WHERE w.WorkItemId = @WorkItemId AND w.Status = 'Leased' AND w.LeaseOwner = @LeaseOwner
   AND w.AttemptCount = @AttemptNo;
   ```
   This closes L8 completely, whatever threading model the SSIS package uses. It also gives the external API a number that only goes up, which the target can check.
3. Reclaim sooner when the owner is known to be dead. ProcessRun.HeartbeatAt already exists. If the owning run has ended, failed, or stopped sending heartbeats, its leases could be reclaimed right away instead of waiting for them to expire. That cuts L4 without making the lease shorter.
4. Ordering only holds at hand-off. The guide says Dispatched doesn't block FIFO. If the OMSI agent or the LumberTrack API processes messages asynchronously and later rejects item n, item n+1 has already been applied, and the target is out of sync. Two options:
      - Make operations that need strict order wait until acknowledgement.
      - Send the source revision (V3) to the target and have it reject older revisions. This fits your minimum-latency goal better.
5. Replay and ordering. If Replay puts an old work item back to Pending under its original, lower ID, it can send an old snapshot after newer ones. Replay should create a new work item from the latest state of the entity, or be checked against V3.
6. Publish's transaction scope. When Publish runs inside a caller's transaction (@OwnTran = 0), the UPDLOCK, HOLDLOCK on the entity stays held until the caller commits. A detector that publishes many entities in one outer transaction keeps all those entity locks at once. Require one entity per transaction.
7. Batch claims hold up ordering. Items claimed in a batch but not started yet still count as Leased, so each one blocks its entity's later items. If the worker crashes, all of them are delayed. Set batch size per operation type, for example 1 for HTTP and 50 for OMSI on the same instance. Don't make it a global setting.
8. NULL source version. When @SourceChangeVersion is NULL, the stale-revision guard is skipped entirely. State which detectors are allowed to send NULL, and alert when one does.

## 4. Issues in the proposed OCC procedure (§3.3)

- @Reason is never saved. It's accepted as a parameter but not written to EntityStateHistory.
- The operator isn't recorded. History stores 'OPERATOR' but not who it was. Add @Actor or ORIGINAL_LOGIN().
- Any target state is accepted. The procedure checks V1 (the row version) but not whether the transition is legal. Add a check against the allowed transitions, as the work-item procedures already do with their state checks.
- Side effects on open work items aren't handled. Setting an entity to Cancelled while it still has Pending work items leaves the two out of step. Cancel or supersede those items in the same transaction.
- Conflicts aren't logged reliably. §10 suggests logging OCC conflicts, but anything logged before the ROLLBACK is lost. Log after the rollback, or in the caller.

## 5. Document fixes

- §4.7 refers to "§8.2 S2", but that table uses L1–L11. It should say L8.
 - §5 calls OCC "Lock-free". Say "non-blocking across think-time" instead: the single write still takes U and X locks.
 - §1.3, the phrase "no READPAST benefit for already-locked rows that later need FIFO checks", is unclear. Rewrite it or remove it.
 - §11 Test B depends on WAITFOR timing. Add a test-only @Now parameter (clock injection) so lease-expiry tests run deterministically and fast.
 - L5: a DENY UPDATE doesn't stop dbo or sysadmin. Pair it with auditing on integ.WorkItem.
 - Verify]IftheledgerandOMSIdatabasesareinanAvailabilityGroup,theguaranteethatCompleteandtheOMSIinsertcommittogether(§4.4)needscross−databasetransactionsupport(‘DTCSUPPORT=PERDB‘)toholdthroughafailover.Verify] If the ledger and OMSI databases are in an Availability Group, the guarantee that Complete and the OMSI insert commit together (§4.4) needs cross-database transaction support (`DTC_SUPPORT = PER_DB`) to hold through a failover.

## 6. Overall verdict
| Area	| Rating	| Comment | 
| --- | --- | --- |
| Problem split and vocabulary	| Strong	| Ready to publish |
| OCC design	| Good	| Fix the §3.3 procedure; StateVersion is the right long-term token |
| Lease claim and fencing	| Good, with defects	| L9, D1, and the AttemptNo fence must be fixed before go-live |
| Time model	| Weak	| UTC (D2) and the job window (gap 1) |
| Exactly-once at the target	| Depends on D3	| Must stay a go-live gate for the LumberTrack API |
| Observability and tests	| Good	| Add Abandoned→DeadLetter metrics and clock-injected tests |

**Fix before go-live**, in this order: L9, D1, D3, D2, the AttemptNo fence, then D4. D5 and D6 are should-fix items once you've confirmed them against 02_integ_core_procs.sql.
