# RISC-V Unprivileged Compressed ISA Cheatsheet

Companion to [`rv_unprivileged_base_isa_cheatsheet.md`](./rv_unprivileged_base_isa_cheatsheet.md) (the main RISC-V Unprivileged ISA Cheatsheet). This file covers only **`inst[1:0]` = 00 / 01 / 10** — the 16-bit compressed instruction encodings defined by the "C" extension, version 2.0, part of the RISC-V Unprivileged ISA spec (current release [20260120](https://docs.riscv.org/reference/isa/v20260120/unpriv/unpriv-index.html)).

`inst[1:0] = 11` (standard 32-bit+ instructions) is covered in the main cheatsheet's [Official Base Opcode Map](./rv_unprivileged_base_isa_cheatsheet.md#official-base-opcode-map-inst10--11-ie-all-32-bit-instructions).

---

## Table of Contents

- [Quadrant Overview](#quadrant-overview)
- [Compressed Opcode Map](#compressed-opcode-map)
- [Format Bit Layouts](#format-bit-layouts)
- [Quadrant / funct3 Instruction Map](#quadrant--funct3-instruction-map)
- [Quick Reference](#quick-reference)
- [Main cheatsheet (separate file →)](./rv_unprivileged_base_isa_cheatsheet.md)

---

## Quadrant Overview

| inst[1:0] | Quadrant | Length | Formats used |
|---|---|---|---|
| **00** | C0 | 16-bit | CIW, CL, CS |
| **01** | C1 | 16-bit | CI, CJ, CB, CA |
| **10** | C2 | 16-bit | CI, CR, CSS |
| 11 | — | 32-bit+ | *(not compressed — see main cheatsheet)* |

Within each quadrant, `funct3` (bits [15:13]) further selects the actual instruction — see the [Quadrant / funct3 Instruction Map](#quadrant--funct3-instruction-map) below.

`rd'`/`rs1'`/`rs2'` are **3-bit** register fields — they only address `x8`–`x15` (`s0`–`a5`), which is why not every register works with every compressed instruction. Plain `rd`/`rs1`/`rs2` (5-bit) fields address the full `x0`–`x31`.

---

## Compressed Opcode Map

Grid form of the table above — same layout style as the main cheatsheet's Official Base Opcode Map. Columns are the quadrant (`inst[1:0]`), rows are `funct3` (`inst[15:13]`):

| 10 | 01 | 00 | funct3 &#92; quadrant |
|---|---|---|---|
| C.SLLI | C.NOP / C.ADDI | C.ADDI4SPN | **000** |
| C.FLDSP / C.LQSP | C.JAL (RV32) / C.ADDIW (RV64) | C.FLD / C.LQ | **001** |
| C.LWSP | C.LI | C.LW | **010** |
| C.FLWSP (RV32) / C.LDSP (RV64) | C.ADDI16SP / C.LUI | C.FLW (RV32) / C.LD (RV64) | **011** |
| C.JR / C.MV / C.EBREAK / C.JALR / C.ADD | C.SRLI / C.SRAI / C.ANDI / C.SUB / C.XOR / C.OR / C.AND / C.SUBW / C.ADDW | *reserved* | **100** |
| C.FSDSP / C.SQSP | C.J | C.FSD / C.SQ | **101** |
| C.SWSP | C.BEQZ | C.SW | **110** |
| C.FSWSP (RV32) / C.SDSP (RV64) | C.BNEZ | C.FSW (RV32) / C.SD (RV64) | **111** |

Cell `(funct3=100, quadrant=01)` packs multiple instructions because it's further split by bits [11:10] and [6:5] — see the detailed [Quadrant / funct3 Instruction Map](#quadrant--funct3-instruction-map) below for the exact sub-decode. Non-bold entries (`C.FLD`, `C.FSW`, `C.FLDSP`, etc.) are D/F-extension or RV128 forms — not emitted for reflexrv's `rv32imc`/`rv64imac` builds and safe to treat as illegal in the decoder.

---

## Format Bit Layouts

```
 15  14  13 12 11  10  9  8  7  6  5  4  3  2  1  0
+---------------+------------------+----------+-----+
|    funct4     |     rd/rs1       |   rs2    | op  | CR   (register)
+---------------+------------------+----------+-----+

 15  14  13 12 11  10  9  8  7  6  5  4  3  2  1  0
+-----------+---+------------------+----------+-----+
|  funct3   |imm|     rd/rs1       |   imm    | op  | CI   (immediate)
+-----------+---+------------------+----------+-----+

 15  14  13 12  11  10  9  8  7  6  5  4  3  2  1  0
+-----------+------------------------+----------+-----+
|  funct3   |          imm           |   rs2    | op  | CSS  (stack-rel store)
+-----------+------------------------+----------+-----+

 15  14  13 12  11  10  9  8  7  6  5  4  3  2  1  0
+-----------+------------------------+-------+-----+
|  funct3   |          imm            | rd'   | op  | CIW  (wide immediate)
+-----------+------------------------+-------+-----+

 15  14  13 12  11  10  9  8  7  6  5  4  3  2  1  0
+-----------+--------+---------+--------+-------+-----+
|  funct3   |  imm   |  rs1'   |  imm   | rd'   | op  | CL   (load)
+-----------+--------+---------+--------+-------+-----+

 15  14  13 12  11  10  9  8  7  6  5  4  3  2  1  0
+-----------+--------+---------+--------+-------+-----+
|  funct3   |  imm   |  rs1'   |  imm   | rs2'  | op  | CS   (store)
+-----------+--------+---------+--------+-------+-----+

 15  14  13  12  11  10  9  8  7  6  5  4  3  2  1  0
+----------------+---------+-------+-------+-----+
|    funct6      | rd'/rs1'| funct2| rs2'  | op  | CA   (arithmetic reg-reg)
+----------------+---------+-------+-------+-----+

 15  14  13 12  11  10  9  8  7  6  5  4  3  2  1  0
+-----------+--------+---------+------------+-----+
|  funct3   | offset |  rs1'   |   offset   | op  | CB   (branch / shift-imm)
+-----------+--------+---------+------------+-----+

 15  14  13 12  11  10  9  8  7  6  5  4  3  2  1  0
+-----------+----------------------------------+-----+
|  funct3   |         jump target[11:1]        | op  | CJ   (jump)
+-----------+----------------------------------+-----+
```

---

## Quadrant / funct3 Instruction Map

| Quadrant (`op`) | funct3 [15:13] | Format | Instruction(s) | Notes |
|---|---|---|---|---|
| 00 (C0) | 000 | CIW | **C.ADDI4SPN** | `rd' = sp + nzuimm`; illegal if imm=0 |
| 00 (C0) | 001 | CL | C.FLD / C.LQ | D ext / RV128 — not in reflexrv (IMC) |
| 00 (C0) | 010 | CL | **C.LW** | 32-bit load, RV32 + RV64 |
| 00 (C0) | 011 | CL | C.FLW (RV32,F ext) / **C.LD** (RV64) | reflexrv uses C.LD on RV64 only |
| 00 (C0) | 100 | — | *reserved* | |
| 00 (C0) | 101 | CS | C.FSD / C.SQ | D ext / RV128 — not in reflexrv |
| 00 (C0) | 110 | CS | **C.SW** | 32-bit store, RV32 + RV64 |
| 00 (C0) | 111 | CS | C.FSW (RV32,F ext) / **C.SD** (RV64) | reflexrv uses C.SD on RV64 only |
| 01 (C1) | 000 | CI | **C.NOP** (rd=0) / **C.ADDI** (rd≠0) | |
| 01 (C1) | 001 | CJ / CI | C.JAL (**RV32 only**) / **C.ADDIW** (**RV64 only**, rd≠0) | opcode reused per width |
| 01 (C1) | 010 | CI | **C.LI** | |
| 01 (C1) | 011 | CI | **C.ADDI16SP** (rd=2) / **C.LUI** (rd≠0,2) | |
| 01 (C1) | 100 | CB/CA | **C.SRLI / C.SRAI / C.ANDI** (bits[11:10]=00/01/10) | shift-imm / and-imm group |
| 01 (C1) | 100 | CA | **C.SUB / C.XOR / C.OR / C.AND** (bits[11:10]=11, funct2 [6:5]) | reg-reg, bit 12=0 |
| 01 (C1) | 100 | CA | **C.SUBW / C.ADDW** (bits[11:10]=11, bit 12=1) | **RV64/RV128 only** |
| 01 (C1) | 101 | CJ | **C.J** | unconditional jump |
| 01 (C1) | 110 | CB | **C.BEQZ** | branch if rs1'==0 |
| 01 (C1) | 111 | CB | **C.BNEZ** | branch if rs1'!=0 |
| 10 (C2) | 000 | CI | **C.SLLI** | |
| 10 (C2) | 001 | CI | C.FLDSP / C.LQSP | D ext / RV128 — not in reflexrv |
| 10 (C2) | 010 | CI | **C.LWSP** | rd≠0 |
| 10 (C2) | 011 | CI | C.FLWSP (RV32,F ext) / **C.LDSP** (RV64) | reflexrv uses C.LDSP on RV64 only |
| 10 (C2) | 100 | CR | bit12=0: **C.JR** (rs2=0) / **C.MV** (rs2≠0) | |
| 10 (C2) | 100 | CR | bit12=1: **C.EBREAK** (rs1=rs2=0) / **C.JALR** (rs2=0) / **C.ADD** (rs2≠0) | |
| 10 (C2) | 101 | CSS | C.FSDSP / C.SQSP | D ext / RV128 — not in reflexrv |
| 10 (C2) | 110 | CSS | **C.SWSP** | |
| 10 (C2) | 111 | CSS | C.FSWSP (RV32,F ext) / **C.SDSP** (RV64) | reflexrv uses C.SDSP on RV64 only |

For reflexrv's `rv32imc`/`rv64imac` builds, the F/D rows (C.FLD, C.FSW, C.FLDSP, etc.) never get emitted by GCC and can be decoded as illegal — only bold entries above are relevant. Full bit mapping and immediate-field bit ordering: ISA manual, Chapter 27 ("C" extension) — worth hand-verifying against `riscv-none-elf-objdump -d` output on a small `.c` test file compiled with `-march=rv32imc`/`rv64imac` (no `-mno-relax`/no `-fno-rvc`) to see which compressed forms your toolchain actually emits.

---

## Quick Reference

- ⬅ Back to [main cheatsheet](./rv_unprivileged_base_isa_cheatsheet.md)
- [ISA manual, Chapter 27 — "C" Extension for Compressed Instructions](https://docs.riscv.org/reference/isa/v20260120/unpriv/c-st-ext.html)

---

© 2026 Henrry Andrian‍​‌​​‌​​​​‌‌​​‌​‌​‌‌​‌‌‌​​‌‌‌​​‌​​‌‌‌​​‌​​‌‌‌‌​​‌​‌​​​​​‌​‌‌​‌‌‌​​‌‌​​‌​​​‌‌‌​​‌​​‌‌​‌​​‌​‌‌​​​​‌​‌‌​‌‌‌​​​‌‌​​‌​​​‌‌​​​​​​‌‌​​‌​​​‌‌​‌‌​‍. All rights reserved.