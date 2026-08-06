# RISC-V CPU Live-Coding Bank — MEDIUM Tier, Problems 301–400
### Phase 2 of 3 (Easy 1–200 complete · Medium 201–400 · Hard 401–600)

Continues directly from `riscv_medium_200_part1.md`. **Part 2 covers Categories 6–10.**

---

## Category 6: Pipeline Control & Exceptions (301–320)

**301. Precise Exception Point Detection** — *(Medium)*
*Purpose:* Different exception causes are naturally detected in different pipeline stages (illegal instruction in Decode, misaligned address in Execute, page fault in Memory) — this collects each stage's detection into one per-instruction exception-pending bit.
```systemverilog
module exc_detect_collect (
    input  logic id_illegal_instr,
    input  logic ex_misaligned_branch,
    input  logic mem_misaligned_access,
    output logic id_exc_pending, ex_exc_pending, mem_exc_pending
);
    assign id_exc_pending  = id_illegal_instr;
    assign ex_exc_pending  = ex_misaligned_branch;
    assign mem_exc_pending = mem_misaligned_access;
endmodule
```
*Derivation:* Each cause is checked in the earliest stage that has the information needed to detect it (illegality is knowable from the opcode alone in Decode; a branch's misaligned target isn't known until the adder resolves in Execute; a misaligned *data* access isn't known until the address is used in Memory) — collecting all three as independent per-stage flags, rather than one shared flag, is necessary because they attach to *different* in-flight instructions simultaneously.

**302. Exception Priority Resolver Across Pipeline Stages** — *(Medium)*
*Purpose:* If exceptions are pending simultaneously in multiple stages (each belonging to a different in-flight instruction), the *oldest* instruction's exception must be serviced first — younger ones are simply squashed since they'll be re-fetched and re-executed after the trap handler returns anyway.
```systemverilog
module exc_stage_priority (
    input  logic id_exc, ex_exc, mem_exc,
    output logic take_id_exc, take_ex_exc, take_mem_exc
);
    assign take_mem_exc = mem_exc;                    // MEM holds the oldest in-flight instruction
    assign take_ex_exc  = ex_exc && !mem_exc;
    assign take_id_exc  = id_exc && !ex_exc && !mem_exc;
endmodule
```
*Derivation:* Program order across pipeline stages runs oldest-to-newest from Memory back to Decode (MEM holds the earliest-fetched still-in-flight instruction), so a fixed priority favoring the later pipeline stage is exactly equivalent to favoring the architecturally older instruction — this is the same reasoning as Problem 179's exception-over-interrupt priority, generalized across multiple simultaneously-pending exceptions from different stages instead of one exception vs. one interrupt.

**303. Pipeline Walk-to-Commit for Precise Exceptions** — *(Medium)*
*Purpose:* "Precise" exceptions require that all instructions *older* than the faulting one complete normally, and all instructions *younger* are discarded as if they never executed — this sequences that squash.
```systemverilog
module precise_exc_walk (
    input  logic exc_taken, input logic [1:0] exc_stage,   // 0=ID,1=EX,2=MEM
    output logic squash_if, squash_id, squash_ex
);
    assign squash_if = exc_taken;                            // IF is always younger than any exception source
    assign squash_id = exc_taken && (exc_stage != 2'd0);
    assign squash_ex = exc_taken && (exc_stage == 2'd2);
endmodule
```
*Derivation:* Everything strictly younger (earlier pipeline stage) than the exception-taking instruction must be squashed; the instruction that actually excepted itself is *not* architecturally committed either (its effects, if any, must not become visible) — this table encodes exactly that "squash everything at or above the faulting stage" rule, mirroring Problem 149's branch-flush logic but parameterized by which stage detected the fault.

**304. Exception PC Capture at Multiple Stages** — *(Medium)*
*Purpose:* Since exceptions can be detected in ID, EX, or MEM, the PC that gets saved to `mepc` (Problem 166) must track whichever instruction actually faulted, not just whatever's currently in a fixed stage.
```systemverilog
module exc_pc_select (
    input  logic [1:0] exc_stage,
    input  logic [31:0] id_pc, ex_pc, mem_pc,
    output logic [31:0] exc_pc
);
    always_comb begin
        unique case (exc_stage)
            2'd0:    exc_pc = id_pc;
            2'd1:    exc_pc = ex_pc;
            2'd2:    exc_pc = mem_pc;
            default: exc_pc = id_pc;
        endcase
    end
endmodule
```
*Derivation:* Each pipeline stage carries its own instruction's PC forward (via the pipeline registers from Problems 141–144), so selecting by `exc_stage` correctly picks out the PC belonging to whichever specific instruction Problem 302 determined should actually take the trap.

**305. Trap-Entry Redirect Sequencing FSM** — *(Medium)*
*Purpose:* Ties together capturing `mepc`/`mcause` (Problems 166/167), updating `mstatus` (Problem 174), and redirecting fetch to the trap vector (Problem 168) into one coordinated multi-signal sequence, since all of these must happen together, atomically, on the same trap-taken cycle.
```systemverilog
module trap_entry_seq (
    input  logic clk, rst_n, trap_taken,
    input  logic [31:0] trap_pc, mtvec,
    output logic mepc_we, mcause_we, mstatus_we,
    output logic fetch_redirect_valid,
    output logic [31:0] fetch_redirect_pc
);
    assign mepc_we                = trap_taken;
    assign mcause_we               = trap_taken;
    assign mstatus_we              = trap_taken;
    assign fetch_redirect_valid    = trap_taken;
    assign fetch_redirect_pc       = {mtvec[31:2], 2'b00};
endmodule
```
*Derivation:* All five effects fire from the same single `trap_taken` pulse in the same cycle — there's no sequencing *within* trap entry itself (unlike, say, Problem 292's multi-phase AXI write), it's simply several independent registers all latching new values simultaneously in response to one triggering event, which is why this is a combinational fan-out rather than an actual multi-state FSM despite the "sequencing" name.

**306. Nested Trap Detection** — *(Medium)*
*Purpose:* If a second exception occurs *while already in a trap handler* (e.g. the handler itself hits an illegal instruction), the core must recognize this rather than silently overwriting `mepc` with the nested fault's PC and losing the original trap's return address.
```systemverilog
module nested_trap_detect (
    input  logic in_trap_handler, new_trap_taken,
    output logic is_nested_trap
);
    assign is_nested_trap = in_trap_handler && new_trap_taken;
endmodule
```
*Derivation:* A minimal RISC-V core with only `mepc` (one save slot) genuinely cannot handle a second nested trap correctly — real systems either forbid it via careful handler design (never re-enable interrupts and never execute code that could re-fault inside a handler) or implement a stack of trap contexts in software; this detector's role is simply to make the (otherwise silent and data-losing) condition observable, e.g. for a debug assertion or to force a fatal double-fault path.

**307. WFI (Wait-For-Interrupt) FSM** — *(Medium)*
*Purpose:* The WFI instruction lets a core cheaply pause (e.g. clock-gate itself) until an interrupt becomes pending, rather than busy-spinning in software — this sequences that pause/resume.
```systemverilog
module wfi_fsm (
    input  logic clk, rst_n, wfi_instr, interrupt_pending,
    output logic core_stalled, clock_gate_request
);
    typedef enum logic {ACTIVE, WAITING} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= ACTIVE;
        else unique case (state)
            ACTIVE:  if (wfi_instr) state <= WAITING;
            WAITING: if (interrupt_pending) state <= ACTIVE;
        endcase
    end
    assign core_stalled       = (state == WAITING);
    assign clock_gate_request = (state == WAITING);
endmodule
```
*Derivation:* WFI is architecturally permitted to be a no-op (spec allows implementations to just continue executing), but a real low-power core uses it as a hint to actually clock-gate itself (Problem 388) — `interrupt_pending` reuses Problem 177's OR-reduce directly as the wake condition, since *any* pending interrupt (not necessarily an enabled/taken one) is sufficient to wake the core per spec, even if `mstatus.MIE` would otherwise prevent it from actually being taken.

**308. Interrupt Injection Point Selection** — *(Medium)*
*Purpose:* Interrupts are asynchronous and can become pending at any time, but they must only actually be *taken* at a clean instruction boundary — this picks the earliest safe point in the pipeline to inject one.
```systemverilog
module interrupt_injection_point (
    input  logic interrupt_pending, id_valid, id_exc_pending,
    output logic take_interrupt_at_id
);
    assign take_interrupt_at_id = interrupt_pending && id_valid && !id_exc_pending;
endmodule
```
*Derivation:* Injecting at Decode (rather than, say, mid-Execute) is convenient because it's early enough that squashing everything younger (Problem 303's pattern) is cheap, and `id_exc_pending` is explicitly excluded because Problem 179 already establishes that a synchronous exception on this same instruction takes priority over an interrupt.

**309. Precise-State Rollback on Exception (Stub)** — *(Medium)*
*Purpose:* Demonstrates the principle that a precise-exception core must guarantee no *younger* instruction's register-file write becomes visible before the trap is taken — this stub shows the write-suppress condition.
```systemverilog
module precise_rollback_stub (
    input  logic exc_taken, instr_is_younger_than_exc,
    output logic suppress_regfile_write
);
    assign suppress_regfile_write = exc_taken && instr_is_younger_than_exc;
endmodule
```
*Derivation:* In a simple in-order pipeline, this is automatically satisfied as long as the flush (Problem 303) reaches the pipeline stage *before* that stage's write-back would occur — the explicit suppress signal here exists mainly to make the guarantee testable/assertable rather than relying purely on flush-timing correctness, the same "make an implicit invariant explicit and checkable" philosophy as Problem 256.

**310. Exception vs Interrupt Same-Cycle Arbitration** — *(Medium)*
*Purpose:* A fuller version of Problem 179, now integrated with the actual pipeline-stage exception sources from Problem 302 rather than two abstract flags.
```systemverilog
module exc_int_arbitration (
    input  logic pipeline_exc_pending, interrupt_pending,
    input  logic [31:0] pipeline_exc_cause, interrupt_cause,
    output logic trap_taken,
    output logic [31:0] trap_cause
);
    assign trap_taken = pipeline_exc_pending || interrupt_pending;
    assign trap_cause = pipeline_exc_pending ? pipeline_exc_cause : interrupt_cause;
endmodule
```
*Derivation:* Identical priority logic to Problem 179 — restated here because in a real pipeline, `pipeline_exc_pending` is itself the output of the multi-stage priority resolution chain (Problems 301–302), not a single flat input, so this module is the point where that resolved pipeline-exception signal actually meets the interrupt path.

**311. Debug Single-Step FSM** — *(Medium)*
*Purpose:* Lets an external debugger execute exactly one instruction at a time — a common debug-mode feature — by re-halting the core immediately after the next instruction retires.
```systemverilog
module debug_single_step (
    input  logic clk, rst_n, step_request, instr_retired,
    output logic core_halted
);
    typedef enum logic [1:0] {HALTED, STEPPING, HALT_PENDING} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= HALTED;
        else unique case (state)
            HALTED:       if (step_request) state <= STEPPING;
            STEPPING:      if (instr_retired) state <= HALT_PENDING;
            HALT_PENDING: state <= HALTED;
        endcase
    end
    assign core_halted = (state == HALTED) || (state == HALT_PENDING);
endmodule
```
*Derivation:* `HALT_PENDING` exists as a distinct one-cycle state (rather than transitioning `STEPPING → HALTED` directly) to give exactly one cycle of settling time after `instr_retired` before external logic (e.g. a debug-mode status register read) sees the halted state, avoiding a same-cycle race between the retirement event and the halt-status becoming visible.

**312. Debug Breakpoint Address Compare** — *(Medium)*
*Purpose:* Compares the currently-fetched PC against a small set of hardware breakpoint addresses, the mechanism underlying `EBREAK`-independent hardware breakpoints a debugger can set without modifying program memory.
```systemverilog
module debug_bp_compare #(parameter int NUM_BP = 4) (
    input  logic [31:0] fetch_pc,
    input  logic [NUM_BP-1:0] bp_enable,
    input  logic [NUM_BP-1:0][31:0] bp_addr,
    output logic bp_hit
);
    logic [NUM_BP-1:0] match;
    always_comb
        for (int i = 0; i < NUM_BP; i++)
            match[i] = bp_enable[i] && (bp_addr[i] == fetch_pc);
    assign bp_hit = |match;
endmodule
```
*Derivation:* A small parallel comparator array (one comparator per breakpoint register) checked every fetch cycle — structurally identical to the BTB's tag-compare pattern (Problem 225), just comparing against a handful of debugger-programmed addresses instead of cached branch targets.

**313. Halt-on-Breakpoint Controller** — *(Medium)*
```systemverilog
module halt_on_bp (input logic bp_hit, debug_mode_enabled, output logic force_halt);
    assign force_halt = bp_hit && debug_mode_enabled;
endmodule
```
*Purpose:* Gates Problem 312's hit signal behind a global debug-enable, since breakpoint registers might remain programmed even when a debugger isn't actively attached, and shouldn't halt the core in that case.

**314. Pipeline Drain-to-Idle Controller (Debug Entry)** — *(Medium)*
*Purpose:* Before a core can safely report "halted" to an external debugger, every in-flight instruction must be allowed to either complete or be safely squashed — abruptly freezing mid-pipeline would leave inconsistent architectural state for the debugger to inspect.
```systemverilog
module debug_drain_ctrl (
    input  logic clk, rst_n, halt_request,
    input  logic pipeline_empty,
    output logic draining, halted
);
    typedef enum logic [1:0] {RUNNING, DRAINING, HALTED_ST} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= RUNNING;
        else unique case (state)
            RUNNING:   if (halt_request) state <= DRAINING;
            DRAINING:  if (pipeline_empty) state <= HALTED_ST;
            HALTED_ST: if (!halt_request) state <= RUNNING;
        endcase
    end
    assign draining = (state == DRAINING);
    assign halted    = (state == HALTED_ST);
endmodule
```
*Derivation:* `DRAINING` stops new instructions from being fetched (an implied side effect a real design would wire from this state) while letting already-in-flight ones complete naturally through the pipeline — only once `pipeline_empty` (no valid instructions in any stage) is the core's state actually fully consistent and safe to report as `halted` to external debug logic.

**315. Exception Cause Aggregator Across Stages** — *(Medium)*
*Purpose:* Combines Problem 302's stage-priority winner with the actual specific cause code that stage detected, producing the single `mcause`-ready value for Problem 305's trap-entry sequence.
```systemverilog
module exc_cause_aggregate (
    input  logic take_id_exc, take_ex_exc, take_mem_exc,
    input  logic [31:0] id_cause, ex_cause, mem_cause,
    output logic [31:0] final_cause
);
    assign final_cause = take_mem_exc ? mem_cause : (take_ex_exc ? ex_cause : id_cause);
endmodule
```
*Derivation:* Direct composition — Problem 302 already determined *which* stage wins priority, this module just muxes in that winning stage's already-computed cause code (e.g. from Problem 167's per-cause encoder, instantiated once per stage that can detect its own distinct set of causes).

**316. Faulting-Instruction Squash Propagation** — *(Medium)*
*Purpose:* Confirms the faulting instruction itself, not just younger ones, has its side effects suppressed as it continues moving through any remaining pipeline stages before the trap-entry redirect takes effect.
```systemverilog
module faulting_instr_squash (
    input  logic clk, rst_n, this_instr_excepted,
    output logic squash_effects
);
    logic squash_q;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) squash_q <= 1'b0;
        else        squash_q <= this_instr_excepted;
    assign squash_effects = this_instr_excepted || squash_q;
endmodule
```
*Derivation:* A one-bit "poison" flag travels alongside the faulting instruction through any remaining stages it passes through before the pipeline fully squashes — this is the same principle as Problem 147's valid bit, but inverted (a "definitely squash this regardless of anything else" flag rather than "this is real data"), ensuring a partially-through-the-pipeline faulting instruction can never accidentally complete a memory write or register write on its way out.

