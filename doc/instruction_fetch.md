# Instruction Fetch Unit Design: In-Order vs. Out-of-Order

## 1. Role of the Instruction Fetch (IF) Unit

The fetch unit's job every cycle:
1. Generate a fetch PC
2. Read N instructions (a "fetch block") from the I-cache
3. Predict the *next* fetch PC using branch prediction structures (BTB, BHT, RAS)
4. Hand the fetch block + predictions downstream (decode, or a fetch queue)
5. Recover cleanly when a prediction turns out wrong

The three structures you asked about all live in this unit (or right next to it):

| Structure | Predicts | Purpose |
|---|---|---|
| **BTB** (Branch Target Buffer) | Is this a branch? Where does it go? | Gives the *target address* without waiting for decode/execute |
| **BHT** (Branch History Table) | Taken or not-taken? | Gives the *direction* for conditional branches |
| **RAS** (Return Address Stack) | Where does a `ret` go? | Predicts function-return targets (BTB is bad at this) |

---

## 2. Shared Structures — Design Details

### 2.1 BTB (Branch Target Buffer)

Indexed by PC (low bits), tagged with upper PC bits to detect aliasing.

```
Index = PC[log2(sets)+offset-1 : offset]
Tag   = PC[higher bits]

BTB Entry:
+------+----------------+---------------+----------+
| Tag  | Target Address | Branch Type    | Valid    |
|      |                | (cond/uncond/  |          |
|      |                |  call/ret/jmp) |          |
+------+----------------+---------------+----------+
```

- Usually **set-associative** (4–8 way) to reduce conflict evictions.
- Only allocated on the *first time a branch is seen* (fill on misprediction/decode).
- Lookup happens in parallel with I-cache access, using the **same fetch-PC**, so the target is ready by the time you need the next-fetch PC.
- `branch type` field lets fetch route calls/returns to the RAS instead of (or in addition to) the BTB.
- Size trade-off: bigger BTB → fewer "BTB misses" (branch exists but not tracked) → but higher access latency; latency-critical since it's on the fetch critical path (often 1-cycle, sometimes pipelined to 2).

### 2.2 BHT (Branch History Table) / Direction Predictor

BTB tells you a branch *exists* and its target; BHT tells you whether to *take* it.

Simplest form — **2-bit saturating counter**, indexed by PC:

```
00: Strongly Not-Taken
01: Weakly Not-Taken
10: Weakly Taken
11: Strongly Taken
```

Real designs almost always go further:

- **gshare**: index = hash(PC, Global History Register). Captures correlation between branches (e.g., "if branch A was taken, branch B usually is too").
- **Local history predictor**: per-branch history register, captures per-branch patterns (loops).
- **Tournament / TAGE-style predictors**: multiple predictor tables of different history lengths, chosen by a meta-predictor or tag-match confidence. This is what most modern high-performance cores use.
- The Global History Register (GHR) is a shift register of the last N taken/not-taken outcomes, speculatively updated at *prediction* time and corrected at *resolution* time (needs checkpoint/repair, see §4).

### 2.3 RAS (Return Address Stack)

A small hardware **stack** (typically 8–32 entries), not a table:

```
push(PC+len)  on a predicted 'call'
pop()         on a predicted 'ret'  -> predicted target
```

- Because calls/returns nest, LIFO order gives near-perfect prediction for normal control flow.
- Needs a **speculative top-of-stack pointer** plus a **checkpoint/repair mechanism**: on a mispredicted branch that turns out to be a call/return (or on a flush), the RAS pointer must be rolled back, or you get corrupted return predictions for the rest of execution.
- Common hardening: multiple *shadow copies* of the RAS pointer, one per outstanding speculative branch, so recovery is O(1).
- RAS overflow/underflow: handle gracefully (e.g., saturate, or fall back to BTB) — don't corrupt state on deep recursion beyond stack depth.

---

## 3. In-Order CPU Fetch Design

In an in-order core, fetch, decode, and execute all proceed in program order and roughly in lockstep. Fetch is simple because there's no need to track many in-flight predictions — usually only 1 (occasionally 2) branches are "in flight" (predicted but not resolved) at a time.

```
Cycle:      IF1        IF2         ID          EX
            |          |           |           |
PC ----> I$ access --> BTB/BHT --> Decode  --> Resolve
            |          lookup      |           branch
            |          (parallel)  |           |
            +--- next PC = BTB target if predicted taken
                          = PC+4/8  if predicted not-taken
```

Design characteristics:

