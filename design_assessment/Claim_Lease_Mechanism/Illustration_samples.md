Below are three parts: a step-by-step lease example with a timeline, a method for choosing the lease time and retry limit, and a one-page decision guide. I've kept the language plain. The lease sizing rules come from your guide; the retry-limit numbers are my own suggestions, because the guide doesn't set any.

## 1. A lease example from start to finish

The setup: one task, "Send freight accrual for Shipment 4171753 to the LumberTrack API". The lease is 5 minutes. Two SSIS runs are working: Run A and Run B.

| Time	| What happens	| What the task record shows |
| --- | --- | --- |
| 10:00:00	| A shipment change creates the task. It gets a reference number that never changes: SHIP-4171753-REV21-ACCRUAL.	| Waiting · nobody · no due time |
| 10:01:00	| Run A takes the task. Taking it and writing "Run A" on it happen in one step, so no other run can take it at the same moment.	| Taken by Run A · due 10:06 · attempt 1 |
| 10:01:05	| Run B checks the queue. The task is taken and not overdue, so Run B skips it and picks other work.	| No change |
| 10:01:10	| Run A sends the accrual with the reference number. LumberTrack accepts it and saves the number.	| No change |
| 10:01:11	| The server is restarted. Run A dies before it can mark the task done.	| Still taken by Run A · due 10:06 |
| 10:06:00	| The due time passes. Nothing happens yet; the task waits for the next run.	| Overdue |
| 10:11:00	| Run B takes over the overdue task. Attempt 1 is recorded as Abandoned.	| Taken by Run B · due 10:16 · attempt 2 |
| 10:11:02	| Run B sends the accrual again with the same reference number. LumberTrack replies "already have it".	| No change |
| 10:11:03	| Run B treats "already have it" as success and marks the task Done.	| Done · no owner |
| 10:12:00	| (Variation) Run A was only frozen, not dead. It wakes up and tries to mark the task done. The record now says Run B, so its update is refused.	| Unchanged; still Done (by Run B) |

**What each mechanism did:**

- The lease stopped Run B from doing the task while Run A owned it (10:01), and handed the task back automatically after Run A died (10:11).
- The ownership check refused the late update from the frozen worker (10:12).
- The reference number made the second send harmless (10:11:02). Without it, LumberTrack would hold two accruals.

The lease guarantees one owner at a time. It can't prevent a repeat after the time runs out. The reference number makes that repeat safe.

## 2. How to choose the lease time

**Rule 1: the lease must last well past your slowest normal job.** Measure how long one task takes. Use the "slow but normal" time, meaning 99 out of 100 tasks finish within it. Lease time ≥ 2 × that slow-normal time.

**Rule 2: if you take several tasks at once, they all share one due time.** Number of tasks taken × slow-normal time < lease time. If that doesn't hold, take fewer tasks at a time, or ask for more time before each one.

**Rule 3: for long jobs, ask for more time halfway through.** Renew the lease when half of it has passed, so one missed renewal doesn't cost you the task. If a renewal is refused, stop immediately, because someone else may already own the task.

**Rule 4: accept the recovery delay that comes with the lease.** After a crash, the task waits at most lease time + time until the next run. With 5 minutes plus a 10-minute schedule, that's about 15 minutes. Outside the SSIS run window it can be much longer, as I noted in my first review.

The trade-off:

| Lease too short |	Lease too long |
| --- | --- |
| Healthy but slow workers lose their tasks	| Tasks from crashed workers wait a long time |
| Duplicate calls and many "Abandoned" records	| Later tasks for the same shipment wait too, because they're sent in order |

**Worked examples**