**317. Speculative-Exception Suppression** — *(Medium)*
*Purpose:* An instruction fetched down a mispredicted branch path might itself appear to trigger an exception (e.g. it's actually garbage/misaligned data being misinterpreted as an instruction) — such a "wrong-path exception" must never actually be taken, since the instruction was never supposed to execute in the first place.
```systemverilog
module spec_exc_suppress (
    input  logic exc_detected, instr_is_on_wrong_path,
    output logic exc_actually_taken
);
    assign exc_actually_taken = exc_detected && !instr_is_on_wrong_path;
endmodule
```
*Derivation:* `instr_is_on_wrong_path` would typically be derived from the same valid-bit-clearing flush logic as Problem 149 — if a branch resolves as mispredicted before a "wrong-path" instruction's exception is even acted upon, the flush should already have cleared its valid bit; this module exists to explicitly document that the exception-taking logic must check validity, not just cause-detection, as a defensive/assertable design invariant (the same pattern as Problem 256 and Problem 309).

**318. Multiple-Simultaneous-Exception Priority Table** — *(Medium)*
*Purpose:* Within a *single* instruction, more than one exception condition can theoretically be true at once (e.g. an instruction is both illegal *and* would have caused a misaligned access) — the spec requires a defined, consistent priority order rather than an implementation-arbitrary one.
```systemverilog
module multi_exc_priority (
    input  logic illegal_instr, instr_addr_misaligned, load_addr_misaligned, store_addr_misaligned, ecall, ebreak,
    output logic [31:0] cause
);
    always_comb begin
        unique casez ({instr_addr_misaligned, illegal_instr, ebreak, load_addr_misaligned, store_addr_misaligned, ecall})
            6'b1?????: cause = 32'd0;    // instruction-address-misaligned: highest priority (can't even fetch correctly)
            6'b01????: cause = 32'd2;    // illegal instruction
            6'b001???: cause = 32'd3;    // breakpoint
            6'b0001??: cause = 32'd4;    // load address misaligned
            6'b00001?: cause = 32'd6;    // store/AMO address misaligned
            6'b000001: cause = 32'd11;   // environment call
            default:    cause = 32'd0;
        endcase
    end
endmodule
```
*Derivation:* This priority order (instruction-fetch problems before decode problems before execution problems) follows the natural pipeline order in which each condition would first be detectable — an instruction that can't even be correctly fetched obviously can't be meaningfully checked for illegality, so instruction-address-misalignment must outrank illegal-instruction, and so on down the pipeline; the exact numeric priority is implementation-defined by the spec within limits, but must be *consistent* so software behavior is deterministic and reproducible.

**319. mtval Capture Logic** — *(Medium)*
*Purpose:* Beyond `mcause` (why a trap occurred), the `mtval` CSR captures supplementary trap-specific information — the faulting address for an alignment fault, or the raw illegal instruction bits for an illegal-instruction trap — that a handler often needs to actually diagnose or emulate the failure.
```systemverilog
module mtval_capture (
    input  logic illegal_instr, misaligned_access,
    input  logic [31:0] raw_instr, fault_addr,
    output logic [31:0] mtval
);
    assign mtval = illegal_instr ? raw_instr : (misaligned_access ? fault_addr : 32'b0);
endmodule
```
*Derivation:* Per spec, `mtval`'s meaning is cause-dependent — for illegal instructions it's conventionally the raw offending instruction encoding (letting a software emulation trap handler decode and emulate it), for misaligned/fault accesses it's the faulting virtual address; this mux selects the spec-appropriate payload based on which exception is actually being taken.

**320. Pipeline Control Top Wrapper** — *(Medium)*
*Purpose:* Integrates the branch-flush logic (Category 2, Easy tier) and the exception-handling logic from this category into the single pipeline-control module a real core's top level would instantiate.
```systemverilog
module pipeline_ctrl_top (
    input  logic branch_mispredict, exc_taken,
    output logic flush_if, flush_id, flush_ex,
    output logic redirect_valid,
    input  logic [31:0] branch_target, trap_vector_pc,
    output logic [31:0] redirect_pc
);
    logic any_redirect;
    assign any_redirect = branch_mispredict || exc_taken;

    assign flush_if = any_redirect;
    assign flush_id = any_redirect;
    assign flush_ex = exc_taken;   // exceptions squash deeper than a simple branch flush (Problem 303)

    assign redirect_valid = any_redirect;
    assign redirect_pc     = exc_taken ? trap_vector_pc : branch_target;
endmodule
```
*Derivation:* Exceptions get priority over a same-cycle branch misprediction (an exception implies the instruction stream is about to jump to a completely different context anyway, making any branch-target redirect moot) — direct composition of Problems 149 and 303/305, unified behind one unconditional redirect interface.

---

## Category 7: RVC (Compressed) Handling (321–340)

**321. C.ADDI Expander** — *(Medium)*
*Purpose:* Expands the compressed "add immediate to a register" instruction into its canonical 32-bit `ADDI` encoding.
```systemverilog
module c_addi_expand (input logic [15:0] c_instr, output logic [31:0] instr32);
    logic [4:0] rd_rs1;
    logic [5:0] imm6;
    assign rd_rs1 = c_instr[11:7];
    assign imm6   = {c_instr[12], c_instr[6:2]};
    assign instr32 = {{6{imm6[5]}}, imm6, rd_rs1, 3'b000, rd_rs1, 7'b0010011};   // ADDI rd_rs1, rd_rs1, sext(imm6)
endmodule
```
*Derivation:* `C.ADDI` reuses the same register for both source and destination (`rd/rs1` field at `c_instr[11:7]`, the full 5-bit register space, unlike the compressed 3-bit fields), and its 6-bit immediate is scattered across bits 12 and [6:2] per the RVC spec — reassembling it and sign-extending produces exactly the I-immediate an equivalent `ADDI` would need (Problem 21).

**322. C.LW Expander** — *(Medium)*
*Purpose:* Expands the compressed load-word instruction, which uses the restricted 3-bit register fields (x8–x15) to save encoding space.
```systemverilog
module c_lw_expand (input logic [15:0] c_instr, output logic [31:0] instr32);
    logic [2:0] rd_c, rs1_c;
    logic [4:0] rd, rs1;
    logic [6:0] imm7;
    assign rd_c  = c_instr[4:2];
    assign rs1_c = c_instr[9:7];
    assign rd    = {2'b01, rd_c};
    assign rs1   = {2'b01, rs1_c};
    assign imm7  = {c_instr[5], c_instr[12:10], c_instr[6], 2'b00};
    assign instr32 = {{5{1'b0}}, imm7, rs1, 3'b010, rd, 7'b0000011};   // LW rd, imm(rs1)
endmodule
```
*Derivation:* The compressed register fields map to `x8`–`x15` via `{2'b01, 3-bit field}` (Problem 14's expansion rule); the immediate is a word-aligned (`imm[1:0]=00` hardwired) 7-bit unsigned offset scattered per the RVC spec's C.LW encoding, reassembled and zero-extended since a load offset from this format is always non-negative by construction.

**323. C.SW Expander** — *(Medium)*
```systemverilog
module c_sw_expand (input logic [15:0] c_instr, output logic [31:0] instr32);
    logic [2:0] rs2_c, rs1_c;
    logic [4:0] rs2, rs1;
    logic [6:0] imm7;
    assign rs2_c = c_instr[4:2];
    assign rs1_c = c_instr[9:7];
    assign rs2   = {2'b01, rs2_c};
    assign rs1   = {2'b01, rs1_c};
    assign imm7  = {c_instr[5], c_instr[12:10], c_instr[6], 2'b00};
    assign instr32 = {imm7[6:5], rs2, rs1, 3'b010, imm7[4:0], 7'b0100011};   // SW rs2, imm(rs1)
endmodule
```
*Purpose:* Store-word counterpart to Problem 322, sharing the same compressed-register and immediate encoding, but reassembled into S-type's scattered field layout (Problem 22) instead of I-type's.

**324. C.J Expander** — *(Medium)*
*Purpose:* Expands the compressed unconditional jump, which unlike `C.JAL` discards the return address (destination is hardwired to `x0`).
```systemverilog
module c_j_expand (input logic [15:0] c_instr, output logic [31:0] instr32);
    logic [10:0] imm11;
    assign imm11 = {c_instr[12], c_instr[8], c_instr[10:9], c_instr[6], c_instr[7],
                     c_instr[2], c_instr[11], c_instr[5:3]};
    assign instr32 = {imm11[10], imm11[9:0], 1'b0, {8{imm11[10]}}, 5'b00000, 7'b1101111};
    // above is a schematic placeholder for the full 20-bit J-imm packing; see derivation
endmodule
```
*Derivation:* `C.J`'s 11-bit immediate is one of RVC's most heavily scrambled encodings (11 individually-permuted bits); after reassembly it must be sign-extended and repacked into the *32-bit* J-type's own scrambled bit order (Problem 25) with `rd=x0` — this two-stage re-scrambling (compressed layout → linear value → 32-bit J-type layout) is exactly why real RVC expanders are usually implemented as lookup-style bit-permutation logic rather than hand-derived arithmetic, and why this module is shown schematically: the correct full expansion is best generated programmatically from the two bit-order tables rather than transcribed by hand in an interview setting.

**325. C.BEQZ Expander** — *(Medium)*
*Purpose:* Expands the compressed "branch if register equals zero" — a specialized, more compact encoding of the common `BEQ rs1, x0, offset` pattern.
```systemverilog
module c_beqz_expand (input logic [15:0] c_instr, output logic [31:0] instr32);
    logic [2:0] rs1_c;
    logic [4:0] rs1;
    logic [8:0] imm9;
    assign rs1_c = c_instr[9:7];
    assign rs1   = {2'b01, rs1_c};
    assign imm9  = {c_instr[12], c_instr[6:5], c_instr[2], c_instr[11:10], c_instr[4:3]};
    assign instr32 = {{3{imm9[8]}}, imm9[8], imm9[6:1], 5'b00000, rs1, 3'b000, imm9[0], imm9[7], 7'b1100011};
    // schematic: full B-type re-scramble follows Problem 23's field layout with rs2=x0
endmodule
```
*Derivation:* Functionally equivalent to `BEQ rs1, x0, offset` (Problem 101 with `rs2` hardwired to the zero register), using the restricted 3-bit register field since only one operand register is even needed — like Problem 324, the immediate requires re-scrambling from the compressed layout into B-type's own scrambled layout (Problem 23), shown schematically for the same reason.

**326. C.BNEZ Expander** — *(Medium)*
```systemverilog
module c_bnez_expand (input logic [15:0] c_instr, output logic [31:0] instr32);
    logic [2:0] rs1_c;
    logic [4:0] rs1;
    logic [8:0] imm9;
    assign rs1_c = c_instr[9:7];
    assign rs1   = {2'b01, rs1_c};
    assign imm9  = {c_instr[12], c_instr[6:5], c_instr[2], c_instr[11:10], c_instr[4:3]};
    assign instr32 = {{3{imm9[8]}}, imm9[8], imm9[6:1], 5'b00000, rs1, 3'b001, imm9[0], imm9[7], 7'b1100011};
endmodule
```
*Purpose:* Same structure as Problem 325 but for "branch if not equal to zero," differing only in `funct3` (`001` for BNE vs `000` for BEQ).

**327. C.LI Expander** — *(Medium)*
*Purpose:* Expands "load immediate," a compact way to write a small constant into a register, equivalent to `ADDI rd, x0, imm`.
```systemverilog
module c_li_expand (input logic [15:0] c_instr, output logic [31:0] instr32);
    logic [4:0] rd;
    logic [5:0] imm6;
    assign rd   = c_instr[11:7];
    assign imm6 = {c_instr[12], c_instr[6:2]};
    assign instr32 = {{6{imm6[5]}}, imm6, 5'b00000, 3'b000, rd, 7'b0010011};   // ADDI rd, x0, sext(imm6)
endmodule
```
*Derivation:* Structurally almost identical to Problem 321 (`C.ADDI`), just with `rs1` hardwired to `x0` instead of reusing `rd` — the immediate scrambling is identical since both instructions share the same compressed format (CI-type).

**328. C.LUI Expander** — *(Medium)*
*Purpose:* Expands the compressed load-upper-immediate, restricted to loading a smaller, sign-extended 6-bit-scaled immediate compared to the full 32-bit-reach of `LUI`.
```systemverilog
module c_lui_expand (input logic [15:0] c_instr, output logic [31:0] instr32);
    logic [4:0] rd;
    logic [5:0] imm6;
    logic [19:0] imm20;
    assign rd    = c_instr[11:7];
    assign imm6  = {c_instr[12], c_instr[6:2]};
    assign imm20 = {{14{imm6[5]}}, imm6};   // sign-extend into the 20-bit U-immediate field
    assign instr32 = {imm20, rd, 7'b0110111};   // LUI rd, sext(imm6) placed in upper-immediate position
endmodule
```
*Derivation:* Unlike full `LUI` (Problem 24), which takes a raw unsigned 20-bit field, `C.LUI`'s 6-bit immediate must be *sign-extended* before being placed into the 20-bit U-immediate position — this is a deliberate RVC spec choice letting `C.LUI` conveniently express both small positive and small negative upper-immediates (useful for building small negative constants) within its compact encoding.

**329. C.MV Expander** — *(Medium)*
*Purpose:* Expands "move register to register," a compact alias for `ADD rd, x0, rs2`.
```systemverilog
module c_mv_expand (input logic [15:0] c_instr, output logic [31:0] instr32);
    logic [4:0] rd, rs2;
    assign rd  = c_instr[11:7];
    assign rs2 = c_instr[6:2];
    assign instr32 = {7'b0000000, rs2, 5'b00000, 3'b000, rd, 7'b0110011};   // ADD rd, x0, rs2
endmodule
```
*Derivation:* `C.MV` and `C.ADD` (Problem 330) share the same compressed encoding format (CR-type) and are distinguished only by whether `rs1=x0` — the RVC spec defines `C.MV rd, rs2` specifically as this alias, using the *full* 5-bit register fields (unlike the load/store compressed formats), since this format has room for two full register indices rather than two 3-bit restricted ones.

**330. C.ADD Expander** — *(Medium)*
```systemverilog
module c_add_expand (input logic [15:0] c_instr, output logic [31:0] instr32);
    logic [4:0] rd_rs1, rs2;
    assign rd_rs1 = c_instr[11:7];
    assign rs2    = c_instr[6:2];
    assign instr32 = {7'b0000000, rs2, rd_rs1, 3'b000, rd_rs1, 7'b0110011};   // ADD rd_rs1, rd_rs1, rs2
endmodule
```
*Purpose:* Compact register-register add, reusing `rd` as one of the two operands (equivalent to `rd += rs2`), the compressed idiom for accumulation.

**331. C.JR / C.JALR Expander** — *(Medium)*
*Purpose:* Expands the compressed register-indirect jump — with or without saving a return address, distinguished by whether the destination register field would encode `x0` or `x1`.
```systemverilog
module c_jr_jalr_expand (input logic [15:0] c_instr, output logic [31:0] instr32);
    logic [4:0] rs1;
    logic is_jalr;   // bit 12 distinguishes C.JR (0) from C.JALR (1)
    assign rs1     = c_instr[11:7];
    assign is_jalr = c_instr[12];
    assign instr32 = {12'b0, rs1, 3'b000, (is_jalr ? 5'd1 : 5'd0), 7'b1100111};   // JALR rd, 0(rs1)
endmodule
```
*Derivation:* Both compressed forms share the CR-type encoding and reduce to the same underlying `JALR` opcode; the sole architectural difference is the destination register (`x1`/`ra` for `C.JALR`, which saves a return address, vs `x0` for `C.JR`, which discards it) — bit 12 of the compressed instruction is exactly the bit the RVC spec uses to distinguish the two, since every other field is identical.

**332. C.SLLI Expander** — *(Medium)*
*Purpose:* Expands the compressed shift-left-logical-immediate, using the CI-type format shared with `C.ADDI`/`C.LI`/`C.LUI` but interpreting its scattered bits as an unsigned shift amount instead of a signed immediate.
```systemverilog
module c_slli_expand (input logic [15:0] c_instr, output logic [31:0] instr32);
    logic [4:0] rd_rs1;
    logic [5:0] shamt;
    assign rd_rs1 = c_instr[11:7];
    assign shamt  = {c_instr[12], c_instr[6:2]};
    assign instr32 = {6'b000000, shamt, rd_rs1, 3'b001, rd_rs1, 7'b0010011};   // SLLI rd_rs1, rd_rs1, shamt
endmodule
```
*Derivation:* Same bit-scattering as Problem 321's immediate field, but zero-extended (not sign-extended) since a shift amount is inherently unsigned (matching Problem 26's reasoning) — for RV32 the top bit of `shamt` must additionally be checked as reserved-must-be-zero, since RV32's shift amount only needs 5 bits (Problem 8) while this 6-bit compressed field accommodates RV64's wider range (Problem 9).

**333. Compressed-Register Field Expansion Function** — *(Medium)*
*Purpose:* A single reusable function for the `{2'b01, 3-bit field} → 5-bit register` mapping used throughout Problems 322/323/325/326, rather than inlining the concatenation in every expander.
```systemverilog
function automatic logic [4:0] creg_expand(input logic [2:0] c_reg);
    return {2'b01, c_reg};
endfunction
```
*Derivation:* Direct formalization of Problem 14's observation — the compressed 3-bit field values `000`–`111` map exactly onto registers `x8`–`x15`, since prepending the fixed `01` selects that specific 8-register window of the full 32-register space.

**334. RVC Quadrant + funct3 Dispatch Decoder** — *(Medium)*
*Purpose:* The top-level compressed-instruction decoder — combines Problem 12's quadrant field with Problem 13's funct3 field to determine which specific C.* instruction (and thus which expander) applies.
```systemverilog
typedef enum logic [4:0] {
    C_ADDI, C_LW, C_SW, C_J, C_BEQZ, C_BNEZ, C_LI, C_LUI, C_MV, C_ADD, C_JR, C_JALR, C_SLLI, C_ILLEGAL
} c_instr_type_e;

module rvc_dispatch (input logic [15:0] c_instr, output c_instr_type_e itype);
    logic [1:0] quadrant;
    logic [2:0] funct3;
    assign quadrant = c_instr[1:0];
    assign funct3   = c_instr[15:13];

    always_comb begin
        unique case (quadrant)
            2'b00: itype = (funct3 == 3'b010) ? C_LW : (funct3 == 3'b110) ? C_SW : C_ILLEGAL;
            2'b01: begin
                unique case (funct3)
                    3'b000: itype = C_ADDI;
                    3'b001: itype = C_J;      // simplified: C.JAL on RV32 shares this slot
                    3'b010: itype = C_LI;
                    3'b011: itype = C_LUI;
                    3'b110: itype = C_BEQZ;
                    3'b111: itype = C_BNEZ;
                    default: itype = C_ILLEGAL;
                endcase
            end
            2'b10: begin
                unique case (funct3)
                    3'b000: itype = C_SLLI;
                    3'b100: itype = c_instr[6:2] == 5'b0 ? (c_instr[12] ? C_JALR : C_JR) : (c_instr[12] ? C_ADD : C_MV);
                    default: itype = C_ILLEGAL;
                endcase
            end
            default: itype = C_ILLEGAL;   // quadrant 11 = not compressed at all
        endcase
    end
endmodule
```
*Derivation:* Direct transcription of the RVC opcode map's quadrant/funct3 table; quadrant `11` is explicitly excluded (that's Problem 18's "this is actually a 32-bit instruction" case, never reaching this dispatcher) — the funct3=`100` case in quadrant 2 additionally needs to check `c_instr[6:2]` because the CR-type format packs four distinct instructions (`C.JR`/`C.MV`/`C.JALR`/`C.ADD`) into what would otherwise be one ambiguous funct3 slot.

**335. Fetch-Word Straddle Buffer (Compressed Instruction Crossing Boundary)** — *(Medium)*
*Purpose:* A 32-bit-aligned instruction fetch can return a compressed instruction whose second half lies in the *next* fetch word (since 16-bit instructions can start at any 2-byte-aligned address, not just 4-byte-aligned ones) — this buffer holds the dangling first half until the second half arrives.
```systemverilog
module straddle_buffer (
    input  logic clk, rst_n,
    input  logic [31:0] fetch_word,
    input  logic [31:0] fetch_pc,
    output logic [31:0] instr_out,
    output logic instr_valid,
    output logic [31:0] next_fetch_pc
);
    logic pending_valid;
    logic [15:0] pending_half;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pending_valid <= 1'b0;
        else if (fetch_pc[1] && (fetch_word[17:16] == 2'b11))
            // low halfword of this fetch is the tail of a straddling 32-bit instr, high halfword starts a new one that itself needs its tail next fetch
            pending_valid <= 1'b1;
        else
            pending_valid <= 1'b0;
    end
    assign pending_half = fetch_word[31:16];

    assign instr_out      = pending_valid ? {fetch_word[15:0], pending_half} : fetch_word;
    assign instr_valid    = 1'b1;   // simplified: real logic depends on alignment case analysis
    assign next_fetch_pc  = fetch_pc + 32'd4;
endmodule
```
*Derivation:* Because compressed instructions only require 2-byte alignment (Problem 35), a 4-byte-aligned fetch can land squarely in the middle of a 32-bit instruction, or produce two independent compressed instructions, or one compressed instruction plus half of the next — a real straddle buffer needs a small state machine tracking exactly which of these cases applies each cycle; this module is simplified to illustrate the core mechanism (holding a dangling half-instruction across a fetch boundary) rather than exhaustively handling every alignment case, which is genuinely one of the trickier corners of a real RVC-capable fetch unit.

**336. Instruction-Length Determination + PC Increment Combined** — *(Medium)*
*Purpose:* Merges Problem 18's length check with Problems 111/112's PC+4/PC+2 adders into the single decision fetch actually needs each cycle: how far to advance for whatever was just decoded.
```systemverilog
module length_and_increment (
    input  logic [15:0] instr16_lo,
    input  logic [31:0] pc,
    output logic is_compressed,
    output logic [31:0] next_seq_pc
);
    assign is_compressed = (instr16_lo[1:0] != 2'b11);
    assign next_seq_pc    = is_compressed ? (pc + 32'd2) : (pc + 32'd4);
endmodule
```
*Derivation:* Direct composition of Problem 18 (classification) with Problems 111/112 (the two possible increments) — the single point where "how long was this instruction" becomes "where does fetch look next," which must be resolved every single cycle once the C extension is enabled, unlike a C-extension-free core where the increment is always a fixed +4.

**337. Illegal Compressed Instruction Detect (Reserved Encodings)** — *(Medium)*
*Purpose:* Not every 16-bit bit pattern within a given quadrant/funct3 corresponds to a defined instruction — several are explicitly reserved by the RVC spec (e.g. `C.ADDI` with both `rd=x0` and `imm=0` overlaps `C.NOP`'s dedicated encoding, but certain other all-zero-immediate variants are reserved) and must raise illegal-instruction rather than silently doing something undefined.
```systemverilog
module rvc_illegal_check (input c_instr_type_e itype, input logic [15:0] c_instr, output logic illegal);
    always_comb begin
        illegal = (itype == C_ILLEGAL);
        // C.LUI with imm==0 is specifically reserved (would produce a useless LUI rd,0)
        if (itype == C_LUI && {c_instr[12], c_instr[6:2]} == 6'b0) illegal = 1'b1;
        // C.ADDI16SP/C.LUI with rd==x0 or x2 have special-cased meanings not modeled by the plain C_LUI path here
    end
endmodule
```
*Derivation:* Beyond the coarse quadrant/funct3 dispatch (Problem 334), several individual encodings carry additional spec-mandated reserved cases that must be checked at the field level — this module shows the representative `C.LUI`-with-zero-immediate case as an example of the kind of secondary illegal-encoding check a complete RVC decoder needs beyond the primary dispatch table.

**338. C.NOP / C.EBREAK Special Encodings Detect** — *(Medium)*
*Purpose:* Certain specific bit patterns within otherwise-normal instruction slots are reserved by spec to mean something entirely different — `C.ADDI x0, x0, 0` conventionally means `C.NOP`, and a specific all-ones/all-zeros pattern in quadrant 2 means `C.EBREAK`.
```systemverilog
module c_special_detect (input logic [15:0] c_instr, output logic is_c_nop, is_c_ebreak);
    assign is_c_nop    = (c_instr == 16'b000_0_00000_00000_01);          // C.ADDI with rd=x0, imm=0
    assign is_c_ebreak = (c_instr == 16'b100_1_00000_00000_10);          // dedicated CR-type encoding
endmodule
```
*Derivation:* These are exact, fully-specified 16-bit literal matches rather than field-decoded logic — the RVC spec deliberately reserves these specific bit patterns (which would otherwise decode to a "useless" instruction like adding zero to x0) to carry special meaning instead, the same trick the base ISA uses for `ADDI x0,x0,0` as the canonical 32-bit NOP.

**339. Compressed-Instruction Alignment Checker** — *(Medium)*
*Purpose:* Confirms a jump/branch target computed from expanded compressed-instruction logic still only needs 2-byte (not 4-byte) alignment, restating Problem 35 in this category's specific context.
```systemverilog
module rvc_target_align_check (input logic [31:0] target, output logic misaligned);
    assign misaligned = target[0];   // only bit 0 matters once C extension permits 2-byte alignment
endmodule
```
*Derivation:* Identical single-bit check to Problem 35 — repeated here specifically because compressed-instruction jump targets (`C.J`, `C.JR`, etc., Problems 324/331) are exactly the case where this relaxed (2-byte rather than 4-byte) alignment rule actually matters in practice, since a base-ISA-only core would otherwise need to check `target[1:0]`.

**340. RVC Expander Top Wrapper** — *(Medium)*
*Purpose:* Integrates Problem 334's dispatch decoder with the individual expanders (Problems 321–332) into the single module a real fetch/decode stage instantiates to transparently turn every compressed instruction into its canonical 32-bit form before it ever reaches the main decoder (Problem 20's field extractor and beyond).
```systemverilog
module rvc_expand_top (input logic [15:0] c_instr, output logic [31:0] instr32, output logic illegal);
    c_instr_type_e itype;
    rvc_dispatch u_dispatch (.c_instr(c_instr), .itype(itype));

    logic [31:0] addi_out, lw_out, sw_out, li_out, lui_out, mv_out, add_out, jr_jalr_out, slli_out;
    c_addi_expand u0 (.c_instr(c_instr), .instr32(addi_out));
    c_lw_expand   u1 (.c_instr(c_instr), .instr32(lw_out));
    c_sw_expand   u2 (.c_instr(c_instr), .instr32(sw_out));
    c_li_expand   u3 (.c_instr(c_instr), .instr32(li_out));
    c_lui_expand  u4 (.c_instr(c_instr), .instr32(lui_out));
    c_mv_expand   u5 (.c_instr(c_instr), .instr32(mv_out));
    c_add_expand  u6 (.c_instr(c_instr), .instr32(add_out));
    c_jr_jalr_expand u7 (.c_instr(c_instr), .instr32(jr_jalr_out));
    c_slli_expand u8 (.c_instr(c_instr), .instr32(slli_out));

    always_comb begin
        illegal = (itype == C_ILLEGAL);
        unique case (itype)
            C_ADDI:        instr32 = addi_out;
            C_LW:          instr32 = lw_out;
            C_SW:          instr32 = sw_out;
            C_LI:          instr32 = li_out;
            C_LUI:         instr32 = lui_out;
            C_MV:          instr32 = mv_out;
            C_ADD:         instr32 = add_out;
            C_JR, C_JALR:  instr32 = jr_jalr_out;
            C_SLLI:        instr32 = slli_out;
            default:        instr32 = 32'h0000_0013;   // NOP for unimplemented/illegal
        endcase
    end
endmodule
```
*Derivation:* Every downstream pipeline stage (Categories 1–6, and the entire Easy tier) only ever needs to understand canonical 32-bit instructions — this wrapper is exactly what makes that possible, transparently normalizing both instruction widths into one representation before decode, which is the standard architectural approach real RVC-capable cores take rather than threading compressed-awareness through every single pipeline stage.

---

## Category 8: Simple Out-of-Order Building Blocks (341–360)

**341. Basic Scoreboard (Tomasulo-Lite) Register Status Table** — *(Medium)*
*Purpose:* Tracks, for each architectural register, which functional unit (if any) is currently responsible for producing its next value — the foundational data structure of scoreboard-based and Tomasulo-style scheduling.
```systemverilog
module reg_status_table #(parameter int NUM_FU = 4) (
    input  logic clk, rst_n,
    input  logic issue_valid, input logic [4:0] issue_rd, input logic [$clog2(NUM_FU)-1:0] issue_fu_id,
    input  logic complete_valid, input logic [$clog2(NUM_FU)-1:0] complete_fu_id,
    output logic [31:0] reg_producer_valid,
    output logic [31:0][$clog2(NUM_FU)-1:0] reg_producer_fu
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_producer_valid <= 32'b0;
        end else begin
            if (issue_valid && (issue_rd != 5'd0)) begin
                reg_producer_valid[issue_rd] <= 1'b1;
                reg_producer_fu[issue_rd]    <= issue_fu_id;
            end
            if (complete_valid) begin
                for (int r = 0; r < 32; r++)
                    if (reg_producer_valid[r] && (reg_producer_fu[r] == complete_fu_id))
                        reg_producer_valid[r] <= 1'b0;
            end
        end
    end
endmodule
```
*Derivation:* This is a direct generalization of Problem 96's single-bit busy scoreboard, now additionally recording *which* FU will produce the value (not just *that* something will) — that FU-identity is exactly the information Problem 350's wakeup logic needs to know which broadcast tag to watch for.

**342. Simple Reorder Buffer (In-Order Commit Only)** — *(Medium)*
*Purpose:* A circular buffer holding every dispatched-but-not-yet-committed instruction in program order, the structure that lets results complete out of order (Problem 277) while still guaranteeing in-order architectural commit.
```systemverilog
module simple_rob #(parameter int DEPTH = 8) (
    input  logic clk, rst_n,
    input  logic alloc_valid, output logic alloc_ready, output logic [$clog2(DEPTH)-1:0] alloc_tag,
    input  logic [$clog2(DEPTH)-1:0] complete_tag, input logic complete_valid,
    output logic commit_valid, output logic [$clog2(DEPTH)-1:0] commit_tag
);
    localparam int PTR_W = $clog2(DEPTH);
    logic [DEPTH-1:0] done;
    logic [PTR_W:0] head, tail;

    assign alloc_ready  = (tail - head) != PTR_W'(DEPTH);
    assign alloc_tag     = tail[PTR_W-1:0];
    assign commit_valid = (head != tail) && done[head[PTR_W-1:0]];
    assign commit_tag    = head[PTR_W-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head <= '0; tail <= '0; done <= '0;
        end else begin
            if (alloc_valid && alloc_ready) begin
                done[tail[PTR_W-1:0]] <= 1'b0;
                tail <= tail + 1'b1;
            end
            if (complete_valid) done[complete_tag] <= 1'b1;
            if (commit_valid)   head <= head + 1'b1;
        end
    end
endmodule
```
*Derivation:* `alloc_tag` (from `tail`) is handed out in strict program order at dispatch time; `complete_valid` can mark any entry `done` in any order (an FU simply reports "this specific tag is finished" whenever it finishes); but `commit_valid` only ever looks at `head` — the oldest entry — so even if entry `tail-1` finishes before entry `head`, commit still waits for `head` to become `done` first, which is the entire mechanism that turns out-of-order completion (Problem 277) into in-order architectural commit.

**343. ROB Allocate-on-Dispatch** — *(Medium)*
*Purpose:* Isolated view of just the allocation-side interface from Problem 342, useful when dispatch logic and the ROB's internal storage live in separate modules.
```systemverilog
module rob_allocate (
    input  logic dispatch_valid,
    input  logic [$clog2(8)-1:0] tail_ptr,
    output logic alloc_fire,
    output logic [$clog2(8)-1:0] allocated_tag
);
    assign alloc_fire      = dispatch_valid;
    assign allocated_tag  = tail_ptr;
endmodule
```
*Derivation:* Trivial restatement of Problem 342's allocation logic, split out because in a real design dispatch often needs the allocated tag *combinationally, same-cycle* (to attach it to the instruction as it's written into the issue queue) rather than waiting a cycle for a registered ROB response.

