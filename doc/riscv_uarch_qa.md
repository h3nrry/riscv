# RISC-V CPU Microarchitecture/RTL — Mock Q&A

## 1. Pipeline & Instruction Flow

**Q: Walk through the pipeline stages of an out-of-order superscalar CPU, from fetch to retire.**

A:
Fetch (pull instructions from I-cache using PC, predict branches) → Decode (identify instruction type, operands) → Rename (map architectural registers to physical registers, resolving WAW/WAR) → Dispatch (allocate ROB/queue entries) → Issue/Schedule (wait for operands, pick ready instructions out of order) → Execute (ALU/FPU/AGU) → Writeback (broadcast result on forwarding bus, wake up dependents) → Retire/Commit (in-order, update architectural state, free physical registers).

Key point to emphasize: fetch/decode/rename/retire are in-order; issue/execute/writeback are out-of-order. Interviewers want to hear you distinguish these explicitly.

---

**Q: Explain precise exceptions. Why are they hard in an OoO machine, and how does the ROB solve it?**

A: Precise exceptions mean that when an exception fires, architectural state looks exactly as if instructions executed in program order up to the faulting instruction, and nothing after it. In OoO execution, instructions finish out of order, so you can't just update architectural registers as results arrive — a later instruction might complete before an earlier one that later faults. The ROB holds results in program order and only commits (writes to architectural state) in order, so on an exception you simply squash everything after the faulting instruction in the ROB, and only in-order-completed side effects are visible. Mention: this also underlies how speculative state is rolled back on branch mispredicts.

---

## 2. Register Renaming & Hazards

**Q: How does register renaming eliminate WAW and WAR hazards?**

A: WAW/WAR are false dependencies — they exist only because architectural register names are reused, not because of real data dependency. Renaming maps each architectural register write to a fresh physical register, so two instructions writing to the same architectural register (WAW) get different physical destinations, and an instruction reading an old value before another instruction overwrites it (WAR) reads its own renamed physical source, untouched by the later write. Only true RAW (read-after-write) dependencies remain, tracked via a rename map table. Be ready to discuss physical register file (PRF) design vs. ROB-based value storage as two implementation styles.

---

**Q: Explain wakeup and select logic in an out-of-order scheduler.**

A: Each entry in the issue queue/reservation station waits for its source operands. When a result is produced, it's broadcast (tag broadcast, e.g. physical register tag) on a common data bus (CDB); every waiting instruction compares its source tags against the broadcast tag — matches "wake up" (mark operand ready). Once all operands are ready, the instruction becomes eligible; the select logic (often an arbiter/priority encoder) picks among all eligible instructions each cycle, limited by number of execution ports. This is often the critical timing path in OoO cores — wakeup-select is typically a single-cycle loop, so scheduler size vs. clock frequency is a classic PPA tradeoff. Good to mention "speculative wakeup" for load-dependent ops as a bonus point.

---

## 3. Branch Prediction

**Q: Describe two branch prediction techniques and how misprediction recovery works.**

A: 
- Two-level adaptive predictors use branch history (global or local) indexed into a pattern history table (PHT) of saturating counters.
- TAGE (TAgged GEometric) uses multiple tables with increasing history lengths, tagged to reduce aliasing, picking the longest matching history for a prediction — near state-of-the-art accuracy.
- BTB (branch target buffer) caches predicted targets for taken branches to avoid fetch bubbles.

On misprediction: once execute confirms the actual outcome differs from predicted, you squash all younger (speculative) instructions in the pipeline/ROB, restore the rename map table (or use a checkpoint), and redirect fetch to the correct target. The recovery penalty is roughly the pipeline depth from fetch to branch resolution — this is why front-end depth vs. prediction accuracy is a major performance lever.

---

## 4. Load/Store & Memory

**Q: How does a load/store unit handle memory disambiguation?**

A: The LSU must determine if a load can execute before an earlier, older store whose address isn't yet known. Approaches: conservative (stall load until all older store addresses are known), or speculative (predict no dependency, execute load early, and verify later — if a false negative occurs, squash and replay). Store-to-load forwarding: if the load's address matches an in-flight older store, forward the store's data directly rather than going to memory. A memory dependence predictor (e.g., store sets) can learn which load/store pairs actually alias, improving speculation accuracy over time.

---

**Q: Explain cache coherence basics (e.g., MESI) — why does it matter even in a single core context?**

