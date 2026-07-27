# RISC-V LSU: In-Order Superscalar vs. Out-of-Order vs. Unified

---

## PART 1: In-Order Superscalar LSU

Superscalar means **multiple loads/stores per cycle**, still in strict program order.
This adds real complexity beyond the single-pipe in-order design: instructions in the
*same* fetch/issue group can depend on each other, and multiple memory ops now contend
for cache ports simultaneously.

### 1.1 Pipeline (N-wide, e.g. N=2)

```
        AGU x N          TLB x N (or shared, banked)      D-Cache (N ports or banked)
   +-------------+      +------------------------+       +----------------------+
   | rs1+imm (0) |  ->  | VA->PA (0)              |  ->   | port 0 access        | -> align/ext (0) -> WB
   | rs1+imm (1) |  ->  | VA->PA (1)              |  ->   | port 1 access        | -> align/ext (1) -> WB
   +-------------+      +------------------------+       +----------------------+
          |                                                        ^
          +--------- intra-group hazard check (see 1.2) -----------+
```

### 1.2 The New Problem: Intra-Group Hazards

Because program order is enforced *across* groups but N ops execute *together* within
a group, you must detect and handle same-cycle dependencies **within the group itself**:

```
Example group (2-wide): 
  op0: sw  x5, 0(x6)      ; store to address A
  op1: lw  x7, 0(x6)      ; load from address A   <- same cycle as op0!
```

Handling options, in order of complexity:

1. **Conservative stall**: detect same-cycle load/store address overlap (or just
   "can't prove no overlap" — addresses aren't final until AGU) and **stall op1 to
   the next cycle**, so it sees op0's store via the normal store-buffer forward path.
   Simple, correct, costs a bubble on the (rare) hazard case.
2. **Same-cycle forwarding mux**: compare addresses combinationally within the cycle;
   if op0 (older, lower pipe) writes exactly the bytes op1 needs, forward the store's
   data directly into the load's align/extend stage in the same cycle. Requires the
   comparator + mux to fit in the cycle time — adds critical-path pressure, but avoids
   the stall. Most real superscalar in-order cores do this for the common 2-wide case.
3. **General rule**: only pipe *i* forwards to pipe *j* if *i < j* (i.e., the earlier
   pipe is program-order-older) — never the reverse, since that would violate program
   order within the group.

### 1.3 Cache Port Contention / Banking

Two loads (or a load+store) in the same group may want the same cache bank/way:

- **Multi-ported cache** (true dual-port array): most flexible, most area/power cost.
- **Banked cache** (e.g., 8 banks by address bits [5:3]): cheaper — N accesses proceed
  in parallel *if* they land in different banks; a **bank conflict** forces one op to
  stall a cycle. Add a bank-conflict detector before the cache stage; on conflict,
  replay the lower-priority (younger) op next cycle.
- Store buffer / store queue similarly needs **N write ports** (or arbitration) so two
  stores in a group can both allocate an entry in the same cycle.

### 1.4 Store Buffer / Forwarding — same logic as single-pipe, wider ports

- Store buffer entries and the forwarding CAM from the earlier single-pipe design are
  unchanged in *concept*; just widen: N stores can allocate per cycle, and each of the
  N loads needs its own CAM search port against the buffer.
- Because issue is still in-order, **no memory disambiguation predictor is needed** —
  exactly like the single-pipe in-order case. All older stores (including same-group
  older-pipe stores, via 1.2) are already resolved or handled by the intra-group logic.

### 1.5 TLB — shared or replicated?

- Small/cheap cores: **one TLB port, arbitrate** — if both ops need translation in the
  same cycle, one stalls. Loses some superscalar throughput on TLB-heavy code.
- Higher-performance in-order designs: **replicate TLB read ports** (single tag/data
  array, dual read ports) so both ops translate in parallel — common since read-only
  lookup ports are cheaper to replicate than full independent TLBs.

### 1.6 Summary of what superscalar *adds* over single-pipe in-order

| New mechanism | Why needed |
|---|---|
| Intra-group hazard detection + same-cycle forward mux | Ops in one group can alias each other |
| Bank-conflict detection / multi-ported cache | N accesses want the cache at once |
| Multi-port store buffer alloc + N forwarding CAM searches | N stores/loads per cycle |
| Multi-port (or replicated) TLB | N translations per cycle |
| **Still no** load queue or disambiguation predictor | Program order across *and within* groups is still enforced |

---

## PART 2: Out-of-Order LSU (recap, superscalar by nature)

OoO cores are inherently "superscalar" in the sense of multiple pipes, but the harder
problem isn't intra-group hazards (there's no fixed "group" — a scheduler picks ready
ops each cycle) — it's that **any** load can execute before **any** older store,
regardless of grouping, because they're picked by data-readiness, not program order.

