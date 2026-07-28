# RISC-V Pipeline Design: In-Order Superscalar vs. Out-of-Order

## 1. In-Order Superscalar Pipeline (RISC-V)

**Goal**: issue N instructions/cycle, execute in program order, no speculation beyond simple branch prediction.

### Pipeline stages (example: dual-issue, 8-stage)

```
IF0 | IF1 | IF2 | ID/DE | RN | ISS | EX | WB
```

Note: real designs split fetch into 3-4 stages, not 2 — e.g. BOOM uses F0-F3 and XiangShan uses IF1-IF4, because three separate latencies each want their own pipeline register at high clock frequency:

- **IF0 (PC gen / request)**: drive the fetch PC to the I-cache and BTB.
- **IF1 (cache/BTB access)**: the I-cache and BTB SRAM access itself, often 1-2 cycles by itself at high frequency; branch-predictor index hashing also happens here.
- **IF2 (predecode / realign)**: walk the raw fetched bytes to mark instruction boundaries and expand compressed (RVC) instructions — this can't happen in the same cycle as the cache access that produced the bytes, since it needs the returned data first. This is also typically where results merge with the tail bits of the previous fetch packet (to handle instructions straddling a fetch-group boundary) before enqueuing into the fetch buffer.

Higher-performance cores often add a 4th fetch stage to pipeline the branch predictor itself (e.g. a TAGE-style predictor's index-hash → table-access → tag-compare chain doesn't fit in one cycle), decoupled from fetch via a Fetch Target Queue (FTQ) so prediction latency doesn't stall raw fetch bandwidth.
- **ID/Decode**: Decode N instructions in parallel; expand compressed instructions to 32-bit equivalents.
- **RN (Rename)**: Even in-order machines often still rename to avoid false WAW/WAR hazards across the N-wide slots, or you handle this with strict in-order scoreboard hazard checks instead.
- **ISS (Issue/Dispatch)**: Check structural hazards (enough functional units), check register hazards (scoreboard bits), enforce **in-order issue** — if instruction 0 stalls, instruction 1 also stalls even if its operands are ready (this is the defining trait vs OoO).
- **EX**: Multiple parallel functional units — e.g., 2 ALUs, 1 branch unit, 1 AGU (load/store address gen), 1 mul/div.
- **WB**: Multi-port register file write-back (N write ports needed).

### Key design challenges specific to superscalar (even in-order)

1. **Instruction fetch alignment** — RVC makes this painful. A fetch group of 8 bytes could contain 4 compressed, 2 regular, or a mix straddling the boundary. Need a "pre-decode" stage that marks instruction boundaries (often done as I-cache line metadata, computed on fill).
2. **Multi-ported register file** — N-wide issue needs 2N read ports + N write ports minimum. This is a real area/power cost; often the main reason designs stay 2-wide.
3. **In-order hazard resolution** — Use a scoreboard: each register has a "busy" bit set when an instruction that writes it is dispatched, cleared at WB. An instruction can issue only if (a) all instructions ahead of it in program order have issued, and (b) its source operands aren't busy.
4. **Structural hazards across lanes** — e.g., if both instructions in a bundle need the same functional unit, one must stall (or duplicate the unit).
5. **Branch handling** — usually a simple BTB + 2-bit saturating counters or gshare; on misprediction, flush the whole pipeline (all N lanes) and refetch.
6. **Memory ordering** — loads/stores still issue in order in the simplest design, so you avoid a lot of the complexity of OoO memory disambiguation, but you lose the ability to hide cache-miss latency.

### RISC-V specific notes

- RV32I/RV64I base ISA is simple to decode (fixed 32-bit, few formats), which helps superscalar decode logic.
- If you support the C extension (compressed), decide whether to expand compressed instructions into internal "macro-ops" early (common approach: BOOM, most commercial cores do this).
- CSR instructions, fences, and atomics (A extension) typically force serialization — treat as single-issue barriers.

## 2. Out-of-Order Pipeline (RISC-V)

**Goal**: issue/execute instructions when operands are ready, regardless of program order; retire in order for precise exceptions.

