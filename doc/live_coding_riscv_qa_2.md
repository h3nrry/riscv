# RISC-V CPU Live-Coding Bank — EASY Tier, Problems 101–200
### Phase 1 of 3 (Easy 1–200, Medium 201–400, Hard 401–600)

Continues directly from `riscv_easy_200_part1.md`. **Part 2 covers Categories 6–10.**

---

## Category 6: Branch/Jump Basics (101–120)

**101. BEQ Comparator** — *(Easy)*
```systemverilog
module cmp_beq (input logic [31:0] a, b, output logic taken);
    assign taken = (a == b);
endmodule
```
*Purpose:* Implements "branch if equal" — the first of the six RV32I branch conditions.
*Derivation:* Direct equality; equivalent to Problem 54's zero-flag applied to `a-b`, but expressed without an adder (see Problem 59's XOR-NOR identity).

**102. BNE Comparator** — *(Easy)*
```systemverilog
module cmp_bne (input logic [31:0] a, b, output logic taken);
    assign taken = (a != b);
endmodule
```
*Purpose:* "Branch if not equal" — simply the logical complement of Problem 101.

**103. BLT Comparator (signed)** — *(Easy)*
```systemverilog
module cmp_blt (input logic signed [31:0] a, b, output logic taken);
    assign taken = (a < b);
endmodule
```
*Purpose:* "Branch if less than," signed — reuses the same signed-comparison logic as Problem 49 (SLT).

**104. BGE Comparator (signed)** — *(Easy)*
```systemverilog
module cmp_bge (input logic signed [31:0] a, b, output logic taken);
    assign taken = (a >= b);
endmodule
```
*Purpose:* "Branch if greater-or-equal," signed — the logical complement of BLT, not a separately-derived comparison.