A: MESI (Modified/Exclusive/Shared/Invalid) tracks per-cache-line state to ensure multiple caches (or multiple cores) never see stale/conflicting data. Even within one core's cache hierarchy (L1/L2), coherence-like logic governs interactions with DMA, other cores in a cluster, or inclusive/exclusive cache policies. Be ready to explain: Modified (dirty, exclusive owner), Exclusive (clean, sole owner), Shared (clean, possibly cached elsewhere), Invalid. Mention snooping vs. directory-based coherence at the multi-core level if pushed further.

---

## 5. Performance & Power Tradeoffs

**Q: How would you reduce power in an OoO core without significantly hurting IPC?**

A: Techniques to discuss: clock gating idle pipeline stages/functional units, power gating unused execution ports during low-ILP phases, reducing issue-queue/ROB search widths dynamically, using narrower/low-power execution modes when workload allows, register file banking to avoid always reading all ports, and reducing speculative work (better branch prediction reduces wasted power on squashed instructions — connect this back to prediction accuracy). Frame the answer around: "power reduction techniques that target idle/wasted work cost little to no IPC, while techniques that reduce structure size directly trade IPC for power" — showing you understand there's a spectrum.

---

**Q: Given a fixed pipeline depth, how do you trade off frequency against IPC when a critical path is too long?**

A: Options: add a pipeline stage (increases frequency potential but adds bubble/hazard penalty, e.g., branch misprediction cost grows), restructure logic to shorten the critical path (e.g., move a computation earlier, use faster adder topology), or accept a lower frequency to preserve single-cycle behavior. Emphasize you'd quantify this: (cycle time saved × frequency gain) vs. (IPC loss × frequency) to see if it's a net win — PPA analysis, not gut feel.

---

## 6. RTL / Verilog Coding

**Q: Write RTL for a simple N-entry FIFO with full/empty flags.**

Talking points before coding: clarify sync vs async, single clock domain assumed, power-of-2 depth for easy pointer wraparound, use one extra bit in read/write pointers to distinguish full vs empty without wasting an entry.

```verilog
module fifo #(parameter WIDTH=32, DEPTH=16, PTR_W=$clog2(DEPTH)) (
  input  logic clk, rst_n,
  input  logic wr_en, rd_en,
  input  logic [WIDTH-1:0] wr_data,
  output logic [WIDTH-1:0] rd_data,
  output logic full, empty
);
  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [PTR_W:0] wr_ptr, rd_ptr; // extra MSB for full/empty distinction

  assign empty = (wr_ptr == rd_ptr);
  assign full  = (wr_ptr[PTR_W] != rd_ptr[PTR_W]) &&
                 (wr_ptr[PTR_W-1:0] == rd_ptr[PTR_W-1:0]);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= 0; rd_ptr <= 0;
    end else begin
      if (wr_en && !full) begin
        mem[wr_ptr[PTR_W-1:0]] <= wr_data;
        wr_ptr <= wr_ptr + 1;
      end
      if (rd_en && !empty) begin
        rd_ptr <= rd_ptr + 1;
      end
    end
  end
  assign rd_data = mem[rd_ptr[PTR_W-1:0]];
endmodule
```

Follow-up they may ask: "make it a CDC-safe async FIFO" — be ready to discuss Gray-coded pointers and double-flop synchronizers.

---

**Q: Blocking vs. non-blocking assignments — where does using the wrong one cause a simulation/synthesis mismatch?**

A: Non-blocking (`<=`) should be used for sequential (clocked, `always_ff`) logic so all right-hand sides are evaluated using pre-update values, correctly modeling flip-flop behavior. Blocking (`=`) should be used for combinational logic (`always_comb`) where order of execution matters within the block. Using blocking assignments in sequential logic can create race conditions/order-dependent results in simulation, and simulate differently from how synthesis tools infer the intended flip-flops — leading to functional mismatches between RTL sim and gate-level/silicon behavior. A classic bug: mixing blocking and non-blocking in the same always block driving the same signal.

---

**Q: How do you handle clock domain crossing (CDC) safely?**

A: For single-bit control signals, use a 2-flop (or 3-flop for higher-risk paths) synchronizer in the destination clock domain to resolve metastability. For multi-bit buses, don't synchronize the bus directly (bits may arrive at different times); instead use Gray coding for pointers (only one bit changes at a time) or a full handshake protocol (req/ack) for data transfer, or an async FIFO. Mention MTBF calculations and that CDC issues are a common source of "passes sim, fails silicon" bugs — ties back nicely to their functional verification support requirement.

