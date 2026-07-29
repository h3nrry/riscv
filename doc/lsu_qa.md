# Load/Store Unit Deep Dive — 50 Q&A + RTL Coding Exercises

A dedicated, exhaustive prep set for LSU-focused interview rounds. Organized by topic; work through one section at a time and self-test before checking answers.

---

## Section A: LSQ Fundamentals (Q1–Q10)

**Q1: What is the Load-Store Queue (LSQ), and what problem does it solve?**
A: The LSQ tracks all in-flight memory operations in program order, allowing the CPU to execute loads/stores out of order relative to other instructions while still enforcing correct memory ordering and dependency rules. Without it, the CPU would have to execute all memory ops strictly in order, killing performance.

**Q2: Why do many designs split the LSQ into a separate Load Queue (LQ) and Store Queue (SQ)?**
A: Loads need to search the SQ (for forwarding), but stores don't need to search the LQ. Splitting reduces the number of CAM ports/comparators needed versus one unified structure searched by both, and allows independent sizing (stores often need to live longer, waiting for commit, than loads).

**Q3: What fields does a typical SQ entry contain?**
A: Address (once computed), data (once computed), byte-enable/size, address-valid bit, data-valid bit, and a program-order identifier (e.g., ROB index or sequence number) used for age comparisons.

**Q4: What fields does a typical LQ entry contain?**
A: Address, destination physical register (where the loaded value should be written), size/sign-extension info, a "speculative" or "executed" status bit, and a program-order identifier for ordering checks against stores.

**Q5: Why is the LSQ allocated in-order at dispatch, even though execution is out of order?**
A: Allocating in program order preserves the age information needed for forwarding and disambiguation — you need to know which stores are "older" than a given load without an expensive separate ordering mechanism. The circular buffer position itself encodes age.

**Q6: When is an entry removed from the SQ?**
A: Only at commit/retire (after the store becomes non-speculative), once its data has actually been written to the cache/memory — not simply once its address and data are known.

**Q7: When is an entry removed from the LQ?**
A: Typically once the load has executed and it's confirmed there was no memory-order violation and no exception — often this can happen before commit, since loads don't have the same "irreversible side effect" concern as stores writing memory.

**Q8: Why can't stores write directly to cache at execute time?**
A: They may be speculative (on a mispredicted path, or ahead of an instruction that will fault/except). Writing memory immediately would make that speculative state visible and irreversible. Stores must wait until commit, when they're guaranteed non-speculative.

**Q9: What limits the size of the SQ/LQ in a real design?**
A: Area and timing — the CAM search (associative address comparison) scales in area and critical path delay with the number of entries, since every load must compare against every valid, older store entry each cycle.

**Q10: How does the LSQ interact with the ROB?**
A: The ROB tracks all in-flight instructions for in-order commit and exception handling; the LSQ tracks just the memory-specific state (address/data/ordering) for loads and stores. A store's ROB entry and SQ entry are typically linked, with the ROB signaling "commit" to trigger the SQ to drain that entry to memory.

---

## Section B: Store-to-Load Forwarding (Q11–Q20)

**Q11: What is store-to-load forwarding, and why does it matter for performance?**
A: When a load's address matches an older, in-flight store's address, the store's data is forwarded directly to the load instead of requiring the load to wait for the store to drain to memory and then read it back — this avoids a large stall (potentially many cycles) on a very common pattern (store followed shortly by a load to the same location, e.g., stack spill/reload).

**Q12: Describe the RTL mechanism for forwarding at a high level.**
A: The load's resolved address performs an associative (CAM) search against all valid, older SQ entries. On an address match with a store whose data is ready, a mux selects that store's data as the load's result instead of the cache read data.

**Q13: What happens if the address matches an older store, but that store's data isn't ready yet?**
A: The load must stall (or be marked for replay) until the store's data becomes valid — you cannot forward garbage, and you cannot let the load proceed and read stale memory data either.

**Q14: What happens if there are multiple older stores matching the same address?**
A: The **youngest** among the matching older stores must win (most recent write to that address, per program order) — forwarding from an older-than-necessary store would give a stale value.

**Q15: How do you determine "youngest of the matching older stores" in RTL?**
A: Use age-encoded indices (accounting for circular buffer wraparound) and a priority encoder that selects the match closest in age to the load (but still older than it) among all CAM hits.