### Classic Tomasulo-style pipeline (like BOOM — Berkeley Out-of-Order Machine)

```
IF0-IF3 (multi-stage frontend) | ID | RENAME | DISPATCH | ISSUE (out of order) | EX | WB | COMMIT/ROB
```

### Core structures you need to design

1. **Fetch + Branch Predictor**
   - The frontend itself is typically 3-4 pipeline stages (see the in-order section above for why): PC generation, I-cache/BTB access, and predecode/realignment are each hard to fit in one cycle at high frequency.
   - BTB, RAS (return address stack) for `jalr`/function returns, direction predictor (gshare/TAGE) — TAGE in particular is often pipelined across 2-3 of its own sub-stages (index hash → table access → tag compare), decoupled from raw fetch via a Fetch Target Queue (FTQ) so predictor latency doesn't stall fetch bandwidth. XiangShan's frontend, for example, spreads branch prediction across IF2-IF4 (labeled BP1-BP3) for exactly this reason.

2. **Rename stage**
   - Map RISC-V architectural registers (x0–x31, f0–f31) to a larger physical register file (PRF) using a Register Alias Table (RAT).
   - x0 is hardwired to zero in RISC-V — special-case it (never rename, never write).
   - Free list tracks available physical registers; on dispatch, allocate a new physical dest register.

3. **Dispatch → ROB + Issue Queues**
   - **Reorder Buffer (ROB)**: holds all in-flight instructions in program order, for precise state and in-order commit.
   - **Issue Queue / Reservation Stations**: per functional-unit-type or unified; instructions wait here until operands ready (via tag broadcast/wakeup) then issue out of order.
   - Wakeup-select logic: when a producer finishes, it broadcasts its physical register tag; waiting consumers snoop and mark operand ready; select logic picks ready instructions for available FUs (age-based priority is common to avoid starvation).

4. **Execute**
   - Multiple FUs: ALU(s), branch unit, load/store unit (AGU + cache access), multiply/divide (often multi-cycle, non-pipelined or partially pipelined for div).
   - Bypass/forwarding network so dependent instructions don't wait for WB.

5. **Load/Store Unit (the hard part)**
   - Load Queue (LQ) and Store Queue (SQ), since RISC-V has a relatively relaxed memory model (RVWMO) but still needs correctness for a single hart's program order illusion.
   - Store-to-load forwarding: check SQ for address match before going to cache.
   - Speculative loads need memory disambiguation — either conservative (loads wait for all prior store addresses to resolve) or speculative with replay/squash on ordering violation.
   - Must respect RISC-V's `fence`, `fence.i`, and atomic (`lr`/`sc`, AMO) semantics — these often serialize the LSU.

6. **Commit / Retire**
   - Strictly in-order from the ROB head. Only commit when instruction is the oldest and has completed without exception.
   - On exception or branch misprediction: flush ROB tail, restore RAT from a checkpoint (or walk back rename mappings), restore free list.
   - This is what gives you **precise exceptions** — critical since RISC-V's privileged spec requires precise traps.

7. **Branch misprediction recovery**
   - Checkpoint the RAT (or use a walkable rename history) at each branch; on misprediction, restore checkpoint, redirect fetch, flush younger instructions from ROB/IQ/LSU.

### Sizing decisions you'll need to make

| Structure | Typical range (small → big core) |
|---|---|
| ROB entries | 32 – 224 |
| Issue queue entries | 8 – 64 per FU type |
| Physical registers | ~64 – 128 (int), similar for FP |
| Fetch/decode/rename/commit width | 2 – 6 wide |
| Load/Store queue entries | 8 – 48 each |

### Good reference to study/model after

- **BOOM (Berkeley Out-of-Order Machine)** — open-source RISC-V OoO core written in Chisel, exactly this design, great for seeing real RTL structure: fetch → decode → rename → dispatch → issue → execute → LSU → ROB/commit.
- **SonicBOOM / SweRV / XiangShan** are other open RISC-V cores at varying complexity if you want more reference points.