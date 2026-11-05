# Claim - Lease - Idempotency

The short version: the **lease** is a checkout ticket with a time limit, and **idempotency** is a receipt number the receiving system uses to spot duplicates. 

- One stops two workers from doing the same job at the same time **[lease]**. 
- The other makes sure that if a job gets done twice anyway, the second time does no harm **[idempotency]**. 

Your design also uses a third mechanism, O**CC (optimistic concurrency control)**, which works like a **"this record changed since you opened it"** warning.

Below, each mechanism is explained with everyday comparisons and small stories from your OMSI/LumberTrack flow. There's a short plain-English glossary at the end for the terms you found hard.

## 1. Three mechanisms, three different questions

| Mechanism	| Everyday comparison	| The question it answers |
| --- | --- | --- |
| Lease (claim + time limit)|	Borrowing a library book: it's checked out to you, with a due date	| Who is allowed to do this job right now? |
| Idempotency key	| An order number on a purchase: if you click "Pay" twice, the shop sees the same order number and charges once	| Has this already been done? If so, don't do it again. |
| OCC (version check)	| A shared document that warns "someone edited this since you opened it"	| Is what I'm looking at still current before I save my change? |

They don't replace each other. Each one covers a gap the others leave open.

## 2. How the lease works, step by step

Think of the work-item table as a job board. Each card on the board is one delivery, such as "send Shipment 4171753 update to OMSI". Several workers (SSIS runs) walk up to the board looking for work.

1. Take a card. A worker grabs a free card and writes on it: "Taken by Worker A, until 10:05." Taking the card and writing the name is a single action, so two workers can't take the same card at the same moment. Other workers simply pick a different card instead of standing in line.
2. Do the work. The worker goes off and does the job, such as calling the LumberTrack API or inserting into OMSI. Nothing is locked while it works. The card only carries a name and a due time.
3. Ask for more time (optional). If the job is slow, the worker comes back and says "I'm still on it, extend my time." That only works if the card still has its name and the time hasn't run out.
4. Hand in the result. The worker says "Done" or "Failed." The board accepts this only if the card still shows that worker's name.
5. If the worker never comes back, the due time passes. The next worker who checks the board sees an overdue card, takes it, and the first attempt is recorded as "Abandoned".

That's what "claim-based lease" means: **claim** is taking the card, and the **lease** is the name plus the due time.

## 3. The lease in action: five stories

**Story 1,** a normal day. Worker A takes the card for Shipment 4171753, sends it to OMSI in under a second, and hands in "Done." Nobody else ever saw the card as available.

**Story 2,** two workers at the same moment. Two SSIS runs overlap, which can happen when one run takes longer than the 10-minute schedule. Both look at the board at the same time. Worker A gets card 9001, and Worker B automatically gets card 9002. Neither waits, and neither does the other's job. The design's test showed this with 8 parallel workers and 400 items: every item was done exactly once and none were lost.

**Story 3,** the worker crashes. Worker A takes card 9001 at 10:00 with a 5-minute lease, then the server is patched and the run is killed. The card still says "Worker A until 10:05." At the next scheduled run after 10:05, Worker B sees the overdue card, takes it, and the shipment goes out. Nothing is lost; it's just late, by up to the lease time plus one schedule interval. The workers don't need to coordinate with each other for this to work.

**Story 4,** the slow worker comes back (the "zombie"). Worker A takes the card and then freezes for 6 minutes. Its time runs out, Worker B takes over, finishes, and hands in "Done." Then Worker A wakes up and also tries to hand in "Done." The board says the card is no longer Worker A's and rejects it. For OMSI on the same server, Worker A's insert is rolled back together with its rejected "Done", so only Worker B's write survives. This rejection is what "fencing" means.

**Story 5,** a long job. Calling the LumberTrack API for 50 shipments at about 10 seconds each takes around 8 minutes, which is more than a 5-minute lease. The worker must either ask for more time before each shipment or take fewer cards at once. Otherwise its later cards run out of time while it's still working, and another worker repeats them.

## 4. Why the lease alone isn't enough, and how idempotency helps

Go back to Story 4, but make the target an external system (the LumberTrack API over HTTP) instead of OMSI on the same server:

 - Worker A sends the freight accrual to LumberTrack. LumberTrack accepts it.
 - Before Worker A can record "Done", it freezes and its time runs out.
 - Worker B takes over and sends the same accrual again.

The board can reject Worker A's late "Done", but it can't undo a call that has already reached another system. Without help, LumberTrack would now have two accruals.

**Idempotency fixes this.** Every work item gets a fixed reference number when it's created, for example SHIP-4171753-REV21-ACCRUAL. Every send includes that number. LumberTrack keeps a list of numbers it has already processed:

 - The first send with that number is processed normally.
 - The second send with the same number gets the reply "Already have it" (for example HTTP 409). The ledger treats that reply as success.

