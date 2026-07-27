# RISC-V TLB Design: In-Order, Out-of-Order, and Unified

## 1. RISC-V-Specific TLB Requirements (baseline for all designs)

| RISC-V feature | TLB implication |
|---|---|
| **Sv32 / Sv39 / Sv48 / Sv57** (`satp.MODE`) | Multi-level page table walk (2/3/4/5 levels); TLB must know current mode to interpret VA correctly |
| **ASID** (`satp.ASID`) | TLB entries tagged with ASID so entries from different address spaces can coexist without flushing on context switch |
| **Superpages** (megapage/gigapage/etc.) | TLB entries need a variable **page-size field**, not a fixed 4KB granularity — matters for both lookup (multiple possible tag masks) and fill |
| **`sfence.vma [rs1] [rs2]`** | Selective or global TLB invalidation: by VA, by ASID, by both, or flush-all — TLB needs invalidation logic that respects the operand encoding |
| **G-stage / two-stage translation (H-extension, hypervisor)** | If supporting virtualization: TLB entries may need both GVA→GPA and GPA→HPA components, or a combined GVA→HPA cache — adds a dimension but same core structure |
| **PMA/PMP** | Physical-side checks happen *after* translation, independent of TLB permission bits — both gate the access |
| **Precise exceptions required** | Page faults must be attributable to the exact instruction and not taken speculatively/out of order |

---

## 2. Core TLB Structure (shared foundation)

```
TLB Entry:
+-----+------+---------------+------------------+-----------------------+
| VPN | ASID | PPN           | Page size        | Permission bits (R/W/X/
|     |      |               | (4K/2M/1G/...)    | U/G/A/D/V)             |
+-----+------+---------------+------------------+-----------------------+

Lookup: compare (VPN masked by page-size, ASID) against all ways
        -> hit: return PPN + perms
        -> miss: trigger page-table walk
```

- **Set-associative or fully-associative** — L1 DTLB is usually small (32–64 entries)
  and fully-associative or highly-associative for good hit rate; an optional larger L2
  TLB (512–2048 entries) can be set-associative for area efficiency.
- **Superpage handling**: either (a) a separate small fully-associative array just for
  superpages (common — superpages are rare but must never miss due to eviction by 4K
  entries), or (b) a per-entry size/mask field in a unified array, with lookup masking
  VPN bits according to each entry's own size.
- **Page Table Walker (PTW)**: hardware state machine that walks Sv39/Sv48 levels on a
  miss, itself issuing memory reads (which are cacheable, and can even hit in the
  regular data cache) — these intermediate reads need the *same* protection/PMA
  checking as normal loads.
- **`sfence.vma` handling**: decode `rs1`/`rs2` to determine scope (single VA + ASID,
  all VA for one ASID, single VA for all ASID, or global flush), and either
  invalidate matching entries directly (if array is small enough to search
  combinationally) or set a "flush pending" generation counter that entries check
  against (cheap global flush trick — bump a counter, treat any entry with an older
  generation as invalid, lazily reclaim).

This structure — array + PTW + `sfence.vma` decode — is **identical** in both machine
types. The difference is entirely in *how many translations can be outstanding at
once* and *what happens when one has to be redone*.

---

## 3. In-Order TLB Design

### 3.1 Single-pipe in-order

```
   VA (from AGU) --> TLB lookup --> hit? --> PA to cache stage
                          |
                        miss
                          |
                          v
                    stall pipeline, invoke PTW
                          |
                    PTW walks levels (each level = a memory read,
                    itself possibly needing translation for
                    non-identity-mapped page tables — but page
                    table base is physical, so PTW reads are PA
                    directly, no recursion needed)
                          |
                    fill TLB entry, retry lookup
                          |
                    resume pipeline
```

- Because only one memory op is in flight, a TLB miss simply **stalls the whole
  pipeline** until the PTW completes. No speculation, no need to track "which
  instruction owns this walk" — there's only ever one.
- Fault detection (page fault, access fault) can be handled essentially
  synchronously: since there's nothing speculative in flight, the trap can be taken
  close to where it's detected (though still logically "at commit" for cleanliness —
  in a simple in-order core commit is often the same cycle as execute).

### 3.2 Superscalar in-order (N-wide)

```
   VA0, VA1, ... VAN-1  -->  N parallel TLB lookup ports  -->  hit/miss per lane
                                        |
                         any miss in the group?
                                        |
                    stall the ENTIRE group (simplest, common choice)
                    -- or --
                    let hits proceed, only stall the missing lane(s)
                    and everything *younger* than it in program order
                                        |
                              PTW walks (one at a time, or
                              a small number of parallel walkers
                              if misses can coincide)
```

Design choices:
- **Simplest correct option**: any TLB miss in the group stalls the *entire* group
  (including hits) until the walk completes, then re-lookup everyone. Loses some
  throughput on hit lanes but avoids any need to track partial progress.
- **Better**: let hit lanes complete and retire; only the missing lane and anything
  younger (in-order!) stalls. Requires the pipeline's normal in-order stall/bubble
  machinery — no new tracking structure needed beyond what a superscalar in-order
  core already has for other same-cycle hazards (see the LSU discussion).
- **Multiple simultaneous misses** (two lanes miss in the same group): either
  serialize (walk one, then the other) or provide 2 PTW state machines. Serializing
  is usually fine since simultaneous misses are rare and this is already the
  "slow path."
- Since issue is still strictly in program order, there is still **no need to track
  "which in-flight instruction requested this walk against a later squash"** — by the
  time a walk completes, there's nothing younger that could have been squashed out
  from under it (aside from an interrupt, which is handled like any other precise
  trap point).

---

## 4. Out-of-Order TLB Design