**Q16: What is a partial/sub-word forwarding hazard?**
A: When a store writes a subset of the bytes a load reads (e.g., store writes 1 byte, load reads a 4-byte word overlapping that byte), full-word forwarding logic can't directly supply the load's data. Most designs conservatively stall in this case rather than build byte-level merge logic, since it's expensive and rare.

**Q17: Why is full/exact address+size match preferred over partial overlap handling in most designs?**
A: Byte-level merging logic (combining forwarded bytes from the store with fetched bytes from cache) adds significant complexity and timing cost for a case that's uncommon in typical compiled code — the area/complexity tradeoff usually favors stalling.

**Q18: What's the cost of forwarding logic in terms of critical path?**
A: The CAM comparison (address compare across N entries) plus priority encoding for youngest match plus data mux selection all sit in the load's execute-to-writeback timing path — this is frequently one of the tightest timing paths in a high-frequency OoO core.

**Q19: How would you reduce the timing/area cost of a large SQ's forwarding logic?**
A: Options: reduce SQ depth (tradeoff vs. how far ahead stores can be tracked), pipeline the CAM search over multiple cycles (tradeoff vs. forwarding latency), or use a Bloom-filter-style early-reject structure to quickly rule out "no match" cases before doing the full CAM compare, saving power/time in the common no-match case.

**Q20: Does forwarding apply only within the same core, or can it interact with multi-core coherence?**
A: Forwarding here is purely an intra-core, in-flight (not yet committed) mechanism — it's about giving a not-yet-globally-visible store's data to a program-order-younger load in the *same* core. Multi-core coherence (MESI etc.) is a separate mechanism that governs visibility of *committed* stores across cores.

---

## Section C: Memory Disambiguation & Speculation (Q21–Q30)

**Q21: What is memory disambiguation?**
A: Determining, at the time a load wants to execute, whether it depends on (aliases with) any older store whose address isn't yet known — deciding whether it's safe to let the load execute early.

**Q22: What are the two basic disambiguation strategies?**
A: Conservative: stall the load until all older store addresses are known (safe but slow). Speculative: let the load execute assuming no aliasing, and verify/recover later if wrong (fast but requires misspeculation recovery hardware).

**Q23: How does the hardware detect a memory-order violation after speculative load execution?**
A: When an older store's address finally resolves, it performs a CAM search against younger loads in the LQ that have already executed. If a younger load already read from the same address (and didn't get the store's data because the store wasn't ready yet), that's a violation.

**Q24: What's the recovery mechanism for a memory-order violation?**
A: Squash the offending load and all younger instructions (similar to a branch misprediction flush), then re-fetch/re-execute from that load onward with correct data.

**Q25: What is a memory dependence predictor, and why is it used?**
A: A structure (e.g., "store sets") that learns, over time, which load/store pairs have historically aliased. Loads predicted to alias with a specific older, unresolved store are forced to wait for it, while loads with no predicted dependency are allowed to speculate — improving the accuracy/performance tradeoff versus naive "always speculate" or "always stall."

**Q26: What is the "store sets" technique specifically?**
A: Each load and store gets assigned to a "set" via a hash of its PC; if a violation occurs between a specific load and store PC pair, they get associated into the same set, and future instances of that load are made to wait on any unresolved store in its set — building a targeted, PC-based history of aliasing behavior.

**Q27: Why not just always stall loads until all older store addresses are known (avoid speculation entirely)?**
A: Store addresses often take time to compute (e.g., involve an add with a register operand not yet ready), and forcing all loads to wait would serialize much of the memory pipeline unnecessarily, since true aliasing is relatively rare — most loads don't actually depend on nearby stores.

**Q28: What's a "load replay," and what typically triggers it besides memory-order violations?**
A: Re-executing a load that couldn't complete correctly the first time. Triggers include: cache miss requiring a later retry, a bank conflict in a multi-banked cache, a matching-but-not-yet-ready forwarding store, or a TLB miss.

**Q29: How does a load-store unit handle a TLB miss during address translation?**
A: The load/store is marked as not-yet-translated and typically removed from immediate scheduling; a page table walk is initiated, and once the translation is installed in the TLB, the memory op is replayed/rescheduled.

**Q30: Why is address computation (base + offset) usually done in a dedicated AGU (Address Generation Unit) rather than the main ALU?**
A: Separating address generation lets it be scheduled and pipelined independently from general arithmetic, often with a simpler/faster adder tuned specifically for address calculation, keeping the load/store pipeline moving without contending with general ALU traffic.

---

## Section D: Memory Ordering & Consistency (Q31–Q36)