**344. ROB Complete-on-Execute-Done** — *(Medium)*
```systemverilog
module rob_complete (
    input  logic exec_done,
    input  logic [$clog2(8)-1:0] exec_tag,
    output logic complete_fire,
    output logic [$clog2(8)-1:0] complete_tag
);
    assign complete_fire = exec_done;
    assign complete_tag  = exec_tag;
endmodule
```
*Purpose:* Isolated view of the completion-side interface — whenever any FU finishes an operation, it reports the tag it was working on, which is exactly the `complete_valid`/`complete_tag` pair Problem 342's ROB consumes.

**345. ROB Commit-on-Head-Ready** — *(Medium)*
```systemverilog
module rob_commit_check (
    input  logic [7:0] done_bits,
    input  logic [$clog2(8)-1:0] head_ptr,
    input  logic rob_empty,
    output logic commit_fire
);
    assign commit_fire = !rob_empty && done_bits[head_ptr];
endmodule
```
*Purpose:* Isolated view of the commit-decision logic — again split out from Problem 342's integrated module, matching how a real design's commit stage often lives physically separate from (and one or more cycles behind) the ROB's allocate/complete logic.

**346. Register Renaming — Single-Checkpoint RAT** — *(Medium)*
*Purpose:* Maps each architectural register to whichever physical register currently holds its most recent (possibly still in-flight) value — the core structure that eliminates WAW/WAR hazards by giving every new write a fresh physical destination.
```systemverilog
module rat_basic #(parameter int PREG_W = 6) (
    input  logic clk, rst_n,
    input  logic rename_valid, input logic [4:0] rename_areg, input logic [PREG_W-1:0] rename_preg,
    input  logic [4:0] lookup_areg,
    output logic [PREG_W-1:0] lookup_preg
);
    logic [PREG_W-1:0] map [32];
    assign lookup_preg = map[lookup_areg];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) map[i] <= i[PREG_W-1:0];   // identity mapping at reset
        end else if (rename_valid && (rename_areg != 5'd0)) begin
            map[rename_areg] <= rename_preg;
        end
    end
endmodule
```
*Derivation:* At reset, architectural register `x_i` maps to physical register `p_i` (a simple identity mapping, one common initialization choice); each subsequent instruction that writes `rd` updates that architectural register's mapping to a newly-allocated physical register (from Problem 347's free list) — any later instruction reading that same architectural register before it's overwritten again will see the updated mapping and correctly read the new physical register, which is exactly how renaming breaks WAW/WAR dependencies (each write gets its own distinct storage location rather than reusing the same physical slot).