The result is that the action can happen twice, but the effect only happens once.

The rule that makes this work: the reference number must be created once and never change between attempts. If each retry made a new number, LumberTrack couldn't recognize the duplicate. That's why I listed this earlier as a go-live check (D3).

## 5. How OCC works: a different problem

OCC isn't about workers and jobs. It's about a person, or a process, making a decision based on information that may already be out of date.

**Story 6,** a support user with an old screen.

 - At 9:00, Sarah opens Shipment 4171753. It shows "In review". The screen also quietly remembers a version stamp, say version 7.
 - At 9:05, LumberTrack sends a newer revision, and the shipment becomes "Modified", version 8.
 - At 9:10, Sarah, still looking at her 9:00 screen, clicks "Mark Cancelled."

When she saves, the system checks whether the record is still version 7. It isn't, so the save is refused with the message "This record changed since you opened it. Please reload." Sarah reloads, sees the new revision, and decides again.

Without OCC, her "Cancelled" would silently overwrite a change she never saw. Nobody was blocked while she had the screen open; the check happens only when she saves.

**Story 7,** two support users click Retry at the same time. Both see the same dead-letter item and click "Retry". The first click succeeds. The second gets "Only failed items can be retried", because the item is no longer in the failed state. Exactly one retry happens.

## 6. Side-by-side comparison in plain terms
|	  | Lease (checkout ticket)	| Idempotency (reference number)	| OCC (version check) | 
| --- | --- | --- | ---|
| Main job |	One worker per job at a time	| A repeated action has no extra effect	 | Don't save decisions based on old information |
| When it acts	| Before the work starts, and again when the result comes back	| When the target receives the request	| At the moment of saving |
| Blocks anyone?	| Others skip the job until the time runs out	| No	| No, nobody waits |
| If the actor crashes	| Job comes back automatically after the time runs out	| Not affected	| Nothing to clean up |
| Advantages	| Stops duplicate work before it happens; recovers from crashes by itself; many workers can share the queue; every attempt is recorded	| Only reliable protection for external systems; simple to understand; works however many times something is retried	| Very light; good for people who take their time; no time limits to tune; no locks left behind |
| Disadvantages	| Needs a sensible time limit (too short means repeats, too long means slow recovery); a crash delays the job; can't undo a call already made outside the database	| The receiving system has to support it; the number must never change; the target must keep a list of processed numbers	| Only finds the problem when you save, after any work is already done; the person has to redo the decision; with many people editing the same record, many saves fail |
| Simple rule	| Use it for tasks	| Use it for effects on other systems	| Use it for decisions on shared records |

## 7. When to use each one

Ask these questions in order:

1. Is a worker (a program) doing a job, possibly slowly, and could it crash partway? Use a lease.
2. Does that job change something outside your database, such as an API or a file transfer? Add an idempotency key, and make the receiving system check it.
3. Is a person or process saving a change based on something it read earlier? Use OCC.
4. Is it a quick change inside the database that takes milliseconds? A short ordinary lock is enough, as the Publish step does today.

| Situation in your integration	| Mechanism |
| --- | --- |
| SSIS runs sending shipment updates to OMSI	| Lease |
| Sending freight accruals or AP to the LumberTrack API	| Lease + idempotency |
| A support user changing a shipment's status in a screen	| OCC |
| Two operators retrying the same failed item	| OCC (a state check)
| A late LumberTrack revision 20 arriving after revision 21	| OCC using the source's revision number, so the older one is ignored |
| Making sure only one inbound harvester runs at a time |	Lease |

## 8. The terms from my earlier review, in plain English

| Term	| Plain meaning | 
| --- | --- |
| RCSI (read committed snapshot isolation)	| A database setting where readers see a recent saved copy of a row instead of waiting for someone else to finish changing it. It's fast, but the copy can be a moment out of date.|
| FIFO NOT EXISTS	| The claim's rule that it won't take card #2 for a shipment while card #1 for the same shipment is still unfinished, so updates arrive in order. |
| D1 (RCSI + FIFO)	| Because of the snapshot setting, the "is card #1 finished?" check could look at a slightly old copy, see card #1 as done when an operator has just reopened it, and send card #2 too early. The fix makes that one check read the live row. |
| Supersede vs. Leased	| When a newer version of a shipment arrives, older cards that haven't been sent can be replaced. The question was whether a card someone is working on right now should also be replaced. My recommendation is no, because its call to an external system may already be under way. |
| Fencing	| Rejecting results from a worker that no longer owns the card, as in Story 4. |
| Zombie	| A worker that froze, lost its card, and later woke up still thinking it owns the job. |

**The takeaway**: the lease controls who does the work, idempotency means repeating it does no harm, and OCC stops decisions based on out-of-date information. A reliable integration needs all three, each in its own place.
