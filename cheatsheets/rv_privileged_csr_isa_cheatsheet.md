# RISC-V Privileged CSR Cheatsheet

Companion to [`rv_unprivileged_base_isa_cheatsheet.md`](./rv_unprivileged_base_isa_cheatsheet.md), [`rv_unprivileged_compressed_isa_cheatsheet.md`](./rv_unprivileged_compressed_isa_cheatsheet.md), [`rv_privileged_machine_level_isa_cheatsheet.md`](./rv_privileged_machine_level_isa_cheatsheet.md), [`rv_privileged_Smepmp_isa_cheatsheet.md`](./rv_privileged_Smepmp_isa_cheatsheet.md), and [`README.md`](./README.md). This file covers **Chapter 1, "Control and Status Registers (CSRs)"** — the general 12-bit CSR address space, the encoding convention that maps address bits to privilege/access rules, and the complete cross-privilege-level CSR listing, part of the RISC-V Privileged Architecture, Volume II (current release [20260120](https://docs.riscv.org/reference/isa/v20260120/priv/priv-index.html)).

Per-CSR bit-field detail for M-mode registers lives in the [Machine-Level ISA cheatsheet](./rv_privileged_machine_level_isa_cheatsheet.md); PMP CSR fields live in the [Smepmp cheatsheet](./rv_privileged_Smepmp_isa_cheatsheet.md). This file is the address-space map that ties them together.

---

## Table of Contents

- [Specification Version](#specification-version)
- [CSR Address Encoding](#csr-address-encoding)
- [CSR Address Range Allocation](#csr-address-range-allocation)
- [Field Encoding Conventions](#field-encoding-conventions)
- [High-Half CSRs & Width Modulation](#high-half-csrs--width-modulation)
- [Unprivileged CSR Listing](#unprivileged-csr-listing)
- [Supervisor-Level CSR Listing](#supervisor-level-csr-listing)
- [Hypervisor and VS CSR Listing](#hypervisor-and-vs-csr-listing)
- [Machine-Level CSR Listing](#machine-level-csr-listing)
- [Indirect CSR (Smcsrind/Sscsrind) Mappings](#indirect-csr-smcsrindsscsrind-mappings)
- [See Also](#see-also)

---

## Specification Version

Chapter 1, "Control and Status Registers (CSRs)" — RISC-V Privileged Architecture, Volume II, overall release [20260120](https://docs.riscv.org/reference/isa/v20260120/priv/priv-csrs.html).

---

## CSR Address Encoding

The SYSTEM major opcode encodes all privileged instructions, split into two classes: atomic CSR read-modify-write instructions (Zicsr — `csrrw`/`csrrs`/`csrrc`/immediate forms, see the [base ISA cheatsheet](./rv_unprivileged_base_isa_cheatsheet.md#system--environment)) and all other privileged instructions (trap-return, `wfi`, `sfence.vma`, etc.).

A 12-bit space (`csr[11:0]`) is reserved for up to 4,096 CSRs. The upper 4 bits (`csr[11:8]`) encode default accessibility:

| Bits | Meaning |
|---|---|
| `csr[11:10]` | `00`/`01`/`10` = read/write; `11` = read-only |
| `csr[9:8]` | Lowest privilege level required to access the CSR — `00` = Unprivileged/User, `01` = Supervisor, `10` = Hypervisor/VS, `11` = Machine |

Registers and instructions are associated with one privilege level but remain accessible from any *higher* privilege level. Accessing a non-existent CSR, or an existing CSR without sufficient privilege, raises an illegal-instruction exception (or a virtual-instruction exception under the H extension); writing a read-only CSR also raises illegal-instruction. Standard CSRs have no side effects on reads, but may on writes.

Machine-mode CSRs `0x7A0`–`0x7BF` are reserved for the debug system: `0x7A0`–`0x7AF` are M-mode-visible, `0x7B0`–`0x7BF` are debug-mode-only (M-mode access to the latter raises illegal-instruction).

---

## CSR Address Range Allocation

| Privilege group | `[11:10]` | `[9:8]` | `[7:4]` | Range | Access |
|---|---|---|---|---|---|
| Unprivileged/User | `00` | `00` | `XXXX` | `0x000`–`0x0FF` | Standard R/W |
| Unprivileged/User | `01` | `00` | `XXXX` | `0x400`–`0x4FF` | Standard R/W |
| Unprivileged/User | `10` | `00` | `XXXX` | `0x800`–`0x8FF` | Custom R/W |
| Unprivileged/User | `11` | `00` | `0XXX` | `0xC00`–`0xC7F` | Standard read-only |
| Unprivileged/User | `11` | `00` | `10XX` | `0xC80`–`0xCBF` | Standard read-only |
| Unprivileged/User | `11` | `00` | `11XX` | `0xCC0`–`0xCFF` | Custom read-only |
| Supervisor | `00` | `01` | `XXXX` | `0x100`–`0x1FF` | Standard R/W |
| Supervisor | `01` | `01` | `0XXX` | `0x500`–`0x57F` | Standard R/W |
| Supervisor | `01` | `01` | `10XX` | `0x580`–`0x5BF` | Standard R/W |
| Supervisor | `01` | `01` | `11XX` | `0x5C0`–`0x5FF` | Custom R/W |
| Supervisor | `10` | `01` | `0XXX` | `0x900`–`0x97F` | Standard R/W |
| Supervisor | `10` | `01` | `10XX` | `0x980`–`0x9BF` | Standard R/W |
| Supervisor | `10` | `01` | `11XX` | `0x9C0`–`0x9FF` | Custom R/W |
| Supervisor | `11` | `01` | `0XXX` | `0xD00`–`0xD7F` | Standard read-only |
| Supervisor | `11` | `01` | `10XX` | `0xD80`–`0xDBF` | Standard read-only |
| Supervisor | `11` | `01` | `11XX` | `0xDC0`–`0xDFF` | Custom read-only |
| Hypervisor/VS | `00` | `10` | `XXXX` | `0x200`–`0x2FF` | Standard R/W |
| Hypervisor/VS | `01` | `10` | `0XXX` | `0x600`–`0x67F` | Standard R/W |
| Hypervisor/VS | `01` | `10` | `10XX` | `0x680`–`0x6BF` | Standard R/W |
| Hypervisor/VS | `01` | `10` | `11XX` | `0x6C0`–`0x6FF` | Custom R/W |
| Hypervisor/VS | `10` | `10` | `0XXX` | `0xA00`–`0xA7F` | Standard R/W |
| Hypervisor/VS | `10` | `10` | `10XX` | `0xA80`–`0xABF` | Standard R/W |
| Hypervisor/VS | `10` | `10` | `11XX` | `0xAC0`–`0xAFF` | Custom R/W |
| Hypervisor/VS | `11` | `10` | `0XXX` | `0xE00`–`0xE7F` | Standard read-only |
| Hypervisor/VS | `11` | `10` | `10XX` | `0xE80`–`0xEBF` | Standard read-only |
| Hypervisor/VS | `11` | `10` | `11XX` | `0xEC0`–`0xEFF` | Custom read-only |
| Machine | `00` | `11` | `XXXX` | `0x300`–`0x3FF` | Standard R/W |
| Machine | `01` | `11` | `0XXX` | `0x700`–`0x77F` | Standard R/W |
| Machine | `01` | `11` | `100X` | `0x780`–`0x79F` | Standard R/W |
| Machine | `01` | `11` | `1010` | `0x7A0`–`0x7AF` | Standard R/W debug CSRs |
| Machine | `01` | `11` | `1011` | `0x7B0`–`0x7BF` | Debug-mode-only CSRs |
| Machine | `01` | `11` | `11XX` | `0x7C0`–`0x7FF` | Custom R/W |
| Machine | `10` | `11` | `0XXX` | `0xB00`–`0xB7F` | Standard R/W |
| Machine | `10` | `11` | `10XX` | `0xB80`–`0xBBF` | Standard R/W |
| Machine | `10` | `11` | `11XX` | `0xBC0`–`0xBFF` | Custom R/W |
| Machine | `11` | `11` | `0XXX` | `0xF00`–`0xF7F` | Standard read-only |
| Machine | `11` | `11` | `10XX` | `0xF80`–`0xFBF` | Standard read-only |
| Machine | `11` | `11` | `11XX` | `0xFC0`–`0xFFF` | Custom read-only |

Custom-use ranges above are guaranteed never to be redefined by future standard extensions. Counters are the only CSRs currently *shadowed* (read-only at a lower privilege level, aliased read-write at a higher one) — this lets native code run unmodified inside a virtualized environment while still trapping only genuinely illegal accesses.

---

## Field Encoding Conventions

Abbreviations used throughout this file and the other privileged cheatsheets to describe individual CSR bit/field behavior:

| Label | Meaning |
|---|---|
| **WPRI** | Reserved Writes Preserve Values, Reads Ignore Values — software must not assume anything about reads, and must preserve the field's existing bits on a read-modify-write of other fields in the same register |
| **WLRL** | Write/Read-Only Legal Values — only a defined subset of bit patterns are legal; software must only write legal values, and reads are only guaranteed legal after a legal write |
| **WARL** | Write Any Values, Reads Legal Values — any value may be written, but a read always returns some legal value; the accepted range can be probed by write-then-read |

Access-type prefixes seen in the listings below: **U**nprivileged, **S**upervisor, **H**ypervisor, **M**achine, **D**ebug, followed by **RO** (read-only) or **RW** (read/write) — e.g. `MRW` = Machine-level, read/write.

---

## High-Half CSRs & Width Modulation

If a standard CSR is wider than XLEN, an explicit read/write only touches the least-significant XLEN bits. Some standard CSRs (e.g. the Zicntr counters) are always 64 bits even on RV32 — for each of these, a *high-half CSR* with the same name plus a trailing `h` (e.g. `timeh`) aliases bits 63:32, giving RV32 software a way to reach them. High-half CSRs only exist when XLEN=32; on RV64 their addresses are reserved and typically raise illegal-instruction.

If a CSR's width itself changes (e.g. SXLEN/UXLEN toggling via `mstatus.SXL`/`UXL`), writable fields carry over positionally into the new width (zero-extended if growing, truncated if shrinking); this event is not a read or write of the CSR and triggers no side effects.

---

## Unprivileged CSR Listing

| Number | Access | Name | Description |
|---|---|---|---|
| `0x001` | URW | `fflags` | Floating-point accrued exceptions |
| `0x002` | URW | `frm` | Floating-point dynamic rounding mode |
| `0x003` | URW | `fcsr` | Floating-point control/status (`frm` + `fflags`) |
| `0x008` | URW | `vstart` | Vector start position |
| `0x009` | URW | `vxsat` | Fixed-point accrued saturation flag |
| `0x00A` | URW | `vxrm` | Fixed-point rounding mode |
| `0x00F` | URW | `vcsr` | Vector control and status |
| `0xC20` | URO | `vl` | Vector length |
| `0xC21` | URO | `vtype` | Vector data type register |
| `0xC22` | URO | `vlenb` | Vector register length, in bytes |
| `0x011` | URW | `ssp` | Shadow stack pointer (Zicfiss) |
| `0x015` | URW | `seed` | Seed for cryptographic random-bit generators |
| `0x017` | URW | `jvt` | Table-jump base vector and control (Zcmt) |
| `0xC00` | URO | `cycle` | Cycle counter (`rdcycle`) |
| `0xC01` | URO | `time` | Timer (`rdtime`) |
| `0xC02` | URO | `instret` | Instructions-retired counter (`rdinstret`) |
| `0xC03`–`0xC1F` | URO | `hpmcounter3`–`hpmcounter31` | Performance-monitoring counters |
| `0xC80` | URO | `cycleh` | Upper 32 bits of `cycle`, **RV32 only** |
| `0xC81` | URO | `timeh` | Upper 32 bits of `time`, **RV32 only** |
| `0xC82` | URO | `instreth` | Upper 32 bits of `instret`, **RV32 only** |
| `0xC83`–`0xC9F` | URO | `hpmcounter3h`–`hpmcounter31h` | Upper 32 bits of the `hpmcounterN` counters, **RV32 only** |

---

## Supervisor-Level CSR Listing

| Number | Access | Name | Description |
|---|---|---|---|
| `0x100` | SRW | `sstatus` | Supervisor status |
| `0x104` | SRW | `sie` | Supervisor interrupt-enable |
| `0x105` | SRW | `stvec` | Supervisor trap-handler base address |
| `0x106` | SRW | `scounteren` | Supervisor counter enable |
| `0x10A` | SRW | `senvcfg` | Supervisor environment configuration |
| `0x120` | SRW | `scountinhibit` | Supervisor counter-inhibit |
| `0x140` | SRW | `sscratch` | Supervisor scratch register |
| `0x141` | SRW | `sepc` | Supervisor exception program counter |
| `0x142` | SRW | `scause` | Supervisor trap cause |
| `0x143` | SRW | `stval` | Supervisor trap value |
| `0x144` | SRW | `sip` | Supervisor interrupt pending |
| `0xDA0` | SRO | `scountovf` | Supervisor count overflow |
| `0x150`–`0x157` | SRW | `siselect`, `sireg`–`sireg6` | Supervisor indirect register select + 6 aliases (see [Indirect CSR mappings](#indirect-csr-smcsrindsscsrind-mappings)) |
| `0x180` | SRW | `satp` | Supervisor address translation and protection |
| `0x14D` | SRW | `stimecmp` | Supervisor timer compare |
| `0x15D` | SRW | `stimecmph` | Upper 32 bits of `stimecmp`, **RV32 only** |
| `0x5A8` | SRW | `scontext` | Supervisor-mode debug/trace context register |
| `0x181` | SRW | `srmcfg` | Supervisor resource-management configuration |
| `0x10C`–`0x10F` | SRW | `sstateen0`–`sstateen3` | Supervisor State Enable registers 0–3 |
| `0x14E`,`0x14F`,`0x15F` | SRW | `sctrctl`, `sctrstatus`, `sctrdepth` | Supervisor Control Transfer Records control/status/depth |

---

## Hypervisor and VS CSR Listing

| Number | Access | Name | Description |
|---|---|---|---|
| `0x600` | HRW | `hstatus` | Hypervisor status |
| `0x602` | HRW | `hedeleg` | Hypervisor exception delegation |
| `0x603` | HRW | `hideleg` | Hypervisor interrupt delegation |
| `0x604` | HRW | `hie` | Hypervisor interrupt-enable |
| `0x606` | HRW | `hcounteren` | Hypervisor counter enable |
| `0x607` | HRW | `hgeie` | Hypervisor guest external interrupt-enable |
| `0x612` | HRW | `hedelegh` | Upper 32 bits of `hedeleg`, **RV32 only** |
| `0x643` | HRW | `htval` | Hypervisor trap value |
| `0x644` | HRW | `hip` | Hypervisor interrupt pending |
| `0x645` | HRW | `hvip` | Hypervisor virtual interrupt pending |
| `0x64A` | HRW | `htinst` | Hypervisor trap instruction (transformed) |
| `0xE12` | HRO | `hgeip` | Hypervisor guest external interrupt pending |
| `0x60A` | HRW | `henvcfg` | Hypervisor environment configuration |
| `0x61A` | HRW | `henvcfgh` | Upper 32 bits of `henvcfg`, **RV32 only** |
| `0x680` | HRW | `hgatp` | Hypervisor guest address translation and protection |
| `0x6A8` | HRW | `hcontext` | Hypervisor-mode debug/trace context register |
| `0x605` | HRW | `htimedelta` | Delta for VS/VU-mode timer |
| `0x615` | HRW | `htimedeltah` | Upper 32 bits of `htimedelta`, **RV32 only** |
| `0x60C`–`0x60F` | HRW | `hstateen0`–`hstateen3` | Hypervisor State Enable registers 0–3 |
| `0x61C`–`0x61F` | HRW | `hstateen0h`–`hstateen3h` | Upper 32 bits of `hstateenN`, **RV32 only** |
| `0x200` | HRW | `vsstatus` | Virtual supervisor status |
| `0x204` | HRW | `vsie` | Virtual supervisor interrupt-enable |
| `0x205` | HRW | `vstvec` | Virtual supervisor trap-handler base address |
| `0x240` | HRW | `vsscratch` | Virtual supervisor scratch register |
| `0x241` | HRW | `vsepc` | Virtual supervisor exception program counter |
| `0x242` | HRW | `vscause` | Virtual supervisor trap cause |
| `0x243` | HRW | `vstval` | Virtual supervisor trap value |
| `0x244` | HRW | `vsip` | Virtual supervisor interrupt pending |
| `0x280` | HRW | `vsatp` | Virtual supervisor address translation and protection |
| `0x250`–`0x257` | HRW | `vsiselect`, `vsireg`–`vsireg6` | Virtual supervisor indirect register select + 6 aliases |
| `0x24D` | HRW | `vstimecmp` | Virtual supervisor timer compare |
| `0x25D` | HRW | `vstimecmph` | Upper 32 bits of `vstimecmp`, **RV32 only** |
| `0x24E` | HRW | `vsctrctl` | Virtual Supervisor Control Transfer Records control |

---

## Machine-Level CSR Listing

Full address listing for completeness — bit-field detail for the trap/status registers lives in the [Machine-Level ISA cheatsheet](./rv_privileged_machine_level_isa_cheatsheet.md); `pmpcfg`/`pmpaddr`/`mseccfg` detail lives in the [Smepmp cheatsheet](./rv_privileged_Smepmp_isa_cheatsheet.md).

| Number | Access | Name | Description |
|---|---|---|---|
| `0xF11`–`0xF15` | MRO | `mvendorid`, `marchid`, `mimpid`, `mhartid`, `mconfigptr` | Machine information registers |
| `0x300`–`0x306` | MRW | `mstatus`, `misa`, `medeleg`, `mideleg`, `mie`, `mtvec`, `mcounteren` | Machine trap setup |
| `0x310`,`0x312` | MRW | `mstatush`, `medelegh` | Upper-32-bit aliases, **RV32 only** |
| `0x340`–`0x344` | MRW | `mscratch`, `mepc`, `mcause`, `mtval`, `mip` | Machine trap handling |
| `0x34A`,`0x34B` | MRW | `mtinst`, `mtval2` | Machine trap instruction / second trap value |
| `0x350`–`0x357` | MRW | `miselect`, `mireg`–`mireg6` | Machine indirect register select + 6 aliases |
| `0x30A`,`0x31A` | MRW | `menvcfg`, `menvcfgh` | Machine environment configuration (+ RV32 upper half) |
| `0x747`,`0x757` | MRW | `mseccfg`, `mseccfgh` | Smepmp security config — see [Smepmp cheatsheet](./rv_privileged_Smepmp_isa_cheatsheet.md) |
| `0x3A0`–`0x3AF` | MRW | `pmpcfg0`–`pmpcfg15` | PMP configuration — see [Smepmp cheatsheet](./rv_privileged_Smepmp_isa_cheatsheet.md) |
| `0x3B0`–`0x3EF` | MRW | `pmpaddr0`–`pmpaddr63` | PMP address registers — see [Smepmp cheatsheet](./rv_privileged_Smepmp_isa_cheatsheet.md) |
| `0x30C`–`0x30F` | MRW | `mstateen0`–`mstateen3` | Machine State Enable registers 0–3 |
| `0x31C`–`0x31F` | MRW | `mstateen0h`–`mstateen3h` | Upper 32 bits of `mstateenN`, **RV32 only** |
| `0x740`–`0x744` | MRW | `mnscratch`, `mnepc`, `mncause`, `mnstatus` | Resumable NMI (Smrnmi) registers |
| `0xB00`,`0xB02` | MRW | `mcycle`, `minstret` | Machine cycle / instructions-retired counters |
| `0xB03`–`0xB1F` | MRW | `mhpmcounter3`–`mhpmcounter31` | Machine performance-monitoring counters |
| `0xB80`,`0xB82` | MRW | `mcycleh`, `minstreth` | Upper 32 bits, **RV32 only** |
| `0xB83`–`0xB9F` | MRW | `mhpmcounter3h`–`mhpmcounter31h` | Upper 32 bits of `mhpmcounterN`, **RV32 only** |
| `0x320`–`0x324`…`0x33F` | MRW | `mcountinhibit`, `mcyclecfg`, `minstretcfg`, `mhpmevent3`–`mhpmevent31` | Machine counter setup / event selectors |
| `0x721`–`0x73F` | MRW | `mcyclecfgh`, `minstretcfgh`, `mhpmevent3h`–`mhpmevent31h` | Upper 32 bits of the above, **RV32 only** |
| `0x34E` | MRW | `mctrctl` | Machine Control Transfer Records control |
| `0x7A0`–`0x7A3`,`0x7A8` | MRW | `tselect`, `tdata1`–`tdata3`, `mcontext` | Debug/trace trigger registers (shared with debug mode) |
| `0x7B0`–`0x7B3` | DRW | `dcsr`, `dpc`, `dscratch0`, `dscratch1` | Debug-mode-only registers |

---

## Indirect CSR (Smcsrind/Sscsrind) Mappings

The `*iselect`/`*ireg`–`*ireg6` CSRs (M-mode: `miselect`/`mireg*`; S-mode: `siselect`/`sireg*`; VS-mode: `vsiselect`/`vsireg*`) provide an indirection layer: write a value to `*iselect`, then access the mapped register through `*ireg`. This exists so extensions can add many more logical CSRs than the flat 4096-entry address space could hold directly.

| `*iselect` | M-mode `mireg` | S/VS-mode `sireg`/`vsireg` |
|---|---|---|
| `0x30`–`0x3F` | `iprio0`–`iprio15` | `iprio0`–`iprio15` |
| `0x40` | — | `cycle` (via `sireg`), `cyclecfg` (via `sireg2`) |
| `0x42` | — | `instret` (via `sireg`), `instretcfg` (via `sireg2`) |
| `0x43`–`0x5F` | — | `hpmcounter3`–`hpmcounter31` (`sireg`) / `hpmevent3`–`hpmevent31` (`sireg2`) |
| `0x70` | `eidelivery` | `eidelivery` |
| `0x72` | `eithreshold` | `eithreshold` |
| `0x80`–`0xBF` | `eip0`–`eip63` | `eip0`–`eip63` |
| `0xC0`–`0xFF` | `eie0`–`eie63` | `eie0`–`eie63` |
| `0x200`–`0x2FF` (S/VS only) | — | `ctrsource0`–`ctrsource255` (`sireg`) / `ctrtarget*` (`sireg2`) / `ctrdata*` (`sireg3`) |

RV32 only: `sireg4`/`sireg5` alias the upper 32 bits of the counter/event values reached via `sireg`/`sireg2` (e.g. `cycleh`, `cyclecfgh`). VS-mode mirrors the S-mode mapping exactly, addressed through `vsiselect`/`vsireg*` instead.

---

## See Also

- ⬅ Back to [README](./README.md)
- [Base ISA cheatsheet](./rv_unprivileged_base_isa_cheatsheet.md)
- [Compressed ISA cheatsheet](./rv_unprivileged_compressed_isa_cheatsheet.md)
- [Machine-Level ISA cheatsheet](./rv_privileged_machine_level_isa_cheatsheet.md)
- [Smepmp (PMP Enhancements) cheatsheet](./rv_privileged_Smepmp_isa_cheatsheet.md)
- [Control and Status Registers, Chapter 1](https://docs.riscv.org/reference/isa/v20260120/priv/priv-csrs.html)
- [Privileged Architecture, Volume II index](https://docs.riscv.org/reference/isa/v20260120/priv/priv-index.html)

---

© 2026 Henrry Andrian‍​‌​​‌​​​​‌‌​​‌​‌​‌‌​‌‌‌​​‌‌‌​​‌​​‌‌‌​​‌​​‌‌‌‌​​‌​‌​​​​​‌​‌‌​‌‌‌​​‌‌​​‌​​​‌‌‌​​‌​​‌‌​‌​​‌​‌‌​​​​‌​‌‌​‌‌‌​​​‌‌​​‌​​​‌‌​​​​​​‌‌​​‌​​​‌‌​‌‌​‍. All rights reserved.