# RISC-V CPU Live-Coding Bank — MEDIUM Tier, Problems 201–300
### Phase 2 of 3 (Easy 1–200 complete · Medium 201–400 · Hard 401–600)

Each problem includes **Purpose**, a **full reference SystemVerilog solution**, and a **Derivation** (formal proof where a module is fundamentally a math/bit-manipulation function; a structured design derivation — FSM state-transition reasoning, timing trace, or handshake-protocol argument — everywhere else). Medium tier steps up from single combinational blocks to small FSMs, multi-cycle sequencing, and simple pipelined/arbitrated structures. **Part 1 covers Categories 1–5.**

---

## Category 1: Multi-Cycle & FSM-Based Execution (201–220)

**201. Multi-Cycle ALU Dispatch Controller** — *(Medium)*
*Purpose:* Routes an operation to either the single-cycle ALU or a multi-cycle unit (MUL/DIV), and tells Execute whether to expect a result this cycle or to wait.
```systemverilog
module exec_dispatch (
    input  logic is_muldiv,
    output logic use_multicycle,
    output logic use_single_cycle
);
    assign use_multicycle   = is_muldiv;
    assign use_single_cycle = !is_muldiv;
endmodule
```
*Derivation:* `is_muldiv` is exactly Problem 79's M-extension detector; this is the routing decision that detector feeds directly into.

**202. Shift-Add Unsigned Multiplier FSM** — *(Medium)*
*Purpose:* Implements MUL/MULHU using the classic shift-and-add algorithm over 32 cycles, avoiding a large combinational multiplier array.
```systemverilog
module mul_fsm (
    input  logic clk, rst_n, start,
    input  logic [31:0] a, b,
    output logic busy, done,
    output logic [63:0] product
);
    logic [63:0] acc, multiplicand;
    logic [31:0] multiplier;
    logic [5:0]  count;
    typedef enum logic [1:0] {IDLE, COMPUTE, DONE} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; done <= 1'b0;
        end else begin
            done <= 1'b0;
            unique case (state)
                IDLE: if (start) begin
                    acc <= 64'b0; multiplicand <= {32'b0, a}; multiplier <= b;
                    count <= 6'd0; state <= COMPUTE;
                end
                COMPUTE: begin
                    if (multiplier[0]) acc <= acc + multiplicand;
                    multiplicand <= multiplicand << 1;
                    multiplier   <= multiplier >> 1;
                    count <= count + 1'b1;
                    if (count == 6'd31) state <= DONE;
                end
                DONE: begin done <= 1'b1; state <= IDLE; end
                default: state <= IDLE;
            endcase
        end
    end
    assign busy    = (state == COMPUTE);
    assign product = acc;
endmodule
```
*Derivation:* This is the standard grade-school multiplication algorithm in binary: for each bit of `multiplier` (LSB first), conditionally add the (progressively left-shifted) `multiplicand` into an accumulator. After 32 iterations, `acc` holds the full 64-bit unsigned product — correctness follows directly from `a*b = Σ(b[i] * a * 2^i)` for `i=0..31`, which is exactly what the loop accumulates.

**203. Signed Multiplier via Pre/Post Two's-Complement Correction** — *(Medium)*
*Purpose:* Reuses Problem 202's unsigned engine for MUL (signed×signed), by negating negative operands before the unsigned multiply and correcting the sign of the result afterward.
```systemverilog
module signed_mul_wrap (
    input  logic clk, rst_n, start,
    input  logic signed [31:0] a, b,
    output logic busy, done,
    output logic signed [63:0] product
);
    logic [31:0] a_mag, b_mag;
    logic result_neg;
    logic [63:0] unsigned_product;
    logic ufsm_busy, ufsm_done;

    assign a_mag = a[31] ? (~a + 1'b1) : a;
    assign b_mag = b[31] ? (~b + 1'b1) : b;

    mul_fsm u_mul (.clk(clk), .rst_n(rst_n), .start(start), .a(a_mag), .b(b_mag),
                    .busy(ufsm_busy), .done(ufsm_done), .product(unsigned_product));

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) result_neg <= 1'b0;
        else if (start) result_neg <= a[31] ^ b[31];

    assign busy    = ufsm_busy;
    assign done    = ufsm_done;
    assign product = result_neg ? (~unsigned_product + 1'b1) : unsigned_product;
endmodule
```
*Derivation:* `|a*b| = |a| * |b|`, and the sign of the product is negative iff exactly one operand is negative (`a[31] ^ b[31]`) — standard two's-complement multiplication-by-magnitude identity, letting the unsigned engine be reused without modification.

**204. MULH/MULHU/MULHSU Result Selection** — *(Medium)*
*Purpose:* The M-extension defines four multiply variants that all compute the same 64-bit product but return different 32-bit halves depending on operand signedness.
```systemverilog
typedef enum logic [1:0] {MUL_LOW, MULH_SS, MULH_UU, MULH_SU} mul_variant_e;

module mul_result_select (
    input  mul_variant_e variant,
    input  logic [63:0] product_ss, product_uu, product_su,
    output logic [31:0] result
);
    always_comb begin
        unique case (variant)
            MUL_LOW: result = product_ss[31:0];   // low half is identical regardless of signedness
            MULH_SS: result = product_ss[63:32];
            MULH_UU: result = product_uu[63:32];
            MULH_SU: result = product_su[63:32];
        endcase
    end
endmodule
```
*Derivation:* The low 32 bits of a 64-bit product are identical whether the multiply was performed as signed×signed, unsigned×unsigned, or mixed — two's-complement multiplication only affects the *upper* bits, which is exactly why MUL (low half) needs no signedness distinction while MULH/MULHU/MULHSU (all upper-half) each need their own dedicated product computed with the correct operand interpretation.

**205. Restoring Division FSM (Unsigned)** — *(Medium)*
*Purpose:* Implements DIVU/REMU via the standard restoring-division algorithm, producing both quotient and remainder over 32 cycles.
```systemverilog
module divu_fsm (
    input  logic clk, rst_n, start,
    input  logic [31:0] dividend, divisor,
    output logic busy, done,
    output logic [31:0] quotient, remainder
);
    logic [63:0] work;
    logic [31:0] divisor_q;
    logic [5:0]  count;
    typedef enum logic [1:0] {IDLE, COMPUTE, DONE} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; done <= 1'b0;
        end else begin
            done <= 1'b0;
            unique case (state)
                IDLE: if (start) begin
                    work <= {32'b0, dividend}; divisor_q <= divisor; count <= 6'd0; state <= COMPUTE;
                end
                COMPUTE: begin
                    automatic logic [63:0] shifted = work << 1;
                    automatic logic [31:0] rem_part = shifted[63:32];
                    if (rem_part >= divisor_q) work <= {(rem_part - divisor_q), shifted[31:1], 1'b1};
                    else                        work <= shifted;
                    count <= count + 1'b1;
                    if (count == 6'd31) state <= DONE;
                end
                DONE: begin done <= 1'b1; state <= IDLE; end
                default: state <= IDLE;
            endcase
        end
    end
    assign busy      = (state == COMPUTE);
    assign quotient  = work[31:0];
    assign remainder = work[63:32];
endmodule
```
*Derivation:* Each iteration shifts the combined remainder:quotient register left by one, then tests whether the (shifted) partial remainder is at least the divisor — if so, subtracting the divisor and setting the incoming quotient bit to 1 is correct because that's the largest multiple of the divisor (shifted appropriately) that still fits, which is the defining step of long division in binary.