**Q31: What is a memory consistency model, and why does it matter for LSU design?**
A: It defines the rules for what orderings of loads/stores are legal to be observed by other cores/threads. It directly constrains how aggressively the LSU can reorder or speculate memory operations while remaining correct under the ISA's guarantees.

**Q32: What memory model does RISC-V use by default?**
A: RVWMO (RISC-V Weak Memory Ordering) — a weak/relaxed model, meaning the hardware is allowed to reorder memory operations aggressively unless explicit ordering is enforced via fence instructions or the ordering bits on atomic operations.

**Q33: What does a `fence` instruction do in RISC-V, and how would the LSU implement it?**
A: It enforces ordering between memory operations before and after it, per the fence's specified predecessor/successor sets (e.g., fence r,w). The LSU implementation typically stalls issuing new memory ops past the fence until all older memory ops it's ordered against have completed/drained.

**Q34: What's the difference between a strongly ordered (TSO-like) and weakly ordered memory model, from a hardware design perspective?**
A: A strongly ordered model restricts how much the LSU can reorder loads/stores relative to each other (e.g., stores must become visible in program order), constraining speculation/forwarding opportunities. A weakly ordered model like RVWMO allows much more aggressive reordering by default, only requiring order at explicit synchronization points — generally easier to build a high-performance LSU against, at the cost of needing careful software-side fencing.

**Q35: How do atomic instructions (e.g., RISC-V AMO, LR/SC) interact with the LSU?**
A: They require the LSU to guarantee an atomic read-modify-write with no other core's access intervening — often implemented via a cache-line lock/reservation mechanism (e.g., load-reserved sets a reservation on a cache line; store-conditional succeeds only if that reservation wasn't invalidated by another core's access in between).

**Q36: What is a misaligned memory access, and how might an LSU handle it?**
A: An access whose address isn't naturally aligned to its size (e.g., a 4-byte load at an address not divisible by 4). Some ISAs disallow this (trap to software), others support it in hardware by splitting it into multiple aligned accesses and merging the result — RISC-V's base ISA allows implementations to trap on misaligned accesses, handled by a software handler, or support it natively as a microarchitectural choice.

---

## Section E: Cache Interaction & Miss Handling (Q37–Q45)

**Q37: What is an MSHR (Miss Status Holding Register), and why is it needed?**
A: A structure that tracks outstanding cache misses so the cache can continue servicing new requests while a miss is being fetched from the next level — essential for a non-blocking cache. Each MSHR entry records the missing address, which instructions/loads are waiting on it, and status of the pending fill.

**Q38: What is a blocking vs. non-blocking (lockup-free) cache?**
A: A blocking cache stalls all further accesses until the current miss is serviced. A non-blocking cache allows independent, non-conflicting accesses to proceed while one or more misses are outstanding, using MSHRs to track and later service each one.

**Q39: What happens when two loads miss to the same cache line (secondary miss)?**
A: The second miss should detect that an MSHR already exists for that line (via address match) and merge into the same MSHR entry (as an additional waiting requester) rather than issuing a redundant fetch — this is called MSHR merging/secondary miss handling.

**Q40: What limits the number of outstanding misses a core can have?**
A: The number of MSHR entries — this caps memory-level parallelism (MLP). Too few MSHRs and the core stalls waiting for a free entry even though the memory system could handle more in flight; this is a common performance bottleneck in memory-intensive workloads.

**Q41: How does a load interact with the cache when it hits vs. misses?**
A: On a hit, data returns in a fixed number of cycles and the load completes/wakes up dependents. On a miss, the load is typically removed from the pipeline, an MSHR entry is allocated, and the load is marked to replay once the fill data returns (often broadcast directly to the waiting load/dependents without a full cache re-access, for latency reasons — critical-word-forwarding).

