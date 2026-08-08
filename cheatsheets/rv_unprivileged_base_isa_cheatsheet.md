# RISC-V Unprivileged Base ISA Cheatsheet

Quick reference for the RV32I / RV64I **base integer ISA** — registers, instructions, and their bit-level encoding. Scoped strictly to the base ISA; extensions, toolchain flags, and build/debug commands live in [`README.md`](./README.md) instead.

Companion file: [`rv_unprivileged_compressed_isa_cheatsheet.md`](./rv_unprivileged_compressed_isa_cheatsheet.md) — covers `inst[1:0] = 00 / 01 / 10` (16-bit compressed / C extension) in full detail.

---

## Table of Contents

- [Specification Version](#specification-version)
- [Registers (ABI names)](#registers-abi-names)
- [Base Instruction Set (RV32I / RV64I)](#base-instruction-set-rv32i--rv64i)
- [Instruction Encoding](#instruction-encoding)
- [Compressed Instructions (separate file →)](./rv_unprivileged_compressed_isa_cheatsheet.md)
- [Extensions, Toolchain & Build Reference (README →)](./README.md)

---

## Specification Version

This cheatsheet reflects the current **RISC-V Instruction Set Manual, Volume I: Unprivileged Architecture**, base integer ISA chapters only:

| Item | Version |
|---|---|
| Unprivileged ISA (overall release) | **20260120** (official release) |
| RV32I Base Integer ISA | 2.1 |
| RV64I Base Integer ISA | 2.1 |

Source: [docs.riscv.org — RISC-V Ratified Specifications Library](https://docs.riscv.org/reference/isa/v20260120/unpriv/unpriv-index.html). Extension versions (M/A/C/F/D and beyond) are listed in `README.md`.

---

## Registers (ABI names)

| Reg | ABI Name | Description | Saved by |
|-----|----------|-------------|----------|
| x0 | zero | Hard-wired 0 | — |
| x1 | ra | Return address | Caller |
| x2 | sp | Stack pointer | Callee |
| x3 | gp | Global pointer | — |
| x4 | tp | Thread pointer | — |
| x5-x7 | t0-t2 | Temporaries | Caller |
| x8 | s0/fp | Saved reg / frame pointer | Callee |
| x9 | s1 | Saved register | Callee |
| x10-x11 | a0-a1 | Args / return values | Caller |
| x12-x17 | a2-a7 | Arguments | Caller |
| x18-x27 | s2-s11 | Saved registers | Callee |
| x28-x31 | t3-t6 | Temporaries | Caller |

`pc` — program counter (not a GPR, no direct access via `mv`).

---

## Base Instruction Set (RV32I / RV64I)

### Arithmetic / Logic

| Mnemonic | Fmt | Operation | Usage |
|---|---|---|---|
| `add` | R | `rd = rs1 + rs2` | `add rd, rs1, rs2` |
| `sub` | R | `rd = rs1 - rs2` | `sub rd, rs1, rs2` |
| `addi` | I | `rd = rs1 + sext(imm)` | `addi rd, rs1, imm` |
| `and` | R | `rd = rs1 & rs2` | `and rd, rs1, rs2` |
| `or` | R | `rd = rs1 \| rs2` | `or rd, rs1, rs2` |
| `xor` | R | `rd = rs1 ^ rs2` | `xor rd, rs1, rs2` |
| `andi` | I | `rd = rs1 & sext(imm)` | `andi rd, rs1, imm` |
| `ori` | I | `rd = rs1 \| sext(imm)` | `ori rd, rs1, imm` |
| `xori` | I | `rd = rs1 ^ sext(imm)` | `xori rd, rs1, imm` |
| `sll` | R | `rd = rs1 << rs2[4:0]/[5:0]` | `sll rd, rs1, rs2` |
| `srl` | R | `rd = rs1 >>u rs2[4:0]/[5:0]` | `srl rd, rs1, rs2` |
| `sra` | R | `rd = rs1 >>s rs2[4:0]/[5:0]` | `sra rd, rs1, rs2` |
| `slli` | I | `rd = rs1 << shamt` | `slli rd, rs1, shamt` |
| `srli` | I | `rd = rs1 >>u shamt` | `srli rd, rs1, shamt` |
| `srai` | I | `rd = rs1 >>s shamt` | `srai rd, rs1, shamt` |
| `lui` | U | `rd = imm << 12` | `lui rd, imm` |
| `auipc` | U | `rd = pc + (imm << 12)` | `auipc rd, imm` |

### Comparison

| Mnemonic | Fmt | Operation | Usage |
|---|---|---|---|
| `slt` | R | `rd = (rs1 < rs2) ? 1 : 0` | `slt rd, rs1, rs2` |
| `sltu` | R | `rd = (rs1 < rs2) ? 1 : 0` | `sltu rd, rs1, rs2` |
| `slti` | I | `rd = (rs1 < sext(imm)) ? 1 : 0` | `slti rd, rs1, imm` |
| `sltiu` | I | `rd = (rs1 < sext(imm)) ? 1 : 0` | `sltiu rd, rs1, imm` |

### Branches (pc-relative)

| Mnemonic | Fmt | Operation | Usage |
|---|---|---|---|
| `beq` | B | `if (rs1 == rs2) pc += offset` | `beq rs1, rs2, label` |
| `bne` | B | `if (rs1 != rs2) pc += offset` | `bne rs1, rs2, label` |
| `blt` | B | `if (rs1 < rs2) pc += offset` | `blt rs1, rs2, label` |
| `bge` | B | `if (rs1 >= rs2) pc += offset` | `bge rs1, rs2, label` |
| `bltu` | B | `if (rs1 < rs2) pc += offset` | `bltu rs1, rs2, label` |
| `bgeu` | B | `if (rs1 >= rs2) pc += offset` | `bgeu rs1, rs2, label` |

Offset range: ±4 KiB (13-bit signed immediate, always even — bit 0 implicit 0). There's no `bgt`/`ble` hardware opcode; the assembler synthesizes them by swapping `rs1`/`rs2` on `blt`/`bge` (see [Pseudo-Instructions](#pseudo-instructions) below).

### Jumps

| Mnemonic | Fmt | Operation | Usage |
|---|---|---|---|
| `jal` | J | `rd = pc+4; pc += offset` | `jal rd, label` |
| `jalr` | I | `t = pc+4; pc = (rs1 + sext(imm)) & ~1; rd = t` | `jalr rd, rs1, imm` |

### Loads / Stores

| Mnemonic | Fmt | Operation | Usage |
|---|---|---|---|
| `lb` | I | `rd = sext(mem8[rs1+offset])` | `lb rd, offset(rs1)` |
| `lh` | I | `rd = sext(mem16[rs1+offset])` | `lh rd, offset(rs1)` |
| `lw` | I | `rd = sext(mem32[rs1+offset])` | `lw rd, offset(rs1)` |
| `lbu` | I | `rd = zext(mem8[rs1+offset])` | `lbu rd, offset(rs1)` |
| `lhu` | I | `rd = zext(mem16[rs1+offset])` | `lhu rd, offset(rs1)` |
| `sb` | S | `mem8[rs1+offset] = rs2[7:0]` | `sb rs2, offset(rs1)` |
| `sh` | S | `mem16[rs1+offset] = rs2[15:0]` | `sh rs2, offset(rs1)` |
| `sw` | S | `mem32[rs1+offset] = rs2[31:0]` | `sw rs2, offset(rs1)` |
| `lwu` | I | `rd = zext(mem32[rs1+offset])` | `lwu rd, offset(rs1)` |
| `ld` | I | `rd = mem64[rs1+offset]` | `ld rd, offset(rs1)` |
| `sd` | S | `mem64[rs1+offset] = rs2` | `sd rs2, offset(rs1)` |

`offset` is a 12-bit signed immediate (−2048..2047 bytes) relative to `rs1`. Misaligned accesses are architecturally permitted but may trap or run slower depending on the implementation — reflexrv should decide (and document) its policy explicitly.

### System / Environment

| Mnemonic | Fmt | Operation | Usage |
|---|---|---|---|
| `ecall` | I (SYSTEM) | trap into the execution environment | `ecall` |
| `ebreak` | I (SYSTEM) | trap to debugger | `ebreak` |
| `fence` | I (MISC-MEM) | orders device I/O and memory accesses | `fence pred, succ` |
| `fence.i` | I (MISC-MEM) | synchronizes instruction & data streams | `fence.i` |
| `csrrw` / `csrrs` / `csrrc` | I (SYSTEM) | atomically read-modify-write a CSR | `csrrw rd, csr, rs1` |
| `csrrwi` / `csrrsi` / `csrrci` | I (SYSTEM) | same, with a 5-bit immediate instead of `rs1` | `csrrwi rd, csr, imm` |

### Pseudo-Instructions

Not real opcodes — the assembler expands these to one or more real instructions. Worth knowing when reading `objdump -d` output (it usually re-collapses these back into the short form).

| Pseudo | Expands to | Usage |
|---|---|---|
| `nop` | `addi x0, x0, 0` | `nop` |
| `li` | `addi` alone, or `lui`+`addi` | `li rd, imm` |
| `mv` | `addi rd, rs, 0` | `mv rd, rs` |
| `not` | `xori rd, rs, -1` | `not rd, rs` |
| `neg` | `sub rd, x0, rs` | `neg rd, rs` |
| `seqz` | `sltiu rd, rs, 1` | `seqz rd, rs` |
| `snez` | `sltu rd, x0, rs` | `snez rd, rs` |
| `sltz` | `slt rd, rs, x0` | `sltz rd, rs` |
| `sgtz` | `slt rd, x0, rs` | `sgtz rd, rs` |
| `beqz` | `beq rs, x0, label` | `beqz rs, label` |
| `bnez` | `bne rs, x0, label` | `bnez rs, label` |
| `blez` | `bge x0, rs, label` | `blez rs, label` |
| `bgez` | `bge rs, x0, label` | `bgez rs, label` |
| `bltz` | `blt rs, x0, label` | `bltz rs, label` |
| `bgtz` | `blt x0, rs, label` | `bgtz rs, label` |
| `bgt` | `blt rt, rs, label` | `bgt rs, rt, label` |
| `ble` | `bge rt, rs, label` | `ble rs, rt, label` |
| `bgtu` | `bltu rt, rs, label` | `bgtu rs, rt, label` |
| `bleu` | `bgeu rt, rs, label` | `bleu rs, rt, label` |
| `j` | `jal x0, label` | `j label` |
| `jr` | `jalr x0, rs, 0` | `jr rs` |
| `ret` | `jalr x0, ra, 0` | `ret` |
| `call` | `auipc`+`jalr` pair | `call label` |
| `tail` | `auipc`+`jalr` pair (`rd=x0`) | `tail label` |

---

## Instruction Encoding

### Base 32-bit Formats (bits [1:0] = 11)

```
 31        25 24     20 19     15 14  12 11      7 6      0
+------------+---------+---------+------+---------+--------+
|   funct7   |   rs2   |   rs1   |funct3|    rd   | opcode | R-type
+------------+---------+---------+------+---------+--------+

 31                 20 19     15 14  12 11      7 6      0
+---------------------+---------+------+---------+--------+
|      imm[11:0]       |   rs1   |funct3|    rd   | opcode | I-type
+---------------------+---------+------+---------+--------+

 31        25 24     20 19     15 14  12 11      7 6      0
+------------+---------+---------+------+---------+--------+
| imm[11:5]  |   rs2   |   rs1   |funct3|imm[4:0] | opcode | S-type
+------------+---------+---------+------+---------+--------+

 31   30      25 24  20 19  15 14  12 11    8   7  6      0
+---+-----------+------+------+------+-------+---+--------+
|12 | imm[10:5] | rs2  | rs1  |funct3|imm[4:1]|11 | opcode | B-type
+---+-----------+------+------+------+-------+---+--------+

 31                                12 11      7 6      0
+-------------------------------------+---------+--------+
|             imm[31:12]               |    rd   | opcode | U-type
+-------------------------------------+---------+--------+

 31   30        21   20  19        12 11      7 6      0
+---+-------------+---+---------------+---------+--------+
|20 |  imm[10:1]  |11 |   imm[19:12]  |    rd   | opcode | J-type
+---+-------------+---+---------------+---------+--------+
```

All base instructions are 32 bits wide; `opcode` always occupies bits [6:0]. Branch/jump immediates encode odd-numbered bits out of order (hardware detail to save an adder bit) — always halfword-aligned, so bit 0 is implicit 0.

### Official Base Opcode Map (inst[1:0] = 11, i.e. all 32-bit+ instructions)

Rows = `inst[4:2]`, columns = `inst[6:5]`:

| 11 | 10 | 01 | 00 | inst[4:2] &#92; inst[6:5] |
|---|---|---|---|---|
| BRANCH | MADD | STORE | LOAD | **000** |
| JALR | MSUB | STORE-FP | LOAD-FP | **001** |
| *reserved* | NMSUB | custom-1 | custom-0 | **010** |
| JAL | NMADD | AMO | MISC-MEM | **011** |
| SYSTEM | OP-FP | OP | OP-IMM | **100** |
| *reserved* | *reserved* | LUI | AUIPC | **101** |
| custom-3/rv128 | custom-2/rv128 | OP-32 | OP-IMM-32 | **110** |
| ≥80b instr | 48b instr | 64b instr | 48b instr | **111** |

reflexrv (RV32/64 IMC, no float) only actually implements: `LOAD`, `STORE`, `MISC-MEM`, `OP-IMM`, `AUIPC`, `OP-IMM-32` (RV64), `OP`, `LUI`, `OP-32` (RV64), `AMO` (if A ext), `BRANCH`, `JALR`, `JAL`, `SYSTEM` — every other cell (`LOAD-FP`/`STORE-FP`/`MADD`/`MSUB`/`NMSUB`/`NMADD`/`OP-FP`, `custom-*`) belongs to extensions you're not building (F/D, custom, rv128) and can be treated as illegal-instruction in the decoder.

### Major Opcodes — Concrete Bit Patterns (bits [6:0])

| opcode (bin) | hex | Named group | Format | Instructions |
|---|---|---|---|---|
| 0110111 | 0x37 | LUI | U | LUI |
| 0010111 | 0x17 | AUIPC | U | AUIPC |
| 1101111 | 0x6F | JAL | J | JAL |
| 1100111 | 0x67 | JALR | I | JALR |
| 1100011 | 0x63 | BRANCH | B | BEQ, BNE, BLT, BGE, BLTU, BGEU |
| 0000011 | 0x03 | LOAD | I | LB, LH, LW, LBU, LHU (+ LWU, LD on RV64) |
| 0100011 | 0x23 | STORE | S | SB, SH, SW (+ SD on RV64) |
| 0010011 | 0x13 | OP-IMM | I | ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI |
| 0110011 | 0x33 | OP | R | ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND (+ M ext: MUL, DIV, REM, ...) |
| 0001111 | 0x0F | MISC-MEM | I | FENCE, FENCE.I |
| 1110011 | 0x73 | SYSTEM | I | ECALL, EBREAK, CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI |
| 0011011 | 0x1B | OP-IMM-32 | I | ADDIW, SLLIW, SRLIW, SRAIW (RV64 only) |
| 0111011 | 0x3B | OP-32 | R | ADDW, SUBW, SLLW, SRLW, SRAW (+ M ext W-forms) (RV64 only) |
| 0101111 | 0x2F | AMO | R | LR.W/D, SC.W/D, AMOSWAP, AMOADD, AMOXOR, AMOAND, AMOOR, AMOMIN, AMOMAX, ... (A ext) |

### funct3 / funct7 Disambiguation

Same opcode, `funct3` (bits [14:12]) — and for R-type, `funct7` (bits [31:25]) too — pick the actual instruction. Example: opcode `0110011` (OP):

| funct3 | funct7 | Instruction |
|---|---|---|
| 000 | 0000000 | ADD |
| 000 | 0100000 | SUB |
| 001 | 0000000 | SLL |
| 010 | 0000000 | SLT |
| 011 | 0000000 | SLTU |
| 100 | 0000000 | XOR |
| 101 | 0000000 | SRL |
| 101 | 0100000 | SRA |
| 110 | 0000000 | OR |
| 111 | 0000000 | AND |

`funct7` bit 5 (`0100000` vs `0000000`) toggles SUB/SRA vs ADD/SRL. The M extension reuses this same opcode with `funct7 = 0000001` for all of MUL/MULH/DIV/REM etc., keyed off `funct3`.

### RV64I-Specific Encodings

RV64 reuses every RV32I opcode as-is, plus adds two new opcodes and widens a few existing ones.

#### New opcodes: OP-IMM-32 / OP-32 (32-bit ops on a 64-bit core)

`ADDIW`/`ADDW` etc. operate on the low 32 bits and sign-extend the result into the full 64-bit register — needed because plain `ADDI`/`ADD` operate on the full XLEN=64 width.

**OP-IMM-32** — opcode `0011011` (0x1B), I-type:

| funct3 | funct7 (if shift) | Instruction |
|---|---|---|
| 000 | — | ADDIW |
| 001 | 0000000 | SLLIW |
| 101 | 0000000 | SRLIW |
| 101 | 0100000 | SRAIW |

**OP-32** — opcode `0111011` (0x3B), R-type:

| funct3 | funct7 | Instruction |
|---|---|---|
| 000 | 0000000 | ADDW |
| 000 | 0100000 | SUBW |
| 001 | 0000000 | SLLW |
| 101 | 0000000 | SRLW |
| 101 | 0100000 | SRAW |
| 000 | 0000001 | MULW (M ext) |
| 100 | 0000001 | DIVW (M ext) |
| 101 | 0000001 | DIVUW (M ext) |
| 110 | 0000001 | REMW (M ext) |
| 111 | 0000001 | REMUW (M ext) |

`SLLIW`/`SRLIW`/`SRAIW` use a **5-bit** shamt (bits [24:20], `funct7` bit 25 must be `0` — a nonzero value there is `reserved`/illegal), since a 32-bit shift only ever needs 0–31.

#### Widened LOAD / STORE (opcode unchanged, new funct3 values)

| funct3 | Instruction | Availability |
|---|---|---|
| 000 | LB / SB | RV32 + RV64 |
| 001 | LH / SH | RV32 + RV64 |
| 010 | LW / SW | RV32 + RV64 |
| 011 | LD / SD | RV64 only — full 64-bit load/store |
| 100 | LBU | RV32 + RV64 |
| 101 | LHU | RV32 + RV64 |
| 110 | LWU | RV64 only — zero-extends a 32-bit load into 64 bits |

#### Shift-amount width change: SLLI / SRLI / SRAI (opcode OP-IMM, `0010011`)

This is the trap for a decoder ported from RV32 to RV64 — the **same opcode**, but the immediate field is reinterpreted:

| | RV32 | RV64 |
|---|---|---|
| shamt field | `imm[4:0]` — bits [24:20] (5 bits, max shift 31) | `imm[5:0]` — bits [25:20] (6 bits, max shift 63) |
| funct7 → | full 7 bits, bits [31:25] | effectively **funct6**, bits [31:26] (bit 25 absorbed into shamt) |
| SLLI/SRLI select | `funct7 = 0000000` | `funct6 = 000000` |
| SRAI select | `funct7 = 0100000` | `funct6 = 010000` |

If reflexrv's decoder hard-codes a 5-bit shamt slice for `SLLI`/`SRLI`/`SRAI`, it will silently produce wrong results (or worse, alias into a "reserved" encoding) once RV64 test code shifts by more than 31 — worth a dedicated test case in `riscv-arch-test`/`riscv-tests` for both widths.

### Compressed Instructions (bits [1:0] = 00 / 01 / 10, C extension)

Whereas [bits [1:0] = 11](#official-base-opcode-map-inst10--11-ie-all-32-bit-instructions) marks a standard 32-bit+ instruction, the other three `inst[1:0]` values each mark a 16-bit compressed instruction, split into three "quadrants" (C0/C1/C2).

Compressed instructions — see [`rv_unprivileged_compressed_isa_cheatsheet.md`](./rv_unprivileged_compressed_isa_cheatsheet.md) for the full bit-layout diagrams and complete quadrant/funct3 instruction map.

---

## See Also

- [`README.md`](./README.md) — extension lists (Unprivileged + Privileged), ABI/width naming, GCC compile flags, binutils/GDB commands, and the minimal bare-metal test pattern
- [`rv_unprivileged_compressed_isa_cheatsheet.md`](./rv_unprivileged_compressed_isa_cheatsheet.md) — companion file, C extension (`inst[1:0]` = 00/01/10) encoding detail

---

© 2026 Henrry Andrian‍​‌​​‌​​​​‌‌​​‌​‌​‌‌​‌‌‌​​‌‌‌​​‌​​‌‌‌​​‌​​‌‌‌‌​​‌​‌​​​​​‌​‌‌​‌‌‌​​‌‌​​‌​​​‌‌‌​​‌​​‌‌​‌​​‌​‌‌​​​​‌​‌‌​‌‌‌​​​‌‌​​‌​​​‌‌​​​​​​‌‌​​‌​​​‌‌​‌‌​‍. All rights reserved.