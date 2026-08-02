# RISC-V Pipeline — 100 Q&A + 25 RTL Coding Exercises

A study/reference set covering classic RISC-V pipeline design: fundamentals, hazards, forwarding, branch prediction, pipeline control, interrupts/exceptions, out-of-order concepts, and performance metrics — followed by 25 hands-on RTL coding exercises with Verilog solutions.

## Table of Contents

1. [Pipeline Fundamentals](#a-pipeline-fundamentals-q1-q12) (Q1–Q12)
2. [Structural Hazards](#b-structural-hazards-q13-q20) (Q13–Q20)
3. [Data Hazards](#c-data-hazards-q21-q35) (Q21–Q35)
4. [Control Hazards](#d-control-hazards-q36-q50) (Q36–Q50)
5. [Forwarding / Bypassing](#e-forwarding--bypassing-q51-q60) (Q51–Q60)
6. [Branch Prediction](#f-branch-prediction-q61-q70) (Q61–Q70)
7. [Stalling, Flushing & Pipeline Control](#g-stalling-flushing--pipeline-control-q71-q78) (Q71–Q78)
8. [Interrupts & Exceptions](#h-interrupts--exceptions-q79-q88) (Q79–Q88)
9. [Out-of-Order Execution & Advanced Topics](#i-out-of-order-execution--advanced-topics-q89-q95) (Q89–Q95)
10. [Performance Metrics](#j-performance-metrics-q96-q100) (Q96–Q100)
11. [RTL Coding Exercises](#rtl-coding-exercises-rtl1-rtl25) (RTL1–RTL25)

---

## A. Pipeline Fundamentals (Q1–Q12)

**Q1. What is instruction pipelining, and why is it used in CPU design?**
Pipelining overlaps the execution of multiple instructions by splitting instruction processing into sequential stages (e.g., fetch, decode, execute, memory, writeback), where each stage works on a different instruction at the same time. It's used because it increases instruction throughput — ideally one instruction completes per clock cycle in steady state — without needing to speed up individual instruction execution, which is limited by logic/circuit delay.

**Q2. What are the five classic stages of a RISC-V pipeline?**
Fetch (IF) — retrieve the instruction from memory; Decode (ID) — decode the opcode and read register operands; Execute (EX) — perform ALU operations or compute addresses; Memory (MEM) — access data memory for loads/stores; Writeback (WB) — write the result back to the register file.

**Q3. Why does RISC-V's fixed-length, regular instruction encoding help pipelining?**
Because every instruction (in the base RV32I set) is 32 bits with a small number of consistent formats (R, I, S, B, U, J), the decode stage can extract opcode, register fields, and immediates in a simple, uniform way without variable-length parsing. This keeps decode fast and predictable, which is essential for a clean, low-latency pipeline stage.

**Q4. What is pipeline throughput versus latency?**
Latency is the time for a single instruction to travel from fetch to writeback (i.e., pipeline depth × cycle time). Throughput is the rate at which instructions complete, ideally one per cycle once the pipeline is full. Pipelining improves throughput without necessarily reducing the latency of any individual instruction — it can even increase it slightly due to pipeline register overhead.

**Q5. What is a pipeline register, and why is it needed between stages?**
A pipeline register is a set of flip-flops placed between two pipeline stages that captures the outputs of one stage and holds them stable as inputs to the next stage for exactly one clock cycle. It's needed to isolate stages so each can work on a different instruction simultaneously without corrupting data mid-cycle.

**Q6. What determines the maximum clock frequency of a pipelined design?**
The critical path — the longest combinational logic delay between any two pipeline registers — sets the minimum clock period, and its inverse sets the maximum frequency. Deeper pipelines (more stages) generally shorten each stage's combinational logic, allowing higher frequency, at the cost of more pipeline registers and more potential hazard/stall complexity.

**Q7. What is "pipeline fill" and "pipeline drain"?**
Pipeline fill is the initial period where the pipeline hasn't yet reached steady state — the first instruction takes multiple cycles to traverse all stages before the first result emerges. Pipeline drain is the analogous period at the end of a program or after a flush, where remaining in-flight instructions finish draining through the stages with no new instructions being fetched.

**Q8. What is the ideal CPI (cycles per instruction) for a perfectly pipelined, hazard-free processor?**
Ideally 1 CPI — one instruction completes every clock cycle in steady state, regardless of how many pipeline stages exist. In practice, real CPI is higher than 1 due to stalls from hazards, cache misses, and branch mispredictions.

**Q9. In a RISC-V pipeline, which stage typically decodes the opcode and which decodes the register operands?**
Both usually happen in the Decode (ID) stage: the opcode/funct fields identify the operation type, and the same stage reads the source register values from the register file (or forwards them if unavailable) so the Execute stage has operands ready.

**Q10. Why is the register file often designed with two read ports and one write port in a single-issue RISC-V pipeline?**
Most RISC-V instructions have up to two source registers (rs1, rs2) and at most one destination register (rd). Two read ports let both source operands be read in the same cycle during Decode, and one write port lets a single instruction retire and write back per cycle, matching single-issue throughput.

**Q11. What is meant by "in-order" pipeline execution?**
In-order execution means instructions enter and progress through the pipeline stages in the exact program order — no instruction begins execution before an earlier instruction, and results are typically produced (or at least dispatched) in that same order, simplifying hazard detection and making timing analyzable.

**Q12. What is the difference between a scalar and superscalar in-order pipeline?**
A scalar pipeline fetches, decodes, and issues at most one instruction per cycle per stage. A superscalar pipeline duplicates fetch/decode/issue/execute hardware to process multiple instructions per cycle (e.g., dual-issue), increasing throughput but adding complexity in hazard detection, since multiple instructions in the same stage can now depend on each other.

---

## B. Structural Hazards (Q13–Q20)

**Q13. What is a structural hazard?**
A structural hazard occurs when two or more instructions in different pipeline stages need the same hardware resource (e.g., memory port, register file port, functional unit) in the same clock cycle, and the hardware can't service both simultaneously.

**Q14. Give a classic example of a structural hazard in a 5-stage RISC-V pipeline using a single unified memory.**
If instruction and data memory share a single memory port, an instruction in the Fetch stage and a load/store instruction in the Memory stage would need memory access in the same cycle, causing a conflict. This is why most pipelined designs use separate instruction and data caches/memories (Harvard-style access) even if unified in the backing store.

**Q15. How does a Harvard-style memory architecture help avoid structural hazards?**
By providing separate instruction and data memory interfaces (separate caches, separate ports), fetch and memory-stage accesses can happen in the same cycle without contention, eliminating the most common structural hazard in classic pipelines.

**Q16. Can the register file cause a structural hazard? How is it usually resolved?**
Yes — if the pipeline needs to read two operands and write a result in the same cycle, and the register file has too few ports, a hazard occurs. It's typically resolved by giving the register file enough ports (e.g., 2 read + 1 write for a single-issue pipeline) or, for writes/reads to the same register in the same cycle, using write-then-read ordering within the cycle or explicit forwarding logic.

**Q17. How do structural hazards typically get resolved when they can't be designed away?**
By stalling — inserting a bubble that delays the instruction needing the busy resource until the resource is free, at the cost of one or more lost cycles.

**Q18. Why are structural hazards less common in modern pipeline designs than data or control hazards?**
Because structural hazards are largely a hardware provisioning problem — they can be designed away by duplicating resources (separate I/D caches, enough register file ports, pipelined/multiple functional units). Data and control hazards are fundamentally about program dependencies and can't simply be eliminated by adding hardware; they need dedicated detection and mitigation logic.

**Q19. What structural hazard can arise from a non-pipelined multiplier or divider in the Execute stage?**
If multiply/divide takes multiple cycles and the functional unit isn't itself pipelined, a second multiply/divide instruction arriving before the first finishes has nowhere to go — the pipeline must stall (or the multiplier must be pipelined/replicated) until the unit is free.

**Q20. How does instruction and data cache miss handling create resource-contention-like stalls similar to structural hazards?**
While technically a memory-hierarchy stall rather than a classic structural hazard, a cache miss ties up the memory interface for many cycles while it's serviced from a lower level, during which other stages needing that same memory path (e.g., Fetch needing the I-cache while a MEM-stage load is also missing) must wait, producing similar pipeline-stall behavior.

---

## C. Data Hazards (Q21–Q35)

**Q21. What is a data hazard?**
A data hazard occurs when an instruction depends on the result of a previous instruction that hasn't yet completed (specifically, hasn't yet been written back to the register file or made available), and reading the stale/old value would produce incorrect behavior.

**Q22. What are the three classic types of data hazards?**
RAW (Read After Write) — a true dependency where an instruction reads a register before a prior instruction writes it; WAR (Write After Read) — an instruction writes a register before a prior instruction reads the old value; WAW (Write After Write) — two instructions write the same register out of order. In a simple in-order, single-issue pipeline, only RAW hazards typically occur naturally.

**Q23. Why do WAR and WAW hazards not normally occur in a simple in-order 5-stage RISC-V pipeline?**
Because instructions read operands early (Decode) and write results late (Writeback), and instructions proceed through the pipeline strictly in program order, an earlier instruction's write always happens no later than a later instruction's write, and an earlier instruction's read always happens before a later instruction could have written — so the natural ordering prevents WAR/WAW from arising without out-of-order execution.

**Q24. Give a concrete RAW hazard example in RISC-V assembly.**
```
add x1, x2, x3   # writes x1
sub x4, x1, x5   # reads x1
```
The `sub` instruction needs the value of `x1` produced by `add`, but in a naive pipeline `add` won't write `x1` back to the register file until several cycles after `sub` would normally read it in Decode.

**Q25. How many cycles of RAW hazard "distance" exist between back-to-back dependent ALU instructions in an unmitigated 5-stage pipeline?**
Without forwarding, the producing instruction writes back in WB (stage 5) while the very next instruction would read operands in ID (stage 2) one cycle later — that's a 3-cycle gap, requiring up to 3 stall cycles (bubbles) if resolved purely by stalling instead of forwarding.

**Q26. What is a load-use hazard, and why is it special compared to a normal RAW hazard?**
A load-use hazard is a RAW hazard where the producing instruction is a load — the loaded value isn't available until the end of the Memory stage, one stage later than an ALU result (available at end of Execute). This means even with full forwarding, a load-use hazard still requires at least one stall cycle, because the data simply isn't ready yet when the dependent instruction needs it in Execute.

**Q27. How is a load-use hazard typically detected in hardware?**
A hazard detection unit compares the destination register of the instruction currently in the EX/MEM pipeline register boundary (i.e., a load in the ID/EX register, about to enter EX) against the source registers of the instruction currently in Decode; if there's a match and the producing instruction is a load, the pipeline stalls for one cycle (inserts a bubble) and re-decodes.

**Q28. What is the software-visible way to avoid load-use stalls without hardware forwarding, and why is it undesirable?**
A compiler can perform instruction scheduling to insert an independent instruction (or a NOP) between a load and its dependent use, so the load has time to complete before the value is needed. It's undesirable as a sole solution because it either wastes an instruction slot (NOP) or constrains the compiler's scheduling freedom, and it doesn't help pre-compiled/legacy binaries.

**Q29. Can data hazards occur across CSR (Control and Status Register) reads/writes in RISC-V?**
Yes — instructions like `csrrw` that read and write CSRs can create RAW/WAW-like hazards if a subsequent instruction depends on the updated CSR value (e.g., reading `mstatus` right after modifying it), and pipeline implementations must account for CSR read/write timing just like general-purpose register hazards.

**Q30. What is a hazard due to memory-mapped I/O or non-idempotent loads, and why can't it always be resolved by forwarding?**
If a load reads from a memory-mapped I/O register with side effects (e.g., a UART receive buffer that clears on read), reordering, speculative re-execution, or forwarding tricks that assume a value can be safely re-read are invalid — the hazard must be handled by ensuring the load executes exactly once, in order, which restricts aggressive hazard-mitigation techniques for such addresses.

**Q31. Why can data hazards be more complex in a pipeline with multiple execution units of different latencies (e.g., short ALU vs. multi-cycle multiplier)?**
Because different instructions may reach the point of producing a result in different pipeline cycles depending on which functional unit they use, the hazard detection/forwarding logic must track multiple possible "result ready" timings rather than a single fixed stage, complicating both detection and the forwarding network.

**Q32. What is register file "write-then-read" bypassing within a single cycle, and how does it help data hazards?**
If the Writeback stage writes to the register file in the first half of a clock cycle and Decode reads in the second half of the same cycle, an instruction being written back and an instruction reading that same register in Decode in the same cycle can see the correct new value without stalling — a simple, low-cost form of hazard mitigation for the WB-to-ID case specifically.

**Q33. What is operand forwarding (at a high level), and how does it reduce RAW hazard penalties?**
Forwarding (bypassing) routes a result directly from a later pipeline stage (e.g., EX/MEM or MEM/WB pipeline register) back to an earlier stage (e.g., EX stage input mux) that needs it, instead of waiting for the value to be formally written back to the register file. This eliminates or reduces stall cycles for RAW hazards between closely spaced dependent instructions.

**Q34. Why can't forwarding alone eliminate all data hazards?**
Forwarding can only supply a value once it has actually been computed. For a load-use hazard, the loaded data isn't available until after the Memory stage completes, so no forwarding path can deliver it in time for the very next instruction's Execute stage — at least one stall cycle is unavoidable in a standard 5-stage pipeline.

**Q35. What role does the compiler/toolchain play in reducing data hazard stalls even when hardware forwarding exists?**
Instruction scheduling can reorder independent instructions to fill the gap after a load (or other long-latency operation) so that by the time the dependent instruction reaches Execute, the value is already available via forwarding or even the register file, avoiding stalls without changing program semantics.

---

## D. Control Hazards (Q36–Q50)

**Q36. What is a control hazard?**
A control hazard arises from instructions that change the flow of execution — branches, jumps, calls, returns, exceptions — where the pipeline doesn't yet know the next instruction's address at the time it needs to fetch it, risking fetching and partially executing the wrong instructions.

**Q37. Why are control hazards generally considered more costly than data hazards in deep pipelines?**
Because a data hazard typically costs a small, bounded number of stall cycles (often 1, resolved by forwarding), while a branch misprediction in a deep pipeline can require flushing every instruction fetched after the branch — potentially many cycles' worth of wasted work — before the correct path is fetched.

**Q38. In a basic 5-stage RISC-V pipeline, when is a branch's outcome typically known if resolved in Execute?**
If branch comparison happens in the EX stage, the outcome (taken/not-taken) and target address are known at the end of EX, meaning two instructions (the ones fetched during the branch's ID and EX stages) will have been incorrectly fetched down the fall-through path if the branch is actually taken, and must be flushed.

**Q39. How does resolving branches earlier, e.g., in the Decode stage, reduce the misprediction penalty?**
If the branch condition and target can be computed in ID instead of EX (often by adding a dedicated comparator in Decode rather than reusing the ALU), the outcome is known one cycle earlier, so only one incorrectly fetched instruction needs to be flushed instead of two — cutting the flush penalty roughly in half.

**Q40. What is "predict not-taken" as a simple static branch resolution strategy?**
The pipeline assumes every branch is not taken and continues fetching sequentially; if the branch turns out to be taken, the fetched instructions are flushed and fetch restarts at the target. It's simple to implement and works reasonably well for branches that are statistically more often not taken (e.g., certain loop-exit conditions), but performs poorly for loop-back branches, which are usually taken.

**Q41. What is "predict taken," and when is it a better default than "predict not-taken"?**
The pipeline assumes every branch is taken and speculatively fetches from the (precomputed or estimated) target address. It performs better for backward branches common in loops (e.g., a loop's conditional branch back to the top), which are taken far more often than not, but requires knowing or computing the target address early, which adds complexity.

**Q42. What is a delay slot, and did RISC-V adopt this technique?**
A delay slot is an instruction placed immediately after a branch/jump that always executes regardless of the branch outcome, historically used (e.g., in early MIPS) so the pipeline has useful work to do while the branch resolves, avoiding a flush. RISC-V deliberately does not use delay slots — the ISA designers considered them a poor fit for deeper/more varied pipeline implementations and instead rely on prediction and flushing.

**Q43. Why did the RISC-V ISA designers avoid delay slots?**
Delay slots tie the ISA semantics to a specific pipeline depth/behavior, which becomes awkward or outright incompatible as implementations evolve to deeper pipelines, superscalar issue, or out-of-order execution — since the "one delay slot always executes" rule assumes a very particular microarchitecture. RISC-V's designers prioritized implementation flexibility over the small performance win delay slots offered in simple pipelines.

**Q44. What is a Branch Target Buffer (BTB), and what problem does it solve?**
A BTB is a small cache that stores the predicted target address of recently seen branches/jumps, indexed by the branch instruction's PC. It solves the problem of not knowing a branch's target address early enough to fetch it speculatively — instead of waiting for the target to be computed in Decode/Execute, the BTB provides a fast (though possibly stale) predicted target during Fetch.

**Q45. What information does a Branch History Table (BHT) or Pattern History Table (PHT) typically store?**
It stores per-branch (or per-branch-pattern) taken/not-taken history, usually as a small saturating counter (commonly 1 or 2 bits), used to predict whether a given branch will be taken the next time it's encountered, independent of computing its target address.

**Q46. What is a 2-bit saturating counter branch predictor, and why is it more stable than a 1-bit predictor?**
It's a small state machine with four states (strongly not-taken, weakly not-taken, weakly taken, strongly taken) that shifts one step toward "taken" or "not-taken" on each outcome, only flipping its prediction after two consecutive wrong guesses. This avoids the 1-bit predictor's weakness of mispredicting twice at the boundaries of a loop (entry and exit), improving prediction accuracy for typical loop patterns.

**Q47. What is a pipeline flush, and what does it cost?**
A flush discards (squashes) instructions that were incorrectly fetched into the pipeline after a misprediction or exception, typically by converting their control signals into a NOP/bubble as they pass through subsequent stages, or by clearing the relevant pipeline registers. The cost is the number of cycles those squashed instructions occupied — wasted work that must be redone by fetching the correct instruction stream.

**Q48. How does RISC-V's use of a dedicated comparator (rather than reusing the ALU) in the Decode stage help reduce control hazard penalty?**
By adding hardware in ID specifically to compare register operands for branch conditions and compute the branch target using an adder off the immediate, the pipeline can determine the branch outcome and target one stage earlier than if it had to wait for the shared ALU in EX, directly cutting the number of instructions that must be flushed on a misprediction.

**Q49. What is speculative execution, and how does it relate to control hazards?**
Speculative execution means the pipeline continues fetching and executing instructions along a predicted path before the actual outcome (e.g., of a branch) is confirmed, betting that the prediction is correct to avoid stalling. It directly addresses control hazards by turning the "wait and see" cost into an "assume and recover if wrong" cost, which is a net win as long as prediction accuracy is reasonably high.

**Q50. Why must speculatively executed instructions not be allowed to modify architectural state (registers, memory) until the branch is confirmed correct?**
Because if the prediction turns out wrong, any changes made by the speculative instructions (register writes, memory stores, especially to I/O) would corrupt the correct program state and could not be cleanly undone — particularly problematic for stores to memory-mapped I/O with side effects. Pipelines therefore delay committing results (e.g., register writeback) until the relevant branch is resolved, or use recovery/rollback mechanisms.

---

## E. Forwarding / Bypassing (Q51–Q60)

**Q51. What is the difference between EX/MEM forwarding and MEM/WB forwarding?**
EX/MEM forwarding takes a result sitting in the EX/MEM pipeline register (the output of the immediately preceding instruction's Execute stage) and forwards it directly into the current instruction's EX stage inputs. MEM/WB forwarding does the same but for a result one instruction further back, sitting in the MEM/WB pipeline register, covering cases where the immediately preceding instruction isn't the producer but the one before it is.

**Q52. In forwarding logic, why does EX/MEM forwarding typically take priority over MEM/WB forwarding when both could apply to the same register?**
Because EX/MEM holds the most recently produced value for that register (from the closer, more recent instruction), while MEM/WB holds an older value; if both pipeline stages happen to hold results destined for the same register, the more recent one (EX/MEM) is architecturally correct and must be selected to preserve program order semantics.

**Q53. What signals does a forwarding unit typically compare to detect a forwarding opportunity?**
It compares the destination register number in the EX/MEM and MEM/WB pipeline registers against the rs1/rs2 source register numbers of the instruction currently in EX, combined with a check that the destination register number isn't x0 (RISC-V's hardwired zero register, which should never trigger forwarding) and that the producing instruction actually writes a register (RegWrite control signal asserted).

**Q54. Why must forwarding logic explicitly exclude register x0 from triggering a forward?**
Because x0 in RISC-V is hardwired to the constant 0 and any writes to it are discarded — if forwarding logic naively matched "destination == source" without excluding x0, it could incorrectly forward a stale or irrelevant value whenever an instruction happened to have x0 as a destination, even though x0 should always read as zero.

**Q55. What is a forwarding mux, and where is it placed in the datapath?**
A forwarding mux is a multiplexer placed at the ALU (or other execution unit) input in the EX stage that selects between the value read from the register file (via the ID/EX pipeline register) and one or more forwarded values from later pipeline stages, based on the forwarding unit's control signals.

**Q56. Can forwarding fully eliminate stalls for back-to-back dependent ALU instructions in a 5-stage pipeline?**
Yes — since an ALU instruction's result is available at the end of EX (in the EX/MEM pipeline register) exactly when the next instruction needs it as an input to its own EX stage, EX/MEM forwarding supplies the value just in time, with zero stall cycles needed.

**Q57. Why can't forwarding eliminate the single stall cycle in a load-use hazard, even with a full forwarding network?**
Because the loaded value doesn't exist until the end of the Memory stage, one stage later than an ALU result — there is no earlier point in the pipeline from which to forward it. Even with a MEM/MEM or MEM-to-EX forwarding path, the dependent instruction's EX stage would need the value one cycle before it's produced, forcing exactly one stall cycle regardless of forwarding sophistication.

**Q58. How does forwarding interact with store instructions that need a forwarded value for the data being stored (not an address operand)?**
Store instructions often need their "store data" operand later than the address calculation — some pipelines forward the store data value into the Memory stage itself (rather than only into EX), allowing a value produced by an immediately preceding instruction to be forwarded directly into the store's MEM stage, which can relax certain hazard/stall requirements for store-after-compute sequences.

**Q59. What additional complexity does forwarding introduce in a superscalar (multi-issue) pipeline compared to scalar?**
With multiple instructions in the same pipeline stage simultaneously, forwarding logic must also handle same-cycle intra-group dependencies (an instruction depending on another instruction issued in the same bundle), not just inter-cycle dependencies between different pipeline stages, which significantly increases the number of comparison paths and mux inputs needed.

**Q60. Why is a full forwarding network sometimes described as trading hardware complexity for performance?**
Every additional forwarding path requires extra wiring, comparators, and mux inputs across pipeline stages, increasing area, power, and potentially the critical path delay through the mux logic itself, while avoiding stalls that would otherwise cost real cycles — so implementations balance how much forwarding to build against how much stalling they're willing to tolerate, especially in low-power/low-area (e.g., MCU-class) designs.

---

## F. Branch Prediction (Q61–Q70)

**Q61. What is the difference between branch prediction and branch resolution?**
Branch prediction is a speculative guess about a branch's outcome (and target) made early, typically during Fetch, before the branch is actually evaluated. Branch resolution is the actual, authoritative determination of the outcome, computed later (e.g., in Decode or Execute) by evaluating the real condition and comparing it against the prediction.

**Q62. What is a static branch predictor, and give an example used in simple RISC-V cores.**
A static predictor makes the same prediction every time based on fixed rules rather than runtime history — e.g., "always predict not-taken," "always predict taken," or a direction hint based on whether the branch offset is backward (predict taken, common for loops) or forward (predict not-taken, common for conditional skips). Simple, low-area RISC-V microcontroller cores often use these because dynamic predictors cost extra area/power that isn't justified at low clock targets.

**Q63. What is a dynamic branch predictor, and how does it generally outperform static prediction?**
A dynamic predictor tracks a branch's actual runtime behavior (e.g., via saturating counters or more advanced correlating predictors) and adapts its prediction based on that history, capturing patterns static rules can't, such as a branch that's usually taken but occasionally not. This typically achieves higher accuracy at the cost of extra storage and logic.

**Q64. What is a "correlating" (two-level) branch predictor?**
A correlating predictor bases its prediction not just on a single branch's own history but also on the outcomes of recent other branches (global history), exploiting the fact that some branches' outcomes are correlated with preceding branch decisions elsewhere in the program, improving accuracy for patterns a simple per-branch counter can't capture.

**Q65. What is a Return Address Stack (RAS), and what specific control-flow pattern does it optimize?**
An RAS is a small hardware stack that pushes the return address on a `call`-type instruction (e.g., RISC-V `jal`/`jalr` with link register `ra`) and pops it on a matching return (`jalr` using `ra`), allowing the pipeline to correctly predict function return targets — which a generic BTB handles poorly since the same call site can return to different callers.

**Q66. Why is predicting the target of an indirect jump (e.g., `jalr` to a register value) harder than predicting a direct conditional branch?**
A direct branch's target is encoded in the instruction itself (as an immediate offset), so it's computable without runtime data. An indirect jump's target depends on a register's runtime value, which may vary across different executions of the same instruction (e.g., virtual function calls, switch/jump tables, returns), so a simple BTB entry (assuming one fixed target per PC) can be wrong far more often.

**Q67. What is a branch misprediction penalty, and what does it depend on?**
It's the number of cycles wasted (via flushed instructions) when a prediction turns out incorrect, and it depends primarily on how early the misprediction is detected (i.e., which pipeline stage resolves branches) — the deeper into the pipeline the branch is resolved, the more instructions were speculatively fetched and must be discarded.

**Q68. How does increasing pipeline depth generally affect branch misprediction penalty, all else equal?**
Deeper pipelines mean more stages exist between Fetch and the stage where a branch is finally resolved, so more instructions get speculatively fetched down a potentially wrong path before the mistake is caught, increasing the number of cycles flushed per misprediction.

**Q69. Why might a real-time-oriented CPU tier (like an in-order design targeting bounded worst-case timing) deliberately use a simpler branch predictor or none at all?**
Because dynamic predictors introduce state-dependent, history-based behavior that is difficult to bound analytically for worst-case execution time (WCET) — the same branch instruction can take different numbers of cycles to resolve depending on prior execution history, undermining the deterministic timing guarantees real-time systems require. A simple static predictor (or fixed penalty regardless of prediction) is easier to statically analyze.

**Q70. What is a Branch Target Instruction Cache (BTIC), and how does it differ from a plain BTB?**
A BTIC caches not just the predicted target address but the actual target instruction(s) themselves, so on a predicted-taken branch, the fetched instruction is available immediately from the BTIC without waiting for an instruction memory access — reducing the effective taken-branch fetch penalty further than a BTB alone, at the cost of additional cache-like storage.

---

## G. Stalling, Flushing & Pipeline Control (Q71–Q78)

**Q71. What is the difference between a stall (bubble insertion) and a flush?**
A stall freezes the pipeline stages before the hazard point (holding their pipeline registers steady, often via a "PCWrite"/"IF-ID Write" disable signal) and inserts a NOP bubble into the stage after the hazard, delaying forward progress without discarding any already-fetched instruction. A flush actively discards (squashes) one or more instructions already in the pipeline, typically because they were fetched incorrectly (e.g., after a misprediction).

**Q72. What hardware signal is commonly used to implement a stall in a classic 5-stage RISC-V pipeline?**
A hazard detection unit asserts control signals that (1) disable writing the PC register and IF/ID pipeline register (so the same instruction is re-fetched/held), and (2) zero out or force to NOP the control signals in the ID/EX pipeline register for that cycle, effectively inserting a bubble downstream while holding the stalled instruction in place upstream.

**Q73. Why must a bubble's control signals be zeroed (or forced to a NOP encoding) rather than just leaving stale data in the pipeline register?**
If stale control signals were left in place, the "bubble" could inadvertently trigger a register write, memory write, or other side effect using leftover data from a previous instruction, corrupting architectural state. Explicitly zeroing (or NOP-ing) the control signals ensures the bubble behaves as a true no-op with no side effects.

**Q74. What is the typical flush mechanism when a branch is found to be mispredicted in the EX stage?**
The instructions currently in the IF and ID stages (fetched from the wrong path) have their control signals cleared/forced to NOP as they're squashed, and the PC is redirected to the correct target address so the next fetch begins from the right instruction stream.

**Q75. Why is it important that a flush not simply "stop the clock" but instead insert NOPs for the squashed instructions?**
The pipeline as a whole must keep advancing (other, correctly-fetched instructions further down the pipeline still need to complete), so rather than halting everything, only the specific incorrect instructions are converted to harmless NOPs as they continue moving through the pipeline stages they already occupy, while fetch restarts correctly from the new PC.

**Q76. What is pipeline interlocking, and why is it necessary in hardware even though it doesn't exist as a programmer-visible concept?**
Pipeline interlocking is the hardware mechanism (hazard detection plus stall/forward control) that ensures a pipelined implementation produces results identical to a non-pipelined, sequential execution of the same program, despite instructions overlapping in time. It's necessary because the RISC-V ISA specification guarantees sequential-execution semantics — pipelining is purely a microarchitectural performance technique and must be invisible to correct program behavior.

**Q77. How does a hazard detection unit typically interact with the forwarding unit — do they operate independently?**
No — hazard detection and forwarding work together: the forwarding unit first checks whether a hazard can be resolved by forwarding (data already computed and available from a later pipeline stage); only hazards that forwarding cannot resolve (like the one unavoidable load-use cycle) fall through to the hazard detection unit, which then triggers an actual stall.

**Q78. What happens to an in-flight instruction in the Memory or Writeback stage when an earlier flush is triggered due to a branch misprediction detected in EX?**
Nothing — instructions already past the branch instruction in program order and further along the pipeline (i.e., they were correctly fetched before the branch, not after it) are unaffected and continue normally; only instructions fetched after the branch (in IF/ID, i.e., down the wrong speculative path) are squashed.

---

## H. Interrupts & Exceptions (Q79–Q88)

**Q79. What is the difference between an interrupt and an exception in RISC-V terminology?**
An interrupt is an asynchronous event, unrelated to the currently executing instruction, typically triggered by external hardware (timer, external device) or software-triggered inter-processor signaling. An exception is a synchronous event directly caused by executing a particular instruction (e.g., illegal instruction, misaligned access, ECALL/EBREAK, page fault) — both are handled through the same trap mechanism in the RISC-V privileged spec, but they differ in cause and timing relative to instruction execution.

**Q80. What does "precise exception" mean, and why does it matter for a pipelined processor?**
A precise exception means that when a trap occurs, the processor's architectural state reflects exactly the effects of all instructions before the faulting one, and none of the effects of the faulting instruction or any instruction after it — as if execution had stopped cleanly at that exact point in program order. It matters because software (an OS handler) needs a well-defined, consistent state to diagnose the fault, potentially fix it, and resume execution correctly.

**Q81. Why are precise exceptions harder to guarantee in a pipelined processor than in a simple non-pipelined one?**
Because multiple instructions are in flight simultaneously at different stages of completion, an exception detected in an early stage (e.g., illegal instruction in Decode) might occur while later-fetched-but-earlier-in-program-order... more precisely, instructions after the faulting one in later pipeline stages may have already partially executed or even written back results, while instructions before the faulting one might not have finished — the hardware must carefully sequence commit/writeback so state updates appear to happen in program order despite overlapped execution.

**Q82. How does a typical pipeline implement precise exceptions using an "exception flag" propagated through pipeline registers?**
Each pipeline stage that can detect a fault (e.g., illegal instruction in ID, misaligned memory access in MEM) tags the associated pipeline register with an exception-pending flag and cause code; this flag travels down the pipeline alongside the instruction, and only when it reaches the stage where exceptions are actually committed (often Writeback, or a dedicated commit stage) does the processor suppress that instruction's side effects, flush any younger instructions, and vector to the trap handler — ensuring exceptions are handled in program order even though they're detected out of order.

**Q83. What must happen to instructions younger (later in program order) than a faulting instruction once the exception is committed?**
They must be squashed/flushed (their effects discarded, including suppressing any pending register or memory writes), since a precise exception model requires that no instruction after the faulting one has taken effect.

**Q84. What RISC-V CSRs are central to trap handling (interrupts/exceptions)?**
Key CSRs include `mepc` (machine exception program counter — saves the PC to return to or retry), `mcause` (encodes the cause of the trap, and whether it's an interrupt or exception), `mtval` (holds trap-specific information, e.g., the faulting address), `mstatus` (holds global interrupt-enable state and privilege mode info), and `mtvec` (holds the trap handler's base address).

**Q85. Why does an interrupt typically need to be checked at instruction boundaries rather than mid-instruction?**
Because interrupts should also produce a "precise" state — the processor should look as though it completed some instruction and then, before starting the next one, diverted to the handler. Checking (and acting on) pending interrupts only at a clean instruction boundary (e.g., at commit/writeback) avoids ambiguous partial-instruction state.

**Q86. What does "interrupt latency" mean, and why does the Pulse-tier design (an in-order, real-time-focused core) emphasize minimizing and bounding it?**
Interrupt latency is the time from when an interrupt signal is asserted to when the processor begins executing the corresponding handler's first instruction. Real-time systems need this bounded and small so time-critical events (sensor deadlines, control loop ticks) are serviced predictably — an unbounded or highly variable interrupt latency would undermine the deterministic guarantees real-time software depends on.

**Q87. How can a deep pipeline or aggressive out-of-order execution increase interrupt/exception latency variability?**
Because pending, partially-completed in-flight instructions may need to drain, be flushed, or have their state carefully unwound before the processor can cleanly divert to a handler, and the amount of "cleanup" work needed can vary run to run depending on what happens to be in flight — deeper pipelines and OoO windows increase how much in-flight state exists, increasing both average and worst-case latency variability.

**Q88. What is a "nested" or "tail-chained" interrupt, and why do some MCU/real-time-class designs support it?**
Nested interrupt support allows a higher-priority interrupt to preempt a currently executing lower-priority interrupt handler. Tail-chaining allows back-to-back pending interrupts to be serviced without restoring/re-saving full context between them. Both techniques (common in ARM Cortex-M/R designs, for example) reduce the overhead and latency variability of handling multiple time-critical events in close succession, which matters a great deal for real-time-class cores.

---

## I. Out-of-Order Execution & Advanced Topics (Q89–Q95)

**Q89. What is out-of-order (OoO) execution, at a conceptual level?**
OoO execution allows instructions to execute (and complete their execution stage) in an order different from their original program order, based on when their operands actually become available, rather than strictly waiting for all prior instructions to execute first — while still committing/retiring results in program order to preserve correct program semantics.

**Q90. What is register renaming, and what hazard problem does it solve?**
Register renaming maps architectural register names to a larger pool of physical registers dynamically, giving each new write to a register a fresh physical register rather than reusing the same one. This eliminates WAR and WAW hazards (false dependencies that exist only because of reused register names, not because of real data dependencies), allowing more instructions to execute in parallel or out of order.

**Q91. What is a reorder buffer (ROB), and why is it needed in an OoO pipeline?**
The ROB is a structure that tracks all in-flight instructions in program order, holding their (potentially out-of-order-computed) results until they can be committed/retired in the correct original order. It's needed to preserve precise exception semantics and correct architectural state visibility despite instructions actually executing out of order internally.

**Q92. What is a reservation station (or issue queue), and what role does it play in OoO execution?**
A reservation station holds instructions that have been dispatched but are waiting for their operands to become available (via forwarding/broadcast from completing instructions); once all operands are ready, the instruction can be issued to a functional unit for execution, independent of program order, enabling the "execute when ready" behavior central to OoO.

**Q93. Why does OoO execution generally make worst-case execution time (WCET) analysis significantly harder than for an in-order pipeline?**
Because the actual number of cycles an instruction sequence takes depends on dynamic scheduling decisions, memory latency variability, and the availability of reservation stations/ROB entries at runtime — factors that are difficult to bound tightly through static analysis — whereas an in-order pipeline's timing can typically be traced deterministically instruction by instruction.

**Q94. What is speculative execution beyond branch prediction (e.g., memory dependence speculation), and what risk does it introduce?**
Beyond predicting branch direction, some OoO designs also speculate on whether a load can safely execute ahead of an earlier, not-yet-resolved store to a potentially overlapping address (memory dependence speculation), betting there's no actual conflict to gain performance. The risk is a memory-order violation if the speculation is wrong, requiring detection and a costly recovery (squash and re-execute) similar to a branch misprediction — and, as seen in real-world CPU security research, mis-speculation of this kind has also been a source of side-channel vulnerabilities (e.g., Spectre-class attacks).

**Q95. Why might a CPU IP family deliberately limit out-of-order execution to only its highest-performance product tier rather than offering it everywhere?**
Because OoO hardware (reservation stations, ROB, register renaming, wider issue logic) adds substantial area, power, verification complexity, and timing unpredictability — costs that make sense to pay only when raw throughput is the priority (e.g., an application-class core), but that directly conflict with the goals of lower tiers focused on area/power efficiency (microcontroller-class) or deterministic timing (real-time-class).

---

## J. Performance Metrics (Q96–Q100)

**Q96. What is CPI (Cycles Per Instruction), and how is it calculated?**
CPI is the average number of clock cycles required to execute one instruction, calculated as total clock cycles divided by total instructions executed for a given program. Lower CPI (closer to the ideal of 1 for a simple scalar pipeline) indicates less time lost to stalls, hazards, and mispredictions.

**Q97. What is IPC (Instructions Per Cycle), and how does it relate to CPI?**
IPC is the reciprocal of CPI — the average number of instructions completed per clock cycle. A single-issue in-order pipeline has a theoretical maximum IPC of 1, while superscalar and OoO designs can exceed 1 by completing multiple instructions per cycle.

**Q98. What is the standard formula relating execution time, instruction count, CPI, and clock period?**
Execution Time = Instruction Count × CPI × Clock Period (equivalently, Instruction Count × CPI ÷ Clock Frequency). This formula makes explicit the three levers available to reduce execution time: reduce the number of instructions (better compiler/ISA), reduce CPI (fewer stalls/hazards, better prediction), or reduce clock period (higher frequency, often via deeper pipelining).

**Q99. Why can increasing pipeline depth to raise clock frequency sometimes fail to improve, or even worsen, overall performance?**
Because execution time depends on both frequency and CPI — a deeper pipeline can increase CPI (more stall cycles from load-use hazards spanning more stages, larger branch misprediction penalties) faster than it increases frequency, especially if hazard/branch behavior doesn't scale favorably; beyond a certain depth, the CPI penalty can outweigh the frequency gain, a phenomenon well documented in the "diminishing returns of superpipelining" discussions from the early-2000s CPU frequency race.

**Q100. What is Amdahl's Law, and how does it apply to deciding how much effort to invest in pipeline hazard mitigation (e.g., forwarding, branch prediction)?**
Amdahl's Law states that the overall speedup from optimizing part of a system is limited by the fraction of total time that part actually affects — if hazard stalls only account for, say, 10% of total cycles, even perfectly eliminating them caps overall speedup accordingly. It's a useful sanity check for prioritizing pipeline design effort: investing heavily in eliminating a hazard type that's already rare in typical workloads yields far less benefit than addressing a hazard type (like load-use stalls or branch mispredictions) that dominates real program behavior.

---

## RTL Coding Exercises (RTL1–RTL25)

Each exercise includes a problem statement, a Verilog solution, and a short explanation. These are written for clarity/teaching purposes rather than as production-optimized RTL — adapt coding style to your project's linting and synthesis requirements.

### RTL1. Write a generic parameterized pipeline register.

**Problem:** Implement a synchronous pipeline register with reset and stall/enable control, parameterized by width.

```verilog
module pipeline_reg #(
    parameter WIDTH = 32
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             stall,   // hold current value, don't advance
    input  logic             flush,   // force output to zero (bubble)
    input  logic [WIDTH-1:0] d_in,
    output logic [WIDTH-1:0] d_out
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            d_out <= '0;
        else if (flush)
            d_out <= '0;
        else if (!stall)
            d_out <= d_in;
        // if stall and not flush: hold current value (implicit else)
    end
endmodule
```
**Explanation:** `flush` takes priority over `stall` since a squashed instruction must become a bubble even if the stage is otherwise stalled. When neither is asserted, the register behaves as a normal pipeline latch.

---

### RTL2. Write the IF/ID pipeline register for a 5-stage RISC-V core.

**Problem:** Capture the fetched instruction and PC between Fetch and Decode.

```verilog
module if_id_reg (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        stall,
    input  logic        flush,
    input  logic [31:0] pc_in,
    input  logic [31:0] instr_in,
    output logic [31:0] pc_out,
    output logic [31:0] instr_out
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            pc_out    <= 32'b0;
            instr_out <= 32'h00000013; // NOP = addi x0, x0, 0
        end else if (!stall) begin
            pc_out    <= pc_in;
            instr_out <= instr_in;
        end
    end
endmodule
```
**Explanation:** On flush/reset, the instruction field is explicitly set to RISC-V's canonical NOP encoding (`addi x0, x0, 0`) rather than raw zero, so downstream logic decoding this "bubble" behaves correctly as a genuine no-op.

---

### RTL3. Implement a basic RISC-V ALU supporting core R-type/I-type operations.

**Problem:** Support ADD, SUB, AND, OR, XOR, SLT, SLL, SRL, SRA.

```verilog
module alu (
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [3:0]  alu_op,
    output logic [31:0] result,
    output logic        zero
);
    localparam ADD = 4'b0000, SUB  = 4'b0001, AND_OP = 4'b0010,
               OR_OP = 4'b0011, XOR_OP = 4'b0100, SLT = 4'b0101,
               SLL = 4'b0110, SRL = 4'b0111, SRA = 4'b1000;

    always_comb begin
        case (alu_op)
            ADD:    result = a + b;
            SUB:    result = a - b;
            AND_OP: result = a & b;
            OR_OP:  result = a | b;
            XOR_OP: result = a ^ b;
            SLT:    result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            SLL:    result = a << b[4:0];
            SRL:    result = a >> b[4:0];
            SRA:    result = $signed(a) >>> b[4:0];
            default: result = 32'b0;
        endcase
    end

    assign zero = (result == 32'b0);
endmodule
```
**Explanation:** Shift amounts use only `b[4:0]` since RISC-V shift instructions only shift by 0–31 bits for 32-bit operands. `SRA` uses the arithmetic right-shift operator on a signed cast to preserve the sign bit.

---

### RTL4. Implement a 32×32-bit register file with two read ports and one write port, x0 hardwired to zero.

```verilog
module reg_file (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        we,
    input  logic [4:0]  rs1_addr,
    input  logic [4:0]  rs2_addr,
    input  logic [4:0]  rd_addr,
    input  logic [31:0] rd_data,
    output logic [31:0] rs1_data,
    output logic [31:0] rs2_data
);
    logic [31:0] regs [1:31]; // x0 is not stored, always reads 0

    assign rs1_data = (rs1_addr == 5'd0) ? 32'b0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'b0 : regs[rs2_addr];

    always_ff @(posedge clk) begin
        if (we && rd_addr != 5'd0)
            regs[rd_addr] <= rd_data;
    end
endmodule
```
**Explanation:** Reads are combinational (asynchronous) so Decode can use the value in the same cycle; writes happen synchronously on the clock edge. `x0` is excluded from storage entirely and always reads as zero, matching the RISC-V spec.

---

### RTL5. Implement write-first (same-cycle write-then-read) register file bypass.

**Problem:** Extend RTL4 so a register being written in the same cycle it's being read returns the new value, not the stale one.

```verilog
module reg_file_wf (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        we,
    input  logic [4:0]  rs1_addr,
    input  logic [4:0]  rs2_addr,
    input  logic [4:0]  rd_addr,
    input  logic [31:0] rd_data,
    output logic [31:0] rs1_data,
    output logic [31:0] rs2_data
);
    logic [31:0] regs [1:31];

    function automatic logic [31:0] read_port(input logic [4:0] addr);
        if (addr == 5'd0)
            read_port = 32'b0;
        else if (we && (addr == rd_addr))
            read_port = rd_data; // same-cycle write-first bypass
        else
            read_port = regs[addr];
    endfunction

    assign rs1_data = read_port(rs1_addr);
    assign rs2_data = read_port(rs2_addr);

    always_ff @(posedge clk) begin
        if (we && rd_addr != 5'd0)
            regs[rd_addr] <= rd_data;
    end
endmodule
```
**Explanation:** This models the common "write-then-read within the same cycle" convention: Writeback (first half of the cycle, conceptually) and Decode's read (second half) of the same register both see the new value, avoiding a 1-cycle stall for that specific hazard case.

---

### RTL6. Implement a hazard detection unit for a load-use hazard.

```verilog
module hazard_detect (
    input  logic        id_ex_mem_read,   // is instruction in ID/EX a load?
    input  logic [4:0]  id_ex_rd,         // destination reg of ID/EX instr
    input  logic [4:0]  if_id_rs1,        // source regs of instr in IF/ID
    input  logic [4:0]  if_id_rs2,
    output logic        stall             // assert: freeze PC/IF-ID, bubble ID/EX
);
    always_comb begin
        stall = id_ex_mem_read &&
                (id_ex_rd != 5'd0) &&
                ((id_ex_rd == if_id_rs1) || (id_ex_rd == if_id_rs2));
    end
endmodule
```
**Explanation:** This checks specifically for the load-use case: the instruction currently in ID/EX (about to enter EX) is a load, and the instruction currently in IF/ID (about to enter ID) needs that load's destination register as a source — the one hazard forwarding alone cannot resolve.

---

### RTL7. Implement the PC/IF-ID stall control logic driven by the hazard signal.

```verilog
module fetch_stall_ctrl (
    input  logic stall,
    output logic pc_write_en,
    output logic if_id_write_en,
    output logic id_ex_bubble
);
    always_comb begin
        pc_write_en    = ~stall; // hold PC when stalling
        if_id_write_en = ~stall; // hold IF/ID register when stalling
        id_ex_bubble   = stall;  // force ID/EX stage to NOP/bubble
    end
endmodule
```
**Explanation:** These three signals implement the standard stall recipe: freeze the PC and IF/ID register (so the same instruction is re-decoded next cycle) while forcing a bubble into ID/EX so no incorrect control signals propagate forward.

---

### RTL8. Implement a full EX-stage forwarding unit (EX/MEM and MEM/WB priority-encoded).

```verilog
module forwarding_unit (
    input  logic [4:0] id_ex_rs1,
    input  logic [4:0] id_ex_rs2,
    input  logic [4:0] ex_mem_rd,
    input  logic       ex_mem_reg_write,
    input  logic [4:0] mem_wb_rd,
    input  logic       mem_wb_reg_write,
    output logic [1:0] forward_a, // 00: reg file, 01: MEM/WB, 10: EX/MEM
    output logic [1:0] forward_b
);
    always_comb begin
        // Operand A (rs1)
        if (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs1))
            forward_a = 2'b10;
        else if (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1))
            forward_a = 2'b01;
        else
            forward_a = 2'b00;

        // Operand B (rs2)
        if (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs2))
            forward_b = 2'b10;
        else if (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2))
            forward_b = 2'b01;
        else
            forward_b = 2'b00;
    end
endmodule
```
**Explanation:** EX/MEM (`2'b10`) is checked before MEM/WB (`2'b01`) so the more recent result wins if both pipeline registers happen to target the same source register — preserving correct program-order semantics.

---

### RTL9. Implement the EX-stage ALU input muxes driven by the forwarding unit.

```verilog
module ex_operand_mux (
    input  logic [1:0]  forward_a,
    input  logic [1:0]  forward_b,
    input  logic [31:0] reg_rs1,
    input  logic [31:0] reg_rs2,
    input  logic [31:0] ex_mem_result,
    input  logic [31:0] wb_data,
    output logic [31:0] alu_in_a,
    output logic [31:0] alu_in_b
);
    always_comb begin
        case (forward_a)
            2'b10:   alu_in_a = ex_mem_result;
            2'b01:   alu_in_a = wb_data;
            default: alu_in_a = reg_rs1;
        endcase

        case (forward_b)
            2'b10:   alu_in_b = ex_mem_result;
            2'b01:   alu_in_b = wb_data;
            default: alu_in_b = reg_rs2;
        endcase
    end
endmodule
```
**Explanation:** This pairs directly with RTL8's `forward_a`/`forward_b` control codes to select between the register-file value and the two forwarding sources at the ALU's inputs.

---

### RTL10. Implement a branch comparator moved into the Decode stage (early branch resolution).

```verilog
module branch_compare (
    input  logic [31:0] rs1_data,
    input  logic [31:0] rs2_data,
    input  logic [2:0]  funct3,   // RISC-V branch funct3 encoding
    output logic        branch_taken
);
    logic eq, lt_signed, lt_unsigned;

    assign eq          = (rs1_data == rs2_data);
    assign lt_signed   = ($signed(rs1_data) < $signed(rs2_data));
    assign lt_unsigned = (rs1_data < rs2_data);

    always_comb begin
        case (funct3)
            3'b000:  branch_taken = eq;              // BEQ
            3'b001:  branch_taken = ~eq;              // BNE
            3'b100:  branch_taken = lt_signed;        // BLT
            3'b101:  branch_taken = ~lt_signed;       // BGE
            3'b110:  branch_taken = lt_unsigned;      // BLTU
            3'b111:  branch_taken = ~lt_unsigned;     // BGEU
            default: branch_taken = 1'b0;
        endcase
    end
endmodule
```
**Explanation:** Implementing this comparator directly in Decode (rather than reusing the shared ALU in Execute) lets the branch outcome be known one stage earlier, reducing the misprediction flush penalty from two instructions to one.

---

### RTL11. Implement a 2-bit saturating counter branch predictor (single entry).

```verilog
module sat_counter_2bit (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       update_en,
    input  logic       actual_taken,
    output logic       predict_taken
);
    typedef enum logic [1:0] {
        STRONG_NT = 2'b00,
        WEAK_NT   = 2'b01,
        WEAK_T    = 2'b10,
        STRONG_T  = 2'b11
    } state_t;

    state_t state, next_state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= WEAK_NT; // reasonable reset default
        else if (update_en)
            state <= next_state;
    end

    always_comb begin
        case (state)
            STRONG_NT: next_state = actual_taken ? WEAK_NT   : STRONG_NT;
            WEAK_NT:   next_state = actual_taken ? WEAK_T    : STRONG_NT;
            WEAK_T:    next_state = actual_taken ? STRONG_T  : WEAK_NT;
            STRONG_T:  next_state = actual_taken ? STRONG_T  : WEAK_T;
            default:   next_state = WEAK_NT;
        endcase
    end

    assign predict_taken = state[1]; // STRONG_T or WEAK_T
endmodule
```
**Explanation:** The counter only flips its prediction after two consecutive contrary outcomes, which is what gives 2-bit predictors better accuracy than 1-bit counters on typical loop patterns (where the exiting branch mispredicts only once instead of twice).

---

### RTL12. Implement a small direct-mapped Branch Target Buffer (BTB).

```verilog
module btb #(
    parameter ENTRIES = 64,
    parameter IDX_BITS = $clog2(ENTRIES)
) (
    input  logic               clk,
    input  logic                rst_n,
    input  logic [31:0]         pc_fetch,
    output logic                hit,
    output logic [31:0]         predicted_target,
    input  logic                update_en,
    input  logic [31:0]         update_pc,
    input  logic [31:0]         update_target
);
    logic [31:0] tag_mem    [0:ENTRIES-1];
    logic [31:0] target_mem [0:ENTRIES-1];
    logic        valid_mem  [0:ENTRIES-1];

    wire [IDX_BITS-1:0] idx_fetch  = pc_fetch[IDX_BITS+1:2];
    wire [IDX_BITS-1:0] idx_update = update_pc[IDX_BITS+1:2];

    assign hit              = valid_mem[idx_fetch] && (tag_mem[idx_fetch] == pc_fetch);
    assign predicted_target = target_mem[idx_fetch];

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < ENTRIES; i = i + 1)
                valid_mem[i] <= 1'b0;
        end else if (update_en) begin
            tag_mem[idx_update]    <= update_pc;
            target_mem[idx_update] <= update_target;
            valid_mem[idx_update]  <= 1'b1;
        end
    end
endmodule
```
**Explanation:** A direct-mapped BTB trades some accuracy (index collisions between different branch PCs) for simplicity and speed, which is usually an acceptable tradeoff for a small, fast structure accessed every Fetch cycle.

---

### RTL13. Implement a Return Address Stack (RAS) for call/return prediction.

```verilog
module ras #(
    parameter DEPTH = 8,
    parameter PTR_BITS = $clog2(DEPTH)
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        push_en,
    input  logic [31:0] push_addr,
    input  logic        pop_en,
    output logic [31:0] pop_addr,
    output logic         valid
);
    logic [31:0] stack [0:DEPTH-1];
    logic [PTR_BITS-1:0] sp;
    logic empty;

    assign pop_addr = stack[sp - 1'b1];
    assign valid    = ~empty;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp    <= '0;
            empty <= 1'b1;
        end else if (push_en) begin
            stack[sp] <= push_addr;
            sp        <= sp + 1'b1;
            empty     <= 1'b0;
        end else if (pop_en && !empty) begin
            sp <= sp - 1'b1;
            if (sp == 1) empty <= 1'b1;
        end
    end
endmodule
```
**Explanation:** `push_en` should be asserted on `jal`/`jalr` instructions that write `ra` (call-type); `pop_en` on `jalr` instructions that read `ra` with no write (return-type) — this simple stack correctly predicts return targets for typical non-recursive-overflow call patterns.

---

### RTL14. Implement pipeline flush logic for a mispredicted branch resolved in EX.

```verilog
module flush_ctrl (
    input  logic branch_mispredicted, // from EX stage
    output logic flush_if_id,
    output logic flush_id_ex,
    output logic pc_redirect_en
);
    always_comb begin
        flush_if_id     = branch_mispredicted;
        flush_id_ex     = branch_mispredicted;
        pc_redirect_en  = branch_mispredicted;
    end
endmodule
```
**Explanation:** Since the branch resolves in EX, the two instructions fetched after it (currently sitting in IF/ID and ID/EX) were fetched down the wrong path and must both be squashed, while the PC is redirected to the correct target for the next fetch.

---

### RTL15. Implement a control/decode unit that generates key control signals from the opcode.

```verilog
module control_unit (
    input  logic [6:0] opcode,
    output logic        reg_write,
    output logic        mem_read,
    output logic        mem_write,
    output logic        alu_src,   // 0: reg, 1: immediate
    output logic        branch,
    output logic [1:0]  result_src // 0: ALU, 1: MEM, 2: PC+4
);
    localparam OP_RTYPE  = 7'b0110011;
    localparam OP_ITYPE  = 7'b0010011;
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_JAL    = 7'b1101111;

    always_comb begin
        reg_write  = 1'b0;
        mem_read   = 1'b0;
        mem_write  = 1'b0;
        alu_src    = 1'b0;
        branch     = 1'b0;
        result_src = 2'b00;

        case (opcode)
            OP_RTYPE:  begin reg_write = 1'b1; alu_src = 1'b0; result_src = 2'b00; end
            OP_ITYPE:  begin reg_write = 1'b1; alu_src = 1'b1; result_src = 2'b00; end
            OP_LOAD:   begin reg_write = 1'b1; alu_src = 1'b1; mem_read = 1'b1; result_src = 2'b01; end
            OP_STORE:  begin alu_src = 1'b1; mem_write = 1'b1; end
            OP_BRANCH: begin branch = 1'b1; end
            OP_JAL:    begin reg_write = 1'b1; result_src = 2'b10; end
            default:   ; // illegal instruction handling occurs elsewhere
        endcase
    end
endmodule
```
**Explanation:** This is a simplified single-cycle-style decode; a real implementation would also generate `alu_op`/`funct3`/`funct7`-derived signals and feed an illegal-instruction exception trigger for unrecognized opcodes.

---

### RTL16. Implement an immediate generator supporting all six RISC-V immediate formats.

```verilog
module imm_gen (
    input  logic [31:0] instr,
    output logic [31:0] imm_out
);
    wire [6:0] opcode = instr[6:0];

    always_comb begin
        case (opcode)
            7'b0010011, 7'b0000011, 7'b1100111: // I-type (ALU-imm, load, JALR)
                imm_out = {{20{instr[31]}}, instr[31:20]};
            7'b0100011: // S-type (store)
                imm_out = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            7'b1100011: // B-type (branch)
                imm_out = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            7'b0110111, 7'b0010111: // U-type (LUI, AUIPC)
                imm_out = {instr[31:12], 12'b0};
            7'b1101111: // J-type (JAL)
                imm_out = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            default:
                imm_out = 32'b0;
        endcase
    end
endmodule
```
**Explanation:** Each RISC-V immediate format scrambles bit positions differently to optimize encoding hardware/sign-extension sharing across formats — this module reassembles them into a single sign-extended 32-bit value for use by the datapath.

---

### RTL17. Implement store-data forwarding into the MEM stage.

**Problem:** A store instruction's data operand may need to be forwarded from an instruction still completing in EX/MEM when the store reaches MEM.

```verilog
module store_data_forward (
    input  logic [4:0]  mem_stage_rs2,     // store's data-source register
    input  logic [4:0]  ex_mem_rd,
    input  logic         ex_mem_reg_write,
    input  logic [31:0]  reg_rs2_data,
    input  logic [31:0]  ex_mem_alu_result,
    output logic [31:0]  store_data
);
    always_comb begin
        if (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == mem_stage_rs2))
            store_data = ex_mem_alu_result;
        else
            store_data = reg_rs2_data;
    end
endmodule
```
**Explanation:** This handles the case where the value being stored was produced by the immediately preceding instruction, which by the time the store reaches MEM has its result available in the EX/MEM pipeline register — avoiding a stall that would otherwise be needed if only EX-stage forwarding existed.

---

### RTL18. Implement an exception-flag propagation scheme through the pipeline registers.

```verilog
module exc_flag_prop (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        stall,
    input  logic         exc_in_valid,
    input  logic [3:0]   exc_in_cause,
    output logic         exc_out_valid,
    output logic [3:0]   exc_out_cause
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exc_out_valid <= 1'b0;
            exc_out_cause <= 4'b0;
        end else if (!stall) begin
            exc_out_valid <= exc_in_valid;
            exc_out_cause <= exc_in_cause;
        end
    end
endmodule
```
**Explanation:** An instance of this logic sits alongside each pipeline register; a stage that detects a fault sets `exc_in_valid`/`exc_in_cause`, and the flag rides along with the instruction (frozen during stalls, just like the rest of the pipeline register) until it reaches the commit/writeback stage where the actual trap is taken.

---

### RTL19. Implement exception commit/trap logic at the Writeback stage.

```verilog
module trap_commit (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         wb_exc_valid,
    input  logic [3:0]   wb_exc_cause,
    input  logic [31:0]  wb_pc,
    output logic         trap_taken,
    output logic [31:0]  mepc,
    output logic [3:0]   mcause,
    output logic         flush_younger
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trap_taken    <= 1'b0;
            mepc          <= 32'b0;
            mcause        <= 4'b0;
            flush_younger <= 1'b0;
        end else begin
            trap_taken    <= wb_exc_valid;
            flush_younger <= wb_exc_valid;
            if (wb_exc_valid) begin
                mepc   <= wb_pc;
                mcause <= wb_exc_cause;
            end
        end
    end
endmodule
```
**Explanation:** Only when the exception flag reaches the final (Writeback/commit) stage is the trap actually taken — at that point all instructions ahead of the faulting one (in program order) have already completed, and `flush_younger` signals that any instructions behind it in the pipeline must be discarded, satisfying the precise-exception requirement.

---

### RTL20. Implement a simple direct-mapped instruction cache interface with a stall-on-miss signal.

```verilog
module icache_if #(
    parameter LINES = 256,
    parameter IDX_BITS = $clog2(LINES)
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [31:0]  pc,
    output logic [31:0]  instr,
    output logic         hit,
    output logic         miss_stall,
    // simplified backing-memory refill interface
    input  logic         refill_valid,
    input  logic [31:0]  refill_data
);
    logic [31:0] data_mem [0:LINES-1];
    logic [31:0] tag_mem  [0:LINES-1];
    logic        valid_mem[0:LINES-1];

    wire [IDX_BITS-1:0] idx = pc[IDX_BITS+1:2];

    assign hit        = valid_mem[idx] && (tag_mem[idx] == pc);
    assign instr       = hit ? data_mem[idx] : 32'h00000013; // NOP while missing
    assign miss_stall  = ~hit;

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < LINES; i = i + 1)
                valid_mem[i] <= 1'b0;
        end else if (refill_valid) begin
            data_mem[idx]  <= refill_data;
            tag_mem[idx]   <= pc;
            valid_mem[idx] <= 1'b1;
        end
    end
endmodule
```
**Explanation:** `miss_stall` connects into the same stall-control path as hazard-induced stalls (RTL7), freezing the pipeline until `refill_valid` delivers the requested line — conceptually the same "freeze upstream, bubble downstream" mechanism, just triggered by memory latency instead of a data hazard.

---

### RTL21. Implement a simple non-pipelined multi-cycle multiplier with a busy/stall interface.

```verilog
module mult_unit (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [31:0]  a,
    input  logic [31:0]  b,
    output logic [31:0]  result,
    output logic         busy,
    output logic         done
);
    logic [63:0] product;
    logic [2:0]  cycle_cnt;
    logic        running;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running   <= 1'b0;
            done      <= 1'b0;
            cycle_cnt <= 3'b0;
        end else if (start && !running) begin
            product   <= a * b; // synthesis tool infers multiplier hardware
            running   <= 1'b1;
            done      <= 1'b0;
            cycle_cnt <= 3'b0;
        end else if (running) begin
            if (cycle_cnt == 3'd3) begin // model a fixed 4-cycle latency
                running <= 1'b0;
                done    <= 1'b1;
            end else begin
                cycle_cnt <= cycle_cnt + 1'b1;
            end
        end else begin
            done <= 1'b0;
        end
    end

    assign result = product[31:0];
    assign busy   = running;
endmodule
```
**Explanation:** `busy` feeds into the hazard/stall logic (a structural hazard, per Q19) so a second multiply instruction reaching Execute while this unit is busy causes the pipeline to stall until `done` is asserted.

---

### RTL22. Implement a CSR read/write unit for a small subset of machine-mode CSRs.

```verilog
module csr_unit (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [11:0]  csr_addr,
    input  logic         csr_we,
    input  logic [31:0]  csr_wdata,
    output logic [31:0]  csr_rdata,
    // trap interface
    input  logic         trap_taken,
    input  logic [31:0]  trap_pc,
    input  logic [3:0]   trap_cause
);
    logic [31:0] mepc, mcause, mtvec, mstatus;

    localparam ADDR_MEPC   = 12'h341;
    localparam ADDR_MCAUSE = 12'h342;
    localparam ADDR_MTVEC  = 12'h305;
    localparam ADDR_MSTATUS= 12'h300;

    always_comb begin
        case (csr_addr)
            ADDR_MEPC:    csr_rdata = mepc;
            ADDR_MCAUSE:  csr_rdata = mcause;
            ADDR_MTVEC:   csr_rdata = mtvec;
            ADDR_MSTATUS: csr_rdata = mstatus;
            default:      csr_rdata = 32'b0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mepc    <= 32'b0;
            mcause  <= 32'b0;
            mtvec   <= 32'b0;
            mstatus <= 32'b0;
        end else if (trap_taken) begin
            mepc   <= trap_pc;
            mcause <= {28'b0, trap_cause};
        end else if (csr_we) begin
            case (csr_addr)
                ADDR_MTVEC:   mtvec   <= csr_wdata;
                ADDR_MSTATUS: mstatus <= csr_wdata;
                default: ; // read-only or unimplemented CSR write ignored
            endcase
        end
    end
endmodule
```
**Explanation:** `trap_taken` (from RTL19) takes priority over a normal CSR write in the same cycle, since the hardware-driven trap-entry update to `mepc`/`mcause` must win over any coincidental software CSR write that cycle.

---

### RTL23. Implement a simple MPU (memory protection unit) region checker for the Pulse/Nano tiers.

```verilog
module mpu_check #(
    parameter NUM_REGIONS = 8
) (
    input  logic [31:0] addr,
    input  logic         is_write,
    input  logic         is_exec,
    input  logic [31:0]  region_base [0:NUM_REGIONS-1],
    input  logic [31:0]  region_limit[0:NUM_REGIONS-1],
    input  logic          region_valid[0:NUM_REGIONS-1],
    input  logic          region_write_en[0:NUM_REGIONS-1],
    input  logic          region_exec_en[0:NUM_REGIONS-1],
    output logic          access_allowed,
    output logic          region_hit
);
    logic [NUM_REGIONS-1:0] hit_vec;
    integer i;

    always_comb begin
        for (i = 0; i < NUM_REGIONS; i = i + 1) begin
            hit_vec[i] = region_valid[i] &&
                         (addr >= region_base[i]) &&
                         (addr <  region_limit[i]);
        end

        region_hit     = |hit_vec;
        access_allowed = 1'b0;

        for (i = 0; i < NUM_REGIONS; i = i + 1) begin
            if (hit_vec[i]) begin
                access_allowed = (!is_write || region_write_en[i]) &&
                                  (!is_exec  || region_exec_en[i]);
            end
        end
    end
endmodule
```
**Explanation:** Unlike a TLB, an MPU has no page-table walk — every region's bounds and permissions are checked combinationally against fixed region registers, giving fixed, statically analyzable access-check latency, which is exactly why Pulse and Nano use an MPU rather than a full MMU/TLB.

---

### RTL24. Implement a simple TLB (translation lookaside buffer) lookup for the Apex tier's MMU.

```verilog
module tlb_lookup #(
    parameter ENTRIES = 32,
    parameter IDX_BITS = $clog2(ENTRIES)
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [19:0]  vpn,        // virtual page number
    output logic         tlb_hit,
    output logic [21:0]  ppn,        // physical page number
    output logic          perm_read,
    output logic          perm_write,
    output logic          perm_exec,
    // refill interface (from a page-table walker, not implemented here)
    input  logic          refill_en,
    input  logic [19:0]   refill_vpn,
    input  logic [21:0]   refill_ppn,
    input  logic [2:0]    refill_perm
);
    logic [19:0] vpn_mem  [0:ENTRIES-1];
    logic [21:0] ppn_mem  [0:ENTRIES-1];
    logic [2:0]  perm_mem [0:ENTRIES-1];
    logic        valid_mem[0:ENTRIES-1];

    wire [IDX_BITS-1:0] idx = vpn[IDX_BITS-1:0]; // simple direct-mapped index

    assign tlb_hit    = valid_mem[idx] && (vpn_mem[idx] == vpn);
    assign ppn        = ppn_mem[idx];
    assign perm_read  = perm_mem[idx][0];
    assign perm_write = perm_mem[idx][1];
    assign perm_exec  = perm_mem[idx][2];

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < ENTRIES; i = i + 1)
                valid_mem[i] <= 1'b0;
        end else if (refill_en) begin
            vpn_mem[idx]   <= refill_vpn;
            ppn_mem[idx]   <= refill_ppn;
            perm_mem[idx]  <= refill_perm;
            valid_mem[idx] <= 1'b1;
        end
    end
endmodule
```
**Explanation:** On a `tlb_hit` miss, a real MMU triggers a (variable-latency) page-table walk to refill the entry — this variability is precisely why Apex (which needs virtual memory for OS-class software) accepts non-deterministic access timing that Pulse/Nano's MPU deliberately avoids.

---

### RTL25. Implement a top-level 5-stage pipeline stall/flush arbiter combining hazard, cache-miss, and branch-flush sources.

**Problem:** Combine RTL6 (hazard stall), RTL14 (branch flush), and RTL20 (cache-miss stall) into one arbiter producing the final per-stage control signals.

```verilog
module pipeline_ctrl_arbiter (
    input  logic hazard_stall,      // from hazard_detect (RTL6)
    input  logic icache_miss_stall, // from icache_if (RTL20)
    input  logic branch_mispredict, // from EX stage branch resolution
    output logic pc_write_en,
    output logic if_id_write_en,
    output logic if_id_flush,
    output logic id_ex_bubble,
    output logic id_ex_flush
);
    always_comb begin
        // Any stall source freezes fetch/decode advancement.
        logic any_stall;
        any_stall = hazard_stall || icache_miss_stall;

        pc_write_en    = ~any_stall;
        if_id_write_en = ~any_stall;

        // A branch misprediction always flushes, regardless of stall state,
        // since the instructions being flushed were fetched down the wrong path.
        if_id_flush = branch_mispredict;
        id_ex_flush = branch_mispredict;

        // A load-use or cache-miss stall inserts a bubble into ID/EX even
        // without a flush, so the stalled instruction doesn't advance incorrectly.
        id_ex_bubble = any_stall && !branch_mispredict;
    end
endmodule
```
**Explanation:** This shows how independently-designed hazard sources (data hazards, structural/memory-latency hazards, control hazards) must ultimately be arbitrated into one consistent set of pipeline-register control signals — flush takes priority over stall for a given stage, since a squashed instruction should not also be treated as merely "held."

---
