# RISC-V Instruction Fetch — 100 Q&A + 25 RTL Coding Exercises

A study/reference set focused specifically on the instruction fetch stage of a RISC-V pipeline: PC management, instruction memory/I-cache interfacing, compressed-instruction alignment, branch prediction as it applies to fetch, fetch buffering, stalls, redirection/flush, multi-issue fetch, fetch-time exceptions and memory protection, and fetch power/performance optimization — followed by 25 hands-on RTL coding exercises with Verilog solutions.

## Table of Contents

1. [Fetch Fundamentals](#a-fetch-fundamentals-q1-q12) (Q1–Q12)
2. [Instruction Memory / I-Cache Interface](#b-instruction-memory--i-cache-interface-q13-q24) (Q13–Q24)
3. [RISC-V Compressed Instructions & Fetch Alignment](#c-risc-v-compressed-instructions--fetch-alignment-q25-q34) (Q25–Q34)
4. [Branch Prediction Interaction with Fetch](#d-branch-prediction-interaction-with-fetch-q35-q48) (Q35–Q48)
5. [Fetch Buffering / Queueing](#e-fetch-buffering--queueing-q49-q58) (Q49–Q58)
6. [Fetch Stalls & Backpressure](#f-fetch-stalls--backpressure-q59-q68) (Q59–Q68)
7. [Fetch Redirection & Flush](#g-fetch-redirection--flush-q69-q78) (Q69–Q78)
8. [Multi-/Wide-Issue Fetch](#h-multi-wide-issue-fetch-q79-q86) (Q79–Q86)
9. [Fetch Exceptions & Memory Protection](#i-fetch-exceptions--memory-protection-q87-q94) (Q87–Q94)
10. [Fetch Power & Performance Optimization](#j-fetch-power--performance-optimization-q95-q100) (Q95–Q100)
11. [RTL Coding Exercises](#rtl-coding-exercises-rtl1-rtl25) (RTL1–RTL25)

---

## A. Fetch Fundamentals (Q1–Q12)

**Q1. What is the fundamental job of the Instruction Fetch (IF) stage in a RISC-V pipeline?**
The IF stage retrieves the next instruction (or instructions, in a wide-fetch design) to be executed by reading instruction memory at the address held in the Program Counter (PC), and hands that raw instruction bits (plus the fetch-time PC) downstream to Decode — everything else in the pipeline depends on IF supplying the correct instruction stream, in the correct order, as fast as the rest of the pipeline can consume it.

**Q2. What is the Program Counter (PC), and what does it hold at any given moment?**
The PC is a register holding the memory address of the instruction currently being fetched (or, depending on convention, the address of the *next* instruction to fetch). It is the single most important piece of fetch-stage state — nearly everything else in IF exists to compute, predict, or correct the value that goes into the PC each cycle.

**Q3. What are the three basic ways the next PC value can be determined each cycle?**
(1) Sequential: PC + instruction length (4 for a standard 32-bit instruction, or 2 for RVC), for straight-line, non-control-flow code; (2) Predicted/redirected: a branch/jump target address, either speculatively predicted (via BTB/RAS) or authoritatively known (e.g., a direct jump's immediate target); (3) Exception/interrupt vector: the trap handler address, when a fault or interrupt overrides normal fetch flow entirely.

**Q4. Why is the PC update logic often described as a priority-encoded mux rather than a simple two-way choice?**
Because multiple sources can simultaneously want to redirect the PC in a given cycle — a branch misprediction resolved in a later stage, an exception, an interrupt, and a same-cycle BTB prediction, for example — and only one can actually win; the fetch logic must apply a clear priority order (typically: exception/interrupt highest, then a confirmed branch misprediction, then a same-cycle predicted redirect, then simple sequential increment as the default/lowest priority) to decide the PC for the next cycle.

**Q5. What is meant by the "fetch address," and how does it differ conceptually from the "commit PC" of the same instruction later in the pipeline?**
The fetch address is the PC value used to actually read instruction memory for a given instruction, captured at the moment of fetch; the same instruction's PC value is often carried through the pipeline (in pipeline registers) for use by later stages (e.g., computing a branch target relative to that PC, or reporting `mepc` on an exception) — conceptually the same number, but "fetch address" emphasizes its role as an I-cache/memory index, while "commit PC" (or "instruction PC") emphasizes its role as instruction-identifying metadata later in the pipeline.

**Q6. In a simple 5-stage RISC-V pipeline, does the Fetch stage know whether the instruction it just fetched is a branch?**
Not yet in the most basic design — the raw instruction bits haven't been decoded when they're fetched, so Fetch, by itself, has no inherent knowledge of instruction type. Any "prediction" made during Fetch (e.g., using a BTB) is based purely on the fetch address matching a previously-seen branch's PC in a prediction structure, not on decoding the instruction currently being fetched.

**Q7. What does it mean for instruction fetch to be "speculative" even in a simple in-order pipeline?**
Any time Fetch continues fetching sequentially (or via a predicted target) past an unresolved conditional branch, it is speculating that its guess (or the default "not taken, keep going sequentially" assumption) is correct — even a pipeline with no formal branch predictor is implicitly speculating by default whenever it fetches past a branch before that branch is resolved.

**Q8. Why is fetch often considered the stage most sensitive to the overall clock frequency target of a core?**
Fetch must produce a new address, access memory (or a cache), and often make a prediction, all within a single cycle at the target frequency — because this chain (PC generation → memory access → predict) tends to be one of the longer combinational-logic-adjacent paths in a simple pipeline, fetch timing frequently sets or strongly influences the achievable maximum clock frequency, especially in higher-frequency designs like Apex.

**Q9. What is meant by "fetch bandwidth," and why does it matter beyond just clock frequency?**
Fetch bandwidth is the number of instructions (or bytes of instruction stream) the fetch stage can supply per cycle — for a scalar in-order core this is typically one instruction per cycle, but for superscalar/wide-issue designs it must be more than one to keep the rest of the wider pipeline fed; even a very high clock frequency delivers poor overall performance if fetch bandwidth can't keep pace with how many instructions the back end of the pipeline could otherwise consume per cycle.

**Q10. What is the relationship between fetch and the rest of the "front end" of a CPU pipeline?**
Fetch is typically considered part of the front end alongside (pre-)decode and any instruction queueing/buffering, as distinct from the "back end" (execute, memory, writeback, and in OoO designs, the out-of-order execution engine) — the front end's job is purely to keep a correct, timely stream of instructions flowing into the back end, and front-end design (fetch bandwidth, prediction accuracy, buffering depth) is often a separate, dedicated area of optimization from back-end execution design.

**Q11. Why does fetch stage design differ meaningfully between the Nano, Pulse, and Apex tiers of a CPU IP family like ReflexRV?**
Nano's fetch can be extremely simple (single-instruction, no prediction, minimal buffering) since area/power dominate and performance needs are modest; Pulse's fetch needs bounded, predictable latency (favoring simple, statically-analyzable prediction or none at all) to preserve real-time determinism; Apex's fetch needs to sustain high bandwidth and high accuracy prediction (BTB, RAS, possibly wide/multi-instruction fetch) to feed a much deeper, higher-throughput pipeline — the same fundamental fetch job, implemented very differently depending on tier goals.

**Q12. What does "fetch stage decoupling" mean, and why is it a common technique in higher-performance designs?**
Decoupling means separating fetch from decode with a buffer (a FIFO/queue) in between, so fetch can run somewhat ahead of decode (or briefly behind, catching up) rather than being cycle-by-cycle lockstepped with it — this absorbs short-term rate mismatches (e.g., a brief decode stall doesn't have to immediately stall fetch, and vice versa) and is a prerequisite for many advanced fetch techniques like prediction-driven run-ahead fetching.

---

## B. Instruction Memory / I-Cache Interface (Q13–Q24)

**Q13. What is the simplest possible instruction memory interface for the Fetch stage?**
A synchronous, single-port, single-cycle-latency memory that takes the PC as an address input and returns the instruction at that address one cycle later (or combinationally, for an even simpler asynchronous-read model) — appropriate for small, tightly-coupled memories common in MCU-class (Nano-tier) designs where the entire program may fit in on-chip SRAM with deterministic access time.

**Q14. Why do higher-performance cores use an instruction cache (I-cache) rather than direct access to main memory for fetch?**
Main memory (DRAM, or even larger on-chip/off-chip memory) typically has access latency far higher than one cycle — often tens to hundreds of cycles — which would make every single fetch a multi-cycle stall if accessed directly; an I-cache holds a small, fast, on-chip copy of recently/likely-to-be-used instructions, so most fetches (cache hits) complete in one or two cycles, with only relatively rare cache misses paying the full memory latency.

**Q15. What is the difference between a "Harvard" and a "unified" cache/memory architecture as it pertains to fetch specifically?**
A Harvard-style design gives Fetch its own dedicated instruction cache/memory port, completely separate from the data cache/memory used by the Memory stage, avoiding contention between the two; a unified design shares one cache/memory structure for both instructions and data, which is simpler in some ways but risks structural hazards (Q13-Q14 from the earlier pipeline document) between simultaneous fetch and data-memory accesses.

**Q16. What is an I-cache "hit," and what happens on an I-cache "miss" from the fetch stage's perspective?**
A hit means the requested instruction's cache line is already present in the I-cache, and it can be returned within the cache's normal (fast) access latency. A miss means the line isn't present, requiring a fill request to a lower level of the memory hierarchy (L2 cache, or main memory); the fetch stage must stall (stop advancing) until the fill completes and the requested instruction becomes available.

**Q17. What is a cache line (or cache block), and why does the I-cache fetch a whole line rather than just the single requested instruction on a miss?**
A cache line is the fixed-size unit of data (e.g., 32 or 64 bytes) that a cache stores and transfers as a single unit; fetching an entire line on a miss (rather than just the one needed instruction) exploits spatial locality — since instruction execution is often sequential, nearby instructions in the same line are very likely to be fetched soon after, so pre-loading them avoids separate miss penalties for each one individually.

**Q18. What is set associativity in an I-cache, and what tradeoff does increasing it involve?**
Set associativity determines how many different possible locations ("ways") a given address's cache line can be placed in within a cache set; higher associativity reduces conflict misses (two frequently-used addresses competing for the same single cache location) but increases the tag comparison logic, access latency, and power cost of a lookup (more ways must be checked, or activated, per access) — a tradeoff a low-power tier like Nano might resolve very differently (e.g., no cache, or a small direct-mapped cache) than a performance tier like Apex (e.g., a larger, higher-associativity cache).

**Q19. What is a "direct-mapped" I-cache, and why might it be preferred in a low-power, low-complexity fetch design?**
A direct-mapped cache has associativity of one — each address maps to exactly one possible cache location, eliminating the need for way-selection/tag-comparison-among-multiple-ways logic entirely, which keeps the design simple, fast to access, and low-power, at the cost of more conflict misses than a set-associative design would experience for the same total capacity.

**Q20. What is meant by "critical word first" (or "early restart") as an I-cache miss optimization?**
Rather than waiting for an entire cache line to be filled from lower-level memory before returning any of it to Fetch, critical-word-first delivers the specific word actually needed (matching the current fetch address) as soon as it arrives from the fill, letting Fetch resume immediately, while the rest of the line continues filling in the background — reducing the effective miss penalty seen by the pipeline compared to waiting for the whole line.

**Q21. What is instruction prefetching, and how does it aim to reduce the effective I-cache miss rate seen by fetch?**
Prefetching speculatively requests cache lines the fetch stage is likely to need soon (commonly the "next sequential line" after the one currently being fetched) before an actual demand fetch for that line occurs, so that by the time fetch does reach that address, the line is already present in the cache (or on its way), hiding some or all of what would otherwise have been a miss penalty.

**Q22. What is the risk of overly aggressive instruction prefetching, particularly for a power-constrained design?**
Aggressive prefetching can fetch cache lines that end up never actually being used (e.g., prefetching straight-line code past a branch that turns out taken elsewhere), wasting memory bandwidth, cache space (potentially evicting lines that were actually needed, a phenomenon called cache pollution), and power for the wasted fetch/fill activity — a real tradeoff against the miss-rate benefit, especially relevant for area/power-constrained tiers.

**Q23. What is a non-blocking (or "lockup-free") I-cache, and why does it matter for fetch performance?**
A non-blocking cache can continue servicing new requests (or track multiple outstanding misses) even while an earlier miss is still being filled from lower-level memory, rather than stalling the entire cache/fetch pipeline until the one outstanding miss completes — this matters most for designs that want fetch to keep making forward progress (e.g., speculatively continuing down a predicted path) even while a miss is in flight, though it adds meaningful complexity (miss-status-holding registers, MSHRs) versus a simpler blocking cache.

**Q24. Why might the Nano tier of a CPU IP family reasonably choose to have no I-cache at all, using tightly-coupled memory (TCM) instead?**
For small, deterministic microcontroller-class programs that fit entirely in a modestly-sized on-chip SRAM, a cache's associativity/tag/miss-handling machinery adds area, power, and — critically for a real-time-adjacent low-end tier — access-time unpredictability (cache hit/miss variability) that a directly-addressed, fixed-single-cycle-latency tightly-coupled memory avoids entirely, trading some flexibility (must fit in the fixed TCM size) for simplicity, lower power, and fully deterministic fetch timing.

---

## C. RISC-V Compressed Instructions & Fetch Alignment (Q25–Q34)

**Q25. What is the RISC-V "C" (Compressed) extension, and how does it affect instruction fetch?**
The C extension defines 16-bit-wide encodings for a common subset of frequently-used instructions (alongside the base 32-bit encodings), improving code density; for fetch, this means instructions are no longer guaranteed to be a fixed 4 bytes each — fetch logic must handle a mixed stream of 2-byte and 4-byte instructions, including a standard 32-bit instruction that may start at a 2-byte-aligned (but not 4-byte-aligned) address.

**Q26. How does RISC-V distinguish a 16-bit compressed instruction from a 32-bit standard instruction during fetch/predecode?**
The bottom two bits of the first 16-bit half-word being examined indicate instruction length: a value of `11` in bits [1:0] signals a (at least) 32-bit instruction, while any other value (`00`, `01`, `10`) signals a 16-bit compressed instruction — this simple, fixed-position check can be done very early, even before full decode, letting fetch/predecode logic determine instruction boundaries quickly.

**Q27. Why does supporting the C extension mean a 32-bit instruction is no longer guaranteed to be 4-byte aligned in memory?**
Because compressed (16-bit) and standard (32-bit) instructions can be freely mixed in a program, a 32-bit instruction can begin immediately after a 16-bit one, landing it on a memory address that's a multiple of 2 but not necessarily a multiple of 4 — fetch logic (and the I-cache/memory interface) must be able to correctly read a 32-bit instruction that straddles what would otherwise be a "natural" 4-byte-aligned boundary.

**Q28. What is the specific hardware challenge of fetching a 32-bit instruction that straddles a fetch-width or cache-line boundary?**
If the fetch datapath or cache line width is, say, 4 bytes (32 bits) per access, and a 32-bit instruction begins at byte offset 2 within that width, half the instruction's bits come from the current fetch/line and the other half come from the next one — the fetch logic must buffer the first half, fetch the next word/line, and concatenate the two halves correctly before handing a complete instruction to Decode.

**Q29. What is a "predecode" step in the context of compressed instructions, and what does it typically do before full decode?**
Predecode is an early, lightweight pass (often done in or right after Fetch) that determines instruction boundaries (2-byte vs. 4-byte) within a fetched block, and sometimes also expands a 16-bit compressed instruction into an equivalent internal 32-bit-like representation (matching the semantics of its standard-instruction counterpart) so that the rest of the pipeline (decode, execute) can work with a uniform internal instruction format regardless of whether the original encoding was compressed or standard.

**Q30. Why might expanding compressed instructions into their standard-format equivalent early (at predecode) simplify the rest of the pipeline design?**
If Decode, hazard detection, and forwarding logic only ever need to reason about one canonical internal instruction representation (with register fields, opcodes, and immediates always in the same bit positions), the complexity of directly decoding two different encoding widths/formats doesn't need to be duplicated throughout every downstream pipeline stage — it's handled once, early, at the fetch/predecode boundary.

**Q31. How does the presence of compressed instructions complicate PC increment logic during sequential fetch?**
Instead of always advancing the PC by a fixed 4 bytes for the next sequential instruction, the fetch stage must determine, based on the just-fetched instruction's actual length (2 or 4 bytes, per the Q26 length-check), whether to advance the PC by 2 or by 4 — a data-dependent increment rather than a fixed constant, adding a small but real amount of extra logic into what would otherwise be simple PC+constant arithmetic.

**Q32. Why must a branch or jump target address in RISC-V always be even (2-byte aligned), even without the C extension mandating exact alignment otherwise?**
RISC-V requires all instruction addresses (including branch/jump targets) to be at least 2-byte aligned specifically to support the C extension's 16-bit instruction granularity — even in an implementation that doesn't support C, this alignment rule keeps the ISA consistent, and any target address with its least-significant bit set (odd address) triggers a misaligned instruction-fetch exception.

**Q33. What is the fetch-stage implication of C-extension support being optional per RISC-V implementation (some cores support only 4-byte-aligned, C-free code)?**
An implementation that doesn't support the C extension can assume every instruction is exactly 4 bytes and always 4-byte aligned, substantially simplifying fetch alignment logic (no boundary-straddling, no variable PC increment) — this is a legitimate design choice for a tier prioritizing simplicity, though it forecloses the code-density benefits (smaller binaries, better I-cache utilization) that C provides, benefits that are often especially valuable for memory-constrained tiers like Nano.

**Q34. Why can code density from the C extension indirectly improve I-cache performance, even though C itself doesn't change cache design?**
Smaller average instruction size (due to widespread 16-bit encoding of common instructions) means more actual instructions fit within the same fixed-size cache line/capacity, effectively increasing the useful "reach" of a given physical I-cache size — a program using C-extension code can experience a lower I-cache miss rate than the same program compiled without C, purely from fitting more useful instructions into the same cache footprint.

---

## D. Branch Prediction Interaction with Fetch (Q35–Q48)

**Q35. Why does branch prediction fundamentally have to happen in (or in service of) the Fetch stage, rather than later in the pipeline?**
Because the entire point of prediction is to decide what address to fetch *next*, before the branch's real outcome is known — if prediction only happened after the branch had already been decoded or executed, fetch would have already stalled waiting for that information, defeating the purpose; prediction must produce a next-fetch-address decision within the same cycle (or very close to it) that the branch itself is being fetched.

**Q36. What information does a fetch-stage Branch Target Buffer (BTB) lookup need, and what does a "hit" tell the fetch logic?**
A BTB lookup uses the current fetch address (PC) as an index/tag to check whether this PC has been recorded as a branch/jump in the past; a hit indicates "this address was previously seen to be a taken control-flow instruction," and supplies its previously-observed target address, letting fetch redirect to that target speculatively on the very next cycle rather than continuing sequentially and only discovering the branch (and its direction) after full decode.

**Q37. What happens at fetch when a BTB lookup misses (this PC has never been recorded as a branch)?**
Fetch defaults to the fallback behavior — typically continuing sequentially (PC + instruction length) — since there's no prediction information available; if the fetched instruction later turns out to actually be a taken branch (first time seen, or previously evicted from the BTB), the misprediction will be caught later (e.g., at Decode or Execute) and corrected via the normal flush/redirect mechanism, with a new BTB entry typically allocated at that point.

**Q38. How does a separate branch direction predictor (e.g., a 2-bit saturating counter table) complement a BTB during fetch?**
The BTB alone only supplies a target address, implicitly assuming "this branch, once fetched again, is probably taken" (or is looked up specifically because it's a known-taken-before branch); a direction predictor separately estimates taken/not-taken for a given branch based on history, letting fetch make a more nuanced decision — e.g., a BTB hit combined with a direction predictor saying "not taken" would correctly cause fetch to continue sequentially instead of blindly following the BTB's stored target.

**Q39. Why is it common to index both the BTB and the direction predictor using the fetch PC in the same cycle, in parallel?**
Since both structures need to influence the very next PC decision within the same fetch cycle, looking them up in parallel (rather than sequentially, e.g., only checking direction after a BTB hit) keeps the combined prediction latency down to a single cycle instead of stacking multiple sequential lookups — an important consideration since fetch is often a tight, latency-sensitive critical path (Q8).

**Q40. What is the role of the Return Address Stack (RAS) specifically at the fetch stage, and when is it consulted versus updated?**
The RAS is consulted (popped) at fetch time whenever the currently-fetched instruction is predicted/recognized (via BTB metadata or predecode) to be a return-type instruction, supplying the predicted return address as the next PC; it's updated (pushed) at fetch time whenever the currently-fetched instruction is predicted/recognized to be a call-type instruction, storing the return address (fetch PC + instruction length) for a later matching return.

**Q41. Why does fetch-time RAS management require identifying "is this a call/return" before the instruction is even decoded?**
Since the whole point is to redirect fetch immediately (within the same or next cycle) rather than waiting for full decode, fetch-time RAS logic typically relies on metadata stored in the BTB itself (e.g., a "this PC is a call" or "this PC is a return" tag recorded the first time the instruction was seen and classified, likely during an earlier decode/execute pass) rather than decoding the current fetch on the fly.

**Q42. What happens to fetch when a branch is predicted taken via the BTB, but the BTB's stored target address later turns out to be stale (e.g., due to self-modifying or relocated code)?**
Fetch will have speculatively continued down the (now-incorrect) stale target; once the real target is computed (typically at Decode or Execute, from the actual immediate/register value), a misprediction/retarget flush is triggered exactly as it would be for a direction misprediction — the BTB entry is typically then updated with the newly observed correct target, so subsequent fetches of that PC use the corrected value.

**Q43. Why is indirect branch/jump target prediction (e.g., `jalr` to a computed register value) especially hard for fetch-stage prediction structures?**
A basic BTB entry conventionally records one fixed target per PC, but an indirect jump's actual target can vary across different dynamic executions of the exact same instruction (e.g., virtual dispatch, switch-statement jump tables) — a plain BTB will only ever predict whichever target it saw most recently, mispredicting whenever the real target changes, which is why more sophisticated designs use pattern-based indirect predictors that key on recent execution history, not just the PC alone.

**Q44. What is a fetch-stage "predicted taken but not actually a branch" scenario, and how can it occur?**
Because a fetch-time BTB lookup is based purely on matching PC address bits (before the actual instruction bits at that address are even known to be the same instruction that populated the BTB entry, e.g., after a context switch to different code mapped at an aliased address, or after self-modifying code), it's possible for a BTB hit to "predict" a redirect for an address that, in the current context, doesn't actually hold a branch instruction at all — later pipeline stages that do have the real decoded instruction must detect this mismatch and correct it (flush and refetch sequentially), similar to any other misprediction recovery.

**Q45. Why does prediction accuracy matter more, in terms of overall performance impact, for deeper pipelines with a fetch stage further from where branches resolve?**
Per Q67-Q68 from the pipeline-hazards discussion, a deeper pipeline (more stages between Fetch and branch resolution) means more instructions are speculatively fetched down whatever path fetch predicted before a misprediction is caught — so the same prediction accuracy percentage translates into a larger absolute number of wasted fetch cycles (and larger absolute performance loss) on a deeper pipeline than on a shallow one, making prediction accuracy investment more valuable as pipeline depth (and thus Apex-tier ambitions) increases.

**Q46. Why might a real-time-oriented fetch design (Pulse tier) deliberately choose a fetch-time prediction scheme with a fixed, bounded misprediction penalty rather than a highly accurate but variable-penalty one?**
Even a very accurate dynamic predictor introduces execution-history-dependent, data-dependent timing variability (the same branch instruction can resolve after a different number of effectively-wasted fetch cycles depending on unrelated prior program history) — for WCET analysis, a simpler, fixed/bounded-penalty scheme (even if its average-case performance is somewhat worse) is often preferable because its worst case is easy to state and prove, exactly mirroring the branch-predictor tradeoff discussed for Pulse in the pipeline document (Q69 there).

**Q47. What is "fetch-directed prefetching," and how does it use branch prediction beyond just redirecting the immediate next PC?**
Fetch-directed prefetching uses the branch predictor's output not just to decide the very next fetch address, but to run the predictor further ahead (predicting several branches' worth of future control flow in advance) purely to identify and prefetch I-cache lines the fetch stream is likely to need soon, decoupling "predicting where control flow will go" from "actually fetching instructions from there this cycle" — a more advanced technique typically reserved for high-performance, Apex-class designs given the extra prediction/prefetch-queue hardware it requires.

**Q48. How does a mispredicted BTB/direction-predictor outcome typically get fed back to update the prediction structures themselves?**
Once a branch's real outcome (taken/not-taken and actual target) is authoritatively known — typically at Decode (for an early-resolving comparator, as discussed in the pipeline document) or Execute — that outcome is fed back to update the relevant BTB entry (correcting or confirming the stored target) and direction-predictor counter (per Q46's 2-bit saturating counter update rule), so that the next time fetch encounters the same PC, the prediction reflects the most recently observed behavior.

---

## E. Fetch Buffering / Queueing (Q49–Q58)

**Q49. What is a fetch buffer (or instruction queue/FIFO), and why is it placed between Fetch and Decode?**
It's a small FIFO storage structure that holds fetched-but-not-yet-decoded instructions, decoupling the rate at which Fetch produces instructions from the rate at which Decode (and the rest of the pipeline) consumes them, so short-term mismatches between the two (a brief fetch stall, or a brief decode/back-end stall) don't have to immediately and directly propagate as a stall on the other side.

**Q50. Why can a fetch buffer improve overall throughput even in a simple single-issue, in-order pipeline?**
Even in a simple pipeline, fetch and decode can have slightly different natural cadences moment-to-moment (e.g., an I-cache line fill delivers several instructions' worth of data at once, faster than decode consumes them one at a time) — a small buffer smooths out this instantaneous mismatch, letting fetch get some useful work done during what would otherwise be idle cycles from decode's perspective, and vice versa.

**Q51. What does it mean for a fetch buffer to "absorb" a decode-stage stall?**
If Decode (or a later stage) needs to stall for a cycle (e.g., due to a hazard), a full or partially-full fetch buffer means Fetch doesn't necessarily need to also immediately stop that same cycle — it can continue filling the buffer (up to its capacity) with already-fetched-and-queued instructions, and only actually needs to stall once the buffer itself becomes full, giving a small amount of slack before a decode-side stall ripples all the way back to fetch.

**Q52. What happens to a fetch buffer's contents when a branch misprediction or exception triggers a flush?**
The entire buffer (or the portion of it holding instructions from the now-known-incorrect speculative path) must be flushed/invalidated along with the rest of the pipeline, since those buffered instructions were fetched down a path that's now known to be wrong — a buffer effectively increases the amount of "in-flight, potentially-wrong" speculative work that must be discarded on a misprediction, a real cost that must be weighed against the throughput benefits of buffering.

**Q53. Why might a deeper fetch buffer allow a more aggressive, "run further ahead" fetch policy?**
With more buffer capacity to absorb temporary rate mismatches, fetch can afford to speculatively run further ahead of where decode/execute currently is, since there's more room to hold the extra in-flight instructions before backpressure (buffer full) forces fetch to actually stop — this can help hide I-cache miss latency (fetch keeps making progress into buffer space while a miss is serviced) but increases the amount of speculative work at risk on a misprediction (Q52).

**Q54. What is "fetch throttling," and why might a design intentionally limit how far ahead fetch is allowed to run even when buffer space is available?**
Fetch throttling deliberately caps how many outstanding/buffered speculative instructions fetch is allowed to have in flight, even below the buffer's full physical capacity — often used to limit wasted power (speculatively fetching and buffering instructions down a path that has a meaningful chance of misprediction, per Q45, burns power for work that may well be discarded) or to bound worst-case flush cost for latency-sensitive designs.

**Q55. How does a fetch buffer's width relate to instruction fetch bandwidth in a multi-issue design?**
In a design that fetches multiple instructions per cycle (per Section H later), the fetch buffer typically also needs to accept multiple instructions per cycle to avoid becoming a bottleneck that undoes the benefit of wide fetch — buffer write-port width (how many instructions can be pushed in per cycle) must be matched to the actual fetch bandwidth for the buffer not to become the limiting factor.

**Q56. Why might a fetch buffer entry store more than just the raw instruction bits — what other metadata is commonly carried alongside each buffered instruction?**
Common accompanying metadata includes the instruction's own PC (needed later for branch target computation, exception reporting, or debug), a predicted-taken/not-taken flag and predicted target (so later stages can verify the prediction without re-deriving it), and sometimes an early exception flag (e.g., an I-cache access fault or ITLB miss detected at fetch time, to be resolved precisely later, per the earlier pipeline document's exception-flag-propagation discussion).

**Q57. What is a "skid buffer" in the context of fetch, and how does it differ from a general-purpose FIFO fetch buffer?**
A skid buffer is a small buffering structure (often just one or two entries) specifically used to catch instruction(s) that were already "in flight" from a memory/cache access at the exact moment a stall or flush signal arrives, preventing them from being lost — it's a narrower, more specific mechanism than a general fetch queue, aimed at handling the pipeline latency between "request issued to memory" and "stall signal asserted" cleanly.

**Q58. Why is fetch buffer occupancy sometimes monitored and exposed as a performance-counter/debug signal?**
Persistently near-empty occupancy suggests fetch bandwidth or I-cache latency is the bottleneck limiting overall performance (decode/back-end is starved, waiting on fetch); persistently near-full/backpressured occupancy suggests the opposite (decode/back-end can't keep up with what fetch can supply) — this diagnostic signal helps designers and firmware/software performance engineers understand where the actual bottleneck in a given workload lies.

---

## F. Fetch Stalls & Backpressure (Q59–Q68)

**Q59. What are the main sources of fetch-stage stalls in a typical RISC-V core?**
I-cache misses (Q16), fetch buffer full / decode backpressure (Q51), structural hazards from a shared memory port (in a unified-memory design), ITLB misses (for designs with virtual memory, discussed in Section I), and explicit software-visible fetch throttling or sleep states (e.g., `WFI`) are the most common sources.

**Q60. How does fetch backpressure from a full instruction queue actually get communicated to the PC-generation logic?**
Typically via a simple "queue full" (or "almost full," to account for pipeline latency in the stall signal itself) signal that gates the PC-write-enable and I-cache-request-enable signals, functionally identical in spirit to the hazard-detection-driven stall signals discussed in the earlier pipeline document — when backpressure is asserted, the PC simply doesn't advance, and no new fetch request is issued, until the queue has drained enough to accept more.

**Q61. Why must a fetch stall correctly handle an already-in-flight I-cache/memory request rather than simply freezing all fetch logic instantaneously?**
If a fetch request was already issued to the I-cache/memory system in a prior cycle and its response (the fetched instruction data) is still arriving, a naive instantaneous freeze could either lose that in-flight response or incorrectly re-request the same address — proper stall handling (often via a small skid buffer, Q57) must still accept and correctly buffer any already-in-flight response even while further new requests are held off.

**Q62. What is the effect of an I-cache miss's variable latency on fetch stall duration, and why does this matter for real-time-oriented designs?**
Unlike a fixed-latency hazard stall (e.g., exactly one cycle for a load-use hazard), an I-cache miss's stall duration depends on the latency of whatever lower-level memory services it, which can itself vary (e.g., depending on system bus contention, DRAM refresh timing, or further misses at L2) — this variability is a direct source of timing non-determinism, which is exactly why real-time-class designs (Pulse) often prefer deterministic-latency tightly-coupled memory (Q24) over a cache specifically to avoid this class of stall variability.

**Q63. What is a "structural" fetch stall in a unified (non-Harvard) memory architecture, and when does it occur?**
It occurs when Fetch needs to access the shared memory/cache port in the same cycle that a data-memory operation (a load or store from the Memory stage) also needs that same port — since only one access can typically be serviced per cycle on a single shared port, one of the two requesters must stall; many designs resolve this by giving data-memory access priority (since a load/store is architecturally "older" in program order in a simple in-order pipeline) and stalling fetch instead.

**Q64. How does an ITLB miss cause a fetch stall, and how does its latency profile compare to an I-cache miss?**
An ITLB miss means the virtual-to-physical address translation needed to actually access the I-cache/memory for this fetch address isn't cached, requiring a (potentially multi-level) page-table walk to resolve — walks can themselves involve multiple memory accesses and can, in the worst case, take longer than a typical I-cache miss, making ITLB misses one of the most variable-latency fetch stall sources in designs that support virtual memory (relevant to Apex, not Pulse/Nano which use an MPU with no page-table walking at all).

**Q65. Why might a fetch stage need to distinguish between a "recoverable" stall (wait and retry) and a scenario requiring an exception?**
Some fetch-blocking conditions are transient and simply require waiting (an I-cache miss will eventually complete; a full queue will eventually drain) — but others represent a genuine fault (e.g., a fetch address for which no valid physical mapping/permission exists at all) that no amount of waiting will resolve; fetch logic must correctly classify which case it's in, since a genuine fault needs to be reported as a precise exception (per the earlier pipeline document's exception-handling discussion) rather than causing an indefinite stall.

**Q66. What is "stall coalescing," and why might it matter when multiple simultaneous stall conditions could apply to fetch in the same cycle?**
Stall coalescing (or arbitration) is the logic that correctly combines multiple potential stall sources (I-cache miss, queue full, structural hazard) into a single, correct overall stall decision for that cycle, ensuring the PC/fetch-request logic is held whenever *any* applicable condition requires it — a naive implementation that only checked one stall source at a time could incorrectly allow fetch to proceed when a different, unchecked condition should have blocked it.

**Q67. Why does a fetch stall in a design with speculative/predicted fetch also need to correctly handle what to do with an already-in-flight speculative prediction?**
If fetch predicted a redirect (via BTB) for the cycle right before a stall condition asserts, that predicted redirect target needs to be correctly held/queued so it's still applied once the stall clears, rather than being lost (which would incorrectly cause fetch to resume from the wrong, stale sequential address once unstalled) — stall logic and prediction logic must be designed together, not as entirely independent concerns.

**Q68. Why is minimizing average fetch stall frequency often prioritized differently across the three ReflexRV tiers?**
Apex prioritizes minimizing average stall frequency aggressively (bigger/higher-associativity I-cache, prefetching, deep buffering) since raw average throughput is the primary goal; Pulse prioritizes making whatever stalls do occur bounded and predictable over minimizing their average frequency (favoring deterministic-latency memory over a cache, even if that means somewhat more frequent but perfectly predictable stalls); Nano deprioritizes elaborate stall-avoidance machinery entirely in favor of minimal area/power, accepting whatever stall behavior a simple, direct-access tightly-coupled memory naturally provides.

---

## G. Fetch Redirection & Flush (Q69–Q78)

**Q69. What triggers a fetch redirect, in general terms?**
Any authoritative determination that the PC value fetch is currently using (or about to use) is wrong — a confirmed branch misprediction (from Decode's early comparator or Execute's ALU-based resolution), a confirmed BTB/RAS misprediction, an exception or interrupt requiring a trap-handler vector, or a `mret`/`sret` trap-return instruction restoring a previous PC — all cause fetch to redirect to a new, correct address, typically flushing whatever was already fetched down the now-known-wrong path.

**Q70. Why must a fetch redirect always be accompanied by a flush of some portion of the pipeline (and fetch buffer), not just a silent PC change?**
Any instructions already fetched (and possibly buffered or further along in the pipeline) between the mispredicted/wrong instruction and the point where the correct redirect is finally recognized were fetched down an incorrect path and must never be allowed to complete/commit — simply changing the PC going forward without also discarding this already-in-flight incorrect work would let wrong-path instructions corrupt architectural state.

**Q71. What determines exactly how many pipeline stages' worth of instructions must be flushed on a given redirect?**
The redirect penalty depends on how many cycles/stages separate the fetch of the now-known-wrong instructions from the stage where the redirect condition is finally detected and resolved — a redirect resolved early (e.g., a same-cycle BTB correction, or an early Decode-stage branch comparator) flushes very little; a redirect resolved late (e.g., an exception detected deep in a long pipeline, or an OoO core's final commit-stage detection) flushes everything fetched in the intervening window, which can be substantial in a deep/wide/OoO design.

**Q72. How does fetch redirect priority typically get resolved when multiple redirect sources are pending in the same cycle (e.g., an exception and a branch misprediction both signal in the same cycle)?**
A fixed priority order is applied, generally reflecting program order and architectural correctness requirements — an exception/interrupt (which must take effect precisely, per the earlier pipeline document's precise-exception discussion) typically takes priority over a branch misprediction correction if both are pending, since the exception's semantics require the trap to occur as if nothing after the faulting point (including any not-yet-corrected branch redirect) had happened.

**Q73. What is "redirect latency," and why is minimizing it a key fetch-stage performance goal independent of prediction accuracy itself?**
Redirect latency is the number of cycles between a misprediction/exception being detected and fetch actually beginning to supply correct instructions from the new address — even with a fixed misprediction rate, reducing how many cycles it takes to recognize and act on a misprediction (e.g., by resolving branches earlier, or by minimizing the pipeline stages between detection and PC-mux update) directly reduces the average performance cost per misprediction, independent of how often mispredictions happen in the first place.

**Q74. Why does a fetch redirect need to correctly cancel any already-in-flight memory/I-cache request for the (now-wrong) sequential or previously-predicted address?**
If a request was already issued to the I-cache/memory system for the old (now-incorrect) address just before the redirect is recognized, that request's eventual response must either be explicitly discarded when it arrives, or the request itself cancelled if the memory interface supports cancellation — otherwise stale, wrong-path data could be mistakenly accepted into the fetch buffer as if it were a valid response to the new, correct fetch address.

**Q75. What is "redirect coalescing" or "redirect suppression," and when might it be useful?**
If multiple redirect-triggering conditions are detected in quick succession (e.g., a branch misprediction correction is itself immediately followed, before it even completes, by a higher-priority exception), redirect coalescing/suppression logic ensures only the final, correct redirect is actually acted upon rather than fetch briefly (and wastefully) beginning to fetch from an intermediate, soon-to-be-superseded address.

**Q76. Why is it important that a fetch redirect due to a branch misprediction also update the relevant prediction structures (BTB, direction predictor, RAS) as part of the same event?**
Correcting the immediate fetch-stream error (getting fetch back on the right path) is necessary but not sufficient — without also updating the prediction tables with the now-known-correct outcome (per Q48), the exact same misprediction would likely recur the next time this same branch is encountered, so redirect handling and predictor-update logic are tightly coupled, typically triggered by the same misprediction-detection event.

**Q77. What is a "partial flush," and why might a design distinguish it from a "full pipeline flush"?**
A partial flush discards only the specific in-flight instructions known to be on the wrong path (e.g., only those younger than the mispredicted branch, in program order) while leaving unrelated, still-correct in-flight instructions untouched — this matters most in wider/OoO designs where many instructions from various points in the program can be simultaneously in flight, and indiscriminately flushing everything would needlessly discard correct, already-completed work.

**Q78. How does the fetch redirect mechanism differ for a `WFI`-triggered sleep/wake sequence compared to a branch misprediction?**
A `WFI` wake-up isn't correcting an error — it's resuming normal sequential fetch (PC advances to the instruction after `WFI`, or to an interrupt handler vector if an interrupt caused the wake, per the earlier low-power document's `WFI` discussion) from a fetch stage that was deliberately, correctly halted, not one that fetched incorrect instructions; no flush of "wrong-path" work is needed since nothing wrong was fetched — the PC/fetch-enable logic simply resumes normal operation.

---

## H. Multi-/Wide-Issue Fetch (Q79–Q86)

**Q79. What does it mean for a fetch stage to be "wide" or support "multi-instruction fetch"?**
A wide fetch stage retrieves and delivers more than one instruction per clock cycle (e.g., 2, 4, or more), rather than the single instruction per cycle typical of a scalar in-order design — necessary to feed a superscalar or wide-issue back end that's itself capable of decoding/executing multiple instructions per cycle, since a narrow (single-instruction) fetch would otherwise bottleneck the whole pipeline regardless of how wide the back end is.

**Q80. What is a "fetch packet" (or "fetch group"), and why is this concept useful in wide-fetch design?**
A fetch packet is the group of consecutive instructions (up to the fetch width) retrieved together in a single fetch-stage access, typically aligned to some fixed boundary (e.g., a cache-line-aligned chunk) — treating this group as a single logical unit through predecode, buffering, and initial pipeline stages simplifies wide-fetch datapath design compared to tracking each instruction fully independently from the moment of fetch.

**Q81. Why does a taken branch within a fetch packet complicate wide fetch, and how is it typically handled?**
If a fetch packet contains, say, 4 sequential instructions but the 2nd one is a taken branch, only the first 2 instructions in that packet are actually on the correct execution path — the instructions after the taken branch within the same packet must be identified (typically via within-packet BTB/predecode information) and marked invalid/discarded, while fetch redirects to the branch's target for the next packet, meaning a wide fetch packet's effective/useful width can be less than its maximum width whenever a taken branch falls in the middle of it.

**Q82. What is meant by "fetch packet fragmentation" due to taken branches, and why does it reduce effective (delivered) fetch bandwidth below the theoretical maximum?**
Fragmentation refers to exactly the scenario in Q81 — a taken branch partway through a fetch-width-sized packet effectively truncates that cycle's useful yield to fewer instructions than the maximum fetch width, meaning average delivered fetch bandwidth across a real program (with branches distributed throughout) is typically well below the nominal peak fetch width, a key reason why widening fetch has diminishing average-case returns without also improving prediction accuracy and taken-branch handling.

**Q83. What is a "trace cache," and how does it aim to address the taken-branch fetch-packet fragmentation problem?**
A trace cache stores previously-executed dynamic instruction sequences ("traces") that may span multiple original static basic blocks and multiple taken branches, indexed and retrieved as a single contiguous unit — since it stores the already-resolved, actual dynamic path (including having "unrolled" past taken branches), a trace cache hit can deliver a full-width, non-fragmented fetch packet even across what would otherwise be several separate taken-branch-truncated fetches from a conventional I-cache.

**Q84. Why is a trace cache generally reserved for high-performance (Apex-class) designs rather than lower tiers?**
A trace cache adds substantial additional storage (effectively a second, redundantly-overlapping instruction cache holding pre-assembled dynamic traces) plus the construction/management logic to build and maintain valid traces, which is a meaningful area/power/complexity cost — justified only when the fetch-bandwidth gains from avoiding branch-fragmentation losses (Q82) are worth more than that cost, which is generally true only for wide, high-frequency, high-IPC-target designs, not simpler or power-constrained tiers.

**Q85. How does predecode information stored alongside cache lines help wide/multi-issue fetch identify instruction boundaries and branches more quickly?**
Rather than re-deriving instruction-length (Q26) and branch/predicted-redirect information from scratch every time a line is fetched, some designs compute and cache this predecode metadata once (typically at the time a line is first filled into the I-cache) and store it alongside the raw instruction bytes, so subsequent fetches of the same line can immediately use the pre-computed boundary/branch information rather than repeating that work on every single access.

**Q86. Why does the RISC-V C extension's variable instruction length (Q25-Q34) add extra complexity specifically to wide/multi-issue fetch, beyond the scalar case?**
In a scalar fetch, only one instruction's length needs to be determined per cycle to compute the next PC; in a wide fetch delivering several instructions from one packet, the fetch/predecode logic must determine the boundary of every instruction within that packet (since a 16-bit compressed instruction shifts where the *next* instruction inside the same packet begins), which is a meaningfully more complex, chained/cascading boundary-detection problem than the single-instruction scalar case — real high-performance RVC-supporting fetch designs devote specific hardware to this multi-instruction-boundary detection.

---

## I. Fetch Exceptions & Memory Protection (Q87–Q94)

**Q87. What is an "instruction access fault," and when does the fetch stage detect it?**
It's an exception raised when the fetch stage attempts to read an instruction from an address that has no valid mapping, or lacks execute permission, in the current memory protection scheme (an MPU region check or an MMU/TLB permission check, per the earlier pipeline document's Apex-vs-Pulse/Nano MPU/MMU discussion) — this must be detected as part of the fetch-address-to-physical-access translation/check process, before (or as) the actual memory read is attempted.

**Q88. What is a "misaligned instruction fetch" exception, and under what specific condition does it occur in RISC-V?**
It occurs if the fetch address is not properly aligned per the ISA's alignment rule — for a C-extension-supporting implementation, any address is a legal (2-byte-aligned) instruction address, so this specific exception mainly arises for implementations without C support (which require full 4-byte alignment) attempting to fetch from an odd or non-4-byte address, or in any implementation, an attempt to jump to an odd (least-significant-bit-set) target address, since RISC-V requires the LSB of any jump/branch target to be zero.

**Q89. Why must a fetch-stage-detected exception (like an access fault) still be handled precisely, per the earlier pipeline-wide precise-exception discussion, rather than being acted upon immediately at fetch time?**
Even though the fault condition is detected as early as Fetch, the exception can't be "taken" (trap vector fetched, `mepc`/`mcause` updated) until it's confirmed that no earlier-in-program-order instruction itself first causes some other event that should take priority, and until the faulting instruction's position in program order is properly respected relative to any redirects/flushes already in flight — so, exactly as with any other pipeline-stage-detected exception, a fetch-detected fault is tagged with an exception-pending flag (Q82 from the earlier pipeline document) and propagated to the commit stage where it's finally, precisely acted upon.

**Q90. What is the fetch-stage-specific consequence of tagging (rather than immediately halting on) a detected access-fault condition?**
The fetch stage typically still needs to produce *some* placeholder value (since the pipeline register format expects a value) for the "instruction" at that faulting address — commonly a fixed placeholder/NOP-like value — while the exception-pending flag carries the real information forward, ensuring no attempt is made to actually decode/execute meaningless or unavailable instruction bits from an address that couldn't legally be read.

**Q91. How does an ITLB (Instruction TLB) permission check differ from an MPU region check in what it's actually verifying at fetch time?**
An ITLB entry (relevant to Apex-tier virtual memory) verifies that a *virtual* fetch address has a valid *virtual-to-physical* translation and that the resulting mapping carries execute permission for the current privilege mode, potentially failing with a page fault if no valid translation exists yet (requiring a page-table walk, or ultimately an OS-handled page fault if no mapping is ever established); an MPU (relevant to Pulse/Nano) directly checks a *physical* fetch address against a small set of fixed, statically-configured region descriptors for execute permission, with no translation step and no page-fault-style "not yet mapped, go load it" recovery path at all — a fixed pass/fail decision.

**Q92. Why does the ITLB's page-fault-vs-permission-fault distinction matter for how the associated exception is handled?**
A page fault (translation doesn't exist yet) is often a recoverable condition from the processor's point of view — the OS's fault handler can load the missing mapping and the faulting instruction can then be safely retried; a genuine permission fault (translation exists, but this privilege mode / access type isn't allowed) is typically not recoverable by retry and represents a real protection violation, so `mcause`/equivalent trap-cause encoding must distinguish these cases precisely enough for the trap handler to know which of these very different responses is appropriate.

**Q93. Why is fetch-time memory protection checking (MPU or ITLB) considered a critical, not optional, security/safety feature even for a simple in-order core?**
Without any fetch-time execute-permission check, a core could be tricked (e.g., via a corrupted or attacker-controlled PC value, a classic control-flow-hijacking scenario) into fetching and executing instructions from data memory or other unintended regions — enforcing execute permission at the point of fetch is a foundational protection against this entire class of security and safety issue, which is exactly why even the simplest, most area-constrained Nano tier still includes MPU-based protection (per the earlier pipeline document) rather than omitting memory protection entirely.

**Q94. What is the fetch-stage timing implication of an MPU check versus an ITLB check, tying back to the earlier WCET-determinism discussion?**
An MPU's fixed-region comparator logic completes in a small, constant number of gate delays regardless of outcome, contributing a fixed, easily-analyzable amount to fetch-stage timing; an ITLB check's timing is only fixed on a hit — a miss potentially triggers a variable-latency page-table walk, reintroducing exactly the kind of non-deterministic fetch-stall behavior (Q64) that makes ITLB/MMU-based fetch unsuitable for the bounded-WCET goals of the Pulse and Nano tiers, and acceptable only where Apex's virtual-memory requirements make the tradeoff worthwhile.

---

## J. Fetch Power & Performance Optimization (Q95–Q100)

**Q95. What is a loop buffer (or "loop cache"), and how does it reduce both power and, sometimes, latency for tight loops?**
A loop buffer is a small, dedicated storage structure that, once a tight loop's instruction sequence is detected being repeatedly fetched (e.g., a small backward branch executed multiple times in a row), captures that sequence so subsequent iterations can be re-supplied directly from the loop buffer instead of re-accessing the (larger, higher-power-per-access) I-cache — since the loop buffer is small and simple, each access typically costs meaningfully less dynamic power than a full I-cache access, and can sometimes also offer lower or more consistent latency.

**Q96. Why are loop buffers a particularly attractive low-power technique for embedded/DSP-adjacent RISC-V workloads specifically?**
Many embedded and signal-processing-style workloads spend a large fraction of total execution time inside small, tight, frequently-repeated loops (filter kernels, control loops, simple polling loops) — exactly the access pattern a loop buffer is designed to exploit, meaning even a small loop buffer can capture a disproportionately large share of total fetch activity for such workloads, yielding outsized power savings relative to its modest hardware cost.

**Q97. How does a loop buffer's detection logic typically identify when to start "capturing" a loop, and when to start serving fetches from the buffer instead of the I-cache?**
A common approach tracks backward-branch (loop-back) taken events at a given small PC range; after observing the same small instruction-address range being re-executed (e.g., after the second or third iteration, once high confidence is reached that this is indeed a repeating loop, and assuming the loop's instruction footprint is small enough to fit the buffer), the fetch logic switches from normal I-cache fetching to serving directly from the now-populated loop buffer, until the loop-exit branch (or an interrupt/exception) breaks the pattern.

**Q98. What is the relationship between fetch bandwidth, fetch power, and clock gating for an idle/underutilized fetch stage?**
When fetch has no useful work to do — a full downstream buffer causing backpressure (Q60), a `WFI`-triggered sleep (per the earlier low-power document), or simply a narrower-than-peak-bandwidth need for a given workload — the same clock-gating principles discussed for pipeline registers generally apply directly to fetch-stage logic (PC register, I-cache access logic, prediction structures), gating their clocks during cycles where no new fetch request is actually being made, directly reducing fetch's contribution to total dynamic power during those idle cycles.

**Q99. Why might a design deliberately limit branch predictor table sizes (BTB entries, direction-predictor counters) below what maximum achievable accuracy would suggest, specifically for power reasons?**
Every additional predictor table entry is storage that must be read (and often written, on updates) on relevant fetch cycles, and remains powered (leaking) continuously if not itself power-gated — beyond a certain table size, the marginal accuracy improvement from adding more entries diminishes (most of the benefit comes from a relatively small table capturing the "hottest," most-frequently-executed branches) while the power/area cost continues to scale roughly linearly with table size, so a power-conscious design (or even a moderately performance-focused one, per typical diminishing-returns curves) often deliberately caps predictor table size well below what a purely accuracy-maximizing design might otherwise choose.

**Q100. Bringing it together: how does the fetch stage's design across Nano, Pulse, and Apex tiers illustrate the "right-sized tier for the task" philosophy discussed for ReflexRV as a whole?**
Nano's fetch is minimal and direct — a single instruction per cycle from tightly-coupled memory, no prediction structures, aggressive clock gating during idle/`WFI` — prioritizing area and power above all else for simple, small-footprint code; Pulse's fetch adds just enough structure (perhaps simple static or bounded-penalty prediction, deterministic-latency memory access) to be useful without ever compromising bounded, analyzable worst-case fetch timing, since determinism — not raw throughput — is its defining constraint; Apex's fetch is the most elaborate of the three — wide/multi-instruction fetch, deep buffering, accurate dynamic BTB/RAS/direction prediction, an I-cache backed by an ITLB, and potentially advanced techniques like trace caches or fetch-directed prefetching — because sustained high throughput is exactly what that tier exists to deliver, and its fetch design is built to match that goal rather than any other.

---

## RTL Coding Exercises (RTL1–RTL25)

Each exercise includes a problem statement, a Verilog solution, and a short explanation. These are written for clarity/teaching purposes rather than as production-optimized RTL — adapt coding style, port widths, and protocol details to your project's actual memory interface and target library.

### RTL1. Implement the core PC register with reset, sequential increment, and redirect mux.

```verilog
module pc_reg (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         stall,
    input  logic         redirect_en,
    input  logic [31:0]  redirect_target,
    input  logic [31:0]  seq_next_pc,   // pc + 2 or pc + 4, computed externally
    output logic [31:0]  pc
);
    logic [31:0] next_pc;

    assign next_pc = redirect_en ? redirect_target : seq_next_pc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc <= 32'h0000_0000; // reset vector
        else if (!stall)
            pc <= next_pc;
        // stall: hold current pc
    end
endmodule
```
**Explanation:** `redirect_en` takes priority over sequential advance (Q4), and `stall` overrides both — matching the priority order (redirect > stall-hold > sequential) that real fetch-stage PC logic needs. The sequential-vs-compressed increment decision (Q31) is deliberately factored out into `seq_next_pc`, computed by RTL2.

---

### RTL2. Implement a variable PC increment (+2 for compressed, +4 for standard) based on the fetched instruction's length.

```verilog
module pc_increment (
    input  logic [31:0] pc,
    input  logic [15:0] instr_lsh, // lower 16 bits of the fetched word
    output logic [31:0] seq_next_pc,
    output logic         is_compressed
);
    // RISC-V length encoding: bits [1:0] == 2'b11 means >=32-bit instruction.
    assign is_compressed = (instr_lsh[1:0] != 2'b11);
    assign seq_next_pc   = is_compressed ? (pc + 32'd2) : (pc + 32'd4);
endmodule
```
**Explanation:** This implements the Q26/Q31 length check directly — examining only the bottom two bits of the first half-word is sufficient to determine whether to advance the PC by 2 or 4, without needing a full instruction decode.

---

### RTL3. Implement a simple single-cycle tightly-coupled instruction memory (Nano-tier style).

```verilog
module tcm_instr_mem #(
    parameter DEPTH_WORDS = 4096
) (
    input  logic         clk,
    input  logic [31:0]  addr,
    output logic [31:0]  instr_out
);
    logic [31:0] mem [0:DEPTH_WORDS-1];

    // Word-aligned access; caller is responsible for handling the
    // sub-word (compressed-instruction) alignment case (RTL4).
    always_ff @(posedge clk) begin
        instr_out <= mem[addr[$clog2(DEPTH_WORDS)+1:2]];
    end
endmodule
```
**Explanation:** This models the deterministic, fixed-single-cycle-latency memory access described in Q13/Q24 — no tags, no hit/miss logic, no variable latency, exactly the simplicity a Nano-tier fetch stage relies on for bounded timing.

---

### RTL4. Implement compressed-instruction boundary handling for a 32-bit-wide memory interface.

**Problem:** Fetch a possibly-unaligned 32-bit instruction that may straddle two consecutive 32-bit memory words.

```verilog
module unaligned_fetch_align (
    input  logic [31:0] pc,
    input  logic [31:0] mem_word0,   // word at pc[31:2]
    input  logic [31:0] mem_word1,   // word at pc[31:2] + 1
    output logic [31:0] instr_aligned
);
    // If pc[1] == 1, the instruction starts at byte offset 2 within
    // mem_word0 and, if it's a 32-bit instruction, needs its upper
    // 16 bits from mem_word1's lower half.
    always_comb begin
        if (!pc[1])
            instr_aligned = mem_word0;
        else
            instr_aligned = {mem_word1[15:0], mem_word0[31:16]};
    end
endmodule
```
**Explanation:** This directly implements the Q27-Q28 boundary-straddling problem: when `pc[1]` is set (the instruction begins on the upper half of `mem_word0`), the aligned instruction is reconstructed by concatenating the lower 16 bits of the *next* word with the upper 16 bits of the *current* word.

---

### RTL5. Implement a compressed-instruction predecoder that expands a 16-bit C.ADDI to its 32-bit ADDI equivalent.

```verilog
module rvc_expand_addi (
    input  logic [15:0] c_instr,
    output logic [31:0] expanded_instr,
    output logic         valid_c_addi
);
    // C.ADDI: funct3=000, opcode=01 -> addi rd, rd, imm
    wire [4:0] rd  = c_instr[11:7];
    wire signed [5:0] imm6 = {c_instr[12], c_instr[6:2]};

    assign valid_c_addi = (c_instr[1:0] == 2'b01) && (c_instr[15:13] == 3'b000) && (rd != 5'd0);

    always_comb begin
        if (valid_c_addi)
            expanded_instr = {{6{imm6[5]}}, imm6, rd, 3'b000, rd, 7'b0010011}; // ADDI encoding
        else
            expanded_instr = 32'h0000_0013; // NOP fallback
    end
endmodule
```
**Explanation:** This shows the Q29-Q30 predecode-expansion concept concretely for one instruction: `C.ADDI`'s compact 16-bit fields are unpacked and re-assembled into the exact bit layout of the standard 32-bit `ADDI` I-type encoding, so downstream decode logic never needs to know the instruction originally arrived in compressed form.

---

### RTL6. Implement a direct-mapped BTB with metadata for call/return classification (feeding the RAS).

```verilog
module btb_with_metadata #(
    parameter ENTRIES = 128,
    parameter IDX_BITS = $clog2(ENTRIES)
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [31:0]  fetch_pc,
    output logic          hit,
    output logic [31:0]   target,
    output logic          is_call,
    output logic          is_return,
    input  logic          update_en,
    input  logic [31:0]   update_pc,
    input  logic [31:0]   update_target,
    input  logic          update_is_call,
    input  logic          update_is_return
);
    logic [31:0] tag_mem   [0:ENTRIES-1];
    logic [31:0] target_mem[0:ENTRIES-1];
    logic        valid_mem [0:ENTRIES-1];
    logic        call_mem  [0:ENTRIES-1];
    logic        ret_mem   [0:ENTRIES-1];

    wire [IDX_BITS-1:0] idx_f = fetch_pc[IDX_BITS+1:2];
    wire [IDX_BITS-1:0] idx_u = update_pc[IDX_BITS+1:2];

    assign hit       = valid_mem[idx_f] && (tag_mem[idx_f] == fetch_pc);
    assign target    = target_mem[idx_f];
    assign is_call    = hit && call_mem[idx_f];
    assign is_return  = hit && ret_mem[idx_f];

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < ENTRIES; i = i + 1) valid_mem[i] <= 1'b0;
        end else if (update_en) begin
            tag_mem[idx_u]    <= update_pc;
            target_mem[idx_u] <= update_target;
            valid_mem[idx_u]  <= 1'b1;
            call_mem[idx_u]   <= update_is_call;
            ret_mem[idx_u]    <= update_is_return;
        end
    end
endmodule
```
**Explanation:** This extends a basic BTB (as built in the earlier pipeline document) with the `is_call`/`is_return` tags described in Q41 — fetch-time logic can use these directly to decide whether to push or pop the RAS (RTL7) without needing to decode the actual instruction first.

---

### RTL7. Implement fetch-time RAS push/pop control driven by BTB metadata.

```verilog
module fetch_ras_ctrl (
    input  logic         btb_hit,
    input  logic         btb_is_call,
    input  logic         btb_is_return,
    input  logic [31:0]  fetch_pc,
    input  logic [31:0]  seq_next_pc,   // return address to push, if a call
    input  logic [31:0]  ras_pop_addr,  // from RAS module
    output logic          ras_push_en,
    output logic [31:0]   ras_push_addr,
    output logic          ras_pop_en,
    output logic [31:0]   predicted_target,
    output logic          predict_valid
);
    assign ras_push_en   = btb_hit && btb_is_call;
    assign ras_push_addr = seq_next_pc;
    assign ras_pop_en    = btb_hit && btb_is_return;

    assign predicted_target = btb_is_return ? ras_pop_addr : /* fall through to BTB target elsewhere */ 32'bz;
    assign predict_valid    = btb_hit;
endmodule
```
**Explanation:** A call pushes the fall-through address (`seq_next_pc`, the instruction after the call) so a later matching return can pop it back; a return instead pops the RAS for its predicted target — directly implementing the Q40-Q41 fetch-time RAS management logic using only BTB-supplied metadata, with no instruction decode required.

---

### RTL8. Implement the fetch redirect priority mux combining exception, misprediction, and BTB prediction sources.

```verilog
module fetch_redirect_priority (
    input  logic         exception_valid,
    input  logic [31:0]  exception_vector,
    input  logic         branch_mispredict_valid,
    input  logic [31:0]  branch_correct_target,
    input  logic         btb_predict_valid,
    input  logic [31:0]  btb_predict_target,
    input  logic [31:0]  seq_next_pc,
    output logic [31:0]  next_pc,
    output logic          redirect_en
);
    always_comb begin
        if (exception_valid) begin
            next_pc     = exception_vector;
            redirect_en = 1'b1;
        end else if (branch_mispredict_valid) begin
            next_pc     = branch_correct_target;
            redirect_en = 1'b1;
        end else if (btb_predict_valid) begin
            next_pc     = btb_predict_target;
            redirect_en = 1'b1;
        end else begin
            next_pc     = seq_next_pc;
            redirect_en = 1'b0;
        end
    end
endmodule
```
**Explanation:** This directly encodes the Q4/Q72 priority order: exceptions/interrupts win over a confirmed branch misprediction correction, which wins over a same-cycle BTB speculative prediction, which wins over the default sequential fall-through — exactly the kind of arbitration real fetch-redirect logic must perform every cycle.

---

### RTL9. Implement a fetch buffer (FIFO) with push/pop and full/empty status.

```verilog
module fetch_buffer #(
    parameter DEPTH  = 8,
    parameter WIDTH  = 32,
    parameter PTR_W  = $clog2(DEPTH)
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             flush,
    input  logic             push_en,
    input  logic [WIDTH-1:0] push_data,
    input  logic             pop_en,
    output logic [WIDTH-1:0] pop_data,
    output logic             full,
    output logic             empty
);
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    logic [PTR_W:0]   count;

    assign full  = (count == DEPTH);
    assign empty = (count == 0);
    assign pop_data = mem[rd_ptr];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            if (push_en && !full) begin
                mem[wr_ptr] <= push_data;
                wr_ptr      <= wr_ptr + 1'b1;
            end
            if (pop_en && !empty) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
            case ({push_en && !full, pop_en && !empty})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule
```
**Explanation:** This is the decoupling FIFO from Q49-Q52 — `flush` clears the entire buffer instantly (needed on a misprediction/exception redirect, per Q52), while independent push/pop each cycle let fetch and decode advance at their own natural rates within the buffer's depth.

---

### RTL10. Implement fetch backpressure generation from buffer occupancy (with early-warning margin).

```verilog
module fetch_backpressure #(
    parameter DEPTH = 8,
    parameter MARGIN = 2  // stop fetching this many entries before truly full
) (
    input  logic [$clog2(DEPTH+1)-1:0] buf_count,
    output logic                        fetch_stall
);
    assign fetch_stall = (buf_count >= (DEPTH - MARGIN));
endmodule
```
**Explanation:** Stalling a bit before the buffer is truly full (Q60's "almost full" note) accounts for the fact that a fetch request already in flight when backpressure is asserted may still land an additional entry in the buffer a cycle or two later — the margin prevents an overflow that a zero-margin "stall only when literally full" policy could otherwise risk.

---

### RTL11. Implement a skid buffer to catch an in-flight memory response arriving the same cycle a stall is asserted.

```verilog
module fetch_skid_buffer (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         stall,
    input  logic         mem_resp_valid,
    input  logic [31:0]  mem_resp_data,
    output logic         skid_valid,
    output logic [31:0]  skid_data,
    input  logic         skid_consume
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skid_valid <= 1'b0;
        end else if (stall && mem_resp_valid && !skid_valid) begin
            // Response arrived exactly while stalling: catch it here
            // instead of dropping it.
            skid_data  <= mem_resp_data;
            skid_valid <= 1'b1;
        end else if (skid_consume) begin
            skid_valid <= 1'b0;
        end
    end
endmodule
```
**Explanation:** This solves the Q57/Q61 problem directly: a memory response that lands in the exact cycle a stall condition (e.g., buffer-full backpressure) asserts would otherwise be silently lost if fetch logic just froze everything — the skid buffer catches it so it can be consumed (pushed into the main fetch buffer) once the stall clears.

---

### RTL12. Implement stall-source coalescing (arbitrating multiple simultaneous stall conditions).

```verilog
module fetch_stall_coalesce (
    input  logic icache_miss,
    input  logic itlb_miss,
    input  logic buffer_full,
    input  logic structural_hazard,
    output logic fetch_stall,
    output logic [1:0] stall_cause  // encoded for debug/perf-counter use
);
    always_comb begin
        if (itlb_miss) begin
            fetch_stall = 1'b1;
            stall_cause = 2'd0;
        end else if (icache_miss) begin
            fetch_stall = 1'b1;
            stall_cause = 2'd1;
        end else if (structural_hazard) begin
            fetch_stall = 1'b1;
            stall_cause = 2'd2;
        end else if (buffer_full) begin
            fetch_stall = 1'b1;
            stall_cause = 2'd3;
        end else begin
            fetch_stall = 1'b0;
            stall_cause = 2'd0;
        end
    end
endmodule
```
**Explanation:** This directly implements Q66's coalescing requirement — any single applicable stall source is sufficient to hold fetch, and the encoded `stall_cause` output (useful for RTL25's performance counters) records which one actually applied this cycle, even though multiple could theoretically be true simultaneously.

---

### RTL13. Implement a simple direct-mapped MPU-gated fetch address checker.

```verilog
module fetch_mpu_check #(
    parameter NUM_REGIONS = 4
) (
    input  logic [31:0] fetch_addr,
    input  logic [31:0] region_base [0:NUM_REGIONS-1],
    input  logic [31:0] region_limit[0:NUM_REGIONS-1],
    input  logic          region_exec_en[0:NUM_REGIONS-1],
    input  logic          region_valid[0:NUM_REGIONS-1],
    output logic          fetch_allowed,
    output logic          access_fault
);
    logic [NUM_REGIONS-1:0] hit_vec;
    integer i;

    always_comb begin
        for (i = 0; i < NUM_REGIONS; i = i + 1) begin
            hit_vec[i] = region_valid[i] &&
                         (fetch_addr >= region_base[i]) &&
                         (fetch_addr <  region_limit[i]);
        end

        fetch_allowed = 1'b0;
        for (i = 0; i < NUM_REGIONS; i = i + 1) begin
            if (hit_vec[i])
                fetch_allowed = region_exec_en[i];
        end

        access_fault = ~fetch_allowed;
    end
endmodule
```
**Explanation:** A fixed, combinational region check (Q91, Q94) with constant timing regardless of hit/miss outcome — exactly the deterministic-latency property that makes an MPU appropriate for Pulse/Nano fetch, contrasted with the variable-latency ITLB check in RTL14.

---

### RTL14. Implement a simple ITLB lookup with page-fault-vs-hit distinction for Apex-tier fetch.

```verilog
module fetch_itlb_check #(
    parameter ENTRIES = 16,
    parameter IDX_BITS = $clog2(ENTRIES)
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [19:0]  vpn,
    output logic          tlb_hit,
    output logic [21:0]   ppn,
    output logic           exec_perm,
    output logic           page_fault,   // hit, but no execute permission
    output logic           tlb_miss,     // needs a page-table walk
    input  logic          refill_en,
    input  logic [19:0]   refill_vpn,
    input  logic [21:0]   refill_ppn,
    input  logic           refill_exec_perm
);
    logic [19:0] vpn_mem  [0:ENTRIES-1];
    logic [21:0] ppn_mem  [0:ENTRIES-1];
    logic        perm_mem [0:ENTRIES-1];
    logic        valid_mem[0:ENTRIES-1];

    wire [IDX_BITS-1:0] idx = vpn[IDX_BITS-1:0];

    assign tlb_hit    = valid_mem[idx] && (vpn_mem[idx] == vpn);
    assign ppn        = ppn_mem[idx];
    assign exec_perm  = perm_mem[idx];
    assign tlb_miss    = ~tlb_hit;
    assign page_fault = tlb_hit && ~perm_mem[idx];

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < ENTRIES; i = i + 1) valid_mem[i] <= 1'b0;
        end else if (refill_en) begin
            vpn_mem[idx]   <= refill_vpn;
            ppn_mem[idx]   <= refill_ppn;
            perm_mem[idx]  <= refill_exec_perm;
            valid_mem[idx] <= 1'b1;
        end
    end
endmodule
```
**Explanation:** `tlb_miss` (needs a variable-latency page-table walk, Q64/Q92) is distinguished from `page_fault` (a hit, but permission genuinely denied — a real protection violation, Q92) since these two conditions require completely different downstream handling: one triggers a walk-and-retry, the other triggers a precise exception with no retry possible.

---

### RTL15. Implement a 2-entry (dual-issue) wide-fetch packet with in-packet taken-branch truncation.

```verilog
module wide_fetch_packet (
    input  logic [63:0]  raw_packet,   // 2 x 32-bit instructions from I-cache
    input  logic          slot0_is_branch_taken, // from within-packet BTB check
    output logic [31:0]   instr0,
    output logic [31:0]   instr1,
    output logic          instr1_valid
);
    assign instr0       = raw_packet[31:0];
    assign instr1        = raw_packet[63:32];
    // If slot 0 is a taken branch, slot 1 (sequentially after it) is
    // on the wrong path and must be invalidated -- the packet's
    // effective width shrinks to 1 this cycle (Q81-Q82).
    assign instr1_valid = ~slot0_is_branch_taken;
endmodule
```
**Explanation:** This is the simplest possible illustration of fetch packet fragmentation (Q81-Q82): a taken branch in the first slot of a 2-wide packet invalidates the second slot, since it's sequentially past a control-flow instruction that's redirecting elsewhere — real wide-fetch designs generalize this truncation logic across every slot position, not just slot 0.

---

### RTL16. Implement a small loop buffer with capture and playback control.

```verilog
module loop_buffer #(
    parameter DEPTH = 16
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         capture_en,     // loop detected: start recording
    input  logic [31:0]  capture_instr,
    input  logic          capture_valid,
    input  logic          playback_en,    // subsequent iterations: replay
    input  logic [$clog2(DEPTH)-1:0] playback_idx,
    output logic [31:0]   playback_instr,
    output logic           loop_full,
    input  logic           loop_exit      // clears the buffer when loop is done
);
    logic [31:0] buf_mem [0:DEPTH-1];
    logic [$clog2(DEPTH):0] wr_ptr;

    assign loop_full       = (wr_ptr >= DEPTH);
    assign playback_instr  = buf_mem[playback_idx];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || loop_exit) begin
            wr_ptr <= '0;
        end else if (capture_en && capture_valid && !loop_full) begin
            buf_mem[wr_ptr] <= capture_instr;
            wr_ptr          <= wr_ptr + 1'b1;
        end
    end
endmodule
```
**Explanation:** During the first pass through a detected loop, instructions are captured into `buf_mem`; on subsequent iterations, `playback_en` reads directly from the buffer (a small, low-power structure, per Q95-Q97) instead of re-accessing the full I-cache, and `loop_exit` resets capture state once the loop finishes.

---

### RTL17. Implement loop-detection logic driving the loop buffer's capture/playback decision.

```verilog
module loop_detect (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         branch_taken,
    input  logic [31:0]  branch_pc,
    input  logic [31:0]  branch_target,
    output logic          loop_capture_en,
    output logic          loop_playback_en
);
    logic [31:0] last_branch_pc, last_branch_target;
    logic [1:0]  repeat_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            repeat_count <= 2'd0;
        end else if (branch_taken) begin
            if ((branch_pc == last_branch_pc) && (branch_target == last_branch_target)) begin
                if (repeat_count < 2'd3)
                    repeat_count <= repeat_count + 1'b1;
            end else begin
                repeat_count <= 2'd1;
            end
            last_branch_pc     <= branch_pc;
            last_branch_target <= branch_target;
        end
    end

    // First repeat: start capturing. Second+ repeat: confident enough to play back.
    assign loop_capture_en  = (repeat_count == 2'd1);
    assign loop_playback_en = (repeat_count >= 2'd2);
endmodule
```
**Explanation:** This implements the Q97 detection heuristic — the same backward-taken-branch PC/target pair repeating is used as the loop-recognition signal, with capture starting on the first observed repeat and playback beginning only once confidence is higher (a second repeat), balancing quick activation against avoiding false-positive captures of code that merely happened to branch the same way once.

---

### RTL18. Implement an early Decode-stage branch redirect combined with an exception-priority override.

```verilog
module redirect_arbiter_full (
    input  logic         exception_pending,
    input  logic [31:0]  exception_vector,
    input  logic          decode_branch_resolved,
    input  logic          decode_branch_taken,
    input  logic [31:0]   decode_branch_target,
    input  logic           decode_predicted_taken,
    output logic           flush_if_stage,
    output logic [31:0]    redirect_pc,
    output logic            redirect_valid
);
    // A branch resolved in Decode only needs to redirect if its outcome
    // differs from what fetch already speculatively assumed.
    wire branch_mispredicted = decode_branch_resolved &&
                                (decode_branch_taken != decode_predicted_taken);

    always_comb begin
        if (exception_pending) begin
            redirect_valid = 1'b1;
            redirect_pc     = exception_vector;
            flush_if_stage  = 1'b1;
        end else if (branch_mispredicted) begin
            redirect_valid = 1'b1;
            redirect_pc     = decode_branch_target;
            flush_if_stage  = 1'b1;
        end else begin
            redirect_valid = 1'b0;
            redirect_pc     = 32'b0;
            flush_if_stage  = 1'b0;
        end
    end
endmodule
```
**Explanation:** Note the mispredict check compares the *actual* Decode-stage outcome against what fetch *already predicted* (Q42) — a Decode-resolved branch that happens to match fetch's prediction needs no redirect at all, only an *actual* mismatch triggers the flush, avoiding unnecessary pipeline disruption for correctly-predicted branches.

---

### RTL19. Implement a fetch-stage exception tag generator (access fault + misaligned check).

```verilog
module fetch_exception_tag (
    input  logic [31:0] fetch_addr,
    input  logic         mpu_access_fault,
    input  logic         supports_rvc,      // implementation parameter/config
    output logic          exc_valid,
    output logic [3:0]    exc_cause         // RISC-V-style mcause encoding subset
);
    localparam CAUSE_MISALIGNED_FETCH = 4'd0;
    localparam CAUSE_ACCESS_FAULT      = 4'd1;

    wire misaligned = !supports_rvc && (fetch_addr[1:0] != 2'b00);

    always_comb begin
        if (misaligned) begin
            exc_valid = 1'b1;
            exc_cause = CAUSE_MISALIGNED_FETCH;
        end else if (mpu_access_fault) begin
            exc_valid = 1'b1;
            exc_cause = CAUSE_ACCESS_FAULT;
        end else begin
            exc_valid = 1'b0;
            exc_cause = 4'b0;
        end
    end
endmodule
```
**Explanation:** The misalignment check (Q88) is conditioned on `supports_rvc` — an implementation with the C extension enabled only requires 2-byte alignment (any address with `fetch_addr[0] == 0` is legal), while a non-C implementation requires full 4-byte alignment, exactly the distinction discussed in Q32-Q33.

---

### RTL20. Implement placeholder-instruction substitution for a faulting fetch (Q90).

```verilog
module fetch_fault_substitute (
    input  logic         exc_valid,
    input  logic [31:0]  raw_instr,
    output logic [31:0]  instr_out
);
    // On a fetch fault, never let the raw (possibly meaningless/unavailable)
    // bits reach Decode -- substitute a defined NOP; the real fault info
    // travels separately via the exc_valid/exc_cause tag (RTL19).
    assign instr_out = exc_valid ? 32'h0000_0013 : raw_instr; // NOP
endmodule
```
**Explanation:** This is a small but important piece of the precise-exception discipline (Q89-Q90): even though the *real* information about the fault rides along as a separate tag, the instruction-bits field itself is still given a safe, defined value so no downstream logic accidentally tries to decode and act on garbage.

---

### RTL21. Implement a fetch-directed next-line prefetch request generator.

```verilog
module fetch_next_line_prefetch #(
    parameter LINE_BYTES = 32
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [31:0]  fetch_addr,
    input  logic          icache_hit,
    output logic           prefetch_req,
    output logic [31:0]    prefetch_addr
);
    logic [31:0] last_prefetched_line;

    wire [31:0] current_line = {fetch_addr[31:$clog2(LINE_BYTES)], {$clog2(LINE_BYTES){1'b0}}};
    wire [31:0] next_line    = current_line + LINE_BYTES;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_prefetched_line <= 32'hFFFF_FFFF;
            prefetch_req         <= 1'b0;
        end else if (icache_hit && (next_line != last_prefetched_line)) begin
            prefetch_req         <= 1'b1;
            prefetch_addr         <= next_line;
            last_prefetched_line <= next_line;
        end else begin
            prefetch_req <= 1'b0;
        end
    end
endmodule
```
**Explanation:** This implements the simplest form of next-line prefetching (Q21) — on every I-cache hit, speculatively request the *next* sequential line, tracking `last_prefetched_line` to avoid redundant repeat requests for a line already prefetched; a real design would also need to arbitrate this request against demand fetches (RTL22) and guard against the pollution risk from Q22.

---

### RTL22. Implement demand-fetch-priority arbitration between a real fetch request and a prefetch request.

```verilog
module fetch_prefetch_arbiter (
    input  logic         demand_req_valid,
    input  logic [31:0]  demand_req_addr,
    input  logic          prefetch_req_valid,
    input  logic [31:0]   prefetch_req_addr,
    output logic           mem_req_valid,
    output logic [31:0]    mem_req_addr,
    output logic            is_prefetch
);
    // Demand (actual instructions the pipeline needs right now) always
    // wins over a purely speculative prefetch request.
    always_comb begin
        if (demand_req_valid) begin
            mem_req_valid = 1'b1;
            mem_req_addr   = demand_req_addr;
            is_prefetch    = 1'b0;
        end else if (prefetch_req_valid) begin
            mem_req_valid = 1'b1;
            mem_req_addr   = prefetch_req_addr;
            is_prefetch    = 1'b1;
        end else begin
            mem_req_valid = 1'b0;
            mem_req_addr   = 32'b0;
            is_prefetch    = 1'b0;
        end
    end
endmodule
```
**Explanation:** Real, needed instructions must never be delayed behind a speculative prefetch (Q22's pollution/waste risk is bad enough without also directly hurting demand-fetch latency) — this simple fixed-priority arbiter guarantees a pending demand request is always serviced first.

---

### RTL23. Implement a trace-cache-style multi-block index lookup (simplified single-branch trace).

```verilog
module simple_trace_cache #(
    parameter ENTRIES = 32,
    parameter TRACE_LEN = 4
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic [31:0]   start_pc,
    output logic           hit,
    output logic [31:0]    trace_instrs [0:TRACE_LEN-1],
    output logic [31:0]    trace_next_pc,
    input  logic           fill_en,
    input  logic [31:0]    fill_start_pc,
    input  logic [31:0]    fill_instrs [0:TRACE_LEN-1],
    input  logic [31:0]    fill_next_pc
);
    localparam IDX_BITS = $clog2(ENTRIES);

    logic [31:0] tag_mem  [0:ENTRIES-1];
    logic        valid_mem[0:ENTRIES-1];
    logic [31:0] instrs_mem [0:ENTRIES-1][0:TRACE_LEN-1];
    logic [31:0] next_pc_mem[0:ENTRIES-1];

    wire [IDX_BITS-1:0] idx_lookup = start_pc[IDX_BITS+1:2];
    wire [IDX_BITS-1:0] idx_fill   = fill_start_pc[IDX_BITS+1:2];

    assign hit           = valid_mem[idx_lookup] && (tag_mem[idx_lookup] == start_pc);
    assign trace_instrs   = instrs_mem[idx_lookup];
    assign trace_next_pc  = next_pc_mem[idx_lookup];

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < ENTRIES; i = i + 1) valid_mem[i] <= 1'b0;
        end else if (fill_en) begin
            tag_mem[idx_fill]     <= fill_start_pc;
            valid_mem[idx_fill]   <= 1'b1;
            instrs_mem[idx_fill]  <= fill_instrs;
            next_pc_mem[idx_fill] <= fill_next_pc;
        end
    end
endmodule
```
**Explanation:** Unlike a normal I-cache line (contiguous static addresses), each trace-cache entry (Q83-Q84) stores a *dynamic* sequence that may have already "jumped" across one or more taken branches, plus the address to continue from after the trace — a hit delivers a full, non-fragmented multi-instruction packet in one lookup, which is the whole point relative to Q81-Q82's fragmentation problem.

---

### RTL24. Implement wide-fetch predecode boundary detection for RVC across a multi-instruction packet.

```verilog
module wide_predecode #(
    parameter PACKET_INSTRS = 4  // up to 4 x 16-bit half-words = 8 bytes
) (
    input  logic [PACKET_INSTRS*16-1:0] raw_halfwords,
    output logic [PACKET_INSTRS-1:0]     is_instr_start, // marks valid instruction start offsets
    output logic [PACKET_INSTRS-1:0]     is_compressed
);
    integer i;
    logic [PACKET_INSTRS-1:0] consumed;

    always_comb begin
        consumed = '0;
        is_instr_start = '0;
        is_compressed  = '0;

        for (i = 0; i < PACKET_INSTRS; i = i + 1) begin
            if (!consumed[i]) begin
                logic [15:0] hw = raw_halfwords[i*16 +: 16];
                is_instr_start[i] = 1'b1;
                if (hw[1:0] != 2'b11) begin
                    is_compressed[i] = 1'b1;
                    consumed[i]      = 1'b1; // only this half-word consumed
                end else begin
                    is_compressed[i] = 1'b0;
                    if (i+1 < PACKET_INSTRS)
                        consumed[i+1] = 1'b1; // next half-word is the 2nd half of this 32-bit instr
                end
            end
        end
    end
endmodule
```
**Explanation:** This is the "chained boundary detection" problem from Q86 made concrete: each half-word position's status depends on whether it was already "consumed" as the second half of an earlier 32-bit instruction in the same packet, requiring the sequential (but still single-cycle, combinationally-chained) scan shown here rather than independently checking each half-word in isolation.

---

### RTL25. Implement fetch-stage performance counters (stall cycles by cause, redirect count, prediction accuracy).

```verilog
module fetch_perf_counters (
    input  logic         clk,
    input  logic         rst_n,
    input  logic          fetch_stall,
    input  logic [1:0]    stall_cause,     // from RTL12
    input  logic           redirect_valid,  // from RTL8/RTL18
    input  logic           btb_predict_valid,
    input  logic            btb_predict_correct,
    output logic [31:0]     cnt_stall_icache,
    output logic [31:0]     cnt_stall_itlb,
    output logic [31:0]     cnt_stall_buffer,
    output logic [31:0]     cnt_redirects,
    output logic [31:0]     cnt_btb_predictions,
    output logic [31:0]     cnt_btb_correct
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_stall_icache    <= 32'b0;
            cnt_stall_itlb      <= 32'b0;
            cnt_stall_buffer    <= 32'b0;
            cnt_redirects       <= 32'b0;
            cnt_btb_predictions <= 32'b0;
            cnt_btb_correct     <= 32'b0;
        end else begin
            if (fetch_stall) begin
                case (stall_cause)
                    2'd0, 2'd1: cnt_stall_itlb   <= cnt_stall_itlb + (stall_cause == 2'd0);
                    default: ;
                endcase
                if (stall_cause == 2'd1) cnt_stall_icache <= cnt_stall_icache + 1'b1;
                if (stall_cause == 2'd3) cnt_stall_buffer <= cnt_stall_buffer + 1'b1;
            end
            if (redirect_valid)
                cnt_redirects <= cnt_redirects + 1'b1;
            if (btb_predict_valid) begin
                cnt_btb_predictions <= cnt_btb_predictions + 1'b1;
                if (btb_predict_correct)
                    cnt_btb_correct <= cnt_btb_correct + 1'b1;
            end
        end
    end
endmodule
```
**Explanation:** These counters give software (or a debug/bring-up engineer) the visibility described in Q58 and referenced throughout Section F — separately tracking stall cycles by cause (I-cache miss vs. ITLB miss vs. buffer backpressure) and BTB prediction accuracy makes it possible to actually diagnose *which* fetch bottleneck a given workload is hitting, rather than just observing that fetch is "slow."

---