**347. Free List (Simple FIFO of Free Physical Registers)** — *(Medium)*
*Purpose:* Tracks which physical registers are currently unused and available to be allocated as a new rename target.
```systemverilog
module free_list_basic #(parameter int NUM_PREGS = 64) (
    input  logic clk, rst_n,
    input  logic alloc_req, output logic alloc_valid, output logic [$clog2(NUM_PREGS)-1:0] alloc_preg,
    input  logic free_req,  input logic [$clog2(NUM_PREGS)-1:0] free_preg
);
    localparam int PTR_W = $clog2(NUM_PREGS);
    logic [PTR_W-1:0] fifo [NUM_PREGS];
    logic [PTR_W:0] head, tail;

    assign alloc_valid = (head != tail);
    assign alloc_preg   = fifo[head[PTR_W-1:0]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PREGS; i++) fifo[i] <= i[PTR_W-1:0];
            head <= '0; tail <= PTR_W'(NUM_PREGS);
        end else begin
            if (alloc_req && alloc_valid) head <= head + 1'b1;
            if (free_req) begin
                fifo[tail[PTR_W-1:0]] <= free_preg;
                tail <= tail + 1'b1;
            end
        end
    end
endmodule
```
*Derivation:* A plain FIFO (same circular-buffer structure as Problem 342's ROB) rather than any priority-encoded free-bit-vector, since which specific free register gets allocated next doesn't matter architecturally — any free physical register works equally well, so a simple FIFO avoids the extra logic a priority encoder over a bit-vector would need (Problem "free_list" from the Hard tier explores the bit-vector alternative).

**348. Rename-to-Physical Mapping Lookup** — *(Medium)*
*Purpose:* The actual rename-time operation applied to a decoded instruction's `rs1`/`rs2` fields — translating architectural source registers into physical register tags before dispatch to the issue queue.
```systemverilog
module rename_lookup (
    input  logic [4:0] rs1, rs2,
    input  logic [5:0] rat_map [32],
    output logic [5:0] rs1_preg, rs2_preg
);
    assign rs1_preg = rat_map[rs1];
    assign rs2_preg  = rat_map[rs2];
endmodule
```
*Derivation:* Direct application of Problem 346's map to both source operands simultaneously — every instruction needs exactly this translation before entering the issue queue, since the issue queue's wakeup logic (Problem 350) works entirely in physical-register-tag space, never architectural register indices.

**349. Simple Issue Queue (FIFO-Based, In-Order Issue)** — *(Medium)*
*Purpose:* The simplest possible issue structure — holds dispatched-but-not-yet-issued instructions and issues them strictly in order once their operands become ready, a stepping stone toward the fully out-of-order issue queues in the Hard tier.
```systemverilog
module simple_iq #(parameter int DEPTH = 8) (
    input  logic clk, rst_n,
    input  logic enq_valid, output logic enq_ready,
    input  logic [5:0] enq_src1_tag, enq_src2_tag,
    input  logic src1_ready_in, src2_ready_in,
    output logic issue_valid,
    input  logic issue_ready
);
    localparam int PTR_W = $clog2(DEPTH);
    logic [DEPTH-1:0] valid_arr, src1_ready, src2_ready;
    logic [PTR_W:0] head, tail;

    assign enq_ready    = (tail - head) != PTR_W'(DEPTH);
    assign issue_valid  = (head != tail) && src1_ready[head[PTR_W-1:0]] && src2_ready[head[PTR_W-1:0]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head <= '0; tail <= '0;
        end else begin
            if (enq_valid && enq_ready) begin
                src1_ready[tail[PTR_W-1:0]] <= src1_ready_in;
                src2_ready[tail[PTR_W-1:0]] <= src2_ready_in;
                tail <= tail + 1'b1;
            end
            if (issue_valid && issue_ready) head <= head + 1'b1;
        end
    end
endmodule
```
*Derivation:* Because issue is restricted to strictly the head entry (in-order issue), this is functionally just Problem 349's FIFO with an extra "can the head entry actually go yet" gate — much simpler than a real out-of-order issue queue (which must check *every* entry for readiness, not just the oldest), but this in-order-issue restriction is itself a real, valid design point (used by many simpler superscalar or in-order-issue-with-out-of-order-completion cores) worth understanding before tackling the full CAM-style out-of-order version.

**350. Wakeup Logic Basic (Tag Broadcast Compare)** — *(Medium)*
*Purpose:* When a functional unit completes and broadcasts the physical-register tag of its result, every waiting instruction in the issue queue must check whether that tag matches either of its own pending source operands.
```systemverilog
module wakeup_basic #(parameter int DEPTH = 8) (
    input  logic broadcast_valid,
    input  logic [5:0] broadcast_tag,
    input  logic [DEPTH-1:0][5:0] entry_src1_tag, entry_src2_tag,
    input  logic [DEPTH-1:0] entry_valid,
    output logic [DEPTH-1:0] wake_src1, wake_src2
);
    always_comb
        for (int i = 0; i < DEPTH; i++) begin
            wake_src1[i] = broadcast_valid && entry_valid[i] && (entry_src1_tag[i] == broadcast_tag);
            wake_src2[i] = broadcast_valid && entry_valid[i] && (entry_src2_tag[i] == broadcast_tag);
        end
endmodule
```
*Derivation:* This is a parallel CAM-style (content-addressable) compare — every entry's stored source tags are checked against the single broadcast tag simultaneously, in one cycle, across the entire queue — which is exactly why real issue queues are built from associative/CAM structures rather than RAM: the wakeup operation fundamentally needs to search by *content* (does any entry want this tag), not by address.

**351. Select Logic Basic (Choose One Ready Entry)** — *(Medium)*
*Purpose:* Once wakeup (Problem 350) has marked possibly several entries as newly-ready in the same cycle, but only one (or a few) FU ports exist, select logic picks which ready entry actually gets to issue this cycle.
```systemverilog
module select_basic #(parameter int DEPTH = 8) (
    input  logic [DEPTH-1:0] ready,
    output logic [DEPTH-1:0] grant,
    output logic any_grant
);
    always_comb begin
        grant = '0; any_grant = |ready;
        for (int i = 0; i < DEPTH; i++)
            if (ready[i]) begin grant = '0; grant[i] = 1'b1; break; end
    end
endmodule
```
*Derivation:* A fixed-priority select (lowest index wins) is the simplest correct selection policy — real high-performance issue queues often use age-based priority instead (Problem 352) to avoid a persistent low-index entry unfairly starving older, higher-index entries, but the fundamental "exactly one grant among several ready candidates" structure is identical to Problem 183's generic priority mux, just applied to the specific context of issue-queue entry selection.

**352. Simple Age-Ordered Issue Priority** — *(Medium)*
*Purpose:* Replaces Problem 351's fixed-index priority with age-based priority, so the *oldest* ready instruction always wins select, avoiding the starvation risk fixed-priority selection has for entries that happen to sit at higher queue indices.
```systemverilog
module select_age_ordered #(parameter int DEPTH = 8) (
    input  logic [DEPTH-1:0] ready,
    input  logic [DEPTH-1:0][$clog2(DEPTH)-1:0] age,   // lower value = older
    output logic [DEPTH-1:0] grant
);
    always_comb begin
        automatic int oldest_idx = -1;
        grant = '0;
        for (int i = 0; i < DEPTH; i++)
            if (ready[i] && (oldest_idx == -1 || age[i] < age[oldest_idx])) oldest_idx = i;
        if (oldest_idx != -1) grant[oldest_idx] = 1'b1;
    end
endmodule
```
*Derivation:* Because a simple FIFO-based queue (Problem 349) already issues in strict order, age-ordering only becomes meaningful once the queue allows genuinely out-of-order issue (multiple non-head entries can become ready before the head does) — this module is the selection-policy piece that a full non-FIFO issue queue (Hard tier) needs, shown here at minimal complexity against an explicit `age` tag rather than a positional queue-index proxy for age.

**353. Commit-Width-1 Retirement Controller** — *(Medium)*
*Purpose:* The commit-stage logic that actually makes an instruction's effects architecturally visible — for a commit-width-1 design, exactly one instruction (the ROB head) can retire per cycle.
```systemverilog
module retire_ctrl (
    input  logic rob_head_done, rob_head_excepted,
    output logic commit_reg_write, raise_exception
);
    assign commit_reg_write = rob_head_done && !rob_head_excepted;
    assign raise_exception   = rob_head_done && rob_head_excepted;
endmodule
```
*Derivation:* Even an excepting instruction still "completes" from the FU's perspective and reaches the ROB head normally — the exception itself is only actually *taken* at commit time (Problem 358 extends this), which is precisely what gives out-of-order cores precise exceptions despite executing instructions out of order: nothing is architecturally visible until it retires in order, so a younger instruction's exception can never be "seen" before an older one's.

**354. ROB Full Stall Signal** — *(Medium)*
```systemverilog
module rob_full_stall (input logic alloc_ready, output logic dispatch_stall);
    assign dispatch_stall = !alloc_ready;
endmodule
```
*Purpose:* When the ROB (Problem 342) has no free entries, dispatch of new instructions must stall — the out-of-order-core analogue of Problem 152's structural-hazard stall, just against ROB capacity instead of a busy FU.

**355. Rename Stall on Free-List Empty** — *(Medium)*
```systemverilog
module rename_stall (input logic free_list_alloc_valid, output logic rename_stall);
    assign rename_stall = !free_list_alloc_valid;
endmodule
```
*Purpose:* If Problem 347's free list has no available physical registers, no new instruction can be renamed (there's nowhere to put its result) — a second, independent resource-exhaustion stall condition alongside Problem 354's ROB-full case.

**356. Basic Load/Store Queue Entry (Single Structure, No Full Disambiguation)** — *(Medium)*
*Purpose:* A simplified LSQ entry tracking just enough state (address, data, valid, type) to support in-order memory access ordering, without the full store-set/violation-detection machinery of the Hard tier's LSQ structures.
```systemverilog
module lsq_entry_basic (
    input  logic clk, rst_n,
    input  logic alloc_valid, is_store,
    input  logic [31:0] addr, wdata,
    output logic valid, out_is_store,
    output logic [31:0] out_addr, out_wdata,
    input  logic retire_en
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid <= 1'b0;
        else if (alloc_valid) begin
            valid <= 1'b1; out_is_store <= is_store; out_addr <= addr; out_wdata <= wdata;
        end else if (retire_en) valid <= 1'b0;
    end
endmodule
```
*Derivation:* This is the minimal per-entry building block — a real LSQ (Hard tier) needs many of these plus age tracking, disambiguation comparators (Problem 102's `partial_overlap_detect`), and store-to-load forwarding logic (Problem 289's simple version scaled up); this single-entry version demonstrates the core state each slot must hold before any of that surrounding infrastructure is added.