| Target | Slow-normal time per task | Tasks taken at once	| Recommended setting |
| --- | --- | --- | --- |
| OMSI (same server)	| under 1 second	| 50	| 5 min lease, no renewal (50 × 1 s is far below 5 min) |
| LumberTrack API	| about 10 seconds(the guide's example)	| 50	| ❌ 50 × 10 s = 500 s, which is more than 5 min. Don't do this.  |
| LumberTrack API | about 10 seconds	| 10	| ✅ 5 min lease, renew before each task |

How to tune it later: the guide's health check suggests that if more than 1% of attempts end as "Abandoned", you should review the lease time and the number of tasks taken at once.

## 3. How to choose the retry limit

These are my suggestions; please confirm them against your retry settings.

Ask one question: what's the longest outage of the target system you want to ride out automatically? Set the retries so the waits between them add up to about that.

| Item	| Suggested starting point	| Why |
| --- | --- | --- |
| Wait between retries	| Doubles each time: 1, 2, 4, 8, 16, 32 min	| Gives a struggling target room to recover
| Retries for the target being down (timeouts, server errors)	| 6–8, covering about 1–4 hours	| Covers typical outages and maintenance windows
| Retries for bad data (validation errors)	| 0: send straight to the failed list	| Retrying won't fix bad data
| Limit on worker crashes for one task	| 3, then mark it "suspected bad task"	| Stops one bad message from crashing every run and blocking that shipment
| "Already have it" reply	| Not a retry; counts as success	| That's what the reference number is for

Also keep two rules in mind:

 - Count crashes separately from errors. If a task crashes the worker every time, it is never marked failed. It just keeps being retaken. This was D4 in my first review.
 - A later task for the same shipment waits while an earlier one is stuck or failed. So a high retry limit also delays everything after it for that shipment. Give shipment-related tasks a shorter limit than reporting or other low-urgency tasks.

## 4. One-page decision guide: lease, reference number, version check, or short lock

**Step 1. Ask these questions in order and stop at the first "yes".**

1. Is a program doing a job that may be slow, may crash, and could be picked up by more than one worker? → Use a lease. Then go to question 2.
2. Does that job change something outside your database (an API, a file, an email)? → Add a reference number that the receiving system checks. → If the change stays in the same database, record "Done" in the same transaction as the change.
3. Is someone saving a decision based on data they read earlier (a screen, a report, a nightly job)? → Use a version check (OCC). If the order comes from the source system, compare the source's revision number.
4. Is it a quick change of several rows inside the database that takes milliseconds? → Use a short ordinary lock, as the shipment publish step does.
5. None of the above? → Use a single update that changes the row only if it's still in the expected state.

**Step 2. Compare the options at a glance.**

|	| Lease	| Reference number	| Version check (OCC)	| Short lock | 
|---|---|---|---|---|
| Best for	| Jobs done by workers	| Effects on other systems	| Decisions by people or slow processes	| Fast multi-row database changes | 
| Plain question	| Who may do this now?	Has this been done already?	| Is my information still current? | Can I finish this in one go? | 
| Blocks others	| Others skip the job until it's due	| No	| No	| Very briefly | 
| If the actor crashes	| Job comes back after the due time	| Not affected	| Nothing to clean up	| Lock released automatically | 
| Main risk	| Wrong lease time	| Number changes between attempts	| Many save conflicts on busy records| 	Holding the lock too long | 
| Example here	| SSIS sending to OMSI	| Accruals to the LumberTrack API	| Support user changing a shipment's status	| Publishing a shipment change | 

**Step 3. Never do these.**

❌ Use a version check to stop duplicate API calls. It only finds the clash after the call was made.

❌ Use a lease for a person's edit screen. People walk away and the record stays blocked.

❌ Create a new reference number on each retry. Duplicates can no longer be detected.

❌ Retry a refused version-check save automatically. The person needs to reload and decide again.

❌ Keep working after a lease renewal is refused.

**Step 4. Go-live checklist.**

☐ Lease time is at least twice the slow-normal job time.

☐ Tasks taken at once × slow-normal time is less than the lease time.

☐ Long jobs renew halfway through and stop when a renewal is refused.

☐ Reference number is created once and kept the same on every retry.

☐ The receiving system rejects duplicate reference numbers, and the worker treats that reply as success.

☐ Retry limit is set per type of failure, including a separate limit for worker crashes.

☐ The "Abandoned" rate is monitored (review if it goes above 1%).