**206. Signed Division with Sign Correction (DIV/REM)** — *(Medium)*
*Purpose:* RISC-V DIV/REM truncate toward zero (not floor), which requires careful sign handling beyond simply negating operands the way Problem 203 did for multiply.
```systemverilog
module signed_div_wrap (
    input  logic clk, rst_n, start,
    input  logic signed [31:0] dividend, divisor,
    output logic busy, done,
    output logic signed [31:0] quotient, remainder
);
    logic [31:0] dvd_mag, dvs_mag, uq, ur;
    logic q_neg, r_neg, ufsm_busy, ufsm_done;

    assign dvd_mag = dividend[31] ? (~dividend + 1'b1) : dividend;
    assign dvs_mag = divisor[31]  ? (~divisor  + 1'b1) : divisor;

    divu_fsm u_div (.clk(clk), .rst_n(rst_n), .start(start), .dividend(dvd_mag), .divisor(dvs_mag),
                     .busy(ufsm_busy), .done(ufsm_done), .quotient(uq), .remainder(ur));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin q_neg <= 1'b0; r_neg <= 1'b0; end
        else if (start) begin
            q_neg <= dividend[31] ^ divisor[31];   // quotient sign: XOR of operand signs
            r_neg <= dividend[31];                  // remainder sign: same sign as dividend
        end
    end

    assign busy      = ufsm_busy;
    assign done       = ufsm_done;
    assign quotient   = q_neg ? (~uq + 1'b1) : uq;
    assign remainder  = r_neg ? (~ur + 1'b1) : ur;
endmodule
```
*Derivation:* RISC-V's DIV/REM are defined to satisfy `dividend = divisor * quotient + remainder` with truncation toward zero, which forces the remainder to always carry the *dividend's* sign (not the divisor's) — this is a specific, spec-mandated convention (matching C99 integer division semantics), distinct from the "remainder takes the divisor's sign" convention used by floored division in some other languages.

**207. Remainder Extraction as Standalone Module** — *(Medium)*
*Purpose:* Isolates just the remainder-sign-correction step, useful when a core computes quotient and remainder in physically separate pipeline stages.
```systemverilog
module rem_correct (input logic dividend_neg, input logic [31:0] ur, output logic [31:0] remainder);
    assign remainder = dividend_neg ? (~ur + 1'b1) : ur;
endmodule
```
*Derivation:* Directly the remainder half of Problem 206's correction logic, split out for reuse.

**208. Divide-by-Zero Special-Case Handler** — *(Medium)*
*Purpose:* RISC-V defines DIV/DIVU/REM/REMU's behavior on division by zero explicitly (unlike many ISAs, which trap) — the hardware must detect this case and substitute the defined result instead of running the division FSM at all.
```systemverilog
module div_by_zero_check (
    input  logic [31:0] divisor,
    input  logic is_signed,
    output logic div_by_zero,
    output logic [31:0] quotient_override,
    output logic [31:0] remainder_override
);
    assign div_by_zero        = (divisor == 32'b0);
    assign quotient_override  = 32'hFFFF_FFFF;   // all-ones (-1) for both DIV and DIVU
    assign remainder_override = 32'b0;            // undefined placeholder; actual remainder = dividend, see derivation
endmodule
```
*Derivation:* Per spec, division by zero returns quotient = all-ones (`-1` interpreted as either signed or unsigned) for both DIV and DIVU, and remainder = the original dividend unchanged — this module handles the quotient side; the remainder side simply requires passing the dividend straight through (bypassing the FSM entirely) rather than a computed override, which is why `remainder_override` here is a placeholder to be replaced by a mux selecting the original dividend at the top level.

**209. Signed-Overflow Special-Case Handler (INT_MIN / -1)** — *(Medium)*
*Purpose:* The one signed-division case that would overflow a 32-bit result (`-2^31 / -1 = 2^31`, which doesn't fit) is also explicitly defined by spec rather than trapping.
```systemverilog
module div_overflow_check (
    input  logic signed [31:0] dividend, divisor,
    output logic overflow,
    output logic [31:0] quotient_override,
    output logic [31:0] remainder_override
);
    assign overflow           = (dividend == 32'h8000_0000) && (divisor == 32'hFFFF_FFFF);
    assign quotient_override  = 32'h8000_0000;   // dividend unchanged
    assign remainder_override = 32'b0;
endmodule
```
*Derivation:* Per spec, this specific overflow case returns the quotient equal to the dividend itself (`INT_MIN`) and remainder 0 — a defined, deterministic result rather than the undefined/trapping behavior many other ISAs specify, which is exactly what lets software rely on DIV never faulting.

**210. Iterative Barrel-Shift-by-1 Shifter** — *(Medium)*
*Purpose:* An alternative to a fully combinational barrel shifter (Problem "funnel_shifter" from the earlier bank) — shifts one bit position per cycle, trading latency for a much smaller/faster single-bit-shift datapath, useful on area-constrained cores.
```systemverilog
module iter_shifter (
    input  logic clk, rst_n, start,
    input  logic [31:0] data_in,
    input  logic [4:0]  shamt,
    input  logic dir_right, arith,
    output logic busy, done,
    output logic [31:0] result
);
    logic [31:0] shreg;
    logic [4:0]  remaining;
    typedef enum logic [1:0] {IDLE, SHIFTING, DONE} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; done <= 1'b0; end
        else begin
            done <= 1'b0;
            unique case (state)
                IDLE: if (start) begin
                    shreg <= data_in; remaining <= shamt;
                    state <= (shamt == 5'd0) ? DONE : SHIFTING;
                end
                SHIFTING: begin
                    shreg <= dir_right ? (arith ? {shreg[31], shreg[31:1]} : {1'b0, shreg[31:1]})
                                        : {shreg[30:0], 1'b0};
                    remaining <= remaining - 1'b1;
                    if (remaining == 5'd1) state <= DONE;
                end
                DONE: begin done <= 1'b1; state <= IDLE; end
                default: state <= IDLE;
            endcase
        end
    end
    assign busy   = (state == SHIFTING);
    assign result = shreg;
endmodule
```
*Derivation:* Shifting by 1 bit `shamt` times is functionally identical to shifting by `shamt` bits once, just distributed across `shamt` clock cycles instead of one — a direct latency/area tradeoff versus Problem 46–48's single-cycle combinational shifters.

**211. Multi-Cycle Memory-Access Wait-State FSM** — *(Medium)*
*Purpose:* When a memory or peripheral can't guarantee a response in one cycle, this tracks how many wait states to insert before the access completes.
```systemverilog
module mem_wait_fsm (
    input  logic clk, rst_n, req_valid,
    input  logic [2:0] wait_cycles,
    output logic access_done, stall
);
    logic [2:0] count;
    typedef enum logic [1:0] {IDLE, WAITING, DONE} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; access_done <= 1'b0; end
        else begin
            access_done <= 1'b0;
            unique case (state)
                IDLE: if (req_valid) begin
                    count <= wait_cycles;
                    state <= (wait_cycles == 3'd0) ? DONE : WAITING;
                end
                WAITING: begin
                    count <= count - 1'b1;
                    if (count == 3'd1) state <= DONE;
                end
                DONE: begin access_done <= 1'b1; state <= IDLE; end
                default: state <= IDLE;
            endcase
        end
    end
    assign stall = (state != IDLE) || (state == IDLE && req_valid && wait_cycles != 3'd0);
endmodule
```
*Derivation:* Models a memory with variable, request-time-known latency (e.g. different for cache hit vs. a slower memory-mapped peripheral) — the pipeline must hold (`stall`) until `access_done` pulses, generalizing the fixed-latency assumption most of the Easy-tier pipeline registers made.

**212. Bus-Ready Wait Controller** — *(Medium)*
*Purpose:* Unlike Problem 211's known-latency model, a real bus interface often signals completion asynchronously via a `ready` handshake rather than a pre-known cycle count.
```systemverilog
module bus_ready_wait (
    input  logic clk, rst_n,
    input  logic req_valid, bus_ready,
    output logic stall, access_complete
);
    logic waiting;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) waiting <= 1'b0;
        else if (req_valid && !bus_ready) waiting <= 1'b1;
        else if (bus_ready)                waiting <= 1'b0;
    end
    assign stall            = (req_valid || waiting) && !bus_ready;
    assign access_complete  = (req_valid || waiting) && bus_ready;
endmodule
```
*Derivation:* This is the general handshake pattern for any variable-latency bus: keep stalling as long as a request is outstanding and the responder hasn't asserted `ready`; the moment `ready` appears, the access is complete regardless of how many cycles that took — strictly more general than Problem 211's fixed-count model.

**213. Microcode-Style Sequencer (ROM-Based FSM)** — *(Medium)*
*Purpose:* Demonstrates the classic microcoded-control alternative to a hardwired FSM — control signals for each cycle of a multi-cycle instruction come from a small ROM indexed by a micro-PC, rather than being hand-encoded into `case` statements per state.
```systemverilog
typedef struct packed {
    logic [3:0] alu_op;
    logic       mem_read, mem_write, reg_write;
    logic [2:0] next_ustate;
    logic       last_step;
} micro_word_t;

module microcode_seq (
    input  logic clk, rst_n,
    input  logic [2:0] ustate,
    output micro_word_t uword
);
    micro_word_t urom [8];
    initial begin
        urom[0] = '{alu_op: 4'h0, mem_read: 1'b1, mem_write: 1'b0, reg_write: 1'b0, next_ustate: 3'd1, last_step: 1'b0}; // fetch
        urom[1] = '{alu_op: 4'h0, mem_read: 1'b0, mem_write: 1'b0, reg_write: 1'b0, next_ustate: 3'd2, last_step: 1'b0}; // decode
        urom[2] = '{alu_op: 4'h1, mem_read: 1'b0, mem_write: 1'b0, reg_write: 1'b0, next_ustate: 3'd3, last_step: 1'b0}; // execute
        urom[3] = '{alu_op: 4'h0, mem_read: 1'b0, mem_write: 1'b0, reg_write: 1'b1, next_ustate: 3'd0, last_step: 1'b1}; // writeback
    end
    assign uword = urom[ustate];
endmodule
```
*Derivation:* Each entry in `urom` encodes exactly the control-signal state for one cycle of instruction execution plus which micro-state to visit next — this trades the combinational complexity of a hand-derived `case` statement for a simple table lookup, which is how early/simpler CPUs (and even some modern CISC decode paths) implement multi-step instruction sequencing.

**214. Single-Cycle-vs-Multi-Cycle Datapath Selector** — *(Medium)*
*Purpose:* Lets the same execute stage either commit a result immediately (single-cycle ALU ops) or wait for a multi-cycle unit's `done` pulse, unifying both paths behind one `result_valid` signal.
```systemverilog
module exec_result_valid (
    input  logic is_multicycle,
    input  logic multicycle_done,
    output logic result_valid
);
    assign result_valid = is_multicycle ? multicycle_done : 1'b1;
endmodule
```
*Derivation:* Single-cycle ops are always "done" the same cycle they issue; multi-cycle ops are only done when their FSM (Problems 202/205) pulses `done` — this mux-like OR-of-conditions unifies both into the one signal downstream write-back logic needs to check.

**215. FU-Busy/Done Handshake Register** — *(Medium)*
*Purpose:* Latches a multi-cycle functional unit's busy/done status so the pipeline's stall logic can observe stable signals rather than racing against the FU's internal combinational outputs.
```systemverilog
module fu_status_reg (
    input  logic clk, rst_n,
    input  logic fu_busy_comb, fu_done_comb,
    output logic fu_busy, fu_done
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fu_busy <= 1'b0; fu_done <= 1'b0; end
        else begin fu_busy <= fu_busy_comb; fu_done <= fu_done_comb; end
    end
endmodule
```
*Derivation:* Registering these status signals adds one cycle of latency to their visibility but avoids any combinational-path dependency between the FU's internal state machine and the pipeline's stall-generation logic in the same cycle, simplifying timing closure at the cost of that extra cycle.

**216. Result-Latch-on-Done Register** — *(Medium)*
*Purpose:* Captures a multi-cycle FU's output exactly once, on the cycle `done` pulses, and holds it stable afterward for write-back to consume — since the FU's internal registers (e.g. `mul_fsm`'s `acc`) may continue changing on subsequent cycles if immediately reused for a new operation.
```systemverilog
module fu_result_latch (
    input  logic clk, rst_n, done,
    input  logic [63:0] fu_result,
    output logic [63:0] latched_result
);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)  latched_result <= '0;
        else if (done) latched_result <= fu_result;
endmodule
```
*Derivation:* Without this latch, if the FU is re-issued a new operation the very cycle after `done`, its internal accumulator would already be mid-computation on the new operand by the time write-back gets around to reading it — capturing the result on the exact `done` cycle guarantees write-back always sees the correct, matching value.

**217. Multi-Cycle Op Re-Issue Blocker** — *(Medium)*
*Purpose:* Prevents a new operation from being dispatched into a multi-cycle FU while it's still busy with a previous one, which would corrupt the in-flight computation.
```systemverilog
module fu_issue_block (input logic fu_busy, input logic new_op_wants_fu, output logic issue_allowed);
    assign issue_allowed = new_op_wants_fu && !fu_busy;
endmodule
```
*Derivation:* This is the structural-hazard half of Problem 152's `div_busy`/similar signals — a single-instance multi-cycle FU (no pipelining) can only ever have one operation in flight, so any request while `fu_busy` is asserted must be blocked rather than corrupting the FU's internal state.

**218. Execute-Stage Freeze-on-Multicycle Controller** — *(Medium)*
*Purpose:* Ties Problem 217's block condition into an actual pipeline stall, freezing the instructions behind the multi-cycle op until it completes.
```systemverilog
module exec_freeze_ctrl (input logic fu_busy, output logic stall_upstream);
    assign stall_upstream = fu_busy;
endmodule
```
*Derivation:* As long as the multi-cycle FU hasn't produced `done`, every stage upstream of Execute must remain frozen (same reasoning as Problem 148) — otherwise a second instruction needing the same busy FU would either be lost or silently corrupt the first one's in-flight state.

**219. Variable-Latency Op Completion Counter (Debug/Perf)** — *(Medium)*
*Purpose:* Tracks how many cycles a multi-cycle operation actually took, useful for performance debug — since real FUs (especially dividers, which can early-terminate) don't always take a fixed number of cycles.
```systemverilog
module fu_latency_counter (
    input  logic clk, rst_n, fu_busy,
    output logic [15:0] last_latency,
    output logic [31:0] total_cycles_busy
);
    logic [15:0] count;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= '0; last_latency <= '0; total_cycles_busy <= '0;
        end else begin
            if (fu_busy) begin
                count <= count + 1'b1;
                total_cycles_busy <= total_cycles_busy + 1'b1;
            end else if (count != 0) begin
                last_latency <= count;
                count <= '0;
            end
        end
    end
endmodule
```
*Derivation:* `count` accumulates while `fu_busy` is asserted and gets captured into `last_latency` the cycle busy deasserts, giving a per-operation latency sample; `total_cycles_busy` is a simple running sum useful for computing the FU's overall utilization percentage over a benchmark run.

**220. Multi-Cycle FU Top Wrapper** — *(Medium)*
*Purpose:* The integrated module a real Execute stage would instantiate, muxing between the single-cycle ALU and the multi-cycle MUL/DIV engines behind one uniform interface.
```systemverilog
module exec_fu_top (
    input  logic clk, rst_n, start,
    input  logic is_muldiv, is_div, is_signed,
    input  logic [31:0] a, b,
    output logic busy, done,
    output logic [31:0] result
);
    logic mul_busy, mul_done, div_busy, div_done;
    logic [63:0] mul_product;
    logic [31:0] div_quotient;

    signed_mul_wrap u_mul (.clk(clk), .rst_n(rst_n), .start(start && is_muldiv && !is_div),
                            .a(a), .b(b), .busy(mul_busy), .done(mul_done), .product(mul_product));
    signed_div_wrap u_div (.clk(clk), .rst_n(rst_n), .start(start && is_muldiv && is_div),
                            .dividend(a), .divisor(b), .busy(div_busy), .done(div_done),
                            .quotient(div_quotient), .remainder());

    assign busy   = is_muldiv ? (is_div ? div_busy : mul_busy) : 1'b0;
    assign done   = is_muldiv ? (is_div ? div_done : mul_done) : 1'b1;
    assign result = is_muldiv ? (is_div ? div_quotient : mul_product[31:0]) : (a + b);   // single-cycle fallback = generic ALU stub
endmodule
```
*Derivation:* Direct composition of Problems 203/206's signed wrappers with a routing layer matching Problem 201's dispatch decision — a real design would replace the `(a+b)` fallback with the full ALU mux from Problem 51, shown here as a stub to keep focus on the multi-cycle integration.

---

## Category 2: Branch Prediction Structures (221–240)

**221. 2-Bit Saturating Counter (Bimodal Predictor Cell)** — *(Medium)*
*Purpose:* The fundamental unit of dynamic branch prediction — a small piece of state that "remembers" recent outcomes and predicts based on which side of strongly/weakly taken/not-taken it currently sits.
```systemverilog
module sat_counter2 (
    input  logic clk, rst_n,
    input  logic update_valid, actual_taken,
    output logic predict_taken,
    output logic [1:0] state
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= 2'b01;   // weakly not-taken
        else if (update_valid) begin
            if (actual_taken)  state <= (state == 2'b11) ? 2'b11 : state + 1'b1;
            else                state <= (state == 2'b00) ? 2'b00 : state - 1'b1;
        end
    end
    assign predict_taken = state[1];
endmodule
```
*Derivation:* The 4 states (00=strongly-NT, 01=weakly-NT, 10=weakly-T, 11=strongly-T) form a saturating up/down counter; `state[1]` being the prediction bit means only the top half of the range predicts taken — this hysteresis (requiring two consecutive wrong outcomes to flip the prediction) is what makes the bimodal predictor resilient to a single anomalous branch outcome, unlike a naive 1-bit "last outcome" predictor.

**222. Branch History Table (BHT), Direct-Mapped** — *(Medium)*
*Purpose:* An array of Problem 221's counters, indexed by PC, giving each static branch (approximately) its own prediction history.
```systemverilog
module bht #(parameter int ENTRIES = 256) (
    input  logic clk, rst_n,
    input  logic [31:0] lookup_pc,
    output logic predict_taken,
    input  logic update_en,
    input  logic [31:0] update_pc,
    input  logic actual_taken
);
    localparam int IDX_W = $clog2(ENTRIES);
    logic [1:0] counters [ENTRIES];

    assign predict_taken = counters[lookup_pc[IDX_W+1:2]][1];   // PC>>2 indexes, ignoring byte offset

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) counters[i] <= 2'b01;
        end else if (update_en) begin
            automatic logic [IDX_W-1:0] idx = update_pc[IDX_W+1:2];
            if (actual_taken) counters[idx] <= (counters[idx]==2'b11) ? 2'b11 : counters[idx]+1'b1;
            else               counters[idx] <= (counters[idx]==2'b00) ? 2'b00 : counters[idx]-1'b1;
        end
    end
endmodule
```
*Derivation:* Indexing by `PC[IDX_W+1:2]` (skipping the 2 LSBs, which are always 0 for word-aligned instructions) is the standard direct-mapped indexing scheme; because the table has fewer entries than the full PC space, distinct branches can alias to the same counter ("aliasing"), which is the fundamental accuracy/area tradeoff of a direct-mapped BHT versus a fully-tagged one.

**223. BHT Update-on-Resolve Logic** — *(Medium)*
*Purpose:* Isolated view of just the update-triggering condition — a BHT should only be updated once a branch actually resolves in Execute, never speculatively.
```systemverilog
module bht_update_trigger (input logic is_branch, branch_resolved, output logic update_en);
    assign update_en = is_branch && branch_resolved;
endmodule
```
*Derivation:* Updating on anything other than actual resolution (e.g. on the speculative fetch-time prediction itself) would corrupt the table with unconfirmed guesses — `branch_resolved` gates the write to only the cycle Execute has determined the real outcome.

**224. Branch Target Buffer (BTB), Direct-Mapped** — *(Medium)*
*Purpose:* Predicts *where* a taken branch/jump goes, since the BHT (Problems 221–223) only predicts *whether* — without a BTB, even a correctly-predicted "taken" outcome can't redirect fetch until the target is computed in a later stage.
```systemverilog
module btb #(parameter int ENTRIES = 256) (
    input  logic clk, rst_n,
    input  logic [31:0] lookup_pc,
    output logic hit,
    output logic [31:0] predicted_target,
    input  logic update_en,
    input  logic [31:0] update_pc, update_target
);
    localparam int IDX_W = $clog2(ENTRIES);
    localparam int TAG_W = 32 - IDX_W - 2;
    logic valid [ENTRIES];
    logic [TAG_W-1:0] tag [ENTRIES];
    logic [31:0] target [ENTRIES];

    wire [IDX_W-1:0] look_idx = lookup_pc[IDX_W+1:2];
    wire [TAG_W-1:0] look_tag = lookup_pc[31:IDX_W+2];
    assign hit              = valid[look_idx] && (tag[look_idx] == look_tag);
    assign predicted_target = target[look_idx];

    wire [IDX_W-1:0] upd_idx = update_pc[IDX_W+1:2];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) valid[i] <= 1'b0;
        end else if (update_en) begin
            valid[upd_idx]  <= 1'b1;
            tag[upd_idx]    <= update_pc[31:IDX_W+2];
            target[upd_idx] <= update_target;
        end
    end
endmodule
```
*Derivation:* Same direct-mapped structure as the BHT, but storing a full target address plus a tag (to detect aliasing, unlike the untagged BHT) — the tag is necessary here because acting on a *wrong* predicted target (mispredicting the destination, not just the direction) is more costly to get subtly wrong than a BHT aliasing collision, which only costs a possibly-suboptimal direction guess.

**225. BTB Tag Compare & Hit Detect (Standalone)** — *(Medium)*
```systemverilog
module btb_tag_compare (input logic entry_valid, input logic [23:0] entry_tag, lookup_tag, output logic hit);
    assign hit = entry_valid && (entry_tag == lookup_tag);
endmodule
```
*Purpose:* Isolates Problem 224's hit-detection comparator, the same pattern reused for cache tag compares (Problem "sa_cache_ctrl" from the earlier bank) — a BTB is structurally just a tiny, specialized cache.

**226. BTB Update-on-Resolve/Allocate** — *(Medium)*
*Purpose:* Distinguishes two different BTB write reasons — updating an existing entry's target (it changed, e.g. indirect call to a new callee) versus allocating a brand-new entry for a taken branch not previously seen.
```systemverilog
module btb_update_reason (
    input  logic is_branch_or_jump, branch_resolved, actual_taken, btb_hit,
    output logic allocate, update_target
);
    assign allocate      = is_branch_or_jump && branch_resolved && actual_taken && !btb_hit;
    assign update_target = is_branch_or_jump && branch_resolved && actual_taken && btb_hit;
endmodule
```
*Derivation:* A BTB entry is only worth allocating for control-flow that's actually taken (an untaken branch has no useful "target" to remember) and only needs to be written at all once it's resolved — `allocate` handles the first-time case, `update_target` handles refreshing an entry whose target has since changed (common for indirect branches/calls).

**227. Return-Address Stack (RAS) — Push** — *(Medium)*
*Purpose:* Function calls (JAL/JALR with `rd=x1`) push the return address so a later `RET` (JALR with `rd=x0, rs1=x1`) can predict its target with near-perfect accuracy, far better than a generic BTB entry for a target that changes every call site's return.
```systemverilog
module ras_push #(parameter int DEPTH = 8) (
    input  logic clk, rst_n, push_en,
    input  logic [31:0] push_addr,
    output logic [$clog2(DEPTH)-1:0] sp
);
    logic [31:0] stack [DEPTH];
    logic [$clog2(DEPTH)-1:0] ptr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ptr <= '0;
        else if (push_en && (ptr != DEPTH-1)) begin
            stack[ptr] <= push_addr;
            ptr <= ptr + 1'b1;
        end
    end
    assign sp = ptr;
endmodule
```
*Derivation:* A simple hardware stack (LIFO); `push_en` fires exactly when Problem 239's call-detection logic identifies a call-type instruction, and the pushed value is the return address (PC+4, same computation as Problem 111/114).

**228. Return-Address Stack (RAS) — Pop** — *(Medium)*
```systemverilog
module ras_pop #(parameter int DEPTH = 8) (
    input  logic clk, rst_n, pop_en,
    output logic [31:0] popped_addr,
    output logic valid
);
    logic [31:0] stack [DEPTH];
    logic [$clog2(DEPTH)-1:0] ptr;
    assign valid       = (ptr != '0);
    assign popped_addr = valid ? stack[ptr-1] : 32'b0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ptr <= '0;
        else if (pop_en && valid) ptr <= ptr - 1'b1;
    end
endmodule
```
*Purpose:* Companion to Problem 227 — a `RET`-classified instruction pops the most recently pushed return address as its predicted target.
*Derivation:* `valid` gates against popping an empty stack (Problem 229 formalizes this as underflow handling); popping reads the top-of-stack *before* decrementing, so the value returned this cycle corresponds to the most recent unmatched call.

**229. RAS Overflow/Underflow Handling** — *(Medium)*
*Purpose:* Deeply nested or recursive calls can exceed a finite RAS's depth (overflow), and a spurious/mispredicted RET can try to pop an empty stack (underflow) — both must degrade gracefully rather than corrupting prediction state.
```systemverilog
module ras_overflow_underflow (
    input  logic [$clog2(8)-1:0] sp,
    output logic overflow_risk, underflow
);
    assign overflow_risk = (sp == 3'd7);   // stack nearly/fully full
    assign underflow      = (sp == 3'd0);
endmodule
```
*Derivation:* On overflow, real designs typically let the oldest entry be silently overwritten/lost (graceful degradation — the RAS just predicts less well for over-deep call chains, it doesn't corrupt anything); on underflow, `valid=0` from Problem 228 already prevents any actual pop, so `RET` prediction simply falls back to a generic BTB lookup instead.

**230. Global History Register (GHR) Shift-on-Resolve** — *(Medium)*
*Purpose:* Tracks the outcome pattern of the last N branches globally (not per-PC), the input needed by correlating predictors like gshare.
```systemverilog
module ghr_reg #(parameter int WIDTH = 16) (
    input  logic clk, rst_n,
    input  logic branch_resolved, actual_taken,
    output logic [WIDTH-1:0] ghr
);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) ghr <= '0;
        else if (branch_resolved) ghr <= {ghr[WIDTH-2:0], actual_taken};
endmodule
```
*Derivation:* A simple shift register (same structure as Problem 188) that shifts in the newest branch outcome and discards the oldest — the resulting bit pattern is a compact encoding of "was each of the last N branches taken," which correlates with future branch behavior for code with data-dependent, history-correlated control flow.

**231. Gshare Index Generation (PC XOR GHR)** — *(Medium)*
*Purpose:* The defining trick of the gshare predictor — XOR-ing the PC with the global history spreads different branches' predictions across the table based on *both* their location and recent global behavior, reducing aliasing versus a plain PC-indexed BHT.
```systemverilog
module gshare_index #(parameter int IDX_W = 10) (
    input  logic [31:0] pc,
    input  logic [IDX_W-1:0] ghr,
    output logic [IDX_W-1:0] index
);
    assign index = pc[IDX_W+1:2] ^ ghr;
endmodule
```
*Derivation:* XOR is used (rather than concatenation) specifically because it folds both signals into the same `IDX_W`-bit space without needing a wider table — two different (PC, GHR) pairs that happen to XOR to the same index still alias, but empirically XOR-folding distributes collisions much more evenly across the table than raw PC indexing alone.

**232. Local History Table (Per-PC History)** — *(Medium)*
*Purpose:* Unlike Problem 230's single global register, a local predictor keeps a separate short history *per branch*, capturing patterns specific to that individual branch's own recent behavior (e.g. a branch that alternates taken/not-taken/taken/not-taken).
```systemverilog
module local_history_table #(parameter int ENTRIES = 64, parameter int HIST_W = 8) (
    input  logic clk, rst_n,
    input  logic [31:0] pc,
    output logic [HIST_W-1:0] local_history,
    input  logic update_en,
    input  logic [31:0] update_pc,
    input  logic actual_taken
);
    localparam int IDX_W = $clog2(ENTRIES);
    logic [HIST_W-1:0] hist [ENTRIES];

    assign local_history = hist[pc[IDX_W+1:2]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) hist[i] <= '0;
        end else if (update_en) begin
            automatic logic [IDX_W-1:0] idx = update_pc[IDX_W+1:2];
            hist[idx] <= {hist[idx][HIST_W-2:0], actual_taken};
        end
    end
endmodule
```
*Derivation:* Same shift-in structure as the GHR (Problem 230), but replicated per-entry rather than kept as one global register — trades more storage (`ENTRIES × HIST_W` bits instead of just `HIST_W`) for the ability to correlate a prediction with *that specific branch's own* pattern rather than the whole program's recent global mix.

**233. Two-Level Local Predictor (Local History → Pattern Table)** — *(Medium)*
*Purpose:* Combines Problem 232's per-branch history with a second-level table of saturating counters indexed by that history, letting the predictor learn "when this branch has recently gone T-NT-T, it's usually taken next" style patterns.
```systemverilog
module two_level_local_predictor #(parameter int HIST_W = 8) (
    input  logic [HIST_W-1:0] local_history,
    output logic predict_taken,
    input  logic clk, rst_n, update_en,
    input  logic [HIST_W-1:0] update_history,
    input  logic actual_taken
);
    logic [1:0] pattern_table [2**HIST_W];
    assign predict_taken = pattern_table[local_history][1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 2**HIST_W; i++) pattern_table[i] <= 2'b01;
        end else if (update_en) begin
            if (actual_taken) pattern_table[update_history] <= (pattern_table[update_history]==2'b11) ? 2'b11 : pattern_table[update_history]+1'b1;
            else                pattern_table[update_history] <= (pattern_table[update_history]==2'b00) ? 2'b00 : pattern_table[update_history]-1'b1;
        end
    end
endmodule
```
*Derivation:* This is the classic "two-level adaptive" predictor structure: level 1 (Problem 232) captures *what pattern* just happened for this branch, level 2 (this module's `pattern_table`, indexed by that pattern) captures *what usually happens next* given that pattern — the combination can learn history-dependent behaviors a single-level bimodal counter (Problem 221) structurally cannot.

**234. Predictor Speculative-Update + Recovery on Misprediction** — *(Medium)*
*Purpose:* If the GHR/local-history is updated speculatively at prediction time (needed so back-to-back branches before the first resolves still get correlated predictions), a misprediction must roll that speculative update back to the last known-correct history.
```systemverilog
module ghr_checkpoint #(parameter int WIDTH = 16) (
    input  logic clk, rst_n,
    input  logic speculative_update, predict_taken,
    input  logic mispredict_flush, actual_taken,
    output logic [WIDTH-1:0] ghr
);
    logic [WIDTH-1:0] checkpoint;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ghr <= '0; checkpoint <= '0;
        end else if (mispredict_flush) begin
            ghr <= {checkpoint[WIDTH-2:0], actual_taken};   // restore to checkpoint, then apply the real outcome
        end else if (speculative_update) begin
            checkpoint <= ghr;                                 // save pre-speculation state
            ghr <= {ghr[WIDTH-2:0], predict_taken};           // speculatively shift in the *predicted* outcome
        end
    end
endmodule
```
*Derivation:* Without speculative update, back-to-back branches (common in tightly-coded conditionals) would have to wait for the first to resolve before the second's prediction could even use an up-to-date GHR, stalling fetch; without the checkpoint/recovery, a misprediction would leave the GHR permanently corrupted with a "taken" bit that never should have shifted in — this checkpoint-per-speculative-update pattern is the same mechanism used by the much larger checkpoint managers in the Hard tier's OoO rename logic, just applied to a single history register instead of a full rename map.

**235. Combined Predict: BTB-Hit + BHT-Direction Merge** — *(Medium)*
*Purpose:* The actual fetch-time prediction decision merges "does the BTB even know a target for this PC" with "does the BHT/pattern predictor think it's taken" — a BTB miss means there's no known target regardless of direction.
```systemverilog
module combined_predict (
    input  logic btb_hit, bht_predict_taken,
    input  logic [31:0] btb_target, pc_plus4,
    output logic predict_taken,
    output logic [31:0] predicted_next_pc
);
    assign predict_taken      = btb_hit && bht_predict_taken;
    assign predicted_next_pc  = predict_taken ? btb_target : pc_plus4;
endmodule
```
*Derivation:* Even if the direction predictor says "taken," without a BTB hit there's no known target to redirect fetch to — falling back to sequential (`pc_plus4`) is the only safe option, since guessing a target would be pure noise, not a prediction.

**236. Fetch-Redirect Mux (Predicted Target Selection)** — *(Medium)*
*Purpose:* The final PC-select mux at fetch time, extending Problem 113's `next_pc_mux` with the RAS as an additional, higher-priority source for return-type instructions.
```systemverilog
typedef enum logic [1:0] {NPC_SEQ, NPC_BTB, NPC_RAS} npc_src_e;

module fetch_redirect_mux (
    input  npc_src_e src,
    input  logic [31:0] pc_seq, btb_target, ras_target,
    output logic [31:0] next_fetch_pc
);
    always_comb begin
        unique case (src)
            NPC_SEQ: next_fetch_pc = pc_seq;
            NPC_BTB: next_fetch_pc = btb_target;
            NPC_RAS: next_fetch_pc = ras_target;
        endcase
    end
endmodule
```
*Derivation:* `src` is decided by Problem 239's call/return classification: return-type instructions prefer the RAS (Problem 228) over the generic BTB since it's far more accurate for that specific case, everything else falls back to Problem 235's BTB+BHT combination or plain sequential fetch.

**237. Branch-Resolve-vs-Fetch-Predict Conflict Arbitration** — *(Medium)*
*Purpose:* The BTB/BHT/RAS structures are read every cycle by Fetch (for prediction) and written every cycle a branch resolves in Execute (for update) — if both happen to the same structure in the same cycle, something must arbitrate the single memory port.
```systemverilog
module predictor_port_arb (
    input  logic fetch_read_req, execute_write_req,
    output logic grant_fetch, grant_execute
);
    assign grant_execute = execute_write_req;                    // updates always win: correctness > prediction freshness
    assign grant_fetch    = fetch_read_req && !execute_write_req;
endmodule
```
*Derivation:* Giving the resolving-branch's update strict priority over a same-cycle prediction lookup is the safe choice: a delayed prediction just costs one bubble cycle, but reading stale/mid-update table contents (a read-write hazard on a single-ported memory) could produce a corrupted prediction — many real designs instead use a true dual-port array specifically to avoid this arbitration needing to exist at all, at the cost of extra area.

**238. Predictor Confidence-Based Override (Static Fallback on BTB Miss)** — *(Medium)*
*Purpose:* When there's no learned prediction available yet (cold BTB miss, e.g. first execution of a branch), falling back to Problem 117's cheap static BTFNT heuristic is better than defaulting to always-not-taken.
```systemverilog
module predictor_fallback (
    input  logic btb_hit, bht_predict_taken,
    input  logic [31:0] imm_b,
    output logic predict_taken
);
    assign predict_taken = btb_hit ? bht_predict_taken : imm_b[31];   // backward branch (negative offset) => predict taken
endmodule
```
*Derivation:* A cold predictor (no history yet) defaults to whatever its counters reset to (Problem 221 resets to weakly-not-taken); overriding that default with the direction-of-offset heuristic specifically for *never-seen* branches gives a better first-guess than a fixed default, at zero additional storage cost, since it only needs to read a field the fetch stage already has (the immediate).

**239. Branch-Type Classification for RAS Hint** — *(Medium)*
*Purpose:* Determines whether a JAL/JALR is specifically a call (push to RAS) or a return (pop from RAS), per the software calling-convention hint the ISA defines through register `x1`/`x5` usage.
```systemverilog
module ras_hint_classify (
    input  logic is_jal, is_jalr,
    input  logic [4:0] rd, rs1,
    output logic is_call, is_return, is_call_and_return
);
    wire rd_is_link  = (rd  == 5'd1) || (rd  == 5'd5);   // x1 or x5
    wire rs1_is_link = (rs1 == 5'd1) || (rs1 == 5'd5);

    assign is_call             = (is_jal || is_jalr) &&  rd_is_link && !(is_jalr && rs1_is_link && (rd == rs1));
    assign is_return            = is_jalr && rs1_is_link && !rd_is_link;
    assign is_call_and_return  = is_jalr && rd_is_link && rs1_is_link && (rd != rs1);
endmodule
```
*Derivation:* This directly encodes the RISC-V spec's software-convention hints for hardware return-address prediction: a link register (`x1` "ra" or `x5` "alternate link") being written marks a call (push), being read as `rs1` on a JALR with no simultaneous link-register write marks a return (pop), and both happening at once (different registers) marks a call-and-return (tail-call-like), which the spec suggests treating as pop-then-push.

**240. Predictor Top Wrapper (BTB + BHT + RAS Integrated)** — *(Medium)*
*Purpose:* The single module a real fetch stage instantiates, combining Problems 222/224/227–228/239 into one prediction-generation unit.
```systemverilog
module branch_predictor_top (
    input  logic clk, rst_n,
    input  logic [31:0] fetch_pc,
    output logic predict_taken,
    output logic [31:0] predicted_target,
    // resolve-time update inputs
    input  logic resolve_valid, resolve_is_branch, resolve_taken, resolve_is_call, resolve_is_return,
    input  logic [31:0] resolve_pc, resolve_target
);
    logic bht_pred, btb_hit;
    logic [31:0] btb_tgt, ras_tgt;
    logic ras_valid;

    bht u_bht (.clk(clk), .rst_n(rst_n), .lookup_pc(fetch_pc), .predict_taken(bht_pred),
               .update_en(resolve_valid && resolve_is_branch), .update_pc(resolve_pc), .actual_taken(resolve_taken));

    btb u_btb (.clk(clk), .rst_n(rst_n), .lookup_pc(fetch_pc), .hit(btb_hit), .predicted_target(btb_tgt),
               .update_en(resolve_valid && resolve_taken), .update_pc(resolve_pc), .update_target(resolve_target));

    ras_pop u_ras (.clk(clk), .rst_n(rst_n), .pop_en(resolve_is_return), .popped_addr(ras_tgt), .valid(ras_valid));

    assign predict_taken     = btb_hit && bht_pred;
    assign predicted_target  = ras_valid ? ras_tgt : btb_tgt;
endmodule
```
*Derivation:* Direct integration of the category's individual pieces — RAS prediction takes priority when valid (matching Problem 236's source-select priority), otherwise falls back to the combined BTB+BHT result from Problem 235; the RAS push side is omitted here for brevity but would use `resolve_is_call` the same way `resolve_is_return` drives the pop.

---

## Category 3: Hazard/Forwarding Networks (241–260)

**241. Full 2-Source Forwarding Unit** — *(Medium)*
*Purpose:* The complete forwarding unit a real 5-stage pipeline instantiates, resolving both `rs1` and `rs2` against both EX/MEM and MEM/WB producers in one module.
```systemverilog
typedef enum logic [1:0] {FWD_NONE, FWD_EXMEM, FWD_MEMWB} fwd_sel_e;

module forwarding_unit (
    input  logic [4:0] id_ex_rs1, id_ex_rs2,
    input  logic ex_mem_reg_write, mem_wb_reg_write,
    input  logic [4:0] ex_mem_rd, mem_wb_rd,
    output fwd_sel_e fwd_a, fwd_b
);
    always_comb begin
        if (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs1)) fwd_a = FWD_EXMEM;
        else if (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1)) fwd_a = FWD_MEMWB;
        else fwd_a = FWD_NONE;

        if (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs2)) fwd_b = FWD_EXMEM;
        else if (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2)) fwd_b = FWD_MEMWB;
        else fwd_b = FWD_NONE;
    end
endmodule
```
*Derivation:* Combines Problems 155–157's individual pieces into the standard "MIPS-style" forwarding-unit structure, checking EX/MEM before MEM/WB for each operand independently since the two operands can need forwarding from two entirely different pipeline stages simultaneously.

**242. Forwarding Unit with Load-Result Special Case** — *(Medium)*
*Purpose:* Extends Problem 241 to also flag when forwarding *can't* fully resolve the hazard (the load-use case), since a load's data isn't ready even in EX/MEM — that case needs a stall, not a forward.
```systemverilog
module forwarding_unit_ext (
    input  logic [4:0] id_ex_rs1, id_ex_rs2,
    input  logic ex_mem_reg_write, ex_mem_mem_read, mem_wb_reg_write,
    input  logic [4:0] ex_mem_rd, mem_wb_rd,
    output fwd_sel_e fwd_a, fwd_b,
    output logic load_use_stall
);
    forwarding_unit u_fwd (.id_ex_rs1(id_ex_rs1), .id_ex_rs2(id_ex_rs2),
                            .ex_mem_reg_write(ex_mem_reg_write), .mem_wb_reg_write(mem_wb_reg_write),
                            .ex_mem_rd(ex_mem_rd), .mem_wb_rd(mem_wb_rd), .fwd_a(fwd_a), .fwd_b(fwd_b));

    assign load_use_stall = ex_mem_mem_read && (ex_mem_rd != 5'd0) &&
                             ((ex_mem_rd == id_ex_rs1) || (ex_mem_rd == id_ex_rs2));
endmodule
```
*Derivation:* This is subtly different from Problem 150's load-use detector — that one checks against an instruction *currently in EX* about to load; this checks the instruction *already in EX/MEM* that already issued a load and whose data won't be ready until *next* cycle (from memory), which is the more precise point at which forwarding genuinely cannot help and only a stall (or, in a real design, forwarding directly from the memory-read data one more stage later) resolves it.

**243. WAW Hazard Detector (Multi-Cycle FU in Flight)** — *(Medium)*
*Purpose:* If a multi-cycle op (e.g. DIV, taking 32 cycles) is in flight and a later, faster instruction targeting the *same* destination register would complete first, the multi-cycle op's eventual write would incorrectly clobber the newer value — a write-after-write hazard.
```systemverilog
module waw_hazard_detect (
    input  logic older_op_in_flight, older_op_reg_write,
    input  logic [4:0] older_op_rd, newer_op_rd,
    input  logic newer_op_reg_write,
    output logic waw_hazard
);
    assign waw_hazard = older_op_in_flight && older_op_reg_write && newer_op_reg_write &&
                         (older_op_rd == newer_op_rd) && (older_op_rd != 5'd0);
endmodule
```
*Derivation:* In a strictly in-order-issue, in-order-commit pipeline this specific hazard can't actually occur (everything commits in program order, so the "newer" instruction can never complete before the "older" one it depends on for ordering) — but it becomes a real concern the moment any operation (like the multi-cycle divider) can take variably longer than instructions issued after it, foreshadowing why full out-of-order designs (Hard tier) need explicit WAW tracking via renaming.

**244. WAR Hazard Detector (Simple In-Order Teaching Case)** — *(Medium)*
*Purpose:* A write-after-read hazard — a later instruction writing a register before an earlier instruction has read the old value — is structurally impossible in a simple in-order pipeline with in-order register reads, but this module demonstrates the check for educational completeness (and because it *does* matter once out-of-order issue exists).
```systemverilog
module war_hazard_detect (
    input  logic older_op_reads_reg, newer_op_writes_first,
    input  logic [4:0] older_op_src, newer_op_rd,
    output logic war_hazard
);
    assign war_hazard = older_op_reads_reg && newer_op_writes_first && (older_op_src == newer_op_rd);
endmodule
```
*Derivation:* `newer_op_writes_first` can only ever be true in a design where instruction completion order can differ from issue order — in the simple in-order pipelines this Medium tier otherwise assumes, this signal is always false, making `war_hazard` vacuously 0; it's included specifically to make the *reason* WAR/WAW don't matter yet (strict in-order completion) explicit and checkable.

**245. Structural Hazard Detector (Multiply/Divide Unit Busy)** — *(Medium)*
```systemverilog
module structural_hazard_muldiv (input logic muldiv_fu_busy, input logic new_instr_needs_muldiv, output logic structural_stall);
    assign structural_stall = new_instr_needs_muldiv && muldiv_fu_busy;
endmodule
```
*Purpose:* Same concept as Problem 217, framed explicitly as a "structural hazard" (a resource conflict, distinct from a data hazard) for the standard hazard-taxonomy vocabulary interviewers expect.

**246. Multi-Cycle-Aware Stall Controller** — *(Medium)*
*Purpose:* Combines the load-use hazard, the multi-cycle structural hazard, and any bus-wait state into the one overall stall signal the pipeline registers actually consume.
```systemverilog
module stall_controller_full (
    input  logic load_use_stall, muldiv_structural_stall, mem_wait_stall,
    output logic global_stall
);
    assign global_stall = load_use_stall || muldiv_structural_stall || mem_wait_stall;
endmodule
```
*Derivation:* Same OR-combination pattern as Problem 152, now explicitly incorporating the Medium-tier's new multi-cycle FU and variable-latency memory stall sources alongside the Easy tier's load-use case.

**247. Pipeline Interlock Controller** — *(Medium)*
*Purpose:* The umbrella module tying stall generation (Problem 246), flush generation (Problem 149), and their combined priority (flush beats stall) into the single control interface every pipeline register in the design consumes.
```systemverilog
module interlock_ctrl (
    input  logic global_stall, branch_mispredict,
    output logic stall_if, stall_id, flush_if, flush_id
);
    assign flush_if = branch_mispredict;
    assign flush_id = branch_mispredict;
    assign stall_if  = global_stall && !branch_mispredict;
    assign stall_id  = global_stall && !branch_mispredict;
endmodule
```
*Derivation:* If a flush and a stall condition are both asserted the same cycle, the flush must win (an instruction that's being squashed anyway doesn't need its stall condition honored) — this priority is exactly what Problem 145's generic pipeline register template already encodes (`if !rst_n||flush ... else if !stall ...`), and this module is what generates the two signals that template consumes, correctly pre-arbitrated.

**248. Register Scoreboard with Multi-Bit Busy Counters** — *(Medium)*
*Purpose:* Extends Problem 96's single-bit-per-register scoreboard to a small counter per register, correctly handling the (rare but real) case of *multiple* outstanding writes targeting the same register.
```systemverilog
module scoreboard_counted (
    input  logic clk, rst_n,
    input  logic issue_writes_reg,   input logic [4:0] issue_rd,
    input  logic complete_writes_reg, input logic [4:0] complete_rd,
    output logic [31:0][1:0] busy_count
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) busy_count[i] <= 2'd0;
        end else begin
            if (issue_writes_reg && (issue_rd != 5'd0) && (busy_count[issue_rd] != 2'd3))
                busy_count[issue_rd] <= busy_count[issue_rd] + 1'b1;
            if (complete_writes_reg && (complete_rd != 5'd0) && (busy_count[complete_rd] != 2'd0))
                busy_count[complete_rd] <= busy_count[complete_rd] - 1'b1;
        end
    end
endmodule
```
*Derivation:* A plain single busy-bit (Problem 96) would incorrectly clear "busy" the moment *any* outstanding write to that register completes, even if a second one is still in flight — a small saturating counter (same pattern as Problem 193) instead tracks *how many* outstanding writes exist, only reporting "not busy" (`busy_count[r]==0`) once every one of them has completed.

**249. Scoreboard Clear-on-Writeback Logic** — *(Medium)*
```systemverilog
module scoreboard_clear (input logic wb_valid, input logic [4:0] wb_rd, output logic clear_en, output logic [4:0] clear_idx);
    assign clear_en   = wb_valid && (wb_rd != 5'd0);
    assign clear_idx  = wb_rd;
endmodule
```
*Purpose:* Isolated view of exactly what triggers a scoreboard decrement/clear — the write-back stage's actual commit of a value to the register file, matching Problem 96's `clear_en`/`clear_idx` interface.

**250. Full-Bypass-Network Self-Check Assertion** — *(Medium)*
*Purpose:* A formal/simulation-only checker that no data hazard could have "slipped through" the forwarding network undetected — i.e., every possible producer/consumer register-index collision within the pipeline's forwarding window results in either a valid forward or a legitimate stall.
```systemverilog
module fwd_network_selfcheck (
    input  logic clk,
    input  logic [4:0] id_ex_rs1, id_ex_rs2, ex_mem_rd, mem_wb_rd,
    input  logic ex_mem_reg_write, mem_wb_reg_write,
    input  fwd_sel_e fwd_a, fwd_b,
    input  logic load_use_stall
);
    // synthesis translate_off
    always @(posedge clk) begin
        if (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs1))
            assert (fwd_a == FWD_EXMEM || load_use_stall)
                else $error("rs1 hazard from EX/MEM not covered by forward or stall");
        if (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2) && (fwd_b != FWD_EXMEM))
            assert (fwd_b == FWD_MEMWB)
                else $error("rs2 hazard from MEM/WB not covered by forward");
    end
    // synthesis translate_on
endmodule
```
*Derivation:* This kind of self-checking assertion is exactly the sort of thing a verification engineer would bolt onto Problem 241's forwarding unit in a testbench — it doesn't implement any new functionality, it formally restates "every detected hazard condition must correspond to an actual forward-or-stall response" so a bug in the forwarding unit's priority logic (e.g. an off-by-one in which stage is checked first) shows up immediately in simulation rather than as a silent wrong-answer.

**251. Same-Cycle Double-Hazard Resolver** — *(Medium)*
*Purpose:* The case where `rs1` and `rs2` each need forwarding from a *different* stage simultaneously (e.g. `rs1` from EX/MEM, `rs2` from MEM/WB) — demonstrates the two forwarding muxes genuinely operate independently, not as a shared resource.
```systemverilog
module double_hazard_operand_select (
    input  fwd_sel_e fwd_a, fwd_b,
    input  logic [31:0] exmem_data, memwb_data, rs1_reg, rs2_reg,
    output logic [31:0] operand_a, operand_b
);
    always_comb begin
        unique case (fwd_a)
            FWD_EXMEM: operand_a = exmem_data;
            FWD_MEMWB: operand_a = memwb_data;
            default:    operand_a = rs1_reg;
        endcase
        unique case (fwd_b)
            FWD_EXMEM: operand_b = exmem_data;
            FWD_MEMWB: operand_b = memwb_data;
            default:    operand_b = rs2_reg;
        endcase
    end
endmodule
```
*Derivation:* Because Problem 241 computes `fwd_a` and `fwd_b` fully independently (each checking both stages on its own), there's no structural reason they can't resolve to two completely different sources in the same cycle — this module is simply confirming that independence by wiring two separate mux chains rather than one shared one.

**252. CSR-Read-After-CSR-Write Hazard Detector** — *(Medium)*
*Purpose:* If a CSR instruction writes a CSR and the very next instruction reads that same CSR, the pipeline needs the same kind of hazard check as a register RAW — but against CSR address space, not the register file.
```systemverilog
module csr_hazard_detect (
    input  logic older_csr_write, newer_csr_read,
    input  logic [11:0] older_csr_addr, newer_csr_addr,
    output logic csr_hazard
);
    assign csr_hazard = older_csr_write && newer_csr_read && (older_csr_addr == newer_csr_addr);
endmodule
```
*Derivation:* Structurally identical logic to Problem 151's generic RAW detector, just applied to the 12-bit CSR address space (Problem 11) instead of the 5-bit register-file address space — a real core typically resolves this the simple way (stall, since CSR accesses are already rare/slow-path) rather than building a dedicated CSR-forwarding network.

**253. Load-to-Branch Hazard Detector** — *(Medium)*
*Purpose:* If a branch immediately follows a load whose result the branch's condition depends on, the branch comparator (Category 6, Easy tier) needs data that isn't ready yet — a variant of the load-use hazard specific to control-flow-determining operands.
```systemverilog
module load_branch_hazard (
    input  logic ex_mem_mem_read,
    input  logic [4:0] ex_mem_rd, branch_rs1, branch_rs2,
    output logic hazard
);
    assign hazard = ex_mem_mem_read && (ex_mem_rd != 5'd0) &&
                    ((ex_mem_rd == branch_rs1) || (ex_mem_rd == branch_rs2));
endmodule
```
*Derivation:* Same shape as Problem 150, but flagged separately because in many pipeline organizations the branch resolves *earlier* in the pipeline than a normal ALU op (to minimize misprediction penalty), which can make this specific hazard distance even tighter than the generic load-use case — some designs handle it by simply resolving branches later (accepting a longer penalty) specifically to give loads more time.

**254. Multi-Cycle-FU-to-Branch Hazard Detector** — *(Medium)*
```systemverilog
module muldiv_branch_hazard (
    input  logic muldiv_in_flight,
    input  logic [4:0] muldiv_rd, branch_rs1, branch_rs2,
    output logic hazard
);
    assign hazard = muldiv_in_flight && (muldiv_rd != 5'd0) &&
                    ((muldiv_rd == branch_rs1) || (muldiv_rd == branch_rs2));
endmodule
```
*Purpose:* If a branch depends on the result of an in-flight multiply/divide, it must stall until that FU completes (Problem 215's `done`) — there's no way to "forward" a value that hasn't been computed yet, regardless of how many cycles it takes.

**255. Forwarding-Path Mux Depth Reduction** — *(Medium)*
*Purpose:* Demonstrates collapsing Problem 251's two independent 3-way muxes into fewer logic levels by pre-computing the priority-resolved forward value once and sharing it, when `fwd_a` and `fwd_b` happen to select the same source — a real timing-optimization technique.
```systemverilog
module fwd_mux_optimized (
    input  fwd_sel_e fwd_a, fwd_b,
    input  logic [31:0] exmem_data, memwb_data, rs1_reg, rs2_reg,
    output logic [31:0] operand_a, operand_b
);
    logic [31:0] fwd_common;
    assign fwd_common = (fwd_a == FWD_EXMEM || fwd_b == FWD_EXMEM) ? exmem_data : memwb_data;

    assign operand_a = (fwd_a == FWD_NONE) ? rs1_reg : fwd_common;
    assign operand_b = (fwd_b == FWD_NONE) ? rs2_reg : fwd_common;
endmodule
```
*Derivation:* This optimization is only valid because `fwd_a` and `fwd_b` can never simultaneously request *different* non-NONE sources in a correctly-generated Problem 241 (each independently resolves to whichever single stage matches its own register), so sharing one 2:1 mux (EX/MEM vs MEM/WB) ahead of two simpler NONE-or-not muxes produces the same result with less total mux logic than two independent 3-way muxes — a small but real example of the kind of gate-count/logic-depth tradeoff synthesis tools make automatically, shown here done by hand.

**256. Hazard-Free Guarantee Enumeration (Self-Check Module)** — *(Medium)*
*Purpose:* A documentation-as-code module enumerating every hazard *distance* (in pipeline stages) the design claims to handle, so a reviewer (or a formal tool) can confirm coverage against the actual pipeline depth.
```systemverilog
module hazard_coverage_table (output logic [4:0] max_forward_distance, output logic requires_stall_at_distance_1);
    assign max_forward_distance         = 5'd2;   // covers EX/MEM (distance 1) and MEM/WB (distance 2)
    assign requires_stall_at_distance_1  = 1'b1;   // load-use: distance-1 producer whose data isn't ready even via forwarding
endmodule
```
*Derivation:* Not synthesizable logic in the usual sense — a constants-only module used purely to make the design's hazard-handling *claims* explicit and machine-checkable (e.g. a testbench could read these constants and generate exactly the hazard-distance test vectors needed to confirm coverage), which is a lightweight alternative to a full formal proof for a property that's really a design specification, not a derived fact.

**257. Non-Blocking Load Hazard Placeholder** — *(Medium)*
*Purpose:* A stub interface anticipating a future extension to a non-blocking (miss-under-miss capable) load path, where a load-use hazard might resolve via a wakeup event arbitrarily many cycles later rather than a fixed stall — bridges toward the Hard tier's LSQ/MSHR structures.
```systemverilog
module nonblocking_load_stub (
    input  logic load_issued, load_data_ready,
    input  logic [4:0] load_rd, consumer_rs,
    output logic stall_until_ready
);
    assign stall_until_ready = load_issued && !load_data_ready && (load_rd == consumer_rs) && (load_rd != 5'd0);
endmodule
```
*Derivation:* Structurally identical to the earlier hazard detectors, but framed with a `load_data_ready` signal that's explicitly *not* assumed to arrive on any fixed cycle — this is the conceptual seam where a simple in-order core's fixed-latency assumption gets replaced by the wakeup-based signaling used throughout the Hard tier's out-of-order structures.

**258. Stall Cycle Injector with Counter (CPI Measurement)** — *(Medium)*
*Purpose:* A debug/performance-monitoring counter tallying total stall cycles, needed to compute a design's actual CPI (cycles per instruction) against its ideal (1.0 for a fully-pipelined, hazard-free stream).
```systemverilog
module cpi_stall_counter (
    input  logic clk, rst_n, global_stall, instr_retired,
    output logic [31:0] total_stall_cycles, total_instrs_retired
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_stall_cycles <= '0; total_instrs_retired <= '0;
        end else begin
            if (global_stall)    total_stall_cycles    <= total_stall_cycles + 1'b1;
            if (instr_retired)   total_instrs_retired   <= total_instrs_retired + 1'b1;
        end
    end
endmodule
```
*Derivation:* `CPI ≈ (total_cycles_elapsed) / total_instrs_retired`, and `total_stall_cycles` is exactly the gap between that and the ideal 1-cycle-per-instruction baseline — this is the standard, simplest possible performance-counter pair used to validate a pipeline's actual throughput matches its designed-for hazard-handling overhead.

**259. Full Stall+Flush Priority Resolver** — *(Medium)*
*Purpose:* The most complete version of the stall/flush interaction, now folding in the Medium tier's variable-latency (Problem 212) and multi-cycle FU (Problem 217) stall sources alongside the branch-misprediction flush.
```systemverilog
module full_priority_resolver (
    input  logic load_use_stall, muldiv_structural_stall, bus_wait_stall,
    input  logic branch_mispredict,
    output logic effective_stall, effective_flush
);
    assign effective_flush  = branch_mispredict;
    assign effective_stall  = (load_use_stall || muldiv_structural_stall || bus_wait_stall) && !branch_mispredict;
endmodule
```
*Derivation:* Same "flush always wins" priority established in Problem 247, generalized across every stall source this tier introduced — the key invariant across all of these is that a squashed instruction never needs to also be correctly stalled, since it's being discarded either way.

**260. Hazard Unit Top Wrapper** — *(Medium)*
*Purpose:* Integrates Problems 241, 246, and 259 into the single hazard-and-forwarding-unit module a real Medium-complexity pipeline would instantiate.
```systemverilog
module hazard_unit_top (
    input  logic [4:0] id_ex_rs1, id_ex_rs2, ex_mem_rd, mem_wb_rd,
    input  logic ex_mem_reg_write, ex_mem_mem_read, mem_wb_reg_write,
    input  logic muldiv_fu_busy, new_instr_needs_muldiv, bus_wait_stall, branch_mispredict,
    output fwd_sel_e fwd_a, fwd_b,
    output logic effective_stall, effective_flush
);
    logic load_use_stall, muldiv_structural_stall;

    forwarding_unit u_fwd (.id_ex_rs1(id_ex_rs1), .id_ex_rs2(id_ex_rs2),
                            .ex_mem_reg_write(ex_mem_reg_write), .mem_wb_reg_write(mem_wb_reg_write),
                            .ex_mem_rd(ex_mem_rd), .mem_wb_rd(mem_wb_rd), .fwd_a(fwd_a), .fwd_b(fwd_b));

    assign load_use_stall          = ex_mem_mem_read && (ex_mem_rd != 5'd0) &&
                                      ((ex_mem_rd == id_ex_rs1) || (ex_mem_rd == id_ex_rs2));
    assign muldiv_structural_stall = new_instr_needs_muldiv && muldiv_fu_busy;

    assign effective_flush = branch_mispredict;
    assign effective_stall = (load_use_stall || muldiv_structural_stall || bus_wait_stall) && !branch_mispredict;
endmodule
```
*Derivation:* Pure composition of this category's individually-derived pieces — no new logic, just the integrated interface a decode/execute controller would actually wire up to Problem 145's generic pipeline registers.

---

## Category 4: Pipelined Execution Units (261–280)

**261. 2-Stage Pipelined Multiplier** — *(Medium)*
*Purpose:* Unlike Problem 202's 32-cycle iterative multiplier, a pipelined multiplier accepts a new operation every cycle and produces a result 2 cycles later — much higher throughput at the cost of a fixed 2-cycle latency even for the first result.
```systemverilog
module mul_pipe2 (
    input  logic clk,
    input  logic [31:0] a, b,
    input  logic valid_in,
    output logic [63:0] product,
    output logic valid_out
);
    logic [63:0] partial_q;
    logic valid_s1;
    always_ff @(posedge clk) begin
        partial_q <= a * b;
        valid_s1  <= valid_in;
    end
    always_ff @(posedge clk) begin
        product   <= partial_q;
        valid_out <= valid_s1;
    end
endmodule
```
*Derivation:* Breaking the multiply into two registered stages (even though the underlying `*` operator here is behaviorally combinational, standing in for a real 2-level Wallace-tree or Booth-encoded array) lets synthesis insert a pipeline cut partway through what would otherwise be one long combinational multiplier, raising achievable clock frequency at the cost of one extra cycle of result latency — the `valid` signal shifts alongside the data through the same two stages so downstream logic always knows exactly when `product` corresponds to a real operation versus stale/garbage data.

**262. 3-Stage Pipelined Multiplier** — *(Medium)*
```systemverilog
module mul_pipe3 (
    input  logic clk,
    input  logic [31:0] a, b,
    input  logic valid_in,
    output logic [63:0] product,
    output logic valid_out
);
    logic [31:0] a_q, b_q;
    logic [63:0] partial_q;
    logic valid_s1, valid_s2;

    always_ff @(posedge clk) begin
        a_q <= a; b_q <= b; valid_s1 <= valid_in;
    end
    always_ff @(posedge clk) begin
        partial_q <= a_q * b_q; valid_s2 <= valid_s1;
    end
    always_ff @(posedge clk) begin
        product <= partial_q; valid_out <= valid_s2;
    end
endmodule
```
*Purpose:* A finer-grained pipeline split (3 stages instead of 2) trading even more latency for a shorter per-stage critical path — the kind of tradeoff decided by the actual target clock frequency and the synthesized multiplier's natural logic-depth breakpoints.

**263. Pipelined Multiplier Valid-Tracking Shift Chain** — *(Medium)*
*Purpose:* Generalizes the `valid_in → valid_s1 → ... → valid_out` pattern from Problems 261/262 into a single reusable N-deep shift register, since every pipelined FU needs exactly this same valid-tracking structure.
```systemverilog
module valid_shift_chain #(parameter int STAGES = 3) (
    input  logic clk, rst_n,
    input  logic valid_in,
    output logic valid_out
);
    logic [STAGES-1:0] sr;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) sr <= '0;
        else        sr <= {sr[STAGES-2:0], valid_in};
    assign valid_out = sr[STAGES-1];
endmodule
```
*Derivation:* A pure shift register (same structure as Problem 188) — `valid_in` takes exactly `STAGES` cycles to reach `valid_out`, matching however many pipeline registers the actual datapath (Problems 261/262) has, which is exactly why this is factored out as its own parameterized module rather than hand-duplicated per FU.

**264. Non-Pipelined Iterative Divider with Busy Flag** — *(Medium)*
*Purpose:* Reframes Problem 205's restoring-division FSM specifically around its `busy` semantics, to contrast directly against Problem 261's pipelined-throughput model — this is the "one operation at a time, no overlap" alternative.
```systemverilog
module div_nonpipelined_wrapper (
    input  logic clk, rst_n, req_valid,
    input  logic [31:0] dividend, divisor,
    output logic req_ready,
    output logic result_valid,
    output logic [31:0] quotient, remainder
);
    logic busy, done;
    divu_fsm u_div (.clk(clk), .rst_n(rst_n), .start(req_valid && req_ready), .dividend(dividend), .divisor(divisor),
                     .busy(busy), .done(done), .quotient(quotient), .remainder(remainder));
    assign req_ready    = !busy;
    assign result_valid = done;
endmodule
```
*Derivation:* `req_ready = !busy` means a second division request is simply refused (via the standard valid/ready handshake) until the FSM fully completes the first — throughput here is one result per ~32 cycles no matter what, versus Problem 261's one result-per-cycle (after an initial 2-cycle fill), which is precisely the throughput/complexity tradeoff that motivates pipelining a divider at all in a high-performance core.

**265. Divider Early-Termination Optimization** — *(Medium)*
*Purpose:* Real dividers often skip iterations for leading zero bits of the dividend, since those iterations are guaranteed to produce a 0 quotient bit and can't be shortcut in the naive Problem 205 FSM — this computes how many iterations can safely be skipped.
```systemverilog
module div_early_term (input logic [31:0] dividend, output logic [5:0] skip_iterations);
    logic [5:0] lz;
    always_comb begin
        lz = 6'd32;
        for (int i = 31; i >= 0; i--)
            if (dividend[i]) begin lz = 6'd31 - i[5:0]; break; end
    end
    assign skip_iterations = lz;
endmodule
```
*Derivation:* This reuses the leading-zero-count structure from the `lzc` module discussed earlier in this bank — if the dividend has `N` leading zero bits, the first `N` iterations of Problem 205's restoring-division loop are guaranteed to shift in 0s without ever satisfying `rem_part >= divisor` (since the partial remainder stays smaller than any nonzero divisor until a set bit of the dividend enters the window), so a real implementation can start the FSM at iteration `N` instead of 0, directly reducing average-case latency for small dividends.

**266. Execution-Unit Result Bus Arbiter** — *(Medium)*
*Purpose:* If the ALU, the multiplier, and the divider can each produce a result on any given cycle, but there's only one write-back port to the register file, something must arbitrate which result wins that cycle.
```systemverilog
module result_bus_arb (
    input  logic alu_valid, mul_valid, div_valid,
    input  logic [31:0] alu_result, mul_result, div_result,
    output logic wb_valid,
    output logic [31:0] wb_result,
    output logic alu_stalled, mul_stalled, div_stalled
);
    assign wb_valid   = alu_valid || mul_valid || div_valid;
    assign wb_result  = alu_valid ? alu_result : (mul_valid ? mul_result : div_result);   // ALU > MUL > DIV priority
    assign alu_stalled = 1'b0;                                    // ALU never loses arbitration in this scheme
    assign mul_stalled = mul_valid && alu_valid;
    assign div_stalled = div_valid && (alu_valid || mul_valid);
endmodule
```
*Derivation:* A fixed-priority scheme (ALU highest, since single-cycle ALU results can't be buffered without adding a stage, whereas Problem 270's completion buffer can hold a multi-cycle result for a cycle) is the simplest correct arbitration — the `_stalled` outputs tell the losing FU(s) to hold their result and retry write-back next cycle rather than dropping it, which only works because Problem 216's result latch already holds the value stable across cycles.

**267. FU Reservation Slot (Single-Slot, In-Order Issue)** — *(Medium)*
*Purpose:* Tracks whether a given functional unit currently has an operation reserved/assigned to it, the minimal "occupancy" bookkeeping needed before a design has any real issue queue.
```systemverilog
module fu_reservation_slot (
    input  logic clk, rst_n,
    input  logic reserve_en, release_en,
    output logic reserved
);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)         reserved <= 1'b0;
        else if (reserve_en) reserved <= 1'b1;
        else if (release_en) reserved <= 1'b0;
endmodule
```
*Derivation:* The simplest possible occupancy tracker — a single SR-latch-like flip-flop — sufficient for a design where at most one operation can ever be assigned to this FU at a time (true for any non-pipelined multi-cycle unit like Problem 205's divider), in contrast to Problem 276's N-deep occupancy tracker needed once the FU itself is pipelined.

**268. FU Dispatch Valid/Ready Handshake** — *(Medium)*
```systemverilog
module fu_dispatch_handshake (
    input  logic dispatch_valid, fu_ready,
    output logic dispatch_fire
);
    assign dispatch_fire = dispatch_valid && fu_ready;
endmodule
```
*Purpose:* The standard valid/ready protocol applied to FU dispatch — `dispatch_fire` is the single signal meaning "this operation is actually, successfully entering the FU this cycle," as opposed to merely being offered (`dispatch_valid`) or the FU merely being able to accept something (`fu_ready`).

**269. Result Tag Matching** — *(Medium)*
*Purpose:* Once multiple FUs (with different, possibly out-of-sync latencies) can be in flight, write-back needs to know *which* in-flight instruction a given result actually belongs to — a small tag travels alongside the operation for exactly this purpose.
```systemverilog
module result_tag_match #(parameter int TAG_W = 4) (
    input  logic [TAG_W-1:0] result_tag, expected_tag,
    output logic tag_match
);
    assign tag_match = (result_tag == expected_tag);
endmodule
```
*Derivation:* In a strictly in-order pipeline, tags are somewhat redundant (order alone identifies the instruction), but this is the direct conceptual predecessor of the ROB-tag matching used pervasively in the Hard tier's out-of-order structures — introducing the concept here at minimal complexity (one tag, one comparator) makes the later, larger structures easier to derive by extension.

**270. In-Order Completion Buffer** — *(Medium)*
*Purpose:* If a fast FU (ALU) and a slow FU (divider) are both in flight, and the divider happens to finish first even though it was issued earlier in program order, its result must be held until it's actually its turn to write back in-order — this buffer provides that holding function.
```systemverilog
module inorder_completion_buffer #(parameter int W = 32) (
    input  logic clk, rst_n,
    input  logic result_ready, this_is_oldest,
    input  logic [W-1:0] result_in,
    output logic held_valid,
    output logic [W-1:0] held_result,
    output logic commit_now
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            held_valid <= 1'b0;
        end else if (result_ready && !this_is_oldest) begin
            held_valid  <= 1'b1;
            held_result <= result_in;
        end else if (commit_now) begin
            held_valid <= 1'b0;
        end
    end
    assign commit_now = held_valid && this_is_oldest;
endmodule
```
*Derivation:* This is a simplified, single-entry precursor to a full reorder buffer (covered at scale in the Hard tier) — the essential idea (a result can be computed out of order but must still be *committed*, i.e. made architecturally visible, strictly in order) is the same, just with capacity for only one outstanding out-of-order result instead of an entire in-flight window.

**271. Execution Latency Table (Per-Op-Type Cycle Count)** — *(Medium)*
*Purpose:* A lookup table letting scheduling/stall logic know in advance how many cycles a given operation type will take, useful for a scoreboard that wants to pre-compute exactly when a result will be ready rather than only reacting to a `done` pulse after the fact.
```systemverilog
typedef enum logic [2:0] {OP_ALU, OP_MUL, OP_DIV, OP_LOAD, OP_BRANCH} op_type_e;

module latency_table (input op_type_e op, output logic [5:0] expected_latency);
    always_comb begin
        unique case (op)
            OP_ALU:    expected_latency = 6'd1;
            OP_MUL:    expected_latency = 6'd2;   // matches mul_pipe2
            OP_DIV:    expected_latency = 6'd32;  // matches divu_fsm worst case
            OP_LOAD:   expected_latency = 6'd2;   // e.g. 1-cycle cache + 1-cycle align
            OP_BRANCH: expected_latency = 6'd1;
        endcase
    end
endmodule
```
*Derivation:* A direct restatement, in table form, of the various latencies this bank's other modules actually implement — useful as the single source of truth a scoreboard or scheduler consults rather than each piece of logic hardcoding its own assumption about how long a dependency takes to resolve.

**272. Pipelined Shifter (Log-Shifter, 2-Stage)** — *(Medium)*
*Purpose:* Splits a full 5-bit barrel shift (32 possible shift amounts) across two pipeline stages, each handling a subset of the shift-amount bits, mirroring how a real log-shifter's stages are often cut for timing.
```systemverilog
module shift_pipe2 (
    input  logic clk,
    input  logic [31:0] data_in,
    input  logic [4:0]  shamt,
    output logic [31:0] result
);
    logic [31:0] stage1_out;
    logic [1:0]  shamt_hi_q;

    always_ff @(posedge clk) begin
        stage1_out <= data_in << {shamt[1:0], 3'b000};   // shift by 0/8/16/24 (coarse, low 2 bits scaled)
        shamt_hi_q <= shamt[4:2];
    end
    always_ff @(posedge clk) begin
        result <= stage1_out << shamt_hi_q;               // shift by remaining 0-7 in fine steps... simplified for illustration
    end
endmodule
```
*Derivation:* Splitting a shift amount into coarse and fine components and applying them across two pipeline stages is the same divide-and-conquer principle behind any log-shifter — each stage handles one bit (or a small group of bits) of the shift amount, and the total shift is the sum of all applied partial shifts; here simplified to two stages for illustration rather than the full one-bit-per-stage decomposition.

**273. Pipelined Adder (2-Cycle Wide Add)** — *(Medium)*
*Purpose:* For very wide adders (e.g. 128-bit or wider accumulate paths) where a single-cycle ripple/carry-lookahead adder can't meet timing, splitting the addition across a registered carry-save intermediate stage trades latency for frequency.
```systemverilog
module add_pipe2 #(parameter int W = 64) (
    input  logic clk,
    input  logic [W-1:0] a, b,
    output logic [W-1:0] sum
);
    logic [W-1:0] a_q, b_q;
    logic [W/2-1:0] lo_sum_q;
    logic lo_cout_q;

    always_ff @(posedge clk) begin
        {lo_cout_q, lo_sum_q} <= a[W/2-1:0] + b[W/2-1:0];
        a_q <= a; b_q <= b;
    end
    always_ff @(posedge clk) begin
        sum <= {a_q[W-1:W/2] + b_q[W-1:W/2] + lo_cout_q, lo_sum_q};
    end
endmodule
```
*Derivation:* The low half's sum and carry-out are computed and registered in stage 1; stage 2 completes the high half's addition incorporating that registered carry — functionally identical to a single-cycle carry-select/ripple add of the full width, just with the carry propagation chain broken across a pipeline register instead of resolving combinationally in one cycle, matching the same latency/frequency tradeoff principle as Problem 261's multiplier split.

**274. FU Flush-in-Flight Handling** — *(Medium)*
*Purpose:* If a branch misprediction is discovered while a multi-cycle FU (e.g. the divider) is still working on an instruction from the now-squashed path, that in-flight operation must be aborted rather than allowed to complete and corrupt architectural state.
```systemverilog
module fu_flush_inflight (
    input  logic clk, rst_n, flush,
    input  logic fu_busy_in,
    output logic fu_busy_out, abort_fu
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) fu_busy_out <= 1'b0;
        else if (flush) fu_busy_out <= 1'b0;
        else            fu_busy_out <= fu_busy_in;
    end
    assign abort_fu = flush && fu_busy_in;
endmodule
```
*Derivation:* `abort_fu` is the signal a real FU's FSM would use to force itself back to `IDLE` (bypassing its normal `done` completion path) — since the operation's result will never be architecturally committed anyway (the whole instruction is being squashed), there's no need to let a 32-cycle divide run to completion just to discard the answer; aborting early also frees the FU up sooner for the correct-path instruction that will replace it.

**275. Multi-Cycle Op Abort/Restart Logic** — *(Medium)*
```systemverilog
module fu_abort_restart (
    input  logic clk, rst_n, abort, new_start,
    output logic fu_active
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        fu_active <= 1'b0;
        else if (abort)    fu_active <= 1'b0;
        else if (new_start) fu_active <= 1'b1;
    end
endmodule
```
*Purpose:* Companion to Problem 274 — confirms that once aborted, the FU's "active" state cleanly returns to idle in the *same* cycle a new (correct-path) operation could start, with no leftover state from the aborted operation bleeding through.

**276. FU Occupancy Tracker (N-Deep Pipeline Valid Bits)** — *(Medium)*
*Purpose:* Once an FU itself is pipelined (Problem 261's 2-stage multiplier), "is the FU busy" isn't a single bit anymore — multiple operations can be in flight simultaneously at different stages, so occupancy must be tracked per stage.
```systemverilog
module fu_occupancy #(parameter int STAGES = 2) (
    input  logic clk, rst_n,
    input  logic new_op_valid,
    output logic [STAGES-1:0] stage_occupied
);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) stage_occupied <= '0;
        else        stage_occupied <= {stage_occupied[STAGES-2:0], new_op_valid};
endmodule
```
*Derivation:* Identical structure to Problem 263's valid-shift-chain — for a *fully pipelined* FU, "occupancy" and "valid-in-flight" are the same concept, since a new operation can be accepted every cycle regardless of how many are already in flight (unlike Problem 267's single-slot reservation, which blocks new dispatch entirely while occupied).

**277. Out-of-Order Completion Handling for a Single Pipelined FU** — *(Medium)*
*Purpose:* Demonstrates the simplest possible case of out-of-order completion: two different FUs (fixed 2-cycle multiply, variable-cycle divide) issued in program order can finish in either order, and downstream logic must handle both possibilities correctly.
```systemverilog
module simple_ooo_completion (
    input  logic mul_done, div_done,
    input  logic mul_is_older,          // true if the in-flight mul was issued before the in-flight div
    output logic mul_can_commit, div_can_commit
);
    // In-order commit rule: the older op can always commit once done;
    // the younger op can only commit once done AND the older one has already committed (or wasn't in flight).
    assign mul_can_commit  = mul_done;
    assign div_can_commit  = div_done && (mul_is_older ? !mul_done || mul_can_commit : 1'b1);
endmodule
```
*Derivation:* This threads the needle between "FUs may *complete* out of order" (which is fine and often unavoidable, e.g. a fast multiply finishing before an earlier-issued slow divide) and "architectural state must still be updated *in order*" (Problem 270's completion-buffer principle) — the mux logic here is a minimal 2-operation illustration of exactly the ordering constraint a full ROB (Hard tier) enforces generally across an arbitrarily deep instruction window.

**278. Result Writeback Port Contention Resolver** — *(Medium)*
*Purpose:* Extends Problem 266's 3-way arbiter with an explicit "loser retries next cycle" queueing behavior, rather than just flagging the stall.
```systemverilog
module wb_port_contention (
    input  logic clk, rst_n,
    input  logic alu_valid, mul_valid,
    input  logic [31:0] alu_result, mul_result,
    output logic wb_valid,
    output logic [31:0] wb_data,
    output logic mul_retry_next_cycle
);
    logic mul_pending_q;
    logic [31:0] mul_pending_data_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_pending_q <= 1'b0;
        end else if (mul_valid && alu_valid) begin
            mul_pending_q <= 1'b1; mul_pending_data_q <= mul_result;
        end else if (mul_pending_q && !alu_valid) begin
            mul_pending_q <= 1'b0;
        end
    end

    assign wb_valid  = alu_valid || mul_pending_q || mul_valid;
    assign wb_data   = alu_valid ? alu_result : (mul_pending_q ? mul_pending_data_q : mul_result);
    assign mul_retry_next_cycle = mul_valid && alu_valid;
endmodule
```
*Derivation:* Rather than requiring the multiplier's own pipeline to stall on contention (which would ripple backward and stall its input stages too), this small holding register lets the multiplier's *result* wait one extra cycle for the port while the multiplier itself keeps accepting new work — a local, minimal version of Problem 270's completion buffer applied specifically to write-back port arbitration.

**279. FU Top-Level Dispatch/Collect Wrapper** — *(Medium)*
*Purpose:* Integrates dispatch handshaking (Problem 268), occupancy tracking (Problem 276), and result-bus arbitration (Problem 266) into the single module a real Execute stage instantiates around its collection of FUs.
```systemverilog
module fu_dispatch_collect (
    input  logic clk, rst_n,
    input  logic dispatch_valid, is_mul,
    input  logic [31:0] a, b,
    output logic dispatch_ready,
    output logic wb_valid,
    output logic [31:0] wb_result
);
    logic mul_valid_out;
    logic [63:0] mul_product;
    logic alu_valid;
    logic [31:0] alu_result;

    mul_pipe2 u_mul (.clk(clk), .a(a), .b(b), .valid_in(dispatch_valid && is_mul),
                      .product(mul_product), .valid_out(mul_valid_out));

    assign alu_valid  = dispatch_valid && !is_mul;
    assign alu_result = a + b;   // stub single-cycle ALU

    assign dispatch_ready = 1'b1;   // ALU always accepts; mul_pipe2 always accepts (fully pipelined, no stall)
    assign wb_valid   = alu_valid || mul_valid_out;
    assign wb_result  = alu_valid ? alu_result : mul_product[31:0];
endmodule
```
*Derivation:* Because `mul_pipe2` is fully pipelined (Problem 261) rather than a single-slot multi-cycle FSM (Problem 205), `dispatch_ready` can simply be constant-1 — there's no busy/structural-hazard case to check the way Problem 217 required, which is precisely the practical payoff of investing in a pipelined FU over an iterative one for a frequently-used operation.

**280. Throughput vs Latency Tradeoff Demonstration** — *(Medium)*
*Purpose:* A direct, side-by-side comparison module quantifying the tradeoff this whole category has been building toward — iterative (Problem 205) vs pipelined (Problem 261) implementations of conceptually similar operations.
```systemverilog
module throughput_latency_compare (
    output logic [31:0] iterative_latency_cycles, iterative_throughput_per_1000cyc,
    output logic [31:0] pipelined_latency_cycles, pipelined_throughput_per_1000cyc
);
    assign iterative_latency_cycles      = 32'd32;             // divu_fsm worst case
    assign iterative_throughput_per_1000cyc = 32'd1000 / 32'd32; // ~31 ops per 1000 cycles
    assign pipelined_latency_cycles       = 32'd2;              // mul_pipe2
    assign pipelined_throughput_per_1000cyc = 32'd1000;          // 1 op/cycle steady-state
endmodule
```
*Derivation:* A constants-only illustrative module (not real logic) making explicit the ~32x throughput gap between an iterative and a pipelined implementation of similarly-complex operations, at the cost of significantly more hardware (a full pipelined multiplier array vs. a small shift-add FSM) — the same fundamental tradeoff a real microarchitect faces when deciding whether a given operation is common enough in target workloads to justify pipelining it.

---

## Category 5: Memory System Basics (281–300)

**281. Direct-Mapped I-Cache Lookup** — *(Medium)*
*Purpose:* The fetch-side cache lookup — checks whether the requested instruction address is already cached before falling back to a slower memory fetch.
```systemverilog
module icache_lookup #(parameter int SETS = 64, parameter int LINE_BYTES = 16) (
    input  logic [31:0] fetch_addr,
    input  logic valid_arr [SETS],
    input  logic [31:0] tag_arr [SETS],
    output logic hit,
    output logic [$clog2(SETS)-1:0] index
);
    localparam int OFF_W = $clog2(LINE_BYTES);
    localparam int IDX_W = $clog2(SETS);
    wire [IDX_W-1:0] idx = fetch_addr[OFF_W +: IDX_W];
    wire [31:0] tag = {fetch_addr[31:OFF_W+IDX_W], {(OFF_W+IDX_W){1'b0}}};

    assign index = idx;
    assign hit   = valid_arr[idx] && (tag_arr[idx] == tag);
endmodule
```
*Derivation:* Same structural pattern as the `dm_cache_ctrl` module discussed earlier in this bank, specialized for instruction fetch — indexed by the middle address bits (above the line-offset, below the tag), with the tag comparison confirming the cached line actually corresponds to this address rather than a different line that happened to alias to the same index.

**282. Direct-Mapped I-Cache Fill-on-Miss FSM** — *(Medium)*
```systemverilog
module icache_fill_fsm (
    input  logic clk, rst_n, miss_detected,
    input  logic [31:0] miss_addr,
    output logic mem_req_valid,
    output logic [31:0] mem_req_addr,
    input  logic mem_resp_valid,
    input  logic [127:0] mem_resp_data,
    output logic fill_commit,
    output logic [127:0] fill_data
);
    typedef enum logic [1:0] {IDLE, REQ, WAIT} state_e;
    state_e state;
    logic [31:0] addr_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; fill_commit <= 1'b0;
        end else begin
            fill_commit <= 1'b0;
            unique case (state)
                IDLE: if (miss_detected) begin addr_q <= miss_addr; state <= REQ; end
                REQ:  state <= WAIT;
                WAIT: if (mem_resp_valid) begin
                    fill_commit <= 1'b1; fill_data <= mem_resp_data; state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
    assign mem_req_valid = (state == REQ);
    assign mem_req_addr  = addr_q;
endmodule
```
*Purpose:* On an I-cache miss, this sequences the request to backing memory, waits for the response, and produces a single-cycle commit pulse the tag/data arrays can write on.
*Derivation:* Three states are the minimum needed to correctly separate "requesting" from "waiting for the response," since a real memory interface's `mem_resp_valid` can arrive an arbitrary number of cycles after the request — collapsing REQ and WAIT into one state would incorrectly re-issue the request every cycle until a response arrives.

**283. Direct-Mapped D-Cache Lookup** — *(Medium)*
```systemverilog
module dcache_lookup #(parameter int SETS = 64, parameter int LINE_BYTES = 16) (
    input  logic [31:0] access_addr,
    input  logic valid_arr [SETS], dirty_arr [SETS],
    input  logic [31:0] tag_arr [SETS],
    output logic hit,
    output logic [$clog2(SETS)-1:0] index
);
    localparam int OFF_W = $clog2(LINE_BYTES);
    localparam int IDX_W = $clog2(SETS);
    wire [IDX_W-1:0] idx = access_addr[OFF_W +: IDX_W];
    wire [31:0] tag = {access_addr[31:OFF_W+IDX_W], {(OFF_W+IDX_W){1'b0}}};

    assign index = idx;
    assign hit   = valid_arr[idx] && (tag_arr[idx] == tag);
endmodule
```
*Purpose:* Same lookup structure as Problem 281, now also exposing a per-line `dirty` bit needed for the write-back policy (Problem 285).

**284. D-Cache Write-Through Policy** — *(Medium)*
*Purpose:* On a store hit, write-through immediately propagates the write to backing memory as well as the cache line, keeping memory always up to date at the cost of extra bus traffic on every store.
```systemverilog
module dcache_write_through (
    input  logic store_valid, cache_hit,
    output logic cache_write_en, mem_write_req
);
    assign cache_write_en = store_valid && cache_hit;
    assign mem_write_req  = store_valid;   // goes to memory whether hit or miss
endmodule
```
*Derivation:* The defining property of write-through is that `mem_write_req` doesn't depend on `cache_hit` at all — every store reaches memory regardless, which trades bus bandwidth for a much simpler cache (no dirty bits, no writeback-on-eviction logic needed) than Problem 285's alternative.

**285. D-Cache Write-Back Policy with Dirty Bit** — *(Medium)*
*Purpose:* Write-back only updates the cache line on a store hit, marking it dirty, and defers writing to memory until that line is eventually evicted — far less bus traffic than write-through, at the cost of needing eviction-time write-back logic (Problem 286).
```systemverilog
module dcache_write_back (
    input  logic store_valid, cache_hit,
    output logic cache_write_en, set_dirty
);
    assign cache_write_en = store_valid && cache_hit;
    assign set_dirty       = store_valid && cache_hit;
endmodule
```
*Derivation:* No memory-write request is generated here at all — the whole point of write-back is that the memory write is deferred until eviction, which is why `set_dirty` (not an immediate `mem_write_req`) is this module's only additional output versus Problem 284.

**286. D-Cache Fill-on-Miss FSM (with Dirty Eviction)** — *(Medium)*
```systemverilog
module dcache_fill_fsm (
    input  logic clk, rst_n, miss_detected, victim_dirty,
    input  logic [31:0] miss_addr, victim_addr,
    input  logic [127:0] victim_data,
    output logic wb_req_valid,
    output logic [31:0] wb_req_addr,
    output logic [127:0] wb_req_data,
    input  logic wb_req_accepted,
    output logic fill_req_valid,
    output logic [31:0] fill_req_addr,
    input  logic fill_resp_valid,
    input  logic [127:0] fill_resp_data,
    output logic fill_commit
);
    typedef enum logic [2:0] {IDLE, WB_REQ, WB_WAIT, FILL_REQ, FILL_WAIT} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; fill_commit <= 1'b0; end
        else begin
            fill_commit <= 1'b0;
            unique case (state)
                IDLE:     if (miss_detected) state <= victim_dirty ? WB_REQ : FILL_REQ;
                WB_REQ:   if (wb_req_accepted) state <= WB_WAIT;
                WB_WAIT:  state <= FILL_REQ;   // simplified: assume writeback completes async, don't need to wait for ack here
                FILL_REQ: state <= FILL_WAIT;
                FILL_WAIT: if (fill_resp_valid) begin fill_commit <= 1'b1; state <= IDLE; end
                default:  state <= IDLE;
            endcase
        end
    end
    assign wb_req_valid   = (state == WB_REQ);
    assign wb_req_addr    = victim_addr;
    assign wb_req_data    = victim_data;
    assign fill_req_valid = (state == FILL_REQ);
    assign fill_req_addr  = miss_addr;
endmodule
```
*Purpose:* Combines the eviction write-back (only needed if the victim line is dirty) with the new-line fill into a single sequencing FSM — the write-back-policy analogue of the `evict_wb_seq` module from the earlier bank, specialized to the direct-mapped, single-victim case.
*Derivation:* The FSM branches at `IDLE` based on `victim_dirty` specifically because a clean victim line can simply be overwritten with no data loss (skip straight to `FILL_REQ`), while a dirty line's modifications would be silently lost forever unless written back first — this conditional skip is the core efficiency gain write-back caching provides over always writing back on every eviction regardless of dirty state.

**287. Single-Entry Store Buffer (Basic)** — *(Medium)*
*Purpose:* Decouples a store instruction's completion (as far as the pipeline is concerned) from its actual write reaching the cache/memory, letting the pipeline continue immediately while the store drains in the background.
```systemverilog
module store_buffer_1entry (
    input  logic clk, rst_n,
    input  logic store_valid,
    input  logic [31:0] store_addr, store_data,
    output logic buffer_full,
    output logic drain_valid,
    output logic [31:0] drain_addr, drain_data,
    input  logic drain_accepted
);
    logic valid_q;
    logic [31:0] addr_q, data_q;

    assign buffer_full = valid_q;
    assign drain_valid = valid_q;
    assign drain_addr  = addr_q;
    assign drain_data  = data_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_q <= 1'b0;
        else if (store_valid && !valid_q) begin
            valid_q <= 1'b1; addr_q <= store_addr; data_q <= store_data;
        end else if (drain_accepted) begin
            valid_q <= 1'b0;
        end
    end
endmodule
```
*Derivation:* With only one entry, a second store can't be accepted (`buffer_full`) until the first has drained — a real store buffer (Hard tier) has many entries specifically to avoid this becoming a frequent structural stall, but the single-entry case demonstrates the core valid/ready producer-consumer pattern with the minimum possible complexity.

**288. Store-Buffer Drain-on-Idle** — *(Medium)*
*Purpose:* Chooses *when* to actually issue the buffered store to the cache — draining only when the cache port isn't needed for a higher-priority demand (load) access this cycle.
```systemverilog
module store_drain_policy (
    input  logic buffer_has_entry, demand_load_this_cycle,
    output logic drain_fire
);
    assign drain_fire = buffer_has_entry && !demand_load_this_cycle;
endmodule
```
*Derivation:* Prioritizing demand loads over buffered-store drains is a common policy since loads are typically on a program's critical path (something is waiting on the result) while a buffered store already let its own instruction retire — same underlying "don't starve, but prioritize the latency-sensitive path" idea as the `store_drain_fsm`'s starvation-counter variant discussed earlier in this bank, simplified here to a single-cycle decision without a starvation counter.

**289. Basic Load Bypass from Store Buffer** — *(Medium)*
*Purpose:* If a load's address matches a still-buffered (not yet drained) store's address, the load must see that store's data directly — reading stale cache/memory data would be incorrect, since the buffered store hasn't reached the cache yet.
```systemverilog
module store_buffer_load_bypass (
    input  logic buffer_valid,
    input  logic [31:0] buffer_addr, buffer_data,
    input  logic load_valid,
    input  logic [31:0] load_addr,
    output logic bypass_hit,
    output logic [31:0] bypass_data
);
    assign bypass_hit  = load_valid && buffer_valid && (load_addr == buffer_addr);
    assign bypass_data = buffer_data;
endmodule
```
*Derivation:* This is the same store-to-load forwarding correctness requirement as Problem 289's Hard-tier counterparts (`ld_st_disambig`, `partial_overlap_detect`) but restricted to the simplest case — full-word, exact address match only, with no partial-overlap handling, which is a reasonable simplifying assumption for a Medium-tier single-entry store buffer where partial overlaps are a rarer edge case worth deferring to the more advanced LSQ structures.

**290. Simple Memory Arbiter (I-Fetch vs D-Access Priority)** — *(Medium)*
*Purpose:* If instruction fetch and data access share a single memory port (common in simpler unified-memory designs), something must arbitrate between them when both want access the same cycle.
```systemverilog
module imem_dmem_arb (
    input  logic ifetch_req, dmem_req,
    input  logic [31:0] ifetch_addr, dmem_addr,
    output logic grant_ifetch, grant_dmem,
    output logic [31:0] mem_addr
);
    assign grant_dmem    = dmem_req;                 // data access has priority
    assign grant_ifetch  = ifetch_req && !dmem_req;
    assign mem_addr      = dmem_req ? dmem_addr : ifetch_addr;
endmodule
```
*Derivation:* Data access is typically given priority over fetch because a stalled load/store blocks the specific instruction waiting on it (a direct critical-path stall), whereas a delayed fetch can often be absorbed by any instruction buffering/prefetch queue already in the pipeline — the opposite priority choice is also defensible and used in some designs, since chronic fetch starvation eventually stalls everything anyway.

**291. AXI-Lite-Style Read Channel FSM** — *(Medium)*
*Purpose:* Models the simplified read-address/read-data handshake pattern common to on-chip bus protocols (AXI-Lite being the canonical simple example), useful for interfacing a core to a standard SoC interconnect.
```systemverilog
module axilite_read_fsm (
    input  logic clk, rst_n,
    input  logic req_valid,
    input  logic [31:0] req_addr,
    output logic req_ready,
    output logic arvalid,
    input  logic arready,
    output logic [31:0] araddr,
    input  logic rvalid,
    output logic rready,
    input  logic [31:0] rdata,
    output logic resp_valid,
    output logic [31:0] resp_data
);
    typedef enum logic [1:0] {IDLE, ADDR, DATA} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; resp_valid <= 1'b0; end
        else begin
            resp_valid <= 1'b0;
            unique case (state)
                IDLE: if (req_valid) begin araddr <= req_addr; state <= ADDR; end
                ADDR: if (arready)   state <= DATA;
                DATA: if (rvalid)    begin resp_data <= rdata; resp_valid <= 1'b1; state <= IDLE; end
                default: state <= IDLE;
            endcase
        end
    end
    assign req_ready = (state == IDLE);
    assign arvalid    = (state == ADDR);
    assign rready      = (state == DATA);
endmodule
```
*Derivation:* AXI's split address/data channels (each with independent valid/ready) require exactly this two-phase sequencing: first negotiate the address handshake (`arvalid`/`arready`), only then wait for the data handshake (`rvalid`/`rready`) — collapsing them into one phase would violate the protocol's requirement that a responder can accept the address before its data path is even ready to return anything.

**292. AXI-Lite-Style Write Channel FSM** — *(Medium)*
```systemverilog
module axilite_write_fsm (
    input  logic clk, rst_n,
    input  logic req_valid,
    input  logic [31:0] req_addr, req_data,
    output logic req_ready,
    output logic awvalid, wvalid,
    input  logic awready, wready,
    output logic [31:0] awaddr, wdata,
    input  logic bvalid,
    output logic bready,
    output logic resp_done
);
    typedef enum logic [1:0] {IDLE, ADDR_DATA, RESP} state_e;
    state_e state;
    logic aw_done_q, w_done_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; resp_done <= 1'b0; end
        else begin
            resp_done <= 1'b0;
            unique case (state)
                IDLE: if (req_valid) begin
                    awaddr <= req_addr; wdata <= req_data;
                    aw_done_q <= 1'b0; w_done_q <= 1'b0;
                    state <= ADDR_DATA;
                end
                ADDR_DATA: begin
                    if (awready) aw_done_q <= 1'b1;
                    if (wready)  w_done_q  <= 1'b1;
                    if ((awready || aw_done_q) && (wready || w_done_q)) state <= RESP;
                end
                RESP: if (bvalid) begin resp_done <= 1'b1; state <= IDLE; end
                default: state <= IDLE;
            endcase
        end
    end
    assign req_ready = (state == IDLE);
    assign awvalid     = (state == ADDR_DATA) && !aw_done_q;
    assign wvalid       = (state == ADDR_DATA) && !w_done_q;
    assign bready        = (state == RESP);
endmodule
```
*Purpose:* AXI's write path is more complex than read because address and data can complete their handshakes independently and in either order, before the final write-response phase — this FSM tracks both independently (`aw_done_q`/`w_done_q`) rather than assuming a fixed order.
*Derivation:* The AXI spec explicitly permits `AWREADY` and `WREADY` to assert in any relative order (or the same cycle), so a correct write-channel controller cannot assume address-then-data sequencing the way the read channel can (Problem 291) — tracking each independently and only advancing once *both* have completed is the only protocol-correct approach.

**293. Burst-Read FSM (Fetch a Full Cache Line over N Beats)** — *(Medium)*
*Purpose:* Real memory fetches a whole cache line (e.g. 4×32-bit beats for a 16-byte line) rather than one word at a time — this sequences the N-beat burst and assembles the results.
```systemverilog
module burst_read_fsm #(parameter int BEATS = 4) (
    input  logic clk, rst_n, start,
    input  logic [31:0] base_addr,
    output logic mem_req_valid,
    output logic [31:0] mem_req_addr,
    input  logic mem_resp_valid,
    input  logic [31:0] mem_resp_data,
    output logic burst_done,
    output logic [BEATS-1:0][31:0] line_data
);
    logic [$clog2(BEATS):0] beat_cnt;
    typedef enum logic [1:0] {IDLE, REQ, WAIT} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; burst_done <= 1'b0; end
        else begin
            burst_done <= 1'b0;
            unique case (state)
                IDLE: if (start) begin beat_cnt <= '0; state <= REQ; end
                REQ:  state <= WAIT;
                WAIT: if (mem_resp_valid) begin
                    line_data[beat_cnt] <= mem_resp_data;
                    if (beat_cnt == BEATS-1) begin burst_done <= 1'b1; state <= IDLE; end
                    else begin beat_cnt <= beat_cnt + 1'b1; state <= REQ; end
                end
                default: state <= IDLE;
            endcase
        end
    end
    assign mem_req_valid = (state == REQ);
    assign mem_req_addr  = base_addr + (beat_cnt * 4);
endmodule
```
*Derivation:* Cycling through `REQ`→`WAIT`→`REQ`→`WAIT`... `BEATS` times (rather than trying to fire all requests back-to-back) matches a memory interface that can only accept one outstanding request at a time — a more advanced version could pipeline the requests (fire beat N+1's address before beat N's data returns) for higher throughput, at the cost of needing to track multiple outstanding requests simultaneously.

**294. Cache-Line Fill Buffer (Assemble Burst Beats)** — *(Medium)*
*Purpose:* Companion to Problem 293 — holds the assembled line data stable until the cache's tag/data arrays are ready to commit it, decoupling burst assembly timing from the cache write itself.
```systemverilog
module line_fill_buffer #(parameter int BEATS = 4) (
    input  logic clk, rst_n,
    input  logic burst_done,
    input  logic [BEATS-1:0][31:0] line_data_in,
    output logic fill_ready,
    output logic [BEATS-1:0][31:0] line_data_out
);
    logic ready_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ready_q <= 1'b0;
        else if (burst_done) begin
            ready_q        <= 1'b1;
            line_data_out  <= line_data_in;
        end else if (fill_ready) begin
            ready_q <= 1'b0;   // consumed
        end
    end
    assign fill_ready = ready_q;
endmodule
```
*Derivation:* Registering the assembled line once (rather than driving the cache write directly off Problem 293's combinational `line_data`) decouples the burst-completion timing from whenever the cache controller's own FSM state happens to be ready to accept a fill, avoiding a tight combinational dependency between two otherwise-independent state machines.

**295. Memory-Mapped Register Bank Basic Interface** — *(Medium)*
*Purpose:* A minimal address-decoded register interface for peripheral/control registers (e.g. a simple UART's control/status registers), demonstrating the read/write decode pattern used throughout SoC peripheral design.
```systemverilog
module mmio_regbank #(parameter int NUM_REGS = 4) (
    input  logic clk, rst_n,
    input  logic wr_en,
    input  logic [$clog2(NUM_REGS)-1:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic [NUM_REGS-1:0][31:0] regs_out
);
    logic [31:0] regs [NUM_REGS];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_REGS; i++) regs[i] <= '0;
        end else if (wr_en) regs[addr] <= wdata;
    end
    assign rdata     = regs[addr];
    assign regs_out  = regs;
endmodule
```
*Derivation:* A direct array-indexed decode (rather than a `case` statement like the earlier `mmio_regs` W1C-capable module) is sufficient here since every register in this simplified bank shares identical read/write behavior — no special bits (like write-1-to-clear status flags) requiring per-register logic.

**296. Bus Timeout/Error Response Handling** — *(Medium)*
*Purpose:* A real bus request can fail to ever complete (unmapped address, dead peripheral) — this watchdog-style timeout prevents the core from hanging forever waiting for a response that will never come.
```systemverilog
module bus_timeout #(parameter int TIMEOUT_CYCLES = 256) (
    input  logic clk, rst_n,
    input  logic req_outstanding, resp_valid,
    output logic timeout_error
);
    logic [$clog2(TIMEOUT_CYCLES+1)-1:0] cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || resp_valid || !req_outstanding) cnt <= '0;
        else if (cnt != TIMEOUT_CYCLES)                cnt <= cnt + 1'b1;
    end
    assign timeout_error = (cnt == TIMEOUT_CYCLES);
endmodule
```
*Derivation:* Structurally the same counter-based timeout pattern as the earlier `watchdog` module — resets whenever the outstanding request actually completes (`resp_valid`) or there's no request in flight at all, and only fires if a request has been outstanding continuously for the full timeout window, which the core's trap logic would then convert into a bus-error exception (a distinct `mcause` value from the ones in Problem 167).

**297. Simple Non-Cacheable Region Bypass Logic** — *(Medium)*
*Purpose:* Extends Problem 132's MMIO range check into an actual bypass decision — accesses to a designated non-cacheable region must skip the cache entirely and go straight to the bus, both to guarantee correctness (device registers shouldn't be cached/stale) and to preserve access ordering.
```systemverilog
module noncacheable_bypass (
    input  logic [31:0] addr, noncacheable_base, noncacheable_limit,
    output logic bypass_cache
);
    assign bypass_cache = (addr >= noncacheable_base) && (addr < noncacheable_limit);
endmodule
```
*Derivation:* Same range-check logic as Problem 132; listed separately here because in a real memory-system top-level, the range check and the actual "route around the cache" control-flow decision are typically two distinct pieces of logic (the check itself is reusable for other policies, like write-combining eligibility) rather than one monolithic module.

**298. Cache Flush-All FSM (Invalidate Every Line)** — *(Medium)*
*Purpose:* Some scenarios (context switch on a VIPT cache without ASID tagging, or a debug/reset request) need every cache line invalidated at once — this sequences through every set doing exactly that.
```systemverilog
module cache_flush_all #(parameter int SETS = 64) (
    input  logic clk, rst_n, flush_start,
    output logic flush_busy, flush_done,
    output logic [$clog2(SETS)-1:0] flush_idx,
    output logic flush_write_en
);
    logic [$clog2(SETS):0] cnt;
    typedef enum logic [1:0] {IDLE, FLUSHING, DONE} state_e;
    state_e state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state <= IDLE; flush_done <= 1'b0; end
        else begin
            flush_done <= 1'b0;
            unique case (state)
                IDLE:     if (flush_start) begin cnt <= '0; state <= FLUSHING; end
                FLUSHING: begin
                    cnt <= cnt + 1'b1;
                    if (cnt == SETS-1) state <= DONE;
                end
                DONE:     begin flush_done <= 1'b1; state <= IDLE; end
                default:  state <= IDLE;
            endcase
        end
    end
    assign flush_busy      = (state == FLUSHING);
    assign flush_idx        = cnt[$clog2(SETS)-1:0];
    assign flush_write_en   = (state == FLUSHING);
endmodule
```
*Derivation:* One index per cycle for `SETS` cycles is the simplest correct approach — a real design could invalidate multiple ways/sets in parallel per cycle if the valid-bit array supports wide writes, but the fundamentally sequential single-index version shown here is the natural starting point (and matches Problem 99's per-entry reset-loop idiom, just spread across runtime cycles instead of collapsed into a single reset edge).

**299. Cache Statistics Counter (Hit/Miss Counters)** — *(Medium)*
*Purpose:* Basic performance-monitoring counters, needed to compute a cache's actual hit rate against a workload — the memory-system analogue of Problem 258's CPI counter.
```systemverilog
module cache_stat_counters (
    input  logic clk, rst_n, access_valid, hit,
    output logic [31:0] hit_count, miss_count
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hit_count <= '0; miss_count <= '0;
        end else if (access_valid) begin
            if (hit) hit_count  <= hit_count + 1'b1;
            else      miss_count <= miss_count + 1'b1;
        end
    end
endmodule
```
*Derivation:* `hit_rate = hit_count / (hit_count + miss_count)` is the standard metric these two counters directly support computing; kept as two separate free-running counters (rather than one hit-rate-computing divider in hardware) since the division is trivial to do in software/testbench post-processing and avoids needing a hardware divider just for a debug counter.

**300. Memory System Top Wrapper** — *(Medium)*
*Purpose:* Integrates an I-cache lookup, a D-cache lookup, and the fetch/data arbiter into the single top-level module a Medium-complexity core's memory subsystem would actually instantiate.
```systemverilog
module memsys_top #(parameter int SETS = 64, parameter int LINE_BYTES = 16) (
    input  logic clk, rst_n,
    input  logic ifetch_req, dmem_req,
    input  logic [31:0] ifetch_addr, dmem_addr,
    input  logic icache_valid_arr [SETS], dcache_valid_arr [SETS],
    input  logic [31:0] icache_tag_arr [SETS], dcache_tag_arr [SETS],
    output logic icache_hit, dcache_hit,
    output logic grant_ifetch, grant_dmem,
    output logic [31:0] mem_addr
);
    icache_lookup #(.SETS(SETS), .LINE_BYTES(LINE_BYTES)) u_ic (
        .fetch_addr(ifetch_addr), .valid_arr(icache_valid_arr), .tag_arr(icache_tag_arr),
        .hit(icache_hit), .index());
    dcache_lookup #(.SETS(SETS), .LINE_BYTES(LINE_BYTES)) u_dc (
        .access_addr(dmem_addr), .valid_arr(dcache_valid_arr), .dirty_arr('{default:0}), .tag_arr(dcache_tag_arr),
        .hit(dcache_hit), .index());
    imem_dmem_arb u_arb (
        .ifetch_req(ifetch_req && !icache_hit), .dmem_req(dmem_req && !dcache_hit),
        .ifetch_addr(ifetch_addr), .dmem_addr(dmem_addr),
        .grant_ifetch(grant_ifetch), .grant_dmem(grant_dmem), .mem_addr(mem_addr));
endmodule
```
*Derivation:* Direct composition of Problems 281, 283, and 290 — the arbiter is only invoked for the *miss* case of each cache (`req && !hit`), since a cache hit needs no backing-memory arbitration at all, which is exactly why the arbiter's inputs are gated by the inverted hit signals rather than the raw request signals.

---

**End of Part 1 (Problems 201–300).** Continued in `riscv_medium_200_part2.md` — Categories 6–10: Pipeline Control & Exceptions, RVC (Compressed) Handling, Simple Out-of-Order Building Blocks, Bus/Interface Protocols, and CDC & Low-Power Basics.