The core array + PTW + `sfence.vma` logic is unchanged. What's new: **many
translations can be outstanding simultaneously, for instructions that may later be
squashed**, and the TLB itself becomes a shared, contended, pipelined resource.

```
   N x AGU (from scheduler, any age/order)
        |
   N x TLB lookup ports  --> hit --> PA, tagged with ROB id, continue to cache
        |
       miss (per lane)
        |
   Miss Status Handling Register (MSHR)-like structure for TLB misses:
   +-----------------------------------------------------------+
   | Outstanding walk entry: { VA, ASID, ROB tag,               |
   |   requesting-instruction still valid?, level in progress } |
   +-----------------------------------------------------------+
        |
   PTW (1 or more walkers, often pipelined/non-blocking)
        |
   fill TLB on completion --> wake up the (possibly several)
   loads/stores in the LQ/SQ or reservation stations that were
   waiting on this VA's translation (merge duplicate misses to
   the same page — classic "miss under miss" coalescing)
```

Key additions beyond the in-order design:

**a) Non-blocking, MSHR-style miss tracking**
A TLB miss must **not** stall the whole pipeline — other independent instructions
keep executing. So outstanding walks are tracked in a small structure (analogous to
cache MSHRs), each entry recording enough to wake the right consumer(s) later.
Multiple loads/stores missing on the *same* page should be **coalesced** into one
walk with multiple waiters, not one walk each.

**b) Squash-awareness**
Because the requesting instruction might get flushed (mispredicted branch, exception
elsewhere) before its walk completes, each outstanding-walk entry needs a way to
detect "is my requester still alive?" — usually a comparison against the current ROB
head/flush point. If squashed, the walk can either be allowed to complete anyway (and
just discarded, simplest) or actively cancelled (saves PTW bandwidth, more complex).
Simplest and most common: **let it finish, discard the result if squashed** — PTW
bandwidth is cheap relative to added complexity of cancellation.

**c) Speculative translations must not corrupt architectural state**
Since a page-table-walk might be for an instruction on a *speculative* (possibly
wrong) path, filling the TLB itself is generally fine (TLB fill is a
performance-only structure, not architectural state — filling it "wastes" an entry
at worst). But **faults must be deferred**: a translation that hits a page fault must
be tagged on the instruction and only actually trap if that instruction survives to
commit — exactly the same "hold fault to commit" rule as the LSU design.

**d) TLB as a shared, ported, pipelined resource**
With N loads/stores issuing per cycle from a scheduler (not a fixed static group),
the TLB needs N lookup ports, but *contention* is now dynamic (whichever ops the
scheduler picks that cycle) rather than statically known — same physical requirement
as superscalar in-order, but the arbitration logic has to interface with the OoO
scheduler's picking/replay mechanism instead of a fixed decode-time hazard checker.

**e) `sfence.vma` in OoO is trickier**
`sfence.vma` must appear to execute atomically with respect to program order (it's
essentially a fence for translation state). In an OoO core this typically means:
treat it like a memory-ordering fence — stall younger loads/stores (and their TLB
lookups) until the sfence has drained/completed, and don't let any *older*
translations that are still in flight fill the TLB after the flush point (or, more
simply, drain all outstanding walks before executing the sfence, then flush, then
resume). Getting this wrong is a classic correctness bug — treat it conservatively
(drain + flush + resume) unless a design specifically optimizes it.

---

## 5. Unified TLB Design (one structure, configurable)

Same methodology as the fetch and LSU designs before: one core array + PTW + fence
logic, extended by configuration.

```
                +---------------------------------------------------+
                |            TLB CORE (array + PTW + sfence.vma)     |
                |   N lookup ports, ASID-tagged, superpage-aware      |
                +---------------------------------------------------+
                       |                          |
              +-----------------+       +----------------------+
              | Blocking stall  |       | Non-blocking MSHR-    |
              | on miss         |       | style miss tracking   |
              | (in-order)      |       | (OoO only)             |
              +-----------------+       +----------------------+
                                                   |
                                          +----------------------+
                                          | Squash-awareness /    |
                                          | fault-defer-to-commit |
                                          | (OoO — matters more,  |
                                          |  same mechanism as    |
                                          |  in-order but trivial |
                                          |  there)                |
                                          +----------------------+
```

| Parameter / mechanism | In-order (1-wide or superscalar) | Out-of-order |
|---|---|---|
| Lookup ports | 1 or N (fixed group) | N (dynamically contended) |
| Miss handling | Stall (whole pipe or whole group) | Non-blocking, MSHR-tracked, coalesced |
| Concurrent outstanding walks | Effectively 1 (or a couple, group-bounded) | Many, window-bounded |
| Squash handling | Not needed (nothing younger to squash mid-walk in practice) | Needed — walks tagged, discarded if requester squashed |
| Fault handling | Can trap close to detection (still cleanest as hold-to-commit) | Must hold-to-commit (required for correctness) |
| `sfence.vma` | Simple: pipeline is already near program order, flush is nearly immediate | Needs drain-then-flush-then-resume w.r.t. in-flight walks |
| Superpage / ASID / multi-level walk logic | Same block | Same block |

**Takeaway**: exactly like the LSU, the array format, page-table-walk state machine,
ASID tagging, superpage handling, and `sfence.vma` decode are **one shared design**.
The only real additions for OoO are (1) making misses non-blocking via an MSHR-like
tracker with coalescing, and (2) squash-awareness so a walk for a since-flushed
instruction doesn't corrupt anything. Build the in-order version first (blocking
stall-on-miss is trivially correct), then add the non-blocking miss tracker as an
extension to get OoO behavior — the core translation logic never has to change.

---