- **Single fetch PC, single prediction per cycle.** BTB/BHT/RAS are looked up once, in parallel with the I-cache read, using the current fetch PC.
- **Predict → fetch next block immediately.** The predicted target (from BTB, or PC+size if BHT says not-taken, or RAS pop if it's a return) becomes next cycle's fetch PC, so fetch doesn't stall waiting for decode.
- **Shallow speculation depth.** Because everything downstream is in-order and usually low-issue-width, you rarely need more than one misprediction "in flight" — recovery is simple: flush the pipeline behind the mispredicted branch and re-fetch.
- **Recovery**: on misprediction (detected in EX, or ID for very simple cores), flush IF/ID/EX stages younger than the branch, restore PC to the correct target, restore RAS pointer, update BHT/BTB with the outcome.
- No need for a decoupled fetch queue — fetch bandwidth roughly matches decode/execute bandwidth, so backpressure is simple (stall fetch if pipeline stalls).

---

## 4. Out-of-Order CPU Fetch Design

OoO cores decouple fetch far ahead of execute (fetch may be dozens to 100+ instructions ahead of where branches actually resolve). This changes the fetch design significantly:

```
   +--------+     +--------------------+     +------------------+     +-----------+
   |  PC    | --> | I$ + BTB/BHT/RAS   | --> |  Fetch Target     | --> | Decode /  |
   | Gen    |     | (predict next PC)  |     |  Queue (FTQ)      |     | Rename /  |
   +--------+     +--------------------+     +------------------+     | Dispatch  |
        ^                                          |                 +-----------+
        |                                          v
        +------------------ backpressure ---- (queue fills, fetch stalls)

   Branch resolves later in EX/ROB --> compares against prediction
   --> on mispredict: flush FTQ + pipeline, restore checkpointed
       predictor state (GHR, RAS pointer), redirect PC
```

Key differences from the in-order design:

**a) Decoupled fetch via a Fetch Target Queue (FTQ) / Instruction Fetch Queue**
Fetch runs ahead of decode/rename/dispatch, buffering fetched blocks (and their predicted-next-PC) in a queue. This lets fetch tolerate I-cache misses or decode bubbles without stalling immediately, and lets fetch "run ahead" to build up a buffer of ready-to-issue work — essential for hiding execution latency in a wide OoO machine.

**b) Multiple predictions in flight, requires checkpointing**
Since many branches can be fetched (predicted) before any of them resolve, every speculative predictor-state update needs to be **checkpointed** and **repairable**:
- **GHR (global history register)**: checkpoint the GHR value at every predicted branch (or use a recoverable structure like a RAS-style shift-register with pointer checkpoints) so a later misprediction can roll history back to exactly the right point.
- **RAS pointer**: checkpoint per speculative call/return, as noted above — with many outstanding calls/returns, you need several shadow pointers or a full checkpoint per branch.
- Checkpoints are usually tagged with the ROB entry / branch tag of the branch that created them, so recovery is: "restore checkpoint associated with mispredicted branch tag, discard everything younger."

**c) Higher fetch bandwidth & wider blocks**
To feed a wide OoO backend (4–10+ wide issue), fetch typically reads a full cache line or multiple basic blocks per cycle, and needs **multiple branch predictions per cycle** if there's more than one branch in the fetch block (common in modern designs — predict up to 2 taken branches per cycle, for example).

**d) More sophisticated, higher-latency predictors are affordable**
Because fetch is decoupled and buffered, OoO designs can afford **multi-cycle, larger, more accurate predictors** (TAGE, perceptron, multi-level BTBs — small L0 BTB for 1-cycle access + large L1 BTB for 2–3 cycle access on L0 miss) without directly stalling the pipeline, as long as the FTQ has enough slack.

**e) Misprediction recovery is more expensive and needs careful ordering**
- Detected typically at **execute** (branch unit) but the *authoritative* recovery point is often at **commit/ROB** for some designs (to also handle recovery from mis-speculated memory/exception cases uniformly), though execute-time redirect is used to reduce misprediction penalty.
- Recovery must: flush FTQ, flush in-flight instructions younger than the branch (via ROB tags), restore rename map (RAT) checkpoint, restore predictor checkpoints (GHR, RAS pointer), and redirect fetch PC — all while the fetch unit resumes fetching from the correct path as fast as possible (this redirect latency is the "misprediction penalty," often 10–20+ cycles in deep OoO pipelines).
- Because the penalty is large, **prediction accuracy matters enormously more** in OoO than in-order — this is why OoO cores invest heavily in TAGE/perceptron-class predictors, large BTBs, and RAS depth/redundancy.

**f) Return-Address Stack needs redundancy**
With many speculative calls in flight, a single RAS pointer isn't enough — OoO designs typically keep multiple checkpointed copies of the RAS pointer (or a full shadow RAS) indexed by branch/ROB tag, so a misprediction can restore the RAS to exactly the right depth without corrupting future return predictions.

---

## 5. Side-by-Side Comparison

| Aspect | In-Order Fetch | Out-of-Order Fetch |
|---|---|---|
| Fetch/execute coupling | Tightly coupled, near-lockstep | Decoupled via FTQ, fetch runs far ahead |
| Predictions in flight | ~1 at a time | Many (10s–100s), need checkpointing |
| BTB/BHT complexity | Simple, single-cycle, modest size | Multi-level (L0/L1), large, higher accuracy predictors (TAGE etc.) |
| RAS management | Single pointer, simple rollback | Multiple checkpointed copies / shadow RAS |
| GHR/history management | Simple speculative update + rollback on flush | Per-branch checkpointed, restored via branch tag |
| Fetch bandwidth | Matches narrow pipeline (~1-2 branches/block) | Wide, multiple branches predicted per cycle |
| Misprediction cost | Small pipeline flush | Large — flush ROB/RAT/FTQ, restore checkpoints |
| Design priority | Simplicity, low area/power | Prediction accuracy, deep speculation support |

---

## 6. Practical Sizing / Design Guidelines

- **BTB**: L0 (fast, small, 32–128 entries, 1-cycle) + optional L1 (slower, 1K–8K entries, 2–4 cycle, used on L0 miss). Fully-associative or high-way set-associative.
- **BHT/direction predictor**: TAGE-style with several tagged tables (history lengths geometrically increasing, e.g. 5/15/44/130 bits) is the current standard for high-performance OoO cores; a simple gshare/2-bit table is adequate for small in-order cores.
- **RAS**: 16–32 entries is typical; deeper for cores expecting heavy recursion/deep call chains; always pair with checkpoint/repair logic in OoO designs.
- **FTQ depth**: sized so fetch can run tens of cycles ahead of dispatch — deep enough to hide typical branch resolution + redirect latency.

---