```
   Store Queue (SQ)                    Load Queue (LQ)
   { addr, data, byte-mask,            { addr, size, data, ROB tag,
     ROB tag, drained? }                 "verified safe" bit }
        |                                      ^
        | CAM search on load exec              | CAM search on every
        v (forwarding)                         | store addr resolution
   +--------------------------------------------------------+
   |     N x AGU -> N x TLB -> N x Cache port -> Align/WB    |
   +--------------------------------------------------------+
        ^
        | store-set predictor: "does this load need to wait
        |  for an older store with unresolved address?"
```

Key mechanisms (detailed in the earlier design, summarized here for comparison):

- **Memory disambiguation**: store-set predictor (or conservative wait, or
  speculate-and-replay) decides whether a load can jump ahead of older stores.
- **Load Queue + violation detection**: every store, when its address resolves,
  CAM-checks against *all younger* loads in the LQ (not just same-cycle ones) —
  because the load could have executed many cycles earlier.
- **Squash/replay**: a detected violation flushes the offending load and its
  dependents, regardless of which "cycle group" they were fetched in — there is no
  group concept at execute time.
- **Multi-ported/banked cache, TLB replication**: same physical needs as superscalar
  in-order (N loads/stores per cycle), but now serving *dynamically scheduled* ops
  rather than a fixed static group — so the port-conflict resolution has to interact
  with the OoO scheduler's picking logic, not just a decode-time hazard check.

---

## PART 3: In-Order Superscalar vs. Out-of-Order — Comparison

| Aspect | In-Order Superscalar | Out-of-Order |
|---|---|---|
| Issue order | Program order (in fixed-width groups) | Data-readiness order, any age |
| Hazard scope | Only within the current issue group (small, static) | Across the *entire* window (LQ/SQ depth), dynamic |
| Detection mechanism | Static comparators within a group, decode/issue time | CAM search against deep queues, continuously, at execute time |
| Disambiguation predictor | **Not needed** — order guarantees safety | **Needed** (store-set or similar) to get performance benefit |
| Recovery on hazard | Stall one cycle (same-cycle forward or bubble) | Squash + replay, possibly many cycles of work lost |
| Load Queue | **Absent** | **Present**, core structure |
| Store Queue depth | Shallow (covers commit latency only) | Deep (covers full speculation window) |
| Cache/TLB porting need | N ports for the fixed group width | N ports, but contended by dynamically-picked ops |
| Complexity driver | Making N-wide *fixed-order* execution correct & fast | Making *any-order* execution correct & fast |
| Peak achievable memory ILP | Bounded by group width N | Bounded by queue depth / scheduler window (usually much higher) |
| Design/verification effort | Moderate — hazard space is small and static | High — hazard space includes all pairwise age combinations in a deep window |