**Q42: What is critical-word-first / early restart?**
A: When a cache line fill returns from the next level, the specific word the requesting load needs is delivered first (out of the full line's burst order) so the load can complete as soon as possible, rather than waiting for the entire line to arrive.

**Q43: Why do stores also need to interact with MSHRs, not just loads?**
A: A store that misses in the cache still needs to bring the line in (for a write-allocate policy) before it can complete the write, so it allocates/uses an MSHR entry just like a load miss would, though its "waiting" completion is about writing rather than returning data to a register.

**Q44: What is a write-allocate vs. no-write-allocate cache policy, and how does it affect the LSU?**
A: Write-allocate: a store miss brings the line into cache before writing (assumes future accesses to the line are likely). No-write-allocate: a store miss writes directly to the next level without allocating a line in this cache. The choice affects whether store misses need to wait for a full line fill (write-allocate) or can complete faster by just forwarding to the next level (no-write-allocate).

**Q45: How does a store buffer differ from the SQ, if a design has both?**
A: In some designs, the SQ (tracking speculative, uncommitted stores for ordering/forwarding purposes) is distinct from a store buffer/write buffer that holds committed stores waiting to actually drain into the cache — decoupling "correctness tracking" from "physical write bandwidth smoothing," since the cache may not be able to accept a write every single cycle.

---

## Section F: RISC-V-Specific & System-Level (Q46–Q50)

**Q46: How does RISC-V's lack of condition codes affect load/store design, if at all?**
A: Not directly — condition codes mainly affect branch/ALU design. But RISC-V's simple, fixed-format load/store instructions (with immediate offsets) simplify address generation logic compared to ISAs with more complex addressing modes (e.g., auto-increment, scaled indexing).

**Q47: What RISC-V load/store instruction variants should you know for an interview (base ISA)?**
A: LB/LH/LW/LD (loads, byte/half/word/double, sign-extended) and LBU/LHU/LWU (zero-extended unsigned variants), and corresponding SB/SH/SW/SD stores. Know that RISC-V uses a simple base+immediate addressing mode only — no register-indexed addressing in the base ISA.

**Q48: How would you extend this LSU discussion to a vector load/store unit (if asked about RISC-V "V" extension)?**
A: Vector loads/stores can access multiple elements per instruction (unit-stride, strided, or gather/scatter/indexed) — the LSU needs to generate multiple addresses per instruction, handle partial faults (some elements succeed, some fault), and often needs a much wider/banked memory interface to get useful throughput; disambiguation and forwarding logic also become more complex since a single vector store can alias with a scalar or another vector load across many addresses at once.

**Q49: How do exceptions from loads/stores (e.g., page fault, misaligned access) get handled precisely in an OoO LSU?**
A: The exception is recorded against the specific ROB entry when detected (which may be well after the instruction's position in program order, due to OoO execution), but it isn't acted upon until that instruction reaches commit/retire — at which point, if it's still valid (not squashed by an earlier fault or branch misprediction), the pipeline flushes and traps precisely at that instruction.

**Q50: In a debug/performance-analysis context, what counters would you want for the LSU specifically?**
A: Load/store miss rate (and MPKI), forwarding hit rate, memory-order violation (replay) rate, MSHR occupancy/full-stall cycles, average load-to-use latency, and store buffer/queue full-stall cycles — these collectively diagnose whether memory-side stalls are structural (queue too small), miss-driven (cache/TLB), or speculation-driven (disambiguation mispredicts).

---

## RTL Coding Exercises

### Exercise 1: Store Queue with Store-to-Load Forwarding

See companion file `Qualcomm_RISCV_CPU_Interview_Prep.md`, Section 15, for the full commented implementation (circular-buffer SQ, address/data writeback ports, forwarding CAM search with stall-on-not-ready).

---

### Exercise 2: MSHR (Miss Status Holding Register) with Secondary Miss Merging

Talking points: MSHR entries need an address tag (to detect merges), a valid bit, and a list of waiting requestors (here simplified to a bitmask of waiting load IDs for merge demonstration).

```verilog
module mshr #(
  parameter NUM_MSHR = 4,
  parameter ADDR_W   = 32,
  parameter NUM_REQ  = 8,       // number of possible waiting requestors (e.g., LQ entries)
  parameter MSHR_W   = $clog2(NUM_MSHR)
) (
  input  logic clk, rst_n,

  // New miss request wants to allocate or merge
  input  logic              req_valid,
  input  logic [ADDR_W-1:0] req_addr,       // line address (already masked to cache-line granularity)
  input  logic [$clog2(NUM_REQ)-1:0] req_id,

  output logic              req_accept,     // allocated a new MSHR or merged into existing
  output logic              req_merged,     // 1 = merged into existing miss, 0 = new primary miss
  output logic [MSHR_W-1:0] req_mshr_idx,
  output logic              req_full_stall, // no free MSHR and no match to merge into

  // Fill response from next-level memory
  input  logic              fill_valid,
  input  logic [MSHR_W-1:0] fill_mshr_idx,
  output logic [NUM_REQ-1:0] fill_wakeup_mask // which waiting requestors to wake up
);

  logic              valid   [0:NUM_MSHR-1];
  logic [ADDR_W-1:0] addr    [0:NUM_MSHR-1];
  logic [NUM_REQ-1:0] waiters[0:NUM_MSHR-1];

  logic match_found;
  logic [MSHR_W-1:0] match_idx;
  logic free_found;
  logic [MSHR_W-1:0] free_idx;

  // Combinational: search for address match (secondary miss) and free entry (primary miss)
  always_comb begin
    match_found = 1'b0;
    match_idx   = '0;
    free_found  = 1'b0;
    free_idx    = '0;
    for (int i = 0; i < NUM_MSHR; i++) begin
      if (valid[i] && (addr[i] == req_addr) && !match_found) begin
        match_found = 1'b1;
        match_idx   = i[MSHR_W-1:0];
      end
      if (!valid[i] && !free_found) begin
        free_found = 1'b1;
        free_idx   = i[MSHR_W-1:0];
      end
    end
  end

  assign req_accept     = req_valid && (match_found || free_found);
  assign req_merged      = req_valid && match_found;
  assign req_mshr_idx    = match_found ? match_idx : free_idx;
  assign req_full_stall  = req_valid && !match_found && !free_found;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NUM_MSHR; i++) begin
        valid[i]   <= 1'b0;
        waiters[i] <= '0;
      end
    end else begin
      // Allocate new primary miss
      if (req_valid && !match_found && free_found) begin
        valid[free_idx]           <= 1'b1;
        addr[free_idx]            <= req_addr;
        waiters[free_idx]         <= '0;
        waiters[free_idx][req_id] <= 1'b1;
      end
      // Merge secondary miss into existing entry
      if (req_valid && match_found) begin
        waiters[match_idx][req_id] <= 1'b1;
      end
      // Free entry on fill completion
      if (fill_valid) begin
        valid[fill_mshr_idx] <= 1'b0;
      end
    end
  end

  assign fill_wakeup_mask = fill_valid ? waiters[fill_mshr_idx] : '0;

endmodule
```

Follow-up points to narrate: (1) this wakes up all waiters in one cycle via a bitmask — a real design may need to arbitrate if downstream write ports can't accept all wakeups simultaneously; (2) address matching here assumes cache-line-aligned addresses are pre-masked by the caller; (3) mention critical-word-first as a further optimization layered on top of this basic structure.

---

### Exercise 3: Age-Based Priority Encoder for "Youngest Matching Older Store"

This isolates the specific piece of forwarding logic interviewers most often drill into: given multiple CAM hits, picking the correct one.

```verilog
module youngest_match_selector #(
  parameter SQ_DEPTH = 8,
  parameter PTR_W    = $clog2(SQ_DEPTH)
) (
  input  logic [SQ_DEPTH-1:0] hit_vec,        // 1 = address matched at this SQ slot
  input  logic [PTR_W-1:0]    entry_age [0:SQ_DEPTH-1], // age rank, 0 = oldest in queue
  input  logic [PTR_W-1:0]    load_age,       // load's own age rank for reference (must be older than this)
  output logic                match_found,
  output logic [PTR_W-1:0]    youngest_match_idx
);

  // Among all hit_vec entries with entry_age < load_age (i.e., older than the load),
  // pick the one with the LARGEST entry_age (closest to the load = youngest of the older stores).
  always_comb begin
    match_found        = 1'b0;
    youngest_match_idx  = '0;
    logic [PTR_W-1:0] best_age;
    best_age = '0;

    for (int i = 0; i < SQ_DEPTH; i++) begin
      if (hit_vec[i] && (entry_age[i] < load_age)) begin
        if (!match_found || (entry_age[i] > best_age)) begin
          match_found        = 1'b1;
          best_age           = entry_age[i];
          youngest_match_idx = i[PTR_W-1:0];
        end
      end
    end
  end

endmodule
```

Note to mention live: real designs avoid a literal per-entry "age rank" register (expensive to maintain/renumber); instead they typically compute relative age directly from circular-buffer pointer positions (mod-N distance from head), which is what the FIFO full/empty extra-bit trick generalizes into for age comparison.

---

## How to Practice This Set

Go section by section (A through F), cover the answer, and speak your response out loud within 30–45 seconds — that's roughly real interview pacing for a conceptual question. For the RTL exercises, retype them from scratch without looking, then compare — the goal is fluency in the *patterns* (circular buffer age tracking, CAM search + priority encode, valid/ready handshakes), not memorizing this exact code, since interviewers will vary the specifics.