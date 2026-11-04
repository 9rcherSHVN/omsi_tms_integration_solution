# Should §5 (work-item ledger) be replaced with entity versioning?

Short answer: partly. Versioning on `BusinessEntity` is a good fit for one problem the design has. It doesn't cover the problem §5 mainly exists for. My view is that we should simplify §5, not remove it.

## Where your proposal is right

Optimistic concurrency (read version → compute → `UPDATE … WHERE Version = @v` → re-read and redo on conflict) is a valid way to handle **concurrent changes to an entity's state**. 

Today the design does that job with pessimistic locking (`UPDLOCK, HOLDLOCK` on `BusinessEntity` in `usp_Outbox_Publish` and in inbound processing). A `rowversion` / `Version` column could replace those locks:

- in publish (revision guard, hash check, state change)
- in inbound processing (lifecycle state updates)

That's a fair change. With a 10-minute batch cadence there's little contention per entity, so the pessimistic and optimistic approaches perform about the same.

## Why it doesn't replace claim/lease/retry

The two mechanisms solve different problems:

| Problem | Does OCC on the entity solve it? |
|---|---|
| Two writers updating the same entity's state | **Yes** |
| **Side effects outside our transaction** (the LT API HTTP call) | **No.** The version check runs at commit, after the POST has already happened. A conflict-and-redo means calling the API twice. Only a claim taken *before* the call prevents that. |
| Two SSIS workers both picking up shipment X to send | **No.** Both read version 7, both write to OMSI, one loses at commit. For OMSI that is wasted work plus deadlock risk; for the API it is a duplicate. |
| Worker crashes mid-send | **No.** Something must record "in progress by whom, until when". That record is a lease, whatever we call it. |
| Retry **later** with backoff (API down for 2 hours) | **No.** OCC redoes immediately. It has no notion of waiting until a later time or of a retry limit. |
| Poison data (bad UOM) | **No.** It would be retried forever, or need a dead-letter flag, which brings back the work-item status. |
| OMSI's asynchronous ack (sent, waiting for `log_entry`) | **No.** "Dispatched but not acknowledged" is a delivery state, not an entity state. |
| Event-type operations (5800/9101/9102 payments) | **No.** Each fact must be delivered once. "Latest version of the entity" would merge two payments into one. |
| Audit and dashboard ("tried 3×, failed with X, retried by Y") | **No.** It needs an attempt history. |

So OCC answers "is my view of the entity still current?" The work-item ledger answers "has this change reached each target system, and if not, why not?" These are separate concerns.

## A simplification your idea does enable

Applied **per target** instead of per entity, your idea becomes a state-based reconciliation model. It would remove a fair amount of §5's complexity for **Snapshot** operations:

```
BusinessEntity          (EntityId, Version, CurrentState, PayloadHash ...)
EntityTargetSync        (EntityId, TargetSystem, DesiredVersion, DeliveredVersion,
                         AckedVersion, AttemptCount, NextAttemptAt, LeaseOwner,
                         LeaseExpiresAt, LastErrorId, Status)
```

- A worker picks rows where `DeliveredVersion < DesiredVersion` and always sends the **current** snapshot.
- **Supersede, promotion and the revision guard largely disappear.** There is only one row per entity per target, so there is nothing to supersede. "Create vs modify" is just `DeliveredVersion IS NULL`.
- This also fixes critical items #1 and #2 in §14, because the delivery fact lives on the entity, not in purgeable history.
- Lease, backoff and dead-letter still exist, but as columns on one row per entity per target rather than as a queue of items.

Event operations (payments, accruals) and inbound follow-ups would still need a small append-only queue. Every fact matters, and the API call needs a per-fact idempotency key.

The net result is two delivery styles instead of one generic one. That trades some uniformity for much simpler snapshot logic.

## Questions for you

1. **Goal.** Is the aim fewer moving parts (tables and procedures), or a different consistency model? The answer decides whether we only swap the locks for OCC or move to the per-target reconciliation model.
2. **Event operations.** Do you agree that payments and accruals (5800/9101/9102) need per-fact delivery, so a queue stays for them?
3. **Version grain.** One version per entity, or per entity per target? Per target is needed once there is more than one consumer (OMSI plus the LT API).
4. **Attempt history.** Is it acceptable to keep an append-only attempt log, alongside either model, for support and BA visibility?
5. **LT API.** Do you accept that a claim (lease) is unavoidable before any external call, whichever model we choose?

If you confirm answers 1 to 3, I can rewrite §5 (and the affected parts of §4.3, §13 and §14) around the reconciliation model.