**Intuition**: superscalar in-order only has to worry about hazards *within a small,
statically-known group* — that's a bounded, cheap problem. OoO has to worry about
hazards across the *entire dynamic scheduling window* — same fundamental correctness
requirement (don't let a load see stale data), but the hazard space is unbounded in
time, so it needs persistent tracking structures (LQ/SQ + CAM) instead of one-shot
static comparators.

---

## PART 4: The Unified LSU (design that scales across both)

Same idea as before, restated with the superscalar detail folded in: build one N-wide
core pipeline, then add/remove structures by configuration.

```
                    +---------------------------------------------------------+
                    |         N-WIDE LSU CORE PIPELINE                        |
                    |  N x (AGU -> TLB -> Cache port -> Align/Fwd -> Commit)   |
                    +---------------------------------------------------------+
                       |                    |                    |
              +----------------+   +------------------+   +------------------+
              | Intra-group    |   | Store Queue       |   | Load Queue       |
              | hazard/forward |   | (always present,  |   | (OoO only;       |
              | mux            |   |  depth scales)     |   |  absent/disabled |
              | (in-order only)|   |                    |   |  in-order)       |
              +----------------+   +------------------+   +------------------+
                                                                    |
                                                            +------------------+
                                                            | Store-Set        |
                                                            | Predictor        |
                                                            | (OoO only)       |
                                                            +------------------+
```

| Parameter | In-order superscalar setting | Out-of-order setting |
|---|---|---|
| `WIDTH` (N) | 2–4 typical | 2–6+ typical |
| Intra-group hazard/forward mux | **Active** | Unused (LQ/SQ CAM subsumes it) |
| `QUEUE_DEPTH` (SQ) | Shallow (4–8) | Deep (16–48) |
| Load Queue | Disabled/absent | 16–64 entries |
| Disambiguation predictor | Absent | Present |
| Bank/port arbitration | Static, per fixed group | Dynamic, tied to scheduler picks |
| Fault handling | Held-to-commit (same block) | Held-to-commit (same block) |
| Fences | Stall-until-SQ-drained (same block) | Stall-until-SQ-drained (same block) |

The unified design's core claim still holds, just refined: the **address
generation/translation/cache/align/fault/fence machinery is shared across all three
configurations**; what changes is (a) whether hazard checking is a small static
comparator (in-order, bounded to group width) or a deep CAM-based queue (OoO,
bounded to window depth), and (b) whether a disambiguation predictor exists at all.

---

## PART 5: Three-Way Comparison — Single-Pipe In-Order vs. Superscalar In-Order vs. Out-of-Order

*(using "Unified" as the design methodology that implements all three via
configuration, not a fourth distinct microarchitecture)*

| Aspect | Single-Pipe In-Order | Superscalar In-Order | Out-of-Order |
|---|---|---|---|
| Ops/cycle | 1 | N (fixed width) | N (dynamically scheduled) |
| Program order | Strict | Strict, but N-wide groups | Relaxed (data-driven) |
| Store buffer | Shallow FIFO, 1 write/read port | Shallow FIFO, N ports | Deep SQ, N ports + CAM search |
| Load queue | None | None | Present, core structure |
| Hazard detection | Trivial (nothing else in flight) | Static, within-group comparators | Dynamic, cross-window CAM |
| Disambiguation predictor | Not needed | Not needed | Needed for performance |
| Cache porting | 1 port | N ports or banked | N ports, dynamically contended |
| TLB porting | 1 port | N ports (replicated or arbitrated) | N ports, dynamically contended |
| Recovery cost on hazard | N/A (can't happen) | 1-cycle bubble (same-group only) | Squash + replay (can lose many cycles of work) |
| Design complexity | Lowest | Moderate | Highest |
| Peak memory ILP | 1/cycle | N/cycle, group-bounded | Bounded by window/queue depth, typically > N sustained |
| Typical use case | Microcontrollers, minimal cores | Efficiency/mid-range cores (e.g. in-order server or mobile "efficiency" cores) | High-performance application cores |
| Where it sits in the unified design | `WIDTH=1`, LQ disabled | `WIDTH=N`, LQ disabled, hazard mux active | `WIDTH=N`, LQ enabled, predictor active |

**One-line summary of the progression**: each step relaxes an ordering constraint —
single-pipe in-order has *no* concurrent memory ops to worry about; superscalar
in-order allows concurrency but only within a small, statically-checkable group;
out-of-order allows concurrency across the whole scheduling window, which is the only
one that needs persistent structures (LQ, disambiguation predictor) to stay both
correct and fast — everything else (AGU, TLB, cache, alignment, atomics, fault
deferral, fences) is the same block, just re-parameterized.

---