---

## 7. Verification & Debug

**Q: If IPC drops unexpectedly on a specific benchmark, walk through your debug methodology.**

A: structure: 
1. Reproduce with performance counters enabled — narrow down which pipeline stage/stall reason dominates (e.g., icache miss stalls, branch mispredict rate spike, structural hazard in issue queue).
2. Compare against a baseline/known-good trace to isolate the delta.
3. If it's a stall-reason counter issue, drill into whether it's a memory-side effect (cache/TLB miss rate change) or front-end (fetch bandwidth, branch prediction accuracy change).
4. Use waveform/trace-driven simulation to inspect the exact cycle-level behavior around the stall.
5. Correlate with any recent RTL or microarchitectural change if regression-testing.

Emphasizing a structured, counter-driven, hypothesis-testing approach (not just "I'd look at waveforms") is what senior interviewers want to hear.

---

## 8. Scripting

**Q: Given a large log file of performance counter dumps, how would you write a script to detect anomalies?**

A: Use Python with pandas to parse structured log/CSV output, compute per-counter statistics (mean, stddev) across runs or time windows, flag entries beyond N standard deviations, and visualize trends (matplotlib) to spot regressions. If parsing raw waveform (VCD) data, mention tools like pyvcd or writing a simple state-machine parser. Show you think about scripting as a productivity multiplier for verification/performance work, exactly as the JD calls out.

---

## 9. Behavioral (STAR format)

**Q: Tell me about a time you had to trade off performance vs. power vs. area.**

Prep guidance: Pick a real project (school, internship, prior job). Structure as:
- Situation: what was the design constraint context?
- Task: what were you specifically responsible for deciding?
- Action: what analysis did you do, what alternatives did you weigh, what did you ultimately choose and why?
- Result: quantify it — "reduced area by X% at Y% IPC cost" or similar.

**Q: Tell me about the hardest bug you've debugged in RTL or post-silicon.**

Prep guidance: Pick a bug with real depth — ideally a CDC issue, a coherence corner case, or a timing-related bug that only showed up in specific conditions. Emphasize your systematic debug process over the "eureka moment."

**Q: Why RISC-V, and why Qualcomm's Cork ASIC team specifically?**

Prep guidance: Connect genuine technical interest (open ISA, extensibility, growing ecosystem) with something specific about Qualcomm's high-performance/low-power CPU work — avoid generic "I love chips" answers; reference the JD's specific focus (performance exploration + low power) to show you read it closely.

---

## 10. Register Renaming Implementation

**Q: Physical register file (PRF) vs. ROB-based (merged) register file — what's the difference?**

A: In a PRF design, a separate pool of physical registers (larger than the architectural set) holds all values; renaming maps architectural names to physical registers, and results are written directly into the PRF at execute time. The ROB only tracks metadata (which physical register maps to which instruction, exception status) — not the data itself. In a ROB-based (merged) design, results are written into the ROB entry at execute, and only copied into the architectural register file at commit. PRF designs dominate modern high-performance cores because they avoid an extra copy-on-commit and simplify issue-stage read ports, but require careful physical register reclamation — a physical register is only freed after no in-flight instruction still needs it (i.e., after the instruction that overwrote its architectural mapping commits).

---

## 11. Cache Hierarchy Design

**Q: Inclusive vs. exclusive cache hierarchies — why pick one over the other?**

A: Inclusive: every line in L1 must also exist in L2 (and so on up the hierarchy). This simplifies coherence — a snoop only needs to check the outer cache to know if any inner cache might hold the line, and invalidating in L2 correctly invalidates everywhere. Cost: wasted capacity from duplication. Exclusive: a line exists in only one level at a time; evicting from L1 moves it to L2 instead of discarding it. This maximizes effective total capacity but complicates coherence and eviction/promotion logic. Non-inclusive (NINE) hybrids are common as a middle ground in modern designs. Be ready to justify a choice based on area/coherence complexity tradeoffs for a specific L1/L2/L3 setup.

---

## 12. Structural Design Tradeoff

**Q: Fixed area budget — would you grow the ROB or the issue queue to improve IPC? How do you decide?**