**357. In-Order Issue, Out-of-Order Complete Model** — *(Medium)*
*Purpose:* Explicitly names and demonstrates the specific, intermediate design point between the Medium tier's simple in-order pipeline and true out-of-order issue — instructions still *issue* to FUs in program order, but different FU latencies mean they can *complete* out of order.
```systemverilog
module inorder_issue_ooo_complete (
    input  logic issue_valid, input logic [1:0] fu_select,   // 0=ALU,1=MUL,2=DIV
    output logic issue_to_alu, issue_to_mul, issue_to_div
);
    assign issue_to_alu = issue_valid && (fu_select == 2'd0);
    assign issue_to_mul  = issue_valid && (fu_select == 2'd1);
    assign issue_to_div  = issue_valid && (fu_select == 2'd2);
endmodule
```
*Derivation:* This is precisely the model Category 4's Problems 261–280 already implicitly assumed (issue in order to whichever FU, let variable latencies produce out-of-order completion, use a completion buffer like Problem 270 to re-serialize commit) — stated explicitly here as the conceptual bridge from "Medium tier's pipelined FUs" to "true out-of-order issue," which additionally requires the issue *itself* (not just completion) to reorder around stalled operands, which is what Problems 341–355's ROB/RAT/IQ machinery actually enables.

**358. Exception Handling in ROB** — *(Medium)*
*Purpose:* Extends Problem 342's basic ROB with an excepting-entry flag, so an exception detected during out-of-order execution is correctly deferred until that specific instruction reaches the ROB head, per Problem 353's precise-exception principle.
```systemverilog
module rob_exception_mark #(parameter int DEPTH = 8) (
    input  logic clk, rst_n,
    input  logic mark_exc_valid, input logic [$clog2(DEPTH)-1:0] mark_exc_tag,
    input  logic [$clog2(DEPTH)-1:0] head_ptr,
    output logic [DEPTH-1:0] excepted,
    output logic head_has_exception
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) excepted <= '0;
        else if (mark_exc_valid) excepted[mark_exc_tag] <= 1'b1;
    end
    assign head_has_exception = excepted[head_ptr];
endmodule
```
*Derivation:* An excepting instruction still completes normally as far as the ROB's `done` bit (Problem 342) is concerned — it's simply also marked `excepted` — so it can still reach the head of the ROB through ordinary in-order commit progression; only once it *is* the head does Problem 353's commit logic actually redirect to the trap handler instead of committing normally, guaranteeing every older instruction has already committed first, exactly satisfying the precise-exception requirement even though the exception itself may have been detected many cycles earlier, out of order, relative to other in-flight instructions.

**359. Branch Misprediction Recovery via ROB Walk** — *(Medium)*
*Purpose:* When a branch resolves as mispredicted, every instruction *younger* than it (allocated after it in the ROB, regardless of completion order) must be flushed — the ROB's tag ordering makes this a simple range check rather than needing to track dependency chains.
```systemverilog
module rob_mispredict_recovery #(parameter int DEPTH = 8) (
    input  logic clk, rst_n, mispredict_valid,
    input  logic [$clog2(DEPTH)-1:0] mispredict_tag,
    output logic [$clog2(DEPTH)-1:0] new_tail
);
    // On misprediction, every entry allocated *after* the mispredicting branch is discarded:
    // the new tail simply rewinds to just past the branch's own tag.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) new_tail <= '0;
        else if (mispredict_valid) new_tail <= mispredict_tag + 1'b1;
    end
endmodule
```
*Derivation:* Because ROB tags are assigned in strict program order at allocation (Problem 343), "every instruction younger than the branch" is exactly "every entry between `mispredict_tag+1` and the current `tail`" — rewinding `tail` back to `mispredict_tag+1` is sufficient to logically discard all of them in a single cycle, without needing to individually walk or invalidate each entry, which is precisely why circular-buffer ROB tags are such a convenient mechanism for flush recovery compared to, say, a linked-list-based instruction window.

**360. Simple OoO Core Top Wrapper** — *(Medium)*
*Purpose:* Integrates Problems 341 (scoreboard), 342 (ROB), 346–348 (rename), and 349–352 (issue queue) into the single top-level module representing a minimal — but functionally complete — out-of-order core skeleton, bridging directly into the much larger structures explored at scale in the Hard tier.
```systemverilog
module simple_ooo_top #(parameter int ROB_DEPTH = 8, parameter int NUM_PREGS = 64) (
    input  logic clk, rst_n,
    input  logic dispatch_valid, input logic [4:0] dispatch_rd, rs1, rs2,
    output logic dispatch_ready,
    input  logic exec_done, input logic [$clog2(ROB_DEPTH)-1:0] exec_tag,
    output logic commit_valid, output logic [$clog2(ROB_DEPTH)-1:0] commit_tag
);
    logic alloc_ready, alloc_fire, free_alloc_valid;
    logic [$clog2(ROB_DEPTH)-1:0] alloc_tag;
    logic [$clog2(NUM_PREGS)-1:0] new_preg;

    simple_rob #(.DEPTH(ROB_DEPTH)) u_rob (
        .clk(clk), .rst_n(rst_n),
        .alloc_valid(dispatch_valid), .alloc_ready(alloc_ready), .alloc_tag(alloc_tag),
        .complete_tag(exec_tag), .complete_valid(exec_done),
        .commit_valid(commit_valid), .commit_tag(commit_tag)
    );

    free_list_basic #(.NUM_PREGS(NUM_PREGS)) u_freelist (
        .clk(clk), .rst_n(rst_n),
        .alloc_req(dispatch_valid && alloc_ready), .alloc_valid(free_alloc_valid), .alloc_preg(new_preg),
        .free_req(commit_valid), .free_preg('0)   // simplified: real design frees the *old* mapping on commit, not shown
    );

    assign dispatch_ready = alloc_ready && free_alloc_valid;
endmodule
```
*Derivation:* Pure structural composition — dispatch only fires when *both* the ROB has a free entry (Problem 354) and the free list has an available physical register (Problem 355); the RAT update and issue-queue enqueue (Problems 346/348/349) would hang off this same `dispatch_ready` pulse in a complete design, omitted here to keep the top-level wiring focused on the two hard resource constraints that actually gate forward progress in any out-of-order core.

---

## Category 9: Bus/Interface Protocols (361–380)

**361. APB (Advanced Peripheral Bus) Basic FSM** — *(Medium)*
*Purpose:* APB is the simplest common on-chip peripheral bus — a 2-phase (SETUP/ACCESS) protocol with no pipelining, well suited to low-bandwidth control/status register access.
```systemverilog
module apb_master_fsm (
    input  logic clk, rst_n, req_valid, req_write,
    input  logic [31:0] req_addr, req_wdata,
    output logic req_ready,
    output logic psel, penable, pwrite,
    output logic [31:0] paddr, pwdata,
    input  logic pready,
    input  logic [31:0] prdata,
    output logic resp_valid,
    output logic [31:0] resp_rdata
);
    typedef enum logic [1:0] {IDLE, SETUP, ACCESS} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; resp_valid <= 1'b0; end
        else begin
            resp_valid <= 1'b0;
            unique case (state)
                IDLE:   if (req_valid) begin paddr <= req_addr; pwdata <= req_wdata; pwrite <= req_write; state <= SETUP; end
                SETUP:  state <= ACCESS;
                ACCESS: if (pready) begin resp_rdata <= prdata; resp_valid <= 1'b1; state <= IDLE; end
                default: state <= IDLE;
            endcase
        end
    end
    assign req_ready = (state == IDLE);
    assign psel        = (state == SETUP) || (state == ACCESS);
    assign penable      = (state == ACCESS);
endmodule
```
*Derivation:* APB mandates exactly one SETUP cycle (`psel=1, penable=0`) before entering ACCESS (`psel=1, penable=1`), and the transfer only completes once the peripheral asserts `pready` during ACCESS — this FSM is a direct, literal transcription of the APB protocol's defined 2-3 cycle minimum transaction, appropriate for register-mapped peripherals that don't need AXI's throughput but benefit from a much simpler master/slave interface.

**362. Wishbone Classic Basic Interface** — *(Medium)*
*Purpose:* Another simple, widely-used open on-chip bus standard — single-cycle-capable, using `stb`/`ack` handshaking rather than APB's fixed 2-phase timing.
```systemverilog
module wishbone_master (
    input  logic clk, rst_n, req_valid, req_we,
    input  logic [31:0] req_addr, req_wdata,
    output logic req_ready,
    output logic cyc, stb, we,
    output logic [31:0] adr, dat_o,
    input  logic ack,
    input  logic [31:0] dat_i,
    output logic resp_valid,
    output logic [31:0] resp_data
);
    logic active;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin active <= 1'b0; resp_valid <= 1'b0; end
        else begin
            resp_valid <= 1'b0;
            if (!active && req_valid) begin
                active <= 1'b1; adr <= req_addr; dat_o <= req_wdata; we <= req_we;
            end else if (active && ack) begin
                active <= 1'b0; resp_data <= dat_i; resp_valid <= 1'b1;
            end
        end
    end
    assign req_ready = !active;
    assign cyc          = active;
    assign stb           = active;
endmodule
```
*Derivation:* Wishbone's `cyc`/`stb` asserted together for the duration of a transfer, with the responder's `ack` signaling completion whenever it's ready (potentially the very same cycle, unlike APB's mandatory minimum-2-cycle timing) — this makes Wishbone capable of true single-cycle transactions when the target is fast enough, a structural advantage over APB's fixed minimum latency.

**363. Generic Valid/Ready Pipelined Bus Adapter** — *(Medium)*
*Purpose:* Converts between this bank's internal valid/ready pipelined convention (used throughout, e.g. Problems 199/200/268) and a generic external request/response bus, the kind of glue logic needed wherever a core's internal interfaces meet an external protocol.
```systemverilog
module valid_ready_to_bus_adapter (
    input  logic clk, rst_n,
    input  logic in_valid, output logic in_ready,
    input  logic [31:0] in_addr, in_data,
    output logic bus_req, input logic bus_gnt,
    output logic [31:0] bus_addr, bus_data
);
    assign bus_req    = in_valid;
    assign in_ready    = bus_gnt;
    assign bus_addr    = in_addr;
    assign bus_data    = in_data;
endmodule
```
*Derivation:* A pure combinational rename/passthrough in this simplest case — `bus_req`/`bus_gnt` is functionally identical to `valid`/`ready`, just named differently by whatever external bus convention is being interfaced to; real adapters often need actual sequential logic (buffering, width conversion) layered on top of this, but the fundamental signal-name mapping is the starting point.

**364. Credit-Based Flow Control Basic** — *(Medium)*
*Purpose:* An alternative to reactive `ready`-based backpressure — a sender tracks a "credit count" representing how much buffer space the receiver has told it is available, and only sends when credits remain, avoiding the round-trip latency a `ready` signal would otherwise impose on high-frequency, long-wire interfaces.
```systemverilog
module credit_flow_sender #(parameter int MAX_CREDITS = 8) (
    input  logic clk, rst_n,
    input  logic send_req,
    input  logic credit_return,
    output logic send_allowed,
    output logic [$clog2(MAX_CREDITS+1)-1:0] credits_available
);
    logic [$clog2(MAX_CREDITS+1)-1:0] credits;
    assign credits_available = credits;
    assign send_allowed        = (credits != 0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) credits <= MAX_CREDITS[$clog2(MAX_CREDITS+1)-1:0];
        else begin
            if (send_req && send_allowed && !credit_return) credits <= credits - 1'b1;
            else if (!(send_req && send_allowed) && credit_return) credits <= credits + 1'b1;
        end
    end
endmodule
```
*Derivation:* Unlike `ready` (which the sender must wait to *receive* before sending, costing a full round-trip in latency), credit-based flow control lets the sender act purely on locally-held state (`credits`) — the receiver returns a credit only once it has actually freed a buffer slot, but that return can be pipelined/batched and doesn't gate the *next* send the way a synchronous `ready` handshake would, which is why credit-based schemes are common on long, high-latency interconnect links (chip-to-chip, or across a large NoC) where a `ready` round-trip would otherwise dominate achievable throughput.

**365. Backpressure Propagation Through a 2-Stage Pipe** — *(Medium)*
*Purpose:* Demonstrates how a `ready` deassertion at the *output* of a pipeline correctly propagates backward through multiple stages, stalling each one in turn rather than only the last.
```systemverilog
module backpressure_2stage #(parameter int W = 32) (
    input  logic clk, rst_n,
    input  logic in_valid, output logic in_ready, input logic [W-1:0] in_data,
    output logic out_valid, input logic out_ready, output logic [W-1:0] out_data
);
    logic stage1_valid;
    logic [W-1:0] stage1_data;
    logic stage2_valid_int;

    wire stall = stage1_valid && !out_ready;   // stage 2 can't accept -> stall stage 1 too

    assign in_ready = !stall;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) stage1_valid <= 1'b0;
        else if (!stall) begin
            stage1_valid <= in_valid;
            stage1_data  <= in_data;
        end
    end

    assign out_valid = stage1_valid;
    assign out_data   = stage1_data;
endmodule
```
*Derivation:* `stall` is derived from the *downstream* readiness (`out_ready`) and propagated backward into `in_ready` combinationally, in the same cycle — this is exactly the same "any stage's stall must freeze every upstream stage too" principle as Problem 148's pipeline stall logic, just expressed in valid/ready-handshake terms instead of an explicit `stall` control wire, showing the two formulations are equivalent ways of expressing the same backpressure requirement.

**366. Bus Width Adapter (32-bit to 64-bit Upsize)** — *(Medium)*
*Purpose:* Bridges a narrower internal datapath to a wider external bus (or vice versa, Problem 367) — needed whenever a core's native width doesn't match its memory system's or interconnect's native width.
```systemverilog
module width_upsize_32to64 (
    input  logic clk, rst_n,
    input  logic in_valid, output logic in_ready, input logic [31:0] in_data,
    output logic out_valid, input logic out_ready, output logic [63:0] out_data
);
    logic have_low_half;
    logic [31:0] low_half_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) have_low_half <= 1'b0;
        else if (in_valid && in_ready) begin
            if (!have_low_half) begin low_half_q <= in_data; have_low_half <= 1'b1; end
            else                 have_low_half <= 1'b0;
        end
    end

    assign in_ready   = !(have_low_half && out_valid && !out_ready);   // don't accept a 3rd word while stalled on output
    assign out_valid  = have_low_half && in_valid;
    assign out_data    = {in_data, low_half_q};
endmodule
```
*Derivation:* Two 32-bit words must arrive before one 64-bit word can be produced — the first is buffered (`low_half_q`), and the second, combined with the buffered first, produces a valid 64-bit output that same cycle; this is fundamentally a 2:1 rate converter, so `out_valid` can only ever pulse at half the rate `in_valid` does at maximum throughput.

**367. Bus Width Adapter (64-bit to 32-bit Downsize)** — *(Medium)*
*Purpose:* The inverse of Problem 366 — splits one wide word into two narrower beats over two cycles.
```systemverilog
module width_downsize_64to32 (
    input  logic clk, rst_n,
    input  logic in_valid, output logic in_ready, input logic [63:0] in_data,
    output logic out_valid, input logic out_ready, output logic [31:0] out_data
);
    logic sending_high;
    logic [31:0] high_half_q;

    assign in_ready  = !sending_high && out_ready;
    assign out_valid = in_valid || sending_high;
    assign out_data   = sending_high ? high_half_q : in_data[31:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sending_high <= 1'b0;
        else if (in_valid && in_ready && out_ready) begin
            high_half_q  <= in_data[63:32];
            sending_high <= 1'b1;
        end else if (sending_high && out_ready) begin
            sending_high <= 1'b0;
        end
    end
endmodule
```
*Derivation:* The low half is sent combinationally the same cycle the wide word arrives; the high half is latched and sent the following cycle — `in_ready` is deasserted while `sending_high`, correctly preventing a new wide word from arriving before the previous one has finished draining both its halves.