**105. BLTU Comparator (unsigned)** — *(Easy)*
```systemverilog
module cmp_bltu (input logic [31:0] a, b, output logic taken);
    assign taken = (a < b);
endmodule
```
*Purpose:* Unsigned less-than — same bit pattern as Problem 103 but operands left undeclared `signed`, so `<` performs unsigned comparison (matches Problem 50/SLTU's logic).

**106. BGEU Comparator (unsigned)** — *(Easy)*
```systemverilog
module cmp_bgeu (input logic [31:0] a, b, output logic taken);
    assign taken = (a >= b);
endmodule
```
*Purpose:* Complement of BLTU, unsigned.

**107. Branch-Taken Decode Mux** — *(Easy)*
*Purpose:* The single module that actually gets instantiated in a branch unit, selecting among Problems 101–106 based on `funct3`.
```systemverilog
module branch_taken_decode (
    input  logic [2:0] funct3,
    input  logic [31:0] rs1_data, rs2_data,
    output logic taken
);
    logic signed [31:0] a_s, b_s;
    assign a_s = rs1_data; assign b_s = rs2_data;
    always_comb begin
        unique case (funct3)
            3'b000:  taken = (rs1_data == rs2_data);              // BEQ
            3'b001:  taken = (rs1_data != rs2_data);              // BNE
            3'b100:  taken = (a_s < b_s);                          // BLT
            3'b101:  taken = (a_s >= b_s);                         // BGE
            3'b110:  taken = (rs1_data < rs2_data);                // BLTU
            3'b111:  taken = (rs1_data >= rs2_data);               // BGEU
            default: taken = 1'b0;
        endcase
    end
endmodule
```
*Derivation:* funct3 encodes exactly these six conditions per the RV32I branch opcode's funct3 table; `funct3` values `010`/`011` are reserved/unused, so the `default` (not-taken) branch is a defensive fallback rather than a defined case.

**108. Branch Target Adder** — *(Easy)*
```systemverilog
module branch_target_adder (input logic [31:0] pc, imm_b, output logic [31:0] target);
    assign target = pc + imm_b;
endmodule
```
*Purpose:* Computes where control transfers to if the branch is taken — PC-relative addressing, using Problem 23's immediate.

**109. JAL Target Adder** — *(Easy)*
```systemverilog
module jal_target_adder (input logic [31:0] pc, imm_j, output logic [31:0] target);
    assign target = pc + imm_j;
endmodule
```
*Purpose:* Same PC-relative pattern as Problem 108, using the J-immediate (Problem 25) for JAL's unconditional jump.

**110. JALR Target Adder** — *(Easy)*
```systemverilog
module jalr_target_adder (input logic [31:0] rs1_data, imm_i, output logic [31:0] target);
    assign target = (rs1_data + imm_i) & ~32'b1;
endmodule
```
*Purpose:* JALR is register-relative, not PC-relative — used for indirect jumps (returns, computed jump tables, virtual dispatch).
*Derivation:* The spec mandates clearing the LSB of the computed target (`& ~1`) even though the addition could produce an odd result, since instruction addresses must always be at least 2-byte aligned — this rule exists specifically because `rs1 + imm` has no guarantee of evenness the way PC-relative B/J immediates do (their LSB is hardwired 0 at the *encoding* level, Problems 23/25).

**111. PC+4 Adder (Sequential/Return-Address)** — *(Easy)*
```systemverilog
module pc_plus4 (input logic [31:0] pc, output logic [31:0] pc4);
    assign pc4 = pc + 32'd4;
endmodule
```
*Purpose:* Two uses: (1) the default next-PC for any non-control-flow instruction, and (2) the return address written to `rd` by JAL/JALR.

**112. PC+2 Adder (Compressed Sequential)** — *(Easy)*
```systemverilog
module pc_plus2 (input logic [31:0] pc, output logic [31:0] pc2);
    assign pc2 = pc + 32'd2;
endmodule
```
*Purpose:* When the C extension is enabled and the current instruction was 16-bit compressed, the next sequential PC only advances 2 bytes, not 4.
*Derivation:* Directly follows from Problem 18's length-detection — a fetch/PC-update unit must select between this and Problem 111 based on that check.

**113. Next-PC Select Mux** — *(Easy)*
*Purpose:* The single decision point that determines what PC actually gets loaded next cycle, given all the possible sources computed above.
```systemverilog
typedef enum logic [1:0] {PC_SEQ, PC_BRANCH, PC_JUMP} pc_sel_e;

module next_pc_mux (
    input  pc_sel_e sel,
    input  logic [31:0] pc_seq, pc_branch_target, pc_jump_target,
    output logic [31:0] next_pc
);
    always_comb begin
        unique case (sel)
            PC_SEQ:    next_pc = pc_seq;
            PC_BRANCH: next_pc = pc_branch_target;
            PC_JUMP:   next_pc = pc_jump_target;
        endcase
    end
endmodule
```
*Derivation:* `sel` is driven by combining Problem 107's `taken` result with the branch/jump classification bits (Problems 65/68/69) — `PC_BRANCH` only if `is_branch && taken`, `PC_JUMP` if `is_jal || is_jalr`, else `PC_SEQ`.

**114. Return-Address Capture (rd = PC+4)** — *(Easy)*
*Purpose:* JAL/JALR's defining side effect beyond the jump itself — writing the fall-through address to `rd`, which is what makes them usable as function calls.
```systemverilog
module return_addr_capture (input logic [31:0] pc, output logic [31:0] ret_addr);
    assign ret_addr = pc + 32'd4;
endmodule
```
*Derivation:* Identical computation to Problem 111 — architecturally the same value, just routed to the register-file write-data port (via Problem 95's `WB_PC4` select) instead of to the PC register.

**115. Static Branch Predictor: Always-Not-Taken** — *(Easy)*
*Purpose:* The simplest possible branch prediction policy, useful as a baseline to compare more sophisticated predictors (gshare, tournament, etc.) against.
```systemverilog
module predict_always_not_taken (output logic predict_taken);
    assign predict_taken = 1'b0;
endmodule
```
*Derivation:* No state, no history — a constant. Correct exactly as often as the program's actual not-taken branch rate, which for typical code is roughly 30–40%, making this a poor but trivially cheap predictor.

**116. Static Branch Predictor: Always-Taken** — *(Easy)*
```systemverilog
module predict_always_taken (output logic predict_taken);
    assign predict_taken = 1'b1;
endmodule
```
*Purpose:* The complementary trivial baseline; loop-heavy code (where backward branches dominate and are usually taken) tends to favor this policy over Problem 115.

**117. Backward-Branch-Taken Heuristic** — *(Easy)*
*Purpose:* A cheap, still-static improvement over Problems 115/116 — most backward branches are loop back-edges (usually taken), most forward branches are error/exception paths (usually not taken).
```systemverilog
module predict_btfnt (input logic [31:0] imm_b, output logic predict_taken);
    assign predict_taken = imm_b[31];    // negative offset = backward branch
endmodule
```
*Derivation:* Reuses Problem 36's sign-bit observation: a negative B-immediate means the target address is lower than PC, i.e. a backward branch. This "backward-taken, forward-not-taken" (BTFNT) heuristic requires no runtime history state at all, unlike the dynamic predictors in the harder tiers (gshare, tournament).

**118. Misprediction Detector** — *(Easy)*
*Purpose:* Compares what was predicted against what actually resolved, generating the signal that triggers a pipeline flush and redirect.
```systemverilog
module mispredict_detect (input logic predicted_taken, actual_taken, output logic mispredict);
    assign mispredict = (predicted_taken != actual_taken);
endmodule
```
*Derivation:* A simple XOR-equivalent inequality — misprediction occurs in exactly two cases (predicted taken but wasn't, or predicted not-taken but was), both captured by this single comparison.

**119. Redirect Valid/Target Latch** — *(Easy)*
*Purpose:* Holds the correct PC to redirect fetch to, for exactly one cycle, once a misprediction (or any other correction) is detected.
```systemverilog
module redirect_latch (
    input  logic clk, rst_n,
    input  logic redirect_en,
    input  logic [31:0] redirect_target,
    output logic redirect_valid,
    output logic [31:0] redirect_pc
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) redirect_valid <= 1'b0;
        else begin
            redirect_valid <= redirect_en;
            if (redirect_en) redirect_pc <= redirect_target;
        end
    end
endmodule
```
*Derivation:* `redirect_valid` is a one-cycle pulse (registered directly from `redirect_en`), giving the fetch stage exactly one cycle to observe and act on the corrected target before the signal deasserts — matching how a single misprediction event should only redirect fetch once, not repeatedly.

**120. Unconditional-Jump Detect** — *(Easy)*
```systemverilog
module is_uncond_jump (input logic [6:0] opcode, output logic jump);
    assign jump = (opcode == 7'b1101111) || (opcode == 7'b1100111);   // JAL or JALR
endmodule
```
*Purpose:* Unlike branches, JAL/JALR always redirect control flow — no comparator or prediction needed, since "taken" is unconditionally true, simplifying next-PC selection for these two opcodes.

---

## Category 7: Load/Store Basics (121–140)

**121. Byte-Enable Generator (RV32)** — *(Easy)*
```systemverilog
module byte_en_gen32 (
    input  logic [2:0] funct3,
    input  logic [1:0] addr_lo,
    output logic [3:0] byte_en
);
    logic [3:0] base;
    always_comb begin
        unique case (funct3[1:0])
            2'b00:   base = 4'b0001;   // byte
            2'b01:   base = 4'b0011;   // halfword
            2'b10:   base = 4'b1111;   // word
            default: base = 4'b0001;
        endcase
        byte_en = base << addr_lo;
    end
endmodule
```
*Purpose:* Tells the memory system which of the 4 bytes in a word-aligned access are actually part of this load/store, based on access size (encoded in `funct3`) and address alignment.
*Derivation:* `funct3[1:0]` directly encodes size (`00`=byte, `01`=half, `10`=word) per the LOAD/STORE opcode's funct3 table; shifting the size mask left by `addr_lo` positions it at the correct byte lane within the aligned word.

**122. Sign-Extend Loaded Byte** — *(Easy)*
```systemverilog
module sext_byte (input logic [7:0] byte_in, output logic [31:0] result);
    assign result = {{24{byte_in[7]}}, byte_in};
endmodule
```
*Purpose:* Implements LB's defined semantics — a signed 8-bit load must be sign-extended to fill the register.

**123. Sign-Extend Loaded Halfword** — *(Easy)*
```systemverilog
module sext_half (input logic [15:0] half_in, output logic [31:0] result);
    assign result = {{16{half_in[15]}}, half_in};
endmodule
```
*Purpose:* Implements LH.

**124. Zero-Extend Loaded Byte** — *(Easy)*
```systemverilog
module zext_byte (input logic [7:0] byte_in, output logic [31:0] result);
    assign result = {24'b0, byte_in};
endmodule
```
*Purpose:* Implements LBU — the unsigned load variants exist specifically so software can load raw byte/half values (e.g. from a `char` array) without accidental sign-extension corrupting the value.

**125. Zero-Extend Loaded Halfword / Word (LHU / LWU)** — *(Easy)*
```systemverilog
module zext_half (input logic [15:0] half_in, output logic [31:0] result);
    assign result = {16'b0, half_in};
endmodule

module zext_word_rv64 (input logic [31:0] word_in, output logic [63:0] result);
    assign result = {32'b0, word_in};
endmodule
```
*Purpose:* LHU (RV32/64) and LWU (RV64-only, needed because RV64 has no unsigned-32-bit-load otherwise, unlike LW which sign-extends).

**126. Load-Data Select Mux (by funct3)** — *(Easy)*
*Purpose:* The single top-level module combining Problems 122–125 with the raw byte-enable-selected data, choosing the correct extension based on `funct3`.
```systemverilog
module load_extend_mux (
    input  logic [2:0] funct3,
    input  logic [31:0] raw_word,
    input  logic [1:0] addr_lo,
    output logic [31:0] result
);
    logic [7:0]  byte_sel;
    logic [15:0] half_sel;
    assign byte_sel = raw_word[addr_lo*8 +: 8];
    assign half_sel = raw_word[addr_lo[1]*16 +: 16];

    always_comb begin
        unique case (funct3)
            3'b000:  result = {{24{byte_sel[7]}},  byte_sel};   // LB
            3'b001:  result = {{16{half_sel[15]}}, half_sel};   // LH
            3'b010:  result = raw_word;                          // LW
            3'b100:  result = {24'b0, byte_sel};                 // LBU
            3'b101:  result = {16'b0, half_sel};                 // LHU
            default: result = raw_word;
        endcase
    end
endmodule
```
*Derivation:* `funct3` bit 2 (the MSB) distinguishes signed (`0`) from unsigned (`1`) loads while bits `[1:0]` select size, matching the encoding pattern visible in Problems 122–125's opcodes (`000/001/010` signed byte/half/word, `100/101` unsigned byte/half).

**127. Store-Data Byte-Lane Pack** — *(Easy)*
*Purpose:* The store-side mirror of Problem 126 — shifts the register's low bytes into the correct lane(s) of a word-aligned write, matching wherever `byte_en` (Problem 121) says the write should land.
```systemverilog
module store_data_pack (
    input  logic [31:0] rs2_data,
    input  logic [1:0] addr_lo,
    output logic [31:0] write_data
);
    assign write_data = rs2_data << (addr_lo * 8);
endmodule
```
*Derivation:* Combined with `byte_en` from Problem 121 (which masks off the *unused* byte lanes), this shift places the relevant low-order bytes of `rs2_data` at the correct offset within the aligned word so a byte-enabled write only updates the intended bytes.

**128. Misaligned-Word-Access Detector** — *(Easy)*
```systemverilog
module misalign_word (input logic [31:0] addr, output logic misaligned);
    assign misaligned = (addr[1:0] != 2'b00);
endmodule
```
*Purpose:* A word access must be 4-byte aligned; many simple RISC-V cores trap on misaligned accesses rather than handling them in hardware, so this check feeds an exception path.
*Derivation:* An address is word-aligned exactly when its low 2 bits are 0 (i.e., divisible by 4); any other value in `addr[1:0]` means the 4-byte access would straddle a word boundary.

**129. Misaligned-Halfword-Access Detector** — *(Easy)*
```systemverilog
module misalign_half (input logic [31:0] addr, output logic misaligned);
    assign misaligned = addr[0];
endmodule
```
*Purpose:* Same idea as Problem 128, but for 2-byte accesses (LH/LHU/SH) — only bit 0 needs to be checked.

**130. Load/Store Address Adder** — *(Easy)*
```systemverilog
module lsu_addr_adder (input logic [31:0] rs1_data, imm, output logic [31:0] addr);
    assign addr = rs1_data + imm;
endmodule
```
*Purpose:* Every load/store's effective address is base register plus offset — this is literally just the ALU's adder (Problem 41) reused with the I-immediate (loads) or S-immediate (stores).

**131. Word-Select Mux (64-bit line, 32-bit word)** — *(Easy)*
*Purpose:* When a data cache line is wider than the access size (e.g. a 64-bit fetch granularity serving a 32-bit RV32 load), this selects which half of the fetched data is the actual requested word.
```systemverilog
module word_select_64 (input logic [63:0] line_data, input logic addr_bit2, output logic [31:0] word_out);
    assign word_out = addr_bit2 ? line_data[63:32] : line_data[31:0];
endmodule
```
*Derivation:* `addr[2]` (the bit above word alignment) determines which 32-bit half of a 64-bit-aligned fetch corresponds to the requested word — a generalization of the byte/half selection logic in Problems 121/126 to a coarser granularity.

**132. Memory-Mapped-Region Range Check** — *(Easy)*
```systemverilog
module mmio_range_check (
    input  logic [31:0] addr, base, limit,
    output logic is_mmio
);
    assign is_mmio = (addr >= base) && (addr < limit);
endmodule
```
*Purpose:* Distinguishes ordinary cacheable memory accesses from memory-mapped I/O, which typically must bypass the cache and can't be reordered/speculated the way normal loads can.

**133. Store-Mask Generator (Generic Width)** — *(Easy)*
```systemverilog
module store_mask_gen #(parameter int W = 32) (
    input  logic [$clog2(W/8)-1:0] addr_lo,
    input  logic [1:0] size,          // 00=byte,01=half,10=word
    output logic [W/8-1:0] mask
);
    logic [W/8-1:0] base;
    always_comb begin
        unique case (size)
            2'b00:   base = {{(W/8-1){1'b0}}, 1'b1};
            2'b01:   base = {{(W/8-2){1'b0}}, 2'b11};
            2'b10:   base = {{(W/8-4){1'b0}}, 4'b1111};
            default: base = {{(W/8-1){1'b0}}, 1'b1};
        endcase
        mask = base << addr_lo;
    end
endmodule
```
*Purpose:* A parameterized generalization of Problem 121's byte-enable logic, reusable for wider memory systems (e.g. a 64-bit or 128-bit-wide data path) rather than being hardcoded to a 32-bit word.

**134. Load-Align Barrel-Shift-Right** — *(Easy)*
```systemverilog
module load_align_shift (input logic [31:0] mem_word, input logic [1:0] addr_lo, output logic [31:0] aligned);
    assign aligned = mem_word >> (addr_lo * 8);
endmodule
```
*Purpose:* Rotates/shifts the fetched word so the requested byte/halfword lands at the bottom (bits `[7:0]`/`[15:0]`) regardless of where it was physically stored within the aligned word — the same operation used inside Problem 126's extraction.

**135. Store-Align Barrel-Shift-Left** — *(Easy)*
```systemverilog
module store_align_shift (input logic [31:0] reg_data, input logic [1:0] addr_lo, output logic [31:0] aligned);
    assign aligned = reg_data << (addr_lo * 8);
endmodule
```
*Purpose:* The store-side mirror of Problem 134 — identical to Problem 127, listed separately as the generic "barrel shift" building block independent of the store-specific framing.

**136. Simple Single-Cycle Synchronous Memory Model** — *(Easy)*
```systemverilog
module sync_mem #(parameter int DEPTH = 1024, parameter int W = 32) (
    input  logic clk,
    input  logic we,
    input  logic [$clog2(DEPTH)-1:0] addr,
    input  logic [W-1:0] wdata,
    output logic [W-1:0] rdata
);
    logic [W-1:0] mem [DEPTH];
    always_ff @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        rdata <= mem[addr];
    end
endmodule
```
*Purpose:* A minimal behavioral memory model for testbenches, representing a typical single-port synchronous SRAM with one cycle of read latency (matching most real memory macros).

**137. Simple Combinational Read-Only Memory Model** — *(Easy)*
```systemverilog
module comb_rom #(parameter int DEPTH = 256, parameter int W = 32) (
    input  logic [$clog2(DEPTH)-1:0] addr,
    output logic [W-1:0] rdata
);
    logic [W-1:0] mem [DEPTH];
    initial $readmemh("rom_init.hex", mem);
    assign rdata = mem[addr];
endmodule
```
*Purpose:* Models an instruction ROM or a lookup table (e.g. for a testbench's program image) with zero-latency combinational reads — useful for simple, non-timing-critical simulation models.

**138. Byte-Lane 4:1 Mux (Word Assembly)** — *(Easy)*
```systemverilog
module byte_lane_mux (
    input  logic [7:0] b0, b1, b2, b3,
    input  logic [1:0] sel,
    output logic [7:0] byte_out
);
    always_comb begin
        unique case (sel)
            2'b00: byte_out = b0;
            2'b01: byte_out = b1;
            2'b10: byte_out = b2;
            2'b11: byte_out = b3;
        endcase
    end
endmodule
```
*Purpose:* The inverse operation of extraction (Problem 126) — picks one of four independently-sourced bytes, useful when byte lanes come from genuinely different sources (e.g. a write-combine buffer merging partial writes) rather than just slicing one word.

**139. FENCE No-Op Passthrough Stub** — *(Easy)*
```systemverilog
module fence_stub (input logic fence_valid, output logic fence_complete);
    assign fence_complete = fence_valid;
endmodule
```
*Purpose:* In a simple in-order, single-issue core with no store buffer or out-of-order memory access, FENCE has nothing to actually order — this stub demonstrates that its correct implementation can be a same-cycle no-op, in contrast to the real sequencing FSM needed once out-of-order memory (Problem 115 in the Hard tier's LSQ category) exists.

**140. Load/Store Top Address+Size Bundle** — *(Easy)*
*Purpose:* Aggregates the address computation, misalignment check, and size/byte-enable generation into one struct output for the memory stage to consume.
```systemverilog
typedef struct packed {
    logic [31:0] addr;
    logic [3:0]  byte_en;
    logic        misaligned;
} lsu_req_t;

module lsu_request_gen (
    input  logic [31:0] rs1_data, imm,
    input  logic [2:0]  funct3,
    output lsu_req_t req
);
    assign req.addr = rs1_data + imm;
    always_comb begin
        logic [3:0] base;
        unique case (funct3[1:0])
            2'b00:   base = 4'b0001;
            2'b01:   base = 4'b0011;
            2'b10:   base = 4'b1111;
            default: base = 4'b0001;
        endcase
        req.byte_en = base << req.addr[1:0];
    end
    assign req.misaligned = (funct3[1:0] == 2'b10) ? (req.addr[1:0] != 2'b00) :
                             (funct3[1:0] == 2'b01) ? req.addr[0] : 1'b0;
endmodule
```
*Derivation:* Direct composition of Problems 121, 128/129, and 130 — no new logic, just the integrated "one struct out" form a real LSU's address-generation stage would produce for downstream stages to consume.

---

## Category 8: Pipeline Registers & Basic Hazard Signals (141–160)

**141. IF/ID Pipeline Register** — *(Easy)*
```systemverilog
module if_id_reg (
    input  logic clk, rst_n, stall, flush,
    input  logic [31:0] instr_in, pc_in,
    output logic [31:0] instr_out, pc_out
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            instr_out <= 32'h0000_0013;   // NOP
            pc_out    <= '0;
        end else if (!stall) begin
            instr_out <= instr_in;
            pc_out    <= pc_in;
        end
    end
endmodule
```
*Purpose:* Latches the fetched instruction and its PC as they cross from the Fetch stage into Decode.
*Derivation:* `flush` (branch misprediction) always wins over `stall` since a squashed instruction should never be preserved regardless of stall state; `stall` alone (e.g. waiting on a cache miss) simply holds the current contents by skipping the update.

**142. ID/EX Pipeline Register** — *(Easy)*
```systemverilog
module id_ex_reg (
    input  logic clk, rst_n, stall, flush,
    input  logic [31:0] rs1_data, rs2_data, imm, pc,
    input  logic [4:0]  rd,
    input  logic        reg_write,
    output logic [31:0] rs1_data_o, rs2_data_o, imm_o, pc_o,
    output logic [4:0]  rd_o,
    output logic        reg_write_o
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            reg_write_o <= 1'b0;
            rd_o        <= '0;
        end else if (!stall) begin
            rs1_data_o <= rs1_data; rs2_data_o <= rs2_data;
            imm_o      <= imm;      pc_o       <= pc;
            rd_o       <= rd;       reg_write_o <= reg_write;
        end
    end
endmodule
```
*Purpose:* Carries decoded operands and control signals from Decode into Execute.
*Derivation:* On flush, it's sufficient to clear just `reg_write_o` (forcing the squashed instruction to behave as a no-effect bubble downstream) rather than resetting every field — a common optimization since the other fields become "don't care" once `reg_write` is false and no other side effect is pending.

**143. EX/MEM Pipeline Register** — *(Easy)*
```systemverilog
module ex_mem_reg (
    input  logic clk, rst_n, stall,
    input  logic [31:0] alu_result, mem_wdata,
    input  logic [4:0]  rd,
    input  logic        reg_write, mem_read, mem_write,
    output logic [31:0] alu_result_o, mem_wdata_o,
    output logic [4:0]  rd_o,
    output logic        reg_write_o, mem_read_o, mem_write_o
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_write_o <= 1'b0; mem_read_o <= 1'b0; mem_write_o <= 1'b0;
        end else if (!stall) begin
            alu_result_o <= alu_result; mem_wdata_o <= mem_wdata;
            rd_o <= rd; reg_write_o <= reg_write;
            mem_read_o <= mem_read; mem_write_o <= mem_write;
        end
    end
endmodule
```
*Purpose:* Carries the ALU result (used as either a final value or a memory address) and control signals from Execute into Memory.

**144. MEM/WB Pipeline Register** — *(Easy)*
```systemverilog
module mem_wb_reg (
    input  logic clk, rst_n,
    input  logic [31:0] alu_result, mem_rdata,
    input  logic [4:0]  rd,
    input  logic        reg_write, mem_to_reg,
    output logic [31:0] alu_result_o, mem_rdata_o,
    output logic [4:0]  rd_o,
    output logic        reg_write_o, mem_to_reg_o
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_write_o <= 1'b0;
        end else begin
            alu_result_o <= alu_result; mem_rdata_o <= mem_rdata;
            rd_o <= rd; reg_write_o <= reg_write; mem_to_reg_o <= mem_to_reg;
        end
    end
endmodule
```
*Purpose:* Carries the final write-back value (or the two candidate sources plus a select bit) from Memory into Write-Back.
*Derivation:* No `stall` input here since, in a classic 5-stage design, the write-back stage never needs to hold up its own output — it's the final stage, and downstream is just the register file's write port, which always accepts a write.

**145. Generic Parameterized Pipeline Register (flush+stall)** — *(Easy)*
*Purpose:* Rather than hand-writing Problems 141–144 individually, a single parameterized template handles any pipeline boundary uniformly.
```systemverilog
module pipe_reg #(parameter int WIDTH = 32) (
    input  logic clk, rst_n, stall, flush,
    input  logic [WIDTH-1:0] d,
    output logic [WIDTH-1:0] q
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) q <= '0;
        else if (!stall)     q <= d;
    end
endmodule
```
*Derivation:* Every one of Problems 141–144 follows the same reset/flush/stall priority pattern; this genericizes the width so the same module instantiates for a 32-bit datapath field, a 5-bit register index, or a single control bit alike.

**146. Bubble/NOP Insertion Mux** — *(Easy)*
```systemverilog
module bubble_insert (input logic insert_bubble, input logic [31:0] instr_in, output logic [31:0] instr_out);
    assign instr_out = insert_bubble ? 32'h0000_0013 : instr_in;
endmodule
```
*Purpose:* Replaces an in-flight instruction with a NOP without actually stalling the pipeline register that holds it — used when a hazard needs the *effect* of a stall in one stage while letting other stages continue (e.g. inserting one bubble for a load-use hazard).

**147. Valid-Bit Pipeline Register** — *(Easy)*
```systemverilog
module valid_pipe_reg (
    input  logic clk, rst_n, stall, flush,
    input  logic valid_in,
    output logic valid_out
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) valid_out <= 1'b0;
        else if (!stall)     valid_out <= valid_in;
    end
endmodule
```
*Purpose:* An explicit valid bit traveling alongside each pipeline stage's data, so downstream logic can distinguish "a real instruction is here" from "this is a bubble," independent of whether the bubble was created by reset, flush, or NOP insertion.

**148. Stall-Propagate (Freeze) Controller** — *(Easy)*
```systemverilog
module stall_ctrl (
    input  logic load_use_hazard, structural_hazard,
    output logic stall_if, stall_id
);
    assign stall_id = load_use_hazard || structural_hazard;
    assign stall_if = stall_id;   // IF must also freeze so it doesn't overwrite ID's stalled instruction
endmodule
```
*Purpose:* When a hazard is detected in Decode, both Fetch and Decode must freeze together — otherwise Fetch would advance and Decode would lose the instruction it's supposed to be stalling on.
*Derivation:* Any stage upstream of the hazard-detecting stage must also stall, since letting it proceed would either overwrite the stalled instruction or fetch instructions that get incorrectly skipped once the stall clears.

**149. Flush-Propagate (Clear Valid) Controller** — *(Easy)*
```systemverilog
module flush_ctrl (input logic branch_mispredict, output logic flush_if, flush_id);
    assign flush_if = branch_mispredict;
    assign flush_id = branch_mispredict;
endmodule
```
*Purpose:* On a misprediction resolved in Execute, both instructions currently sitting in Fetch and Decode (fetched along the wrong path) must be squashed.
*Derivation:* In a 5-stage pipeline, a branch resolved in EX means the two instructions fetched immediately after it (currently in IF and ID) were fetched speculatively down the wrong path and must both be invalidated — this is the origin of the "2-cycle branch penalty" figure commonly quoted for simple 5-stage RISC pipelines.

**150. Load-Use Hazard Detector** — *(Easy)*
```systemverilog
module load_use_detect (
    input  logic ex_mem_read,
    input  logic [4:0] ex_rd, id_rs1, id_rs2,
    output logic hazard
);
    assign hazard = ex_mem_read && (ex_rd != 5'd0) &&
                    ((ex_rd == id_rs1) || (ex_rd == id_rs2));
endmodule
```
*Purpose:* The single most common hazard in a simple pipeline: a load's result isn't available until Memory completes, so an immediately-following instruction that needs that value in Execute can't be resolved by forwarding alone — it must stall one cycle.
*Derivation:* This is specifically checked against the instruction *currently in Execute* (not Memory or later), because forwarding can cover every other same-cycle producer/consumer distance except this one — the load's data literally doesn't exist yet at the cycle Execute needs it.

**151. Generic RAW Hazard Detector** — *(Easy)*
```systemverilog
module raw_hazard_detect (
    input  logic producer_reg_write,
    input  logic [4:0] producer_rd, consumer_rs1, consumer_rs2,
    output logic hazard
);
    assign hazard = producer_reg_write && (producer_rd != 5'd0) &&
                    ((producer_rd == consumer_rs1) || (producer_rd == consumer_rs2));
endmodule
```
*Purpose:* The general form of Problem 150 — any earlier in-flight instruction that writes a register some later instruction is about to read is a read-after-write hazard, whether or not it's specifically a load.

**152. Simple Full-Stall Controller** — *(Easy)*
*Purpose:* Combines the load-use hazard with any other structural hazard (e.g., a busy multi-cycle divide unit) into one overall stall decision.
```systemverilog
module full_stall_ctrl (
    input  logic load_use_hazard, div_busy, icache_miss,
    output logic global_stall
);
    assign global_stall = load_use_hazard || div_busy || icache_miss;
endmodule
```
*Derivation:* Any one of several independent stall sources is sufficient to freeze the pipeline; OR-combining them into a single `global_stall` is correct precisely because Problem 145's generic pipeline register only needs one stall bit per stage boundary, regardless of how many reasons might be asserting it simultaneously.

**153. Single-Cycle vs Pipeline Mode Select Stub** — *(Easy)*
*Purpose:* A configuration bit letting the same core operate as either a simple single-cycle datapath (for teaching/debug) or a pipelined one, useful for verifying a pipelined design's functional correctness against a simpler golden reference built from the same RTL.
```systemverilog
module mode_select (input logic pipeline_mode, output logic enable_forwarding, enable_hazard_stall);
    assign enable_forwarding   = pipeline_mode;
    assign enable_hazard_stall = pipeline_mode;
endmodule
```
*Derivation:* In single-cycle mode there are no pipeline registers to create hazards in the first place, so forwarding and stall logic are simply unnecessary (and their outputs, if left enabled, would be vacuously inactive anyway since no cross-stage register-index collision could occur within one cycle).

**154. PC-Freeze-on-Stall Register** — *(Easy)*
```systemverilog
module pc_reg_stall (
    input  logic clk, rst_n, stall,
    input  logic [31:0] pc_next,
    output logic [31:0] pc
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      pc <= 32'h0000_0000;
        else if (!stall) pc <= pc_next;
    end
endmodule
```
*Purpose:* The PC register itself must also honor the stall signal from Problem 148/152 — otherwise Fetch would keep advancing and fetching new instructions even while Decode is frozen waiting out a hazard.

**155. Forwarding-Source Mux (EX/MEM → EX)** — *(Easy)*
```systemverilog
module fwd_exmem (
    input  logic ex_mem_reg_write,
    input  logic [4:0] ex_mem_rd, id_ex_rs1,
    input  logic [31:0] ex_mem_alu_result, id_ex_rs1_data,
    output logic [31:0] forwarded_rs1
);
    assign forwarded_rs1 = (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs1))
                            ? ex_mem_alu_result : id_ex_rs1_data;
endmodule
```
*Purpose:* The most common forwarding path — an instruction one cycle ahead (currently in EX/MEM) produced a result this cycle's Execute-stage instruction needs, so route it directly instead of stalling for the write-back-then-read round trip.

**156. Forwarding-Source Mux (MEM/WB → EX)** — *(Easy)*
```systemverilog
module fwd_memwb (
    input  logic mem_wb_reg_write,
    input  logic [4:0] mem_wb_rd, id_ex_rs1,
    input  logic [31:0] mem_wb_wdata, id_ex_rs1_data,
    output logic [31:0] forwarded_rs1
);
    assign forwarded_rs1 = (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1))
                            ? mem_wb_wdata : id_ex_rs1_data;
endmodule
```
*Purpose:* Covers the two-cycles-ahead producer — an instruction currently in MEM/WB, whose result the register file hasn't captured yet this cycle (or, per Problem 88, is only just becoming visible), forwarded to a same-cycle Execute-stage consumer.

**157. Forwarding Priority Resolver** — *(Easy)*
*Purpose:* If *both* Problem 155 and Problem 156's conditions are true simultaneously (i.e., two different in-flight instructions both target the same register the current one needs), the more recent value must win.
```systemverilog
module fwd_priority (
    input  logic exmem_match, memwb_match,
    input  logic [31:0] exmem_data, memwb_data, regfile_data,
    output logic [31:0] result
);
    always_comb begin
        if      (exmem_match) result = exmem_data;    // EX/MEM is newer -> highest priority
        else if (memwb_match) result = memwb_data;
        else                   result = regfile_data;
    end
endmodule
```
*Derivation:* EX/MEM holds the result of the instruction that is one cycle *closer* (more recently issued) than whatever's in MEM/WB, so if both match the same destination register, the EX/MEM value is architecturally the correct, most up-to-date one — this priority ordering is what prevents forwarding from silently picking a stale value.

**158. No-Forward Passthrough Case** — *(Easy)*
```systemverilog
module fwd_baseline_mux (input logic [31:0] regfile_data, output logic [31:0] operand);
    assign operand = regfile_data;
endmodule
```
*Purpose:* The trivial default case underlying Problem 157's final `else` branch — when no in-flight instruction produces the needed register, the ordinary register-file read value (Problem 81) is already correct and no forwarding is needed at all.

**159. Pipeline-Flush/Bubble Counter (Debug)** — *(Easy)*
```systemverilog
module bubble_counter (input logic clk, rst_n, bubble_inserted, output logic [31:0] bubble_count);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)             bubble_count <= '0;
        else if (bubble_inserted) bubble_count <= bubble_count + 1'b1;
endmodule
```
*Purpose:* A non-architectural debug/performance counter tracking how many cycles were lost to stalls/flushes — useful for verifying a pipeline's CPI against expectations and for performance debug during bring-up.

**160. 5-Stage Valid-Bit Shift Chain (Structural)** — *(Easy)*
*Purpose:* A minimal illustration of how a valid bit for one instruction physically propagates through all 5 classic pipeline stages, useful as a scaffold before adding real stall/flush behavior at each stage.
```systemverilog
module valid_chain_5stage (
    input  logic clk, rst_n,
    input  logic valid_if,
    output logic valid_id, valid_ex, valid_mem, valid_wb
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_id <= 1'b0; valid_ex <= 1'b0; valid_mem <= 1'b0; valid_wb <= 1'b0;
        end else begin
            valid_id  <= valid_if;
            valid_ex  <= valid_id;
            valid_mem <= valid_ex;
            valid_wb  <= valid_ex ? valid_mem : valid_mem;  // simplified: straight shift, no stall/flush yet
        end
    end
endmodule
```
*Derivation:* With no stall or flush logic at all, a valid bit is just a plain shift register — one flip-flop stage per pipeline stage — which is exactly the skeleton Problems 147–149 build real stall/flush behavior on top of.

---

## Category 9: CSR & Exception Basics (161–180)

**161. CSR Read Mux (Subset)** — *(Easy)*
```systemverilog
module csr_read_mux (
    input  logic [11:0] csr_addr,
    input  logic [31:0] mstatus, mepc, mcause, mtvec, mie, mip,
    output logic [31:0] csr_rdata
);
    always_comb begin
        unique case (csr_addr)
            12'h300: csr_rdata = mstatus;
            12'h341: csr_rdata = mepc;
            12'h342: csr_rdata = mcause;
            12'h305: csr_rdata = mtvec;
            12'h304: csr_rdata = mie;
            12'h344: csr_rdata = mip;
            default: csr_rdata = 32'b0;
        endcase
    end
endmodule
```
*Purpose:* Routes a CSR address (Problem 11) to the correct machine-mode control/status register's value — the read side of every CSR instruction.
*Derivation:* The specific addresses (`0x300`, `0x341`, etc.) are fixed by the RISC-V privileged spec's CSR address map — this mux is a direct, literal transcription of that table for the subset a minimal core implements.

**162. CSRRW Basic** — *(Easy)*
```systemverilog
module csrrw (input logic [31:0] rs1_data, csr_old, output logic [31:0] csr_new, rd_result);
    assign csr_new   = rs1_data;
    assign rd_result = csr_old;
endmodule
```
*Purpose:* "CSR Read-Write": atomically swaps `rd = old CSR value` and `CSR = rs1`, the most basic of the CSR-modifying instructions.

**163. CSRRS Basic** — *(Easy)*
```systemverilog
module csrrs (input logic [31:0] rs1_data, csr_old, output logic [31:0] csr_new, rd_result);
    assign csr_new   = csr_old | rs1_data;
    assign rd_result = csr_old;
endmodule
```
*Purpose:* "CSR Read-Set": uses `rs1` as a bitmask of which CSR bits to set (via OR), leaving other bits untouched — e.g. setting individual bits of `mie` to enable specific interrupts.

**164. CSRRC Basic** — *(Easy)*
```systemverilog
module csrrc (input logic [31:0] rs1_data, csr_old, output logic [31:0] csr_new, rd_result);
    assign csr_new   = csr_old & ~rs1_data;
    assign rd_result = csr_old;
endmodule
```
*Purpose:* "CSR Read-Clear": complementary to Problem 163, using `rs1` as a mask of which bits to force to 0.

**165. CSR Immediate Variants (CSRRWI/CSRRSI/CSRRCI)** — *(Easy)*
```systemverilog
module csr_imm_ops (
    input  logic [1:0] op,        // 00=RW, 01=RS, 10=RC
    input  logic [4:0] zimm,
    input  logic [31:0] csr_old,
    output logic [31:0] csr_new, rd_result
);
    logic [31:0] zimm_ext;
    assign zimm_ext = {27'b0, zimm};
    always_comb begin
        unique case (op)
            2'b00:   csr_new = zimm_ext;
            2'b01:   csr_new = csr_old | zimm_ext;
            2'b10:   csr_new = csr_old & ~zimm_ext;
            default: csr_new = csr_old;
        endcase
    end
    assign rd_result = csr_old;
endmodule
```
*Purpose:* Identical semantics to Problems 162–164, but using the zero-extended 5-bit immediate (Problem 27) instead of `rs1`, letting software set/clear/write small constant CSR bit patterns without burning a register.

**166. mepc Capture-on-Trap Register** — *(Easy)*
```systemverilog
module mepc_reg (
    input  logic clk, rst_n, trap_taken,
    input  logic [31:0] trap_pc,
    output logic [31:0] mepc
);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)          mepc <= '0;
        else if (trap_taken) mepc <= trap_pc;
endmodule
```
*Purpose:* On any exception or interrupt, the hardware must save the PC of the interrupted/faulting instruction so `MRET` can (usually) resume there — this is the register that holds it.

**167. mcause Encode-on-Trap Mux** — *(Easy)*
```systemverilog
typedef enum logic [3:0] {
    CAUSE_ILLEGAL_INSTR = 4'd2, CAUSE_ECALL_M = 4'd11,
    CAUSE_BREAKPOINT    = 4'd3, CAUSE_MISALIGN_LOAD = 4'd4
} mcause_e;

module mcause_encode (
    input  logic illegal_instr, ecall, ebreak, misaligned_load,
    output logic [31:0] mcause
);
    always_comb begin
        unique casez ({illegal_instr, ecall, ebreak, misaligned_load})
            4'b1???: mcause = {28'b0, CAUSE_ILLEGAL_INSTR};
            4'b?1??: mcause = {28'b0, CAUSE_ECALL_M};
            4'b??1?: mcause = {28'b0, CAUSE_BREAKPOINT};
            4'b???1: mcause = {28'b0, CAUSE_MISALIGN_LOAD};
            default: mcause = 32'b0;
        endcase
    end
endmodule
```
*Purpose:* Encodes *why* a trap occurred into the standard numeric cause codes software's trap handler reads to decide how to respond.
*Derivation:* The specific numeric values (2, 11, 3, 4, ...) come directly from the RISC-V privileged spec's exception-code table; the `casez` priority order here (illegal instruction highest) reflects that if multiple exception conditions could theoretically apply to the same instruction, the spec requires a defined, consistent priority rather than an arbitrary one.

**168. mtvec-Based Trap-Vector Mux (Direct Mode)** — *(Easy)*
```systemverilog
module trap_vector_direct (input logic [31:0] mtvec, output logic [31:0] trap_pc);
    assign trap_pc = {mtvec[31:2], 2'b00};   // direct mode: always jump to BASE
endmodule
```
*Purpose:* Direct mode is the simpler of the two RISC-V trap-vector modes — every trap, regardless of cause, jumps to the same fixed handler entry point.
*Derivation:* `mtvec[1:0]` encodes the mode (`00`=Direct); the base address is `mtvec[31:2]` word-aligned (masking the low 2 bits to 0 regardless of mode bit values), so this module implements only the Direct-mode half of the full mtvec logic.

**169. ECALL Detect** — *(Easy)*
```systemverilog
module is_ecall (input logic [6:0] opcode, input logic [2:0] funct3, input logic [11:0] funct12, output logic ecall);
    assign ecall = (opcode == 7'b1110011) && (funct3 == 3'b000) && (funct12 == 12'h000);
endmodule
```
*Purpose:* The standard mechanism for software to request a trap into a higher privilege level (e.g. a syscall into an OS, or into machine mode from a runtime).

**170. EBREAK Detect** — *(Easy)*
```systemverilog
module is_ebreak (input logic [6:0] opcode, input logic [2:0] funct3, input logic [11:0] funct12, output logic ebreak);
    assign ebreak = (opcode == 7'b1110011) && (funct3 == 3'b000) && (funct12 == 12'h001);
endmodule
```
*Purpose:* Requests a breakpoint trap, the standard mechanism debuggers use to stop execution at a specific instruction.

**171. Illegal-Instruction Detect (Minimal)** — *(Easy)*
```systemverilog
module illegal_instr_detect (input logic [6:0] opcode, output logic illegal);
    always_comb begin
        unique case (opcode)
            7'b0110011, 7'b0010011, 7'b0000011, 7'b0100011,
            7'b1100011, 7'b0110111, 7'b0010111, 7'b1101111,
            7'b1100111, 7'b1110011, 7'b0001111: illegal = 1'b0;
            default:                             illegal = 1'b1;
        endcase
    end
endmodule
```
*Purpose:* Same logic as Problem 80, restated here as the direct input to the trap-cause encoder (Problem 167) rather than as a standalone decode-classification flag.

**172. Misaligned-Instruction-Address Detect** — *(Easy)*
```systemverilog
module misalign_instr_addr (input logic [31:0] next_pc, input logic c_ext_enabled, output logic misaligned);
    assign misaligned = c_ext_enabled ? 1'b0 : next_pc[1];   // 2-byte aligned OK if C extension present
endmodule
```
*Purpose:* Without the C extension, every instruction must be 4-byte aligned, so a computed jump/branch target with `PC[1]=1` is illegal; with the C extension, 2-byte alignment is always sufficient, so this check becomes trivially satisfied.
*Derivation:* `PC[0]` is never checked here because both JALR (Problem 110) and the B/J immediate encodings (Problems 23/25) already structurally guarantee bit 0 is 0 — only bit 1 is actually at risk of being set on a base-ISA-only (no-C) core.

**173. mstatus.MIE Extract** — *(Easy)*
```systemverilog
module mstatus_mie_extract (input logic [31:0] mstatus, output logic mie);
    assign mie = mstatus[3];
endmodule
```
*Purpose:* `mstatus` bit 3 is the global machine-mode interrupt-enable bit — the master switch gating whether any interrupt can actually be taken, regardless of individual per-interrupt enables in `mie` (the separate CSR).

**174. mstatus.MIE Clear-on-Trap** — *(Easy)*
```systemverilog
module mstatus_trap_update (
    input  logic clk, rst_n, trap_taken,
    input  logic [31:0] mstatus_in,
    output logic [31:0] mstatus_out
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) mstatus_out <= 32'h0000_1800;   // reset: MPP=11
        else if (trap_taken) begin
            mstatus_out[7] <= mstatus_in[3];   // MPIE <= old MIE
            mstatus_out[3] <= 1'b0;             // MIE  <= 0 (disable interrupts in handler)
        end
    end
endmodule
```
*Purpose:* On entering a trap handler, interrupts must be automatically disabled (so the handler itself isn't interrupted, unless it explicitly re-enables them) — and the *previous* enable state must be saved so it can be restored on return.
*Derivation:* This is exactly the standard save/disable sequence defined by the privileged spec: `MPIE` (bit 7) records what `MIE` was before the trap, then `MIE` is cleared, so `MRET` (Problem 176) can correctly restore the pre-trap interrupt-enable state rather than always blindly re-enabling.

**175. mstatus.MPIE Restore-on-MRET** — *(Easy)*
```systemverilog
module mstatus_mret_update (input logic [31:0] mstatus_in, output logic [31:0] mstatus_out);
    assign mstatus_out = mstatus_in;
    // MIE <= MPIE on MRET:
    assign mstatus_out[3] = mstatus_in[7];
    assign mstatus_out[7] = 1'b1;   // MPIE reset to 1 per spec
endmodule
```
*Purpose:* Companion to Problem 174 — MRET restores the interrupt-enable state that was saved when the trap was taken.
*Derivation:* Per spec, `MRET` sets `MIE = MPIE` and then resets `MPIE` to 1 (the defined default), reversing the save performed in Problem 174.

**176. MRET Detect & PC-Restore Mux** — *(Easy)*
```systemverilog
module mret_handle (
    input  logic [6:0] opcode,
    input  logic [2:0] funct3,
    input  logic [11:0] funct12,
    input  logic [31:0] mepc,
    output logic mret,
    output logic [31:0] restore_pc
);
    assign mret       = (opcode == 7'b1110011) && (funct3 == 3'b000) && (funct12 == 12'h302);
    assign restore_pc = mepc;
endmodule
```
*Purpose:* MRET is the instruction that returns from a trap handler back to (usually) where execution was interrupted, by jumping to the saved `mepc` (Problem 166) and restoring `mstatus` (Problem 175).
*Derivation:* `funct12 = 0x302` is the specific literal the privileged spec assigns to MRET, distinguishing it from ECALL (`0x000`) and EBREAK (`0x001`) despite sharing the same opcode and funct3.

**177. Interrupt-Pending OR-Reduce** — *(Easy)*
```systemverilog
module interrupt_pending_any (input logic [31:0] mip, mie, output logic any_pending);
    assign any_pending = |(mip & mie);
endmodule
```
*Purpose:* An interrupt is only actually "pending and ready to be taken" if it's both flagged in `mip` (a device/timer/software signal is asserted) *and* individually enabled in `mie` — this ANDs the two bit vectors and reduces to a single "something needs attention" flag.

**178. Interrupt-Enable-and-Pending Qualify** — *(Easy)*
```systemverilog
module interrupt_take_check (input logic global_mie, input logic any_local_pending, output logic take_interrupt);
    assign take_interrupt = global_mie && any_local_pending;
endmodule
```
*Purpose:* Combines Problem 173's global enable with Problem 177's local pending check — an interrupt is only actually taken if *both* the master `MIE` switch and the specific interrupt's enable/pending pair agree.

**179. Trap-Priority Mux (Exception over Interrupt)** — *(Easy)*
```systemverilog
module trap_priority (
    input  logic exception_pending, interrupt_pending,
    input  logic [31:0] exception_cause, interrupt_cause,
    output logic trap_taken,
    output logic [31:0] trap_cause
);
    assign trap_taken = exception_pending || interrupt_pending;
    assign trap_cause = exception_pending ? exception_cause : interrupt_cause;
endmodule
```
*Purpose:* Per spec, if a synchronous exception (e.g. illegal instruction) and an asynchronous interrupt could both be taken on the same instruction, the exception associated with that specific instruction takes priority — this mux encodes that ordering rule.
*Derivation:* The RISC-V privileged spec explicitly defines this priority so trap handling is deterministic; giving interrupts priority instead would risk silently dropping a synchronous fault that software needs to see (e.g. an illegal instruction shouldn't be masked just because a timer interrupt also happened to be pending).

**180. Simple CSR Register Bank** — *(Easy)*
*Purpose:* A minimal storage array for the handful of CSRs a basic core implements, gathering Problems 166/174/175's individual registers into one addressable block.
```systemverilog
module csr_bank (
    input  logic clk, rst_n,
    input  logic we,
    input  logic [11:0] waddr,
    input  logic [31:0] wdata,
    output logic [31:0] mstatus, mepc, mcause, mtvec, mie, mip
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus <= 32'h0000_1800; mepc <= '0; mcause <= '0;
            mtvec   <= '0;             mie  <= '0; mip    <= '0;
        end else if (we) begin
            unique case (waddr)
                12'h300: mstatus <= wdata;
                12'h341: mepc    <= wdata;
                12'h342: mcause  <= wdata;
                12'h305: mtvec   <= wdata;
                12'h304: mie     <= wdata;
                12'h344: mip     <= wdata;
                default: ;
            endcase
        end
    end
endmodule
```
*Derivation:* Direct composition of Problem 161's address map with individually-writable storage for each CSR — the write side of the same table the read mux implements.

---

## Category 10: Small Datapath Utility Blocks (181–200)

**181. Generic 2:1 Mux** — *(Easy)*
```systemverilog
module mux2 #(parameter int W = 32) (input logic sel, input logic [W-1:0] a, b, output logic [W-1:0] y);
    assign y = sel ? b : a;
endmodule
```
*Purpose:* The single most common building block in any datapath — nearly every mux in this bank (operand selects, write-back selects, next-PC selects) reduces to chained instances of this.

**182. Generic 4:1 Mux** — *(Easy)*
```systemverilog
module mux4 #(parameter int W = 32) (
    input  logic [1:0] sel,
    input  logic [W-1:0] a, b, c, d,
    output logic [W-1:0] y
);
    always_comb begin
        unique case (sel)
            2'b00: y = a;
            2'b01: y = b;
            2'b10: y = c;
            2'b11: y = d;
        endcase
    end
endmodule
```
*Purpose:* Used directly by Problem 95's write-back mux and similar 4-source selects throughout the datapath.

**183. Generic Priority Mux** — *(Easy)*
```systemverilog
module priority_mux #(parameter int N = 4, parameter int W = 32) (
    input  logic [N-1:0] req,
    input  logic [N-1:0][W-1:0] data,
    output logic [W-1:0] y,
    output logic valid
);
    always_comb begin
        y = '0; valid = |req;
        for (int i = N-1; i >= 0; i--)
            if (req[i]) y = data[i];
    end
endmodule
```
*Purpose:* Selects among several candidate sources by priority rather than a fixed select code — the same overwrite-chain structure as the `priority_enc8` module discussed earlier in this conversation, generalized to select full data words instead of just an index.

**184. Generic 1:4 Demux** — *(Easy)*
```systemverilog
module demux4 #(parameter int W = 32) (
    input  logic [1:0] sel,
    input  logic [W-1:0] d,
    output logic [W-1:0] out0, out1, out2, out3
);
    assign out0 = (sel == 2'b00) ? d : '0;
    assign out1 = (sel == 2'b01) ? d : '0;
    assign out2 = (sel == 2'b10) ? d : '0;
    assign out3 = (sel == 2'b11) ? d : '0;
endmodule
```
*Purpose:* The inverse of Problem 182 — routes one input to exactly one of several destinations, e.g. distributing a single write-back value to one of several possible destination structures.

**185. D Flip-Flop with Synchronous Reset** — *(Easy)*
```systemverilog
module dff_sync_rst (input logic clk, rst_n, d, output logic q);
    always_ff @(posedge clk)
        if (!rst_n) q <= 1'b0;
        else        q <= d;
endmodule
```
*Purpose:* The most basic sequential element; synchronous reset only takes effect on a clock edge, which can be preferable for timing closure (reset path only needs to meet setup time, not act asynchronously) at the cost of needing a clock toggling to actually reset.

**186. D Flip-Flop with Asynchronous Reset** — *(Easy)*
```systemverilog
module dff_async_rst (input logic clk, rst_n, d, output logic q);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) q <= 1'b0;
        else        q <= d;
endmodule
```
*Purpose:* The style used throughout this entire problem bank — reset takes effect immediately regardless of the clock, guaranteeing a known state even if the clock isn't toggling yet (e.g. during power-up before a PLL locks).

**187. D Flip-Flop with Enable** — *(Easy)*
```systemverilog
module dff_en (input logic clk, rst_n, en, d, output logic q);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) q <= 1'b0;
        else if (en) q <= d;
endmodule
```
*Purpose:* The building block behind every conditional pipeline-register write in this bank (Problems 141–145 all reduce to arrays of this with `en = !stall`).

**188. Shift Register — Left** — *(Easy)*
```systemverilog
module shift_left #(parameter int W = 8) (input logic clk, rst_n, sin, output logic [W-1:0] q);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) q <= '0;
        else        q <= {q[W-2:0], sin};
endmodule
```
*Purpose:* The same shift structure underlying the LFSR (Problem "lfsr8" discussed earlier) and UART bit-serialization — new bits enter at the LSB and walk up toward the MSB each cycle.

**189. Shift Register — Right** — *(Easy)*
```systemverilog
module shift_right #(parameter int W = 8) (input logic clk, rst_n, sin, output logic [W-1:0] q);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) q <= '0;
        else        q <= {sin, q[W-1:1]};
endmodule
```
*Purpose:* Mirror of Problem 188, used e.g. for a UART receiver's bit-serial-to-parallel assembly.

**190. Up-Counter** — *(Easy)*
```systemverilog
module up_counter #(parameter int W = 8) (input logic clk, rst_n, en, output logic [W-1:0] count);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)  count <= '0;
        else if (en) count <= count + 1'b1;
endmodule
```
*Purpose:* Free-running counter, the basis for cycle counters, timeout counters (like Problem 148's debounce), and performance monitors.

**191. Down-Counter** — *(Easy)*
```systemverilog
module down_counter #(parameter int W = 8) (input logic clk, rst_n, en, input logic [W-1:0] load_val, load, output logic [W-1:0] count);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)   count <= '0;
        else if (load) count <= load_val;
        else if (en)   count <= count - 1'b1;
endmodule
```
*Purpose:* Used for watchdog-style "count down to zero, then fire" logic (see Problem 197 in the earlier 200-problem bank's `watchdog` module).

**192. Up/Down Counter** — *(Easy)*
```systemverilog
module updown_counter #(parameter int W = 8) (input logic clk, rst_n, en, up_down, output logic [W-1:0] count);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)  count <= '0;
        else if (en) count <= up_down ? count + 1'b1 : count - 1'b1;
endmodule
```
*Purpose:* A single configurable counter covering both Problems 190/191's use cases with one `up_down` control bit.

**193. Saturating Up-Counter** — *(Easy)*
```systemverilog
module sat_up_counter #(parameter int W = 8) (input logic clk, rst_n, en, output logic [W-1:0] count);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)                    count <= '0;
        else if (en && count != {W{1'b1}}) count <= count + 1'b1;
endmodule
```
*Purpose:* Prevents wraparound at the max value — used e.g. for confidence counters in branch predictors, where wrapping from "maximum confidence" back to zero on one more increment would be a functional bug, not just a cosmetic one.

**194. One-Shot Pulse Generator (Level → Pulse)** — *(Easy)*
```systemverilog
module one_shot (input logic clk, rst_n, level_in, output logic pulse_out);
    logic level_q;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) level_q <= 1'b0;
        else        level_q <= level_in;
    assign pulse_out = level_in && !level_q;
endmodule
```
*Purpose:* Converts a signal that stays asserted for many cycles into a single-cycle pulse on its rising edge — needed anywhere a level signal (e.g. a held button, Problem "debounce"'s stable `sig_out`) must trigger an action exactly once rather than every cycle it's high.

**195. Rising-Edge Detector** — *(Easy)*
```systemverilog
module rising_edge_detect (input logic clk, rst_n, sig, output logic edge_pulse);
    logic sig_q;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) sig_q <= 1'b0;
        else        sig_q <= sig;
    assign edge_pulse = sig && !sig_q;
endmodule
```
*Purpose:* Identical structure to Problem 194, named for its more general use — e.g. detecting a newly-asserted interrupt-pending bit.

**196. Falling-Edge Detector** — *(Easy)*
```systemverilog
module falling_edge_detect (input logic clk, rst_n, sig, output logic edge_pulse);
    logic sig_q;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) sig_q <= 1'b0;
        else        sig_q <= sig;
    assign edge_pulse = !sig && sig_q;
endmodule
```
*Purpose:* Complementary to Problem 195 — flags the cycle a signal transitions from 1 to 0, e.g. detecting when a busy/valid signal has just cleared.

**197. Toggle Flip-Flop** — *(Easy)*
```systemverilog
module toggle_ff (input logic clk, rst_n, toggle_en, output logic q);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)        q <= 1'b0;
        else if (toggle_en) q <= ~q;
endmodule
```
*Purpose:* Flips state every time it's enabled rather than loading a new value — the exact mechanism behind the toggle-based CDC pulse synchronizer discussed earlier in this bank, and behind simple clock-divider circuits.

**198. Generic Parity Generator** — *(Easy)*
```systemverilog
module parity_gen #(parameter int W = 32) (input logic [W-1:0] data, output logic parity);
    assign parity = ^data;
endmodule
```
*Purpose:* XOR-reduces every bit to a single parity bit, used for simple single-bit error detection on register-file or memory contents (a lighter-weight alternative to the full SEC-DED ECC seen in the Hard tier).

**199. 1-Deep Skid Buffer (Valid/Ready)** — *(Easy)*
```systemverilog
module skid_buffer_1 #(parameter int W = 32) (
    input  logic clk, rst_n,
    input  logic up_valid, output logic up_ready, input logic [W-1:0] up_data,
    output logic down_valid, input logic down_ready, output logic [W-1:0] down_data
);
    logic [W-1:0] skid_data;
    logic         skid_valid;

    assign up_ready   = !skid_valid;
    assign down_valid = up_valid || skid_valid;
    assign down_data  = skid_valid ? skid_data : up_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skid_valid <= 1'b0;
        end else begin
            if (up_valid && up_ready && !down_ready) begin
                skid_data  <= up_data;
                skid_valid <= 1'b1;
            end else if (down_ready) begin
                skid_valid <= 1'b0;
            end
        end
    end
endmodule
```
*Purpose:* Lets an upstream producer keep sending one more item even the exact cycle a downstream consumer stops accepting, without losing data or needing a combinational-loop `ready` signal — the standard building block for breaking a long `ready` timing path in a valid/ready interface.
*Derivation:* If `up_valid` and `up_ready` are both true but `down_ready` is false in the same cycle, the incoming item would otherwise be lost — the skid register catches exactly that one item, and `up_ready` deasserts immediately afterward (since the skid slot is now full) to prevent losing a second item before the first drains.

**200. 1-Deep Pipeline Buffer with Bypass** — *(Easy)*
```systemverilog
module pipe_buffer_bypass #(parameter int W = 32) (
    input  logic clk, rst_n,
    input  logic up_valid, output logic up_ready, input logic [W-1:0] up_data,
    output logic down_valid, input logic down_ready, output logic [W-1:0] down_data
);
    logic         buf_valid;
    logic [W-1:0] buf_data;

    assign up_ready   = !buf_valid || down_ready;
    assign down_valid = buf_valid || up_valid;
    assign down_data  = buf_valid ? buf_data : up_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_valid <= 1'b0;
        end else if (up_valid && up_ready && !down_ready) begin
            buf_data  <= up_data;
            buf_valid <= 1'b1;
        end else if (down_ready) begin
            buf_valid <= 1'b0;
        end
    end
endmodule
```
*Purpose:* A close relative of Problem 199 with a slightly different timing tradeoff — data can pass straight through combinationally when the buffer is empty and the consumer is ready (lower latency in the common case), only registering when the consumer briefly can't accept.
*Derivation:* Whenever `buf_valid=0`, `down_data` is driven directly from `up_data` with no register in the path (true bypass); the buffer only ever holds data when the pipeline briefly backs up, matching the same single-item-of-slack guarantee as Problem 199 but with a combinational fast path when there's no contention.

---

**End of EASY tier (Problems 1–200).** This completes Phase 1 of 3. Next: **Medium tier (Problems 201–400)** and **Hard tier (Problems 401–600)**, covering pipelined multi-cycle structures, out-of-order building blocks, cache/TLB/CDC/low-power RTL, and verification — in the same purpose + full-solution + derivation format.