A: ROB size sets the maximum reorder window — how far ahead you can look for parallelism and how much speculative work is in flight. Issue queue size determines how many instructions are simultaneously eligible for out-of-order issue within that window. Growing the ROB alone mostly helps hide long-latency misses (letting independent instructions further ahead still be found), but if the issue queue is too small, many ROB entries just sit waiting, not actually schedulable. Growing the issue queue improves near-term ILP extraction but costs more directly, since wakeup/select comparator logic scales roughly quadratically with entries — more expensive per entry than ROB growth. Best answer: state you'd profile the target workload's dependency distance and miss patterns first, since the right answer is workload-dependent — this shows judgment over a memorized answer.

---

## 13. Quick-Fire Round (self-quiz — cover the answer, then check)

**Q: What's the difference between an exception and an interrupt?**
A: An exception is synchronous, caused by the currently executing instruction (e.g., divide-by-zero, page fault, illegal opcode) — it's tied to a specific PC. An interrupt is asynchronous, triggered by external events (timer, I/O device) and can occur between any two instructions, independent of what's executing.

**Q: What is a TLB, and what happens on a TLB miss?**
A: A Translation Lookaside Buffer caches virtual-to-physical address translations to avoid walking page tables on every memory access. On a miss, hardware (or software, depending on ISA) performs a page table walk to fetch the translation, then installs it in the TLB — this walk can itself cause multiple memory accesses and stalls the pipeline.

**Q: Define CPI, IPC, and MPKI.**
A: CPI = cycles per instruction (lower is better). IPC = instructions per cycle (1/CPI, higher is better). MPKI = misses per thousand instructions, a normalized way to compare cache/branch predictor miss rates across workloads regardless of instruction count.

**Q: What's a structural hazard, and give an example in a CPU pipeline.**
A: A structural hazard occurs when two instructions need the same hardware resource in the same cycle. Example: only one memory port, and both a fetch and a load/store need to access memory in the same cycle — one must stall.

**Q: What's store-to-load forwarding, and why is it needed?**
A: When a load's address matches an older, in-flight store's address, the store's data is forwarded directly to the load rather than making the load wait for the store to complete and go through memory — avoiding unnecessary stalls while preserving correctness.

**Q: What is speculative execution, and how does it relate to Spectre-style vulnerabilities?**
A: Speculative execution lets the CPU execute instructions before it's certain they're needed (e.g., past a predicted branch) to keep the pipeline full. Spectre-class attacks exploit the fact that speculative execution can leave observable microarchitectural side effects (e.g., cache state changes) even when the speculation is later squashed, allowing an attacker to infer secret data through timing side channels — this is why modern designs need speculation-aware security mitigations, not just functional correctness.

**Q: What's the difference between a blocking and a non-blocking cache?**
A: A blocking cache stalls the entire pipeline on a miss until it's serviced. A non-blocking (lockup-free) cache allows subsequent independent accesses to proceed while a miss is being serviced, using miss status holding registers (MSHRs) to track outstanding misses — essential for hiding memory latency in OoO cores.

**Q: What are RISC-V privilege levels, and why do they matter for a CPU design?**
A: RISC-V defines Machine (M), Supervisor (S), and User (U) privilege modes (plus optional Hypervisor extensions). They control access to CSRs (control/status registers) and privileged operations, enabling OS/hypervisor isolation from user applications — relevant to how you'd design CSR access checks and trap/exception delegation in RTL.

**Q: What's the difference between formal verification and simulation-based verification?**
A: Simulation exercises the design with specific test vectors/sequences and checks outputs against expected behavior — it can only cover the scenarios you think to test. Formal verification uses mathematical proof techniques (model checking, equivalence checking) to prove properties hold for all possible input sequences, exhaustively — valuable for control logic and coherence protocols where corner cases are easy to miss in simulation.

**Q: Why does dynamic voltage and frequency scaling (DVFS) matter in CPU design, and what's the tradeoff?**
A: DVFS lowers voltage/frequency during low-demand periods to save power (power scales roughly with V²×f), and raises them under load for performance. The tradeoff is transition latency/overhead (switching states isn't free) and the need for margining — voltage/frequency operating points must be validated across PVT (process, voltage, temperature) corners to guarantee correctness at every state.

---

## How to Use This Doc

Practice saying these answers out loud, not just reading them — timing and delivery matter as much as content in these interviews. For the RTL question, practice writing it from memory without looking, then verbally narrate your design decisions as you go (this mirrors how the actual interview will feel). For the quick-fire round, cover the answer with your hand/scroll and force yourself to answer in under 30 seconds per question, like a real screening round.