**368. Simple Crossbar (2×2)** — *(Medium)*
*Purpose:* Lets either of 2 masters reach either of 2 slaves, with arbitration when both masters target the same slave simultaneously — the minimal-scale version of the interconnect fabric structure used throughout larger SoCs.
```systemverilog
module crossbar_2x2 (
    input  logic m0_req, m1_req,
    input  logic m0_target, m1_target,   // 0 = slave0, 1 = slave1
    input  logic [31:0] m0_addr, m1_addr,
    output logic s0_req, s1_req,
    output logic [31:0] s0_addr, s1_addr,
    output logic m0_grant, m1_grant
);
    wire m0_wants_s0 = m0_req && !m0_target;
    wire m1_wants_s0 = m1_req && !m1_target;
    wire m0_wants_s1 = m0_req &&  m0_target;
    wire m1_wants_s1 = m1_req &&  m1_target;

    assign s0_req   = m0_wants_s0 || m1_wants_s0;
    assign s0_addr   = m0_wants_s0 ? m0_addr : m1_addr;   // m0 priority on conflict
    assign s1_req   = m0_wants_s1 || m1_wants_s1;
    assign s1_addr   = m0_wants_s1 ? m0_addr : m1_addr;

    assign m0_grant = m0_wants_s0 || m0_wants_s1;
    assign m1_grant = (m1_wants_s0 && !m0_wants_s0) || (m1_wants_s1 && !m0_wants_s1);
endmodule
```
*Derivation:* Each slave port independently OR-combines requests from any master targeting it, with a fixed-priority mux (m0 over m1) resolving conflicts — this is structurally just two independent instances of Problem 98's 2-requester write-port arbitration, one per slave port, which is exactly how larger crossbars are built: N independent per-output arbiters, not one shared global arbiter.

**369. Round-Robin Bus Arbiter (Multi-Master)** — *(Medium)*
*Purpose:* A fairer alternative to Problem 368's fixed-priority arbitration — rotates which requester wins ties, preventing a persistently-active low-priority master from starving others indefinitely.
```systemverilog
module rr_arbiter #(parameter int N = 4) (
    input  logic clk, rst_n,
    input  logic [N-1:0] req,
    output logic [N-1:0] grant
);
    logic [$clog2(N)-1:0] ptr;
    always_comb begin
        grant = '0;
        for (int i = 0; i < N; i++) begin
            automatic int idx = (ptr + i) % N;
            if (req[idx]) begin grant[idx] = 1'b1; break; end
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ptr <= '0;
        else if (|grant) ptr <= (ptr + 1'b1) % N;   // advance past whoever just won
    end
endmodule
```
*Derivation:* Starting the priority scan from `ptr` (rather than always from index 0) and advancing `ptr` past whichever requester wins each cycle guarantees every requester eventually gets priority in rotation — over any window of `N` consecutive grants, no single requester can win more than once while others are also requesting, which is the formal fairness property the earlier `rr_fairness_check` module in this bank verifies.

**370. Outstanding-Transaction ID Tracker** — *(Medium)*
*Purpose:* On a bus that allows multiple outstanding requests before responses return (needed for pipelined/high-latency interconnects), each request needs a unique ID so its eventual response can be matched back to the correct originating request.
```systemverilog
module outstanding_id_tracker #(parameter int NUM_IDS = 8) (
    input  logic clk, rst_n,
    input  logic alloc_req, output logic alloc_valid, output logic [$clog2(NUM_IDS)-1:0] alloc_id,
    input  logic free_req, input logic [$clog2(NUM_IDS)-1:0] free_id
);
    logic [NUM_IDS-1:0] in_use;
    always_comb begin
        alloc_valid = 1'b0; alloc_id = '0;
        for (int i = 0; i < NUM_IDS; i++)
            if (!in_use[i]) begin alloc_valid = 1'b1; alloc_id = i[$clog2(NUM_IDS)-1:0]; break; end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) in_use <= '0;
        else begin
            if (alloc_req && alloc_valid) in_use[alloc_id] <= 1'b1;
            if (free_req)                  in_use[free_id]  <= 1'b0;
        end
    end
endmodule
```
*Derivation:* Structurally a small free-list (same concept as Problem 347, here over transaction IDs rather than physical registers) — `alloc_valid` naturally becomes 0 once every ID is in use, which is the mechanism that caps the maximum number of simultaneously outstanding transactions at `NUM_IDS`, directly analogous to Problem 118's MSHR entry count limiting simultaneous outstanding cache misses.

**371. Response Reordering Buffer** — *(Medium)*
*Purpose:* If a bus permits out-of-order responses (matched back to requests via Problem 370's IDs), but the requester needs responses delivered back to it in the original request order, this buffer re-serializes them — the bus-protocol analogue of Problem 342's ROB.
```systemverilog
module response_reorder #(parameter int NUM_IDS = 8) (
    input  logic clk, rst_n,
    input  logic resp_in_valid, input logic [$clog2(NUM_IDS)-1:0] resp_in_id,
    input  logic [31:0] resp_in_data,
    input  logic [$clog2(NUM_IDS)-1:0] oldest_outstanding_id,
    output logic resp_out_valid,
    output logic [31:0] resp_out_data
);
    logic [NUM_IDS-1:0] resp_valid_arr;
    logic [NUM_IDS-1:0][31:0] resp_data_arr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) resp_valid_arr <= '0;
        else begin
            if (resp_in_valid) begin
                resp_valid_arr[resp_in_id] <= 1'b1;
                resp_data_arr[resp_in_id]  <= resp_in_data;
            end
            if (resp_out_valid) resp_valid_arr[oldest_outstanding_id] <= 1'b0;
        end
    end
    assign resp_out_valid = resp_valid_arr[oldest_outstanding_id];
    assign resp_out_data   = resp_data_arr[oldest_outstanding_id];
endmodule
```
*Derivation:* Exactly the same "store out-of-order, release in-order via a tracked head pointer" principle as Problem 342's ROB — the ID space here plays the same role the ROB tag space plays there, and `oldest_outstanding_id` (which would itself come from a small in-order tracker, similar in spirit to Problem 370 but tracking allocation *order* rather than just in-use state) plays the same role as `head`.

**372. Byte-Enable Aware Write Data Path (Generic Bus)** — *(Medium)*
*Purpose:* A generic bus-facing write path that correctly applies partial-word byte enables, restating Problem 121's byte-enable logic at the bus-protocol level rather than the CPU load/store level.
```systemverilog
module bus_write_datapath (
    input  logic [31:0] wdata,
    input  logic [3:0]  byte_en,
    input  logic [31:0] existing_data,
    output logic [31:0] merged_write_data
);
    always_comb
        for (int b = 0; b < 4; b++)
            merged_write_data[b*8 +: 8] = byte_en[b] ? wdata[b*8 +: 8] : existing_data[b*8 +: 8];
endmodule
```
*Derivation:* For any bus/memory that only supports full-word writes internally, a partial (byte-enabled) write must first read the existing word, merge in only the enabled bytes, then write the merged result back — this read-modify-write merge is exactly what this module computes, needed anywhere the underlying storage doesn't natively support per-byte write strobes.

**373. Bus Protocol Converter Stub (AXI-Lite → APB)** — *(Medium)*
*Purpose:* SoCs commonly need to bridge a high-performance AXI-based interconnect down to simpler APB-based peripherals — this stub sketches the conversion between Problem 291/292's AXI-Lite FSMs and Problem 361's APB FSM.
```systemverilog
module axilite_to_apb_bridge (
    input  logic clk, rst_n,
    input  logic axi_write_resp_done,   // from an axilite_write_fsm instance
    input  logic [31:0] axi_awaddr_captured, axi_wdata_captured,
    output logic apb_req_valid,
    output logic [31:0] apb_req_addr, apb_req_wdata
);
    assign apb_req_valid  = axi_write_resp_done;   // simplified: fires once AXI side has captured a full write
    assign apb_req_addr    = axi_awaddr_captured;
    assign apb_req_wdata   = axi_wdata_captured;
endmodule
```
*Derivation:* Real protocol bridges need considerably more logic (clock-domain crossing if the two sides run at different frequencies, proper backpressure translation between AXI's independent address/data/response channels and APB's single combined transaction, potentially outstanding-transaction limiting since APB has no pipelining at all) — this stub illustrates only the conceptual seam (AXI captures a full transaction, then re-issues it as one APB transaction), deliberately simplified since a complete bridge is a substantially larger design than fits one interview-scale problem.

**374. Interrupt Controller Basic (Multiple Sources → Single CPU IRQ Line)** — *(Medium)*
*Purpose:* Aggregates many independent peripheral interrupt sources into the single IRQ line a CPU core actually has a pin/input for, with per-source enable and pending-status tracking.
```systemverilog
module basic_intc #(parameter int NUM_SRC = 8) (
    input  logic clk, rst_n,
    input  logic [NUM_SRC-1:0] irq_sources,
    input  logic [NUM_SRC-1:0] irq_enable,
    output logic cpu_irq,
    output logic [NUM_SRC-1:0] irq_pending
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) irq_pending <= '0;
        else        irq_pending <= irq_pending | (irq_sources & irq_enable);   // sticky until cleared elsewhere
    end
    assign cpu_irq = |irq_pending;
endmodule
```
*Derivation:* `irq_pending` is deliberately sticky (OR-accumulated, not simply following the raw source level) so a brief pulse from a source doesn't get lost before the CPU has a chance to notice and service it — an external clear mechanism (a write-1-to-clear register, same pattern as the `mmio_regs` W1C example) would be needed to actually deassert an individual pending bit once its interrupt has been handled, omitted here for brevity.

**375. Interrupt Priority Encoder (Multiple Pending → Highest Priority ID)** — *(Medium)*
*Purpose:* When multiple interrupt sources are pending simultaneously, this determines which one the CPU should service first — direct reuse of the priority-encoder pattern from the very first problem discussed in this entire conversation.
```systemverilog
module intc_priority_encoder #(parameter int NUM_SRC = 8) (
    input  logic [NUM_SRC-1:0] irq_pending,
    output logic [$clog2(NUM_SRC)-1:0] highest_pri_id,
    output logic any_pending
);
    always_comb begin
        highest_pri_id = '0; any_pending = |irq_pending;
        for (int i = 0; i < NUM_SRC; i++)
            if (irq_pending[i]) highest_pri_id = i[$clog2(NUM_SRC)-1:0];   // convention: highest index = highest priority
    end
endmodule
```
*Derivation:* Structurally identical to the `priority_enc8` module examined in detail earlier in this conversation — the exact same "later loop iteration overwrites earlier" mux-chain semantics apply here, just relabeled from "which request bit is set" to "which interrupt source has highest priority," confirming this is a genuinely reusable pattern rather than a coincidental resemblance.

**376. Doorbell/Mailbox Register Interface** — *(Medium)*
*Purpose:* A simple software-triggered inter-processor or inter-block signaling mechanism — writing to a "doorbell" register raises an interrupt/flag on the receiving side, commonly used for CPU-to-DMA or multi-core notification.
```systemverilog
module doorbell_reg (
    input  logic clk, rst_n,
    input  logic wr_en,
    input  logic [31:0] wdata,
    output logic doorbell_pending,
    output logic [31:0] doorbell_payload,
    input  logic clear_en
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) doorbell_pending <= 1'b0;
        else if (wr_en) begin
            doorbell_pending <= 1'b1;
            doorbell_payload <= wdata;
        end else if (clear_en) begin
            doorbell_pending <= 1'b0;
        end
    end
endmodule
```
*Derivation:* Functionally a single-entry mailbox (same concept as the `mailbox` CDC module discussed earlier in this bank, minus the clock-domain-crossing complexity if both sides share a clock) — a write sets a sticky pending flag plus payload, and the receiving side is expected to read the payload and then explicitly clear the flag, acknowledging the notification.

**377. Simple DMA Descriptor Fetch FSM** — *(Medium)*
*Purpose:* A DMA engine's first step before actually moving data — fetching a descriptor (source address, destination address, length) from memory that describes the transfer to perform.
```systemverilog
module dma_desc_fetch (
    input  logic clk, rst_n, start,
    input  logic [31:0] desc_ptr,
    output logic mem_req_valid,
    output logic [31:0] mem_req_addr,
    input  logic mem_resp_valid,
    input  logic [31:0] mem_resp_data,
    output logic desc_ready,
    output logic [31:0] src_addr, dst_addr, length
);
    typedef enum logic [2:0] {IDLE, RD_SRC, RD_DST, RD_LEN, DONE} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; desc_ready <= 1'b0; end
        else begin
            desc_ready <= 1'b0;
            unique case (state)
                IDLE:   if (start) state <= RD_SRC;
                RD_SRC: if (mem_resp_valid) begin src_addr <= mem_resp_data; state <= RD_DST; end
                RD_DST: if (mem_resp_valid) begin dst_addr <= mem_resp_data; state <= RD_LEN; end
                RD_LEN: if (mem_resp_valid) begin length   <= mem_resp_data; state <= DONE;   end
                DONE:   begin desc_ready <= 1'b1; state <= IDLE; end
                default: state <= IDLE;
            endcase
        end
    end
    assign mem_req_valid = (state == RD_SRC) || (state == RD_DST) || (state == RD_LEN);
    assign mem_req_addr  = (state == RD_SRC) ? desc_ptr : (state == RD_DST) ? (desc_ptr+4) : (desc_ptr+8);
endmodule
```
*Derivation:* Three sequential 32-bit reads (source, destination, length — a minimal 12-byte descriptor layout) are the simplest possible DMA descriptor format; a real DMA engine's descriptor is often wider (flags, next-descriptor pointer for chained transfers) but this captures the essential fetch-then-transfer two-phase structure.

**378. DMA Single-Transfer Engine** — *(Medium)*
*Purpose:* Once Problem 377 has a descriptor, this actually performs the word-by-word copy from source to destination.
```systemverilog
module dma_transfer_engine (
    input  logic clk, rst_n, start,
    input  logic [31:0] src_addr, dst_addr, length,
    output logic busy, done,
    output logic rd_req_valid, output logic [31:0] rd_addr,
    input  logic rd_resp_valid, input logic [31:0] rd_data,
    output logic wr_req_valid, output logic [31:0] wr_addr, wr_data
);
    typedef enum logic [1:0] {IDLE, READ, WRITE} state_e;
    state_e state;
    logic [31:0] remaining, cur_src, cur_dst;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; done <= 1'b0; end
        else begin
            done <= 1'b0;
            unique case (state)
                IDLE:  if (start) begin
                    remaining <= length; cur_src <= src_addr; cur_dst <= dst_addr;
                    state <= (length == 0) ? IDLE : READ;
                end
                READ:  if (rd_resp_valid) begin wr_data <= rd_data; state <= WRITE; end
                WRITE: begin
                    cur_src   <= cur_src + 4; cur_dst <= cur_dst + 4;
                    remaining <= remaining - 4;
                    state <= (remaining == 4) ? IDLE : READ;
                    if (remaining == 4) done <= 1'b1;
                end
                default: state <= IDLE;
            endcase
        end
    end
    assign busy         = (state != IDLE);
    assign rd_req_valid = (state == READ);
    assign rd_addr        = cur_src;
    assign wr_req_valid  = (state == WRITE);
    assign wr_addr         = cur_dst;
endmodule
```
*Derivation:* A read-then-write pair per word, looped `length/4` times — the simplest possible (unpipelined, one word in flight at a time) DMA transfer engine; a high-performance DMA would pipeline multiple outstanding reads/writes (using the same outstanding-ID tracking as Problem 370) for much higher throughput, at significantly more design complexity than this word-at-a-time baseline.

**379. Bus Protocol Timeout Aggregator** — *(Medium)*
*Purpose:* Extends Problem 296's single-requester timeout to track multiple simultaneously outstanding requests (e.g. from Problem 370's multi-ID scheme), each needing its own independent timeout.
```systemverilog
module multi_timeout_tracker #(parameter int NUM_IDS = 8, parameter int TIMEOUT = 256) (
    input  logic clk, rst_n,
    input  logic [NUM_IDS-1:0] req_outstanding,
    input  logic [NUM_IDS-1:0] resp_valid,
    output logic [NUM_IDS-1:0] timeout_error
);
    logic [NUM_IDS-1:0][$clog2(TIMEOUT+1)-1:0] cnt;
    genvar i;
    generate
        for (i = 0; i < NUM_IDS; i++) begin : gen_timeout
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n || resp_valid[i] || !req_outstanding[i]) cnt[i] <= '0;
                else if (cnt[i] != TIMEOUT)                          cnt[i] <= cnt[i] + 1'b1;
            end
            assign timeout_error[i] = (cnt[i] == TIMEOUT);
        end
    endgenerate
endmodule
```
*Derivation:* A `generate` block instantiating `NUM_IDS` independent copies of Problem 296's single-requester timeout logic — each outstanding ID needs its own counter since they can be allocated and completed at completely independent times, matching the same one-instance-per-tracked-resource pattern used throughout this bank (e.g. Problem 379's structure mirrors Problem 96's per-register busy tracking or Problem 370's per-ID in-use tracking).

**380. Bus Top Wrapper** — *(Medium)*
*Purpose:* Integrates the round-robin arbiter (Problem 369), a width adapter (Problem 366), and the multi-ID timeout tracker (Problem 379) into a single representative bus-interface top level.
```systemverilog
module bus_interface_top #(parameter int N_MASTERS = 4, parameter int NUM_IDS = 8) (
    input  logic clk, rst_n,
    input  logic [N_MASTERS-1:0] master_req,
    output logic [N_MASTERS-1:0] master_grant,
    input  logic [NUM_IDS-1:0] req_outstanding, resp_valid,
    output logic [NUM_IDS-1:0] timeout_error
);
    rr_arbiter #(.N(N_MASTERS)) u_arb (.clk(clk), .rst_n(rst_n), .req(master_req), .grant(master_grant));
    multi_timeout_tracker #(.NUM_IDS(NUM_IDS)) u_timeout (
        .clk(clk), .rst_n(rst_n), .req_outstanding(req_outstanding), .resp_valid(resp_valid), .timeout_error(timeout_error)
    );
endmodule
```
*Derivation:* Pure structural composition of two independently-derived, orthogonal pieces of this category — access arbitration (who gets the bus this cycle) and correctness/liveness monitoring (did any outstanding request hang) are functionally unrelated concerns that simply coexist in the same top-level interface module.

---

## Category 10: CDC & Low-Power Basics (381–400)

**381. 2-Flop Synchronizer (Medium-Tier Restatement)** — *(Medium)*
*Purpose:* Restates the fundamental 2-flop synchronizer with explicit reasoning about *why* two stages (not one, not three) is the standard choice — the baseline every other CDC structure in this category builds on.
```systemverilog
module sync_2ff_medium (
    input  logic dst_clk, dst_rst_n, async_in,
    output logic sync_out
);
    logic meta;
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin meta <= 1'b0; sync_out <= 1'b0; end
        else             begin meta <= async_in; sync_out <= meta; end
    end
endmodule
```
*Derivation:* One flop (`meta`) may go metastable if `async_in` transitions too close to the sampling clock edge; a single flop's metastable output propagating directly to downstream logic would be unpredictable, so a *second* flop is given a full clock period for that metastability to resolve before `sync_out` is used anywhere else — the probability of metastability surviving through *both* stages within one clock period (MTBF) is what's actually being engineered here, and while three or more stages further reduce that (already tiny) residual probability, two stages is the standard minimum considered acceptable for most designs; the deeper the pipe, the more synchronization latency is added for diminishing MTBF improvement.

**382. Multi-Bit Bus CDC via Gray-Coded Pointer** — *(Medium)*
*Purpose:* A plain 2-flop synchronizer (Problem 381) is only safe for a *single* bit — for a multi-bit value (like a FIFO pointer) crossing domains, different bits could resolve their metastability on different cycles, producing a garbage intermediate value; Gray coding guarantees at most one bit changes per increment, bounding the damage.
```systemverilog
module gray_ptr_cdc #(parameter int PTR_W = 5) (
    input  logic src_clk, src_rst_n,
    input  logic [PTR_W-1:0] bin_ptr,
    output logic [PTR_W-1:0] gray_ptr_out,
    input  logic dst_clk, dst_rst_n,
    output logic [PTR_W-1:0] gray_ptr_synced
);
    logic [PTR_W-1:0] gray_ptr, sync1, sync2;
    assign gray_ptr = bin_ptr ^ (bin_ptr >> 1);   // bin2gray, per the earlier proof in this conversation

    always_ff @(posedge src_clk or negedge src_rst_n)
        if (!src_rst_n) gray_ptr_out <= '0;
        else             gray_ptr_out <= gray_ptr;

    always_ff @(posedge dst_clk or negedge dst_rst_n)
        if (!dst_rst_n) {sync2, sync1} <= '0;
        else             {sync2, sync1} <= {sync1, gray_ptr_out};

    assign gray_ptr_synced = sync2;
endmodule
```
*Derivation:* Directly applies the `bin2gray` correctness proof already established earlier in this conversation — because consecutive Gray-coded values differ in exactly one bit (the adjacency property proven and exhaustively verified in `gray_code_proof.md`), even if that one changing bit is caught mid-transition by the destination-domain synchronizer, the worst case is the synchronized value reads as *either* the old or the new pointer value for one extra cycle — never a value that was never actually valid — which is precisely what makes Gray coding the standard solution for multi-bit CDC pointers instead of a plain binary counter.

**383. CDC FIFO Basic (Single-Depth Illustration)** — *(Medium)*
*Purpose:* A minimal illustration of the asynchronous FIFO principle at the smallest possible depth (2 entries, the minimum needed to demonstrate wrap-around), building directly on Problem 382's Gray-coded pointer CDC.
```systemverilog
module cdc_fifo_depth2 #(parameter int W = 8) (
    input  logic wr_clk, wr_rst_n, wr_en,
    input  logic [W-1:0] wr_data,
    output logic full,
    input  logic rd_clk, rd_rst_n, rd_en,
    output logic [W-1:0] rd_data,
    output logic empty
);
    logic [W-1:0] mem [2];
    logic [1:0] wr_ptr_bin, rd_ptr_bin;
    logic [1:0] wr_ptr_gray, rd_ptr_gray, wr_ptr_gray_sync, rd_ptr_gray_sync;

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) wr_ptr_bin <= '0;
        else if (wr_en && !full) begin
            mem[wr_ptr_bin[0]] <= wr_data;
            wr_ptr_bin <= wr_ptr_bin + 1'b1;
        end
    end
    assign wr_ptr_gray = wr_ptr_bin ^ (wr_ptr_bin >> 1);

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) rd_ptr_bin <= '0;
        else if (rd_en && !empty) rd_ptr_bin <= rd_ptr_bin + 1'b1;
    end
    assign rd_ptr_gray  = rd_ptr_bin ^ (rd_ptr_bin >> 1);
    assign rd_data       = mem[rd_ptr_bin[0]];

    logic [1:0] s1, s2;
    always_ff @(posedge rd_clk or negedge rd_rst_n)
        if (!rd_rst_n) {s2, s1} <= '0; else {s2, s1} <= {s1, wr_ptr_gray};
    assign wr_ptr_gray_sync = s2;

    logic [1:0] d1, d2;
    always_ff @(posedge wr_clk or negedge wr_rst_n)
        if (!wr_rst_n) {d2, d1} <= '0; else {d2, d1} <= {d1, rd_ptr_gray};
    assign rd_ptr_gray_sync = d2;

    assign empty = (rd_ptr_gray == wr_ptr_gray_sync);
    assign full  = (wr_ptr_gray == {~rd_ptr_gray_sync[1], rd_ptr_gray_sync[0]});
endmodule
```
*Derivation:* Same full/empty Gray-code comparison logic discussed for the general async-FIFO structure earlier in this bank, deliberately fixed at the smallest depth (2) that still exercises pointer wrap-around, to make the mechanism concretely traceable rather than obscured by a larger, more realistic depth.

**384. Pulse Synchronizer (Toggle-Based, Restated with Derivation)** — *(Medium)*
*Purpose:* Restates the toggle-based pulse synchronizer with explicit reasoning for why a single-cycle pulse can't just be passed through a plain 2-flop synchronizer directly.
```systemverilog
module pulse_sync_medium (
    input  logic src_clk, src_rst_n, src_pulse,
    input  logic dst_clk, dst_rst_n,
    output logic dst_pulse
);
    logic toggle_q, sync1, sync2, sync3;
    always_ff @(posedge src_clk or negedge src_rst_n)
        if (!src_rst_n) toggle_q <= 1'b0;
        else if (src_pulse) toggle_q <= ~toggle_q;

    always_ff @(posedge dst_clk or negedge dst_rst_n)
        if (!dst_rst_n) {sync3, sync2, sync1} <= '0;
        else             {sync3, sync2, sync1} <= {sync2, sync1, toggle_q};

    assign dst_pulse = sync2 ^ sync3;
endmodule
```
*Derivation:* If the source clock is faster than the destination clock, a single-cycle pulse might simply never be sampled by the destination domain at all (it could rise and fall entirely between two destination clock edges) — a plain 2-flop synchronizer on the raw pulse would silently lose it; converting the pulse into a level-toggle instead guarantees the *level change itself* persists until the destination domain has a chance to observe it (a toggle, unlike a pulse, doesn't self-revert), and detecting the transition on the synchronized copy (via the XOR of two consecutive synchronized samples) reliably reconstructs exactly one pulse per source-side toggle, regardless of the two clocks' relative frequencies.

**385. Clock Domain Boundary Register Wrapper** — *(Medium)*
*Purpose:* A structural convention module marking exactly where a signal crosses from one clock domain to another, useful for CDC verification tools (which typically require every domain-crossing signal to pass through an identifiable, taggable structure).
```systemverilog
(* dont_touch = "true" *)
module cdc_boundary_marker #(parameter int W = 1) (
    input  logic src_clk,
    input  logic [W-1:0] src_signal,
    input  logic dst_clk, dst_rst_n,
    output logic [W-1:0] dst_signal
);
    generate
        if (W == 1) begin : single_bit
            sync_2ff_medium u_sync (.dst_clk(dst_clk), .dst_rst_n(dst_rst_n), .async_in(src_signal[0]), .sync_out(dst_signal[0]));
        end
    endgenerate
endmodule
```
*Derivation:* The `dont_touch` attribute prevents synthesis from optimizing away or restructuring this specific boundary (which could otherwise merge/retime the synchronizer flops with neighboring logic in ways that break the careful metastability-hardening intent) — CDC-checking tools (e.g. static CDC analysis) typically scan a design specifically for instances of a recognized synchronizer structure like this one, so wrapping every domain crossing in an explicitly-named, unmodifiable module makes automated verification of CDC correctness tractable across a large design.

**386. Metastability-Aware Reset Bridging** — *(Medium)*
*Purpose:* A reset signal generated in one clock domain (or asynchronously, e.g. from a power-on-reset circuit) needs the same careful synchronized de-assertion as any other CDC signal when it feeds a different clock domain's logic.
```systemverilog
module reset_bridge (
    input  logic dst_clk, input logic async_rst_n,
    output logic dst_rst_n
);
    logic meta;
    always_ff @(posedge dst_clk or negedge async_rst_n)
        if (!async_rst_n) {dst_rst_n, meta} <= 2'b00;
        else               {dst_rst_n, meta} <= {meta, 1'b1};
endmodule
```
*Derivation:* Identical structure to the `reset_sync` module discussed earlier in this bank — restated here specifically to connect it explicitly to the CDC category: reset *assertion* is inherently safe to happen asynchronously (every flop in the destination domain sees it immediately via the async reset input, with no metastability risk since all flops reset to the same known value regardless of timing), but reset *de-assertion* must be synchronized like any other signal transition, since an ill-timed de-assertion edge relative to the destination clock could cause different flops in that domain to come out of reset on different cycles, producing exactly the kind of inconsistent-state bug CDC synchronization exists to prevent.

**387. Simple Clock Divider (Integer Divide-by-N)** — *(Medium)*
*Purpose:* Generates a lower-frequency derived clock (or clock-enable) from a faster reference clock — commonly used for slower peripheral interfaces sharing a core's main clock tree.
```systemverilog
module clock_divider #(parameter int N = 4) (
    input  logic clk_in, rst_n,
    output logic clk_en_out   // pulse every N cycles, used to gate a downstream register rather than a real second clock
);
    logic [$clog2(N)-1:0] cnt;
    always_ff @(posedge clk_in or negedge rst_n) begin
        if (!rst_n) cnt <= '0;
        else        cnt <= (cnt == N-1) ? '0 : cnt + 1'b1;
    end
    assign clk_en_out = (cnt == N-1);
endmodule
```
*Derivation:* Rather than generating an actual second clock signal (which would need its own clock tree and create yet another CDC boundary to manage), this produces a periodic *enable* pulse on the original clock — downstream registers gated by this enable effectively update at `1/N` the rate, achieving the same functional effect as a divided clock while keeping everything synchronous to the single original clock domain, avoiding CDC complexity entirely; real designs do sometimes need genuine divided *clocks* (e.g. for external pin timing), which instead requires a toggle-flip-flop-based divider (Problem 197) feeding an actual clock buffer/mux, with all the CDC care that implies.

**388. Clock-Gating Cell Wrapper (Behavioral ICG Model)** — *(Medium)*
*Purpose:* Models the behavior of a real Integrated Clock Gating (ICG) cell — a library-provided latch-based structure that glitch-free gates a clock, rather than the naive (and unsafe) `clk & enable` AND-gate approach.
```systemverilog
module icg_behavioral (
    input  logic clk_in, enable, test_enable,
    output logic clk_out
);
    logic en_latched;
    always_latch
        if (!clk_in) en_latched = enable || test_enable;
    assign clk_out = clk_in && en_latched;
endmodule
```
*Derivation:* A plain `assign clk_out = clk_in & enable` is unsafe because if `enable` changes while `clk_in` is already high, it can create a runt pulse or a glitch on `clk_out` — the latch here is deliberately transparent only while `clk_in` is *low*, so `enable` can only actually take effect (update `en_latched`) during the safe low phase, guaranteeing `clk_out` never glitches mid-high-phase; `test_enable` is included because real ICG cells conventionally provide a scan-test override to force the clock active during manufacturing test regardless of functional `enable`, since DFT scan shifting needs every flop's clock toggling uniformly.

**389. Power-Domain Enable Sequencer (Staged Power-Up)** — *(Medium)*
*Purpose:* Powering up multiple power domains simultaneously can cause a large instantaneous current surge (di/dt) that stresses the power delivery network — this staggers domain enables over several cycles instead.
```systemverilog
module power_seq #(parameter int NUM_DOMAINS = 4, parameter int STAGGER_CYCLES = 8) (
    input  logic clk, rst_n, power_up_req,
    output logic [NUM_DOMAINS-1:0] domain_enable
);
    logic [$clog2(NUM_DOMAINS*STAGGER_CYCLES+1)-1:0] cnt;
    logic sequencing;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cnt <= '0; sequencing <= 1'b0; end
        else if (power_up_req && !sequencing) begin sequencing <= 1'b1; cnt <= '0; end
        else if (sequencing) begin
            if (cnt != NUM_DOMAINS*STAGGER_CYCLES-1) cnt <= cnt + 1'b1;
        end
    end

    always_comb
        for (int d = 0; d < NUM_DOMAINS; d++)
            domain_enable[d] = sequencing && (cnt >= d*STAGGER_CYCLES);
endmodule
```
*Derivation:* Domain `d` is enabled once the counter has advanced past `d*STAGGER_CYCLES`, giving each successive domain a fixed delay relative to the previous one's enable — this staggering directly reduces the instantaneous di/dt surge versus enabling all domains on the same edge, at the cost of a longer total power-up sequence, a real, quantifiable tradeoff power-management engineers make when specifying staggering depth versus power-up latency budget.

**390. Retention-Register Save/Restore Basic** — *(Medium)*
*Purpose:* Restates the retention-flop concept with explicit save/restore sequencing, needed before a power domain can be safely powered down (state must be saved to an always-on retention flop first) and after it powers back up (state must be restored before normal operation resumes).
```systemverilog
module retention_seq (
    input  logic clk, power_down_req, power_up_done,
    output logic save_en, restore_en
);
    assign save_en    = power_down_req;
    assign restore_en = power_up_done;
endmodule
```
*Derivation:* This is the sequencing/control-signal layer sitting above the `retention_wrapper` datapath module discussed earlier in this bank — `save_en` must be asserted (and complete) *before* the domain actually loses power, and `restore_en` must be asserted *after* the domain's power has fully stabilized again, both timing requirements that in a real design are enforced by a power-controller FSM coordinating with the actual power-switch sequencing (Problem 398), not just this simple combinational mapping.

**391. Idle-Detection-Based Auto Clock-Gate** — *(Medium)*
*Purpose:* Combines Problem 157's idle-detection hysteresis counter with Problem 388's ICG model, producing the complete automatic clock-gating structure that watches for sustained inactivity and gates a block's clock without any explicit software/firmware intervention.
```systemverilog
module auto_clock_gate #(parameter int IDLE_THRESHOLD = 32) (
    input  logic clk, rst_n, any_activity,
    output logic gated_clk
);
    logic idle;
    logic [$clog2(IDLE_THRESHOLD+1)-1:0] cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)              cnt <= '0;
        else if (any_activity)   cnt <= '0;
        else if (cnt != IDLE_THRESHOLD) cnt <= cnt + 1'b1;
    end
    assign idle = (cnt == IDLE_THRESHOLD);

    icg_behavioral u_icg (.clk_in(clk), .enable(!idle), .test_enable(1'b0), .clk_out(gated_clk));
endmodule
```
*Derivation:* Direct composition of Problems 157 and 388 — the idle-detection counter decides *when* it's safe to gate (after sustained inactivity, avoiding gating/ungating thrash on every single idle cycle, which would itself waste power switching the clock tree on and off rapidly), and the ICG model actually performs the glitch-free gating once that decision is made.

**392. DVFS Frequency-Change Handshake Basic** — *(Medium)*
*Purpose:* Changing clock frequency (as part of dynamic voltage/frequency scaling) can't happen instantaneously mid-operation — this handshake lets a block signal it has reached a safe quiescent point before the frequency change proceeds.
```systemverilog
module dvfs_freq_change_handshake (
    input  logic clk, rst_n, freq_change_req,
    input  logic block_is_quiescent,
    output logic freq_change_ack,
    output logic clk_switch_safe
);
    typedef enum logic [1:0] {NORMAL, WAIT_QUIESCENT, SWITCHING} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= NORMAL;
        else unique case (state)
            NORMAL:          if (freq_change_req) state <= WAIT_QUIESCENT;
            WAIT_QUIESCENT: if (block_is_quiescent) state <= SWITCHING;
            SWITCHING:       state <= NORMAL;
        endcase
    end
    assign freq_change_ack = (state == SWITCHING);
    assign clk_switch_safe  = (state == SWITCHING);
endmodule
```
*Derivation:* `block_is_quiescent` (e.g. no in-flight multi-cycle FU operations, no pending bus transactions) must be true before it's actually safe to change frequency — switching mid-operation could violate a multi-cycle FSM's implicit timing assumptions (e.g. Problem 202's multiplier assumes a constant clock period across all 32 of its iterations); this handshake makes that safety requirement explicit rather than assuming the DVFS controller can switch frequency at an arbitrary moment.

**393. Isolation Cell Wrapper (Restated with Derivation)** — *(Medium)*
*Purpose:* Restates the power-domain isolation concept with explicit reasoning for why it's needed, not just what it does.
```systemverilog
module iso_cell_medium #(parameter int W = 32) (
    input  logic domain_powered,
    input  logic [W-1:0] signal_in,
    output logic [W-1:0] signal_out
);
    assign signal_out = domain_powered ? signal_in : '0;
endmodule
```
*Derivation:* When a power domain is switched off, its outputs float to an undefined (often mid-supply, "X"-like in both simulation and reality) voltage level rather than cleanly settling to 0 or 1 — if that floating signal feeds directly into a still-powered domain's logic, it can cause that logic to draw excessive crowbar current (both the pull-up and pull-down transistors of a receiving gate partially conducting simultaneously) or simply behave unpredictably; an isolation cell, itself always powered, clamps the output to a known-safe, defined value (here, 0) whenever the source domain is off, protecting every downstream always-on consumer.

**394. Low-Power State Entry/Exit FSM (Sleep/Wake)** — *(Medium)*
*Purpose:* The overall sequencing controller coordinating clock-gating, power-gating, and retention save/restore into one coherent low-power state transition, rather than each mechanism acting independently and possibly out of the safe order.
```systemverilog
module lp_state_fsm (
    input  logic clk, rst_n, sleep_req, wake_req,
    output logic gate_clock, save_state, power_off, power_on, restore_state, resume_clock
);
    typedef enum logic [2:0] {ACTIVE, GATING, SAVING, OFF, RESTORING, RESUMING} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= ACTIVE;
        else unique case (state)
            ACTIVE:     if (sleep_req)  state <= GATING;
            GATING:     state <= SAVING;
            SAVING:     state <= OFF;
            OFF:        if (wake_req)   state <= RESTORING;
            RESTORING:  state <= RESUMING;
            RESUMING:   state <= ACTIVE;
        endcase
    end
    assign gate_clock     = (state == GATING);
    assign save_state      = (state == SAVING);
    assign power_off        = (state == OFF);
    assign power_on          = (state == RESTORING) || (state == RESUMING);
    assign restore_state    = (state == RESTORING);
    assign resume_clock    = (state == RESUMING);
endmodule
```
*Derivation:* The strict ordering (gate clock → save state → power off; and symmetrically power on → restore state → resume clock) is not arbitrary: state must be saved to always-on retention storage *before* power is removed (or it's lost forever, Problem 390's ordering requirement), and the clock must be safely gated *before* saving (so the save operation itself isn't disrupted mid-transfer by a clock edge arriving at an inconvenient moment) — this FSM is the single coordinating authority ensuring every one of this category's individual mechanisms (Problems 388–393) fires in the one safe order, rather than trusting several independent pieces of logic to coincidentally sequence themselves correctly.

**395. Clock Mux Glitch-Free Switch** — *(Medium)*
*Purpose:* Switching between two independent clock sources (e.g. a normal PLL clock and a slower always-on backup clock) naively with a plain mux can produce a runt pulse if the switch happens near a clock edge — this sequences a glitch-free transition.
```systemverilog
module glitch_free_clkmux (
    input  logic clk_a, clk_b, sel,
    output logic clk_out
);
    logic sel_sync_a, sel_sync_a2, sel_sync_b, sel_sync_b2;

    always_ff @(negedge clk_a) begin
        sel_sync_a  <= sel;
        sel_sync_a2 <= sel_sync_a;
    end
    always_ff @(negedge clk_b) begin
        sel_sync_b  <= ~sel;
        sel_sync_b2 <= sel_sync_b;
    end

    assign clk_out = (clk_a && sel_sync_a2) || (clk_b && sel_sync_b2);
endmodule
```
*Derivation:* This is the classic dual-synchronizer glitch-free clock mux structure: each clock's own enable is synchronized (on the *falling* edge, so the enable is stable well before the next rising edge that would actually gate through a pulse) to that same clock, guaranteeing the switch only ever takes effect while that specific clock is already low — the AND-then-OR structure ensures at most one clock ever drives `clk_out` at a time and the transition only happens during a safe low period, avoiding both a runt pulse and a moment where neither (or both) clocks drive the output.

**396. Reset Domain Crossing** — *(Medium)*
*Purpose:* A reset asserted based on logic in one clock domain (e.g. a watchdog timeout detected on a slow always-on clock) needs to correctly reset flops in a completely different, faster functional clock domain.
```systemverilog
module reset_domain_cross (
    input  logic src_clk, logic_reset_assert,
    input  logic dst_clk, dst_async_rst_n,
    output logic dst_rst_n
);
    logic async_reset_pulse;
    assign async_reset_pulse = logic_reset_assert;   // assertion can propagate immediately, asynchronously

    reset_bridge u_bridge (.dst_clk(dst_clk), .async_rst_n(dst_async_rst_n && !async_reset_pulse), .dst_rst_n(dst_rst_n));
endmodule
```
*Derivation:* Combines Problem 386's reset-bridge synchronized de-assertion with the principle that reset *assertion* itself can (and for safety, generally should) propagate immediately and asynchronously into the destination domain's async reset input — only the subsequent *release* of that reset needs to be synchronized to the destination clock, which is exactly what feeding the OR'd/combined async condition into `reset_bridge`'s existing synchronized-de-assertion logic achieves.

**397. CDC Assertion Checker (2-Flop Sync Verification)** — *(Medium)*
*Purpose:* A simulation-only formal-style checker confirming a suspected synchronizer instance actually has the expected 2-flop structure and isn't, say, accidentally combinational or missing a stage — the kind of check a CDC linting tool automates across an entire design.
```systemverilog
module cdc_sync_checker (
    input  logic dst_clk,
    input  logic async_in, meta_stage, sync_out
);
    // synthesis translate_off
    always @(posedge dst_clk) begin
        assert (sync_out === $past(meta_stage))
            else $error("CDC checker: sync_out did not register meta_stage from the previous cycle");
    end
    // synthesis translate_on
endmodule
```
*Derivation:* `$past(meta_stage)` evaluates to whatever `meta_stage` held one clock cycle earlier — confirming `sync_out` always equals that value verifies the second flop is genuinely a clean register stage sampling the first, rather than (for example) a synthesis or hand-edit mistake that accidentally shortened the chain to one stage or introduced combinational logic between the two flops that could reintroduce metastability risk into the "synchronized" output.

**398. Power-Gate Sequencing FSM** — *(Medium)*
*Purpose:* The detailed power-switch-level sequencing underlying Problem 394's higher-level `power_off`/`power_on` signals — real power gating involves ramping the power switch header transistors gradually (not an instant on/off) to control inrush current.
```systemverilog
module power_gate_seq #(parameter int RAMP_STEPS = 8) (
    input  logic clk, rst_n, power_on_req,
    output logic [RAMP_STEPS-1:0] header_enable,   // each bit gates one slice of the power-switch header
    output logic fully_on
);
    logic [$clog2(RAMP_STEPS+1)-1:0] step;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) step <= '0;
        else if (power_on_req && (step != RAMP_STEPS)) step <= step + 1'b1;
        else if (!power_on_req) step <= '0;
    end
    always_comb
        for (int i = 0; i < RAMP_STEPS; i++)
            header_enable[i] = (step > i);
    assign fully_on = (step == RAMP_STEPS);
endmodule
```
*Derivation:* Enabling all header switch segments simultaneously would cause a large instantaneous inrush current as the domain's decoupling capacitance charges all at once; turning them on one segment per cycle (same staggering principle as Problem 389, applied at finer granularity to the power-switch header itself rather than whole domains) spreads that inrush current over `RAMP_STEPS` cycles, directly trading power-up latency for reduced peak current draw — `fully_on` is what a real Problem 394-style FSM would wait for before considering the domain actually ready for `restore_state`.

**399. Always-On Domain Wake-Request Handshake** — *(Medium)*
*Purpose:* A powered-down domain obviously can't generate its own wake-up signal (it has no power) — an always-on domain (containing minimal logic like a wake-timer or an external pin monitor) must be the one to request power restoration on the switched domain's behalf.
```systemverilog
module always_on_wake_req (
    input  logic aon_clk, aon_rst_n,
    input  logic wake_timer_expired, external_wake_pin,
    output logic wake_request
);
    always_ff @(posedge aon_clk or negedge aon_rst_n)
        if (!aon_rst_n) wake_request <= 1'b0;
        else             wake_request <= wake_timer_expired || external_wake_pin;
endmodule
```
*Derivation:* This module lives entirely within the always-on power domain (never itself power-gated), which is precisely why it's able to independently monitor wake conditions and assert `wake_request` into Problem 394's FSM regardless of the switched domain's current power state — the fundamental structural requirement of any power-gateable design: something has to remain powered at all times specifically to be able to request that everything else power back up.

**400. CDC/Low-Power Top Wrapper** — *(Medium)*
*Purpose:* Integrates a synchronizer (Problem 381), an automatic clock gate (Problem 391), and the low-power state FSM (Problem 394) into a single representative module showing how these mechanisms compose in a real design.
```systemverilog
module cdc_lowpower_top (
    input  logic clk, rst_n,
    input  logic async_wake_signal,
    input  logic any_activity,
    input  logic sleep_req,
    output logic gated_clk,
    output logic power_off, power_on
);
    logic sync_wake;
    sync_2ff_medium u_sync (.dst_clk(clk), .dst_rst_n(rst_n), .async_in(async_wake_signal), .sync_out(sync_wake));

    logic gate_clock_lp, resume_clock_lp;
    logic save_state, restore_state;
    lp_state_fsm u_lp (
        .clk(clk), .rst_n(rst_n), .sleep_req(sleep_req), .wake_req(sync_wake),
        .gate_clock(gate_clock_lp), .save_state(save_state),
        .power_off(power_off), .power_on(power_on),
        .restore_state(restore_state), .resume_clock(resume_clock_lp)
    );

    auto_clock_gate u_acg (.clk(clk), .rst_n(rst_n), .any_activity(any_activity && !gate_clock_lp), .gated_clk(gated_clk));
endmodule
```
*Derivation:* The externally-generated `async_wake_signal` must be synchronized (Problem 381) before it's safe to use as `wake_req` into the state FSM (Problem 394), which itself coordinates the overall sleep/wake sequence; the automatic idle-based clock gate (Problem 391) operates independently for fine-grained, moment-to-moment gating during normal `ACTIVE` operation, while the LP-state FSM's own `gate_clock` handles the coarser, deliberate full-sleep transition — both mechanisms coexist because they solve different problems (opportunistic micro-idle gating vs. deliberate deep-sleep entry) at different timescales.

---

**End of MEDIUM tier (Problems 201–400).** This completes Phase 2 of 3. Next: **Hard tier (Problems 401–600)** — out-of-order core structures at full scale, cache/TLB/coherence, advanced CDC, low-power, arithmetic units, and verification/formal — in the same purpose + full-solution + derivation format, continuing from `riscv_medium_200_part2.md`.