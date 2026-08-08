# RISC-V Privileged Machine-Level ISA Cheatsheet

Companion to [`rv_unprivileged_base_isa_cheatsheet.md`](./rv_unprivileged_base_isa_cheatsheet.md), [`rv_unprivileged_compressed_isa_cheatsheet.md`](./rv_unprivileged_compressed_isa_cheatsheet.md), [`rv_privileged_Smepmp_isa_cheatsheet.md`](./rv_privileged_Smepmp_isa_cheatsheet.md), and [`README.md`](./README.md). This file covers the **Machine-Level ISA, Version 1.13** — Chapter 2.1 of the RISC-V Privileged Architecture, Volume II (current release [20260120](https://docs.riscv.org/reference/isa/v20260120/priv/priv-index.html)): the mandatory M-mode CSRs, trap handling, and machine-mode-only instructions. PMP CSRs (`pmpcfg`/`pmpaddr`/`mseccfg`) are a separate chapter — see the [Smepmp cheatsheet](./rv_privileged_Smepmp_isa_cheatsheet.md).

---

## Table of Contents

- [Specification Version](#specification-version)
- [Machine-Level CSR Address Table](#machine-level-csr-address-table)
- [misa — Machine ISA Register](#misa--machine-isa-register)
- [Identification CSRs](#identification-csrs)
- [mstatus / mstatush — Machine Status](#mstatus--mstatush--machine-status)
- [mtvec — Machine Trap-Vector Base Address](#mtvec--machine-trap-vector-base-address)
- [medeleg / mideleg — Trap Delegation](#medeleg--mideleg--trap-delegation)
- [mip / mie — Machine Interrupt Pending / Enable](#mip--mie--machine-interrupt-pending--enable)
- [mcause — Machine Cause](#mcause--machine-cause)
- [mepc / mtval / mscratch](#mepc--mtval--mscratch)
- [Counters and menvcfg](#counters-and-menvcfg)
- [Trap Handling Flow](#trap-handling-flow)
- [See Also](#see-also)

---

## Specification Version

Machine-Level ISA, Version 1.13 — part of the RISC-V Privileged Architecture, Volume II, overall release [20260120](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html).

---

## Machine-Level CSR Address Table

| CSR | Address | Access | Description |
|---|---|---|---|
| `mvendorid` | `0xF11` | MRO | Vendor ID |
| `marchid` | `0xF12` | MRO | Architecture ID |
| `mimpid` | `0xF13` | MRO | Implementation ID |
| `mhartid` | `0xF14` | MRO | Hart ID |
| `mconfigptr` | `0xF15` | MRO | Pointer to configuration data structure |
| `mstatus` | `0x300` | MRW | Machine status |
| `misa` | `0x301` | MRW | ISA and extensions |
| `medeleg` | `0x302` | MRW | Machine exception delegation |
| `mideleg` | `0x303` | MRW | Machine interrupt delegation |
| `mie` | `0x304` | MRW | Machine interrupt enable |
| `mtvec` | `0x305` | MRW | Machine trap-vector base address |
| `mcounteren` | `0x306` | MRW | Machine counter enable |
| `mstatush` | `0x310` | MRW | Additional machine status, **RV32 only** |
| `medelegh` | `0x312` | MRW | Upper 32 bits of `medeleg`, **RV32 only** |
| `menvcfg` | `0x30A` | MRW | Machine environment configuration |
| `menvcfgh` | `0x31A` | MRW | Upper 32 bits of `menvcfg`, **RV32 only** |
| `mcountinhibit` | `0x320` | MRW | Machine counter-inhibit |
| `mhpmevent3`–`mhpmevent31` | `0x323`–`0x33F` | MRW | Machine performance-monitoring event selectors |
| `mscratch` | `0x340` | MRW | Machine scratch register |
| `mepc` | `0x341` | MRW | Machine exception program counter |
| `mcause` | `0x342` | MRW | Machine trap cause |
| `mtval` | `0x343` | MRW | Machine trap value |
| `mip` | `0x344` | MRW | Machine interrupt pending |
| `mtinst` | `0x34A` | MRW | Machine trap instruction (transformed) |
| `mtval2` | `0x34B` | MRW | Machine second trap value |
| `mseccfg` / `mseccfgh` | `0x747` / `0x757` | MRW | Smepmp security config — see [Smepmp cheatsheet](./rv_privileged_Smepmp_isa_cheatsheet.md) |
| `pmpcfg0`–`pmpcfg15`, `pmpaddr0`–`pmpaddr63` | `0x3A0`–`0x3AF`, `0x3B0`–`0x3EF` | MRW | PMP config/address — see [Smepmp cheatsheet](./rv_privileged_Smepmp_isa_cheatsheet.md) |
| `mcycle` / `mcycleh` | `0xB00` / `0xB80` | MRW | Cycle counter (`mcycleh` RV32 only) |
| `minstret` / `minstreth` | `0xB02` / `0xB82` | MRW | Instructions-retired counter (`minstreth` RV32 only) |
| `mhpmcounter3`–`mhpmcounter31` (`...h`) | `0xB03`–`0xB1F` (`0xB83`–`0xB9F`) | MRW | Machine performance-monitoring counters |

---

## misa — Machine ISA Register

**Address:** `0x301`. WARL; a value of 0 means "not implemented" (no standard discovery). MXLEN = `2^MXL × 16`.

| MXL | XLEN |
|---|---|
| `1` | 32 |
| `2` | 64 |
| `3` | *Reserved* |

Extensions field: one bit per letter, bit *n* = character `'A'+n`. Set bits are a necessary but not sufficient indicator (a clear bit doesn't guarantee "not implemented" — it may just mean opcodes/CSRs are reserved rather than illegal).

| Bit | Letter | Meaning |
|---|---|---|
| 0 | A | Atomic extension |
| 1 | B | B extension (implies Zba+Zbb+Zbs) |
| 2 | C | Compressed extension |
| 3 | D | Double-precision floating-point |
| 4 | E | RV32E/64E base ISA |
| 5 | F | Single-precision floating-point |
| 7 | H | Hypervisor extension |
| 8 | I | RV32I/64I base ISA |
| 12 | M | Integer multiply/divide |
| 16 | Q | Quad-precision floating-point |
| 18 | S | Supervisor mode implemented |
| 20 | U | User mode implemented |
| 21 | V | Vector extension |
| 23 | X | Non-standard extensions present |

"E" always reads as the complement of "I" (unless `misa` is read-only 0). Disabling a dependency (e.g. `F=0` while `D=1`) clears the dependent bit too.

---

## Identification CSRs

| CSR | Access | Meaning |
|---|---|---|
| `mvendorid` | MRO | JEDEC manufacturer ID; 0 = not implemented / not a commercial vendor |
| `marchid` | MRO | Base microarchitecture ID, globally unique per architecture; 0 = not implemented |
| `mimpid` | MRO | Implementation/processor-version ID; 0 = not implemented |
| `mhartid` | MRO | Unique hart ID within the platform; hart 0 must always exist |
| `mconfigptr` | MRO | Physical address of a platform configuration data structure; 0 = none provided |

---

## mstatus / mstatush — Machine Status

`mstatus` tracks and controls the hart's current operating state. A restricted view is exposed to S-mode as `sstatus`. On RV32, `mstatush` (`0x310`) holds the fields that live in bits 63:32 on RV64.

| Bit (RV64) | Field | Meaning |
|---|---|---|
| 0 | — | WPRI (reserved) |
| 1 | `SIE` | Global interrupt-enable for S-mode |
| 2 | — | WPRI (reserved) |
| 3 | `MIE` | Global interrupt-enable for M-mode |
| 4 | — | WPRI (reserved) |
| 5 | `SPIE` | Previous value of `SIE`, saved on trap entry |
| 6 | `UBE` | U-mode explicit memory-access endianness (0 = little, 1 = big) |
| 7 | `MPIE` | Previous value of `MIE`, saved on trap entry |
| 8 | `SPP` | Privilege mode (S or U) active before the trap being handled in S-mode |
| 9:10 | `VS[1:0]` | Vector context status (Off/Initial/Clean/Dirty) |
| 11:12 | `MPP[1:0]` | Privilege mode active before the trap currently being handled in M-mode |
| 13:14 | `FS[1:0]` | Floating-point context status (Off/Initial/Clean/Dirty) |
| 15:16 | `XS[1:0]` | User-extension context status (Off/Initial/Clean/Dirty) |
| 17 | `MPRV` | Modify Privilege — loads/stores in M-mode use the `MPP` privilege level's translation/protection when set |
| 18 | `SUM` | Permit Supervisor User Memory access — lets S-mode read/write U-mode pages |
| 19 | `MXR` | Make Executable Readable — lets loads read execute-only pages |
| 20 | `TVM` | Trap Virtual Memory — traps `SFENCE.VMA`/`satp` writes in S-mode to M-mode |
| 21 | `TW` | Timeout Wait — traps `WFI` executed outside M-mode after a bounded time |
| 22 | `TSR` | Trap SRET — traps `SRET` executed in S-mode to M-mode |
| 23:31 | — | WPRI (reserved; newer extensions carve individual bits from this range — see note below) |
| 32:33 | `UXL[1:0]` | Effective XLEN for U-mode (same encoding as `misa.MXL`); **RV64 only** |
| 34:35 | `SXL[1:0]` | Effective XLEN for S-mode (same encoding as `misa.MXL`); **RV64 only** |
| 36 | `SBE` | S-mode explicit memory-access endianness |
| 37 | `MBE` | M-mode explicit memory-access endianness |
| 38:62 | — | WPRI (reserved) |
| 63 | `SD` | Set if `FS`/`VS`/`XS` indicate dirty state (summary bit) |

On RV32, `mstatus` only carries bits 0:31 above; `mstatush` (`0x310`) separately exposes bits 4 (`SBE`) and 5 (`MBE`) — the RV64-bit-36/37 fields shifted down by 32 — with the rest of `mstatush` reserved and `SD`/`UXL`/`SXL` not present at all (RV32 has no `UXL`/`SXL`, and `SD` instead occupies bit 31 of `mstatus` itself).

On trap entry to mode *x* from mode *y*: `xPIE ← xIE`, `xIE ← 0`, `xPP ← y`. On `xRET`: `xIE ← xPIE`, privilege ← `xPP`, `xPIE ← 1`, `xPP ←` least-privileged supported mode, and (if returning to a mode ≠ M) `MPRV ← 0`.

Newer additions not bit-mapped here (double-trap `MDT`/`SDT` bits from Smdbltrp/Ssdbltrp, landing-pad state from Zicfilp — both draw from the reserved 23:31 range above) are covered by their own extension chapters in the spec — see [See Also](#see-also).

---

## mtvec — Machine Trap-Vector Base Address

**Address:** `0x305`. WARL. `BASE` (bits `MXLEN-1:2`) must be 4-byte aligned; `MODE` may impose additional alignment.

| MODE | Name | Behavior |
|---|---|---|
| `0` | Direct | All traps set `pc = BASE` |
| `1` | Vectored | Synchronous exceptions set `pc = BASE`; interrupts set `pc = BASE + 4×cause` |
| `≥2` | — | *Reserved* |

Example: in Vectored mode, a machine-timer interrupt (`cause = 7`) jumps to `BASE + 0x1C`.

---

## medeleg / mideleg — Trap Delegation

By default all traps land in M-mode. In harts with S-mode, `medeleg`/`mideleg` **must** exist (and must not exist on harts without S-mode); setting a bit delegates that trap, when it occurs in S/U-mode, straight to the S-mode handler instead of M-mode.

- `medeleg` bit index = the `mcause` exception code it delegates (e.g. bit 8 = delegate U-mode `ECALL`).
- `mideleg` bit layout matches `mip`/`mie` (e.g. bit 5 = delegate STI).
- `medeleg[11]` (M-mode ECALL) and `medeleg[16]` (double trap) are always read-only zero — never delegatable.
- Traps never move to a *less*-privileged mode than where they occurred; delegation only routes traps sideways/down from M toward S, never the reverse.
- Delegating an interrupt masks it at the delegating level — e.g. setting `mideleg[5]` (STI) means STIs are no longer taken while executing in M-mode.
- On XLEN=32, `medelegh` (`0x312`) aliases `medeleg[63:32]`; it doesn't exist on RV64.

---

## mip / mie — Machine Interrupt Pending / Enable

Bit *i* in `mip`/`mie` corresponds to `mcause` interrupt cause *i*. Bits 15:0 are standard; bits ≥16 are platform/custom use.

| Bit | mip field | mie field | Interrupt |
|---|---|---|---|
| 1 | `SSIP` | `SSIE` | Supervisor software |
| 3 | `MSIP` | `MSIE` | Machine software |
| 5 | `STIP` | `STIE` | Supervisor timer |
| 7 | `MTIP` | `MTIE` | Machine timer |
| 9 | `SEIP` | `SEIE` | Supervisor external |
| 11 | `MEIP` | `MEIE` | Machine external |
| 13 | `LCOFIP` | `LCOFIE` | Local counter-overflow (Sscofpmf) |

`MEIP`, `MTIP`, and `MSIP` are read-only in `mip` (cleared via the interrupt controller / timer-compare register / memory-mapped `msip`, respectively). An interrupt traps to M-mode when: current mode is M with `mstatus.MIE=1`, or current mode has less privilege than M; **and** the bit is set in both `mip`/`mie`; **and** (if `mideleg` exists) the bit is clear in `mideleg`. Simultaneous M-mode interrupts are serviced in priority order: **MEI > MSI > MTI > SEI > SSI > STI > LCOFI**.

---

## mcause — Machine Cause

**Address:** `0x342`. Top bit = Interrupt flag; remaining bits = Exception Code (WLRL).

**Interrupts** (Interrupt bit = 1):

| Code | Meaning |
|---|---|
| 1 | Supervisor software interrupt |
| 3 | Machine software interrupt |
| 5 | Supervisor timer interrupt |
| 7 | Machine timer interrupt |
| 9 | Supervisor external interrupt |
| 11 | Machine external interrupt |
| 13 | Counter-overflow interrupt (Sscofpmf) |
| ≥16 | Designated for platform use |

**Exceptions** (Interrupt bit = 0):

| Code | Meaning |
|---|---|
| 0 | Instruction address misaligned |
| 1 | Instruction access fault |
| 2 | Illegal instruction |
| 3 | Breakpoint |
| 4 | Load address misaligned |
| 5 | Load access fault |
| 6 | Store/AMO address misaligned |
| 7 | Store/AMO access fault |
| 8 | Environment call from U-mode |
| 9 | Environment call from S-mode |
| 11 | Environment call from M-mode |
| 12 | Instruction page fault |
| 13 | Load page fault |
| 15 | Store/AMO page fault |
| 16 | Double trap |
| 18 | Software check |
| 19 | Hardware error |
| 24–31, 48–63 | Designated for custom use |

Codes 10, 14, 17, 20–23, 32–47, ≥64 are reserved. Load-reserved generates load exceptions; store-conditional and AMO generate store/AMO exceptions. Synchronous-exception priority (highest→lowest) when an instruction could raise several: instruction address breakpoint → instruction-fetch translation fault → instruction access fault → illegal instruction / misaligned instruction address / ECALL / EBREAK / load-store-AMO address breakpoint → (optionally) load/store misaligned → data translation fault → data access fault → (if not higher priority) load/store misaligned.

---

## mepc / mtval / mscratch

| CSR | Address | Meaning |
|---|---|---|
| `mepc` | `0x341` | Virtual address of the instruction that took the trap (or the instruction to resume at) |
| `mtval` | `0x343` | Exception-specific info: faulting virtual address (misaligned/access-fault/page-fault/breakpoint), faulting instruction bits (illegal-instruction, optional), or a cause code (software-check: `0`=none, `2`=Landing Pad Fault (Zicfilp), `3`=Shadow Stack Fault (Zicfiss)) |
| `mscratch` | `0x340` | Scratch register — conventionally used to stash a pointer to per-hart context at trap entry before general registers are saved |

---

## Counters and menvcfg

- `mcycle`/`minstret` (+ `mhpmcounter3`–`31`) are free-running 64-bit counters, gated by `mcountinhibit` (`0x320`) and exposed to lower modes via `mcounteren`/`scounteren`.
- `mhpmevent3`–`31` (`0x323`–`0x33F`) select the event each `mhpmcounterN` tracks.
- `menvcfg`/`menvcfgh` (`0x30A`/`0x31A`) configure environment behavior visible to lower privilege modes — e.g. `FIOM` (fence of I/O implies memory), cache-block operation enables (`CBIE`/`CBCFE`/`CBZE`), `PBMTE` (Svpbmt enable), `ADUE` (Svadu hardware A/D updates), and other per-extension enable bits added over time; see the spec for the full, still-growing field list.

---

## Trap Handling Flow

1. Hardware sets `mepc = pc` of the trapping/resuming instruction, `mcause` = the code, `mtval` = exception-specific info (or 0), `mstatus.MPIE = MIE`, `mstatus.MPP` = previous mode, `mstatus.MIE = 0`, then jumps per `mtvec`.
2. Handler saves registers (often via `mscratch` to get a scratch pointer first), reads `mcause` to dispatch, and (if `mcause`'s interrupt bit is set) may re-enable nested interrupts once critical state is saved.
3. Handler restores registers and executes `mret` — see [Pseudo-Instructions](./rv_unprivileged_base_isa_cheatsheet.md#pseudo-instructions)-adjacent system instructions in the base cheatsheet for the `csrrw`/`csrrs` family used to read/write these CSRs.

```asm
# minimal direct-mode M-mode trap handler skeleton
trap_handler:
    csrrw   sp, mscratch, sp      # swap in the trap stack, stash user sp in mscratch
    sw      t0, 0(sp)
    csrr    t0, mcause
    bltz    t0, is_interrupt      # mcause sign bit set -> interrupt, else exception
    # ... dispatch on exception code ...
    lw      t0, 0(sp)
    csrrw   sp, mscratch, sp      # restore original sp
    mret
```

`wfi` (Wait For Interrupt) may be executed in any mode with sufficient permission (see `mstatus.TW`); it is a hint that lets the hart stall until an interrupt becomes pending, then resumes at the following instruction (it does not itself take a trap).

---

## See Also

- ⬅ Back to [README](./README.md)
- [Base ISA cheatsheet](./rv_unprivileged_base_isa_cheatsheet.md)
- [Compressed ISA cheatsheet](./rv_unprivileged_compressed_isa_cheatsheet.md)
- [Smepmp (PMP Enhancements) cheatsheet](./rv_privileged_Smepmp_isa_cheatsheet.md)
- [Machine-Level ISA spec, Chapter 2.1](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)
- [Privileged Architecture, Volume II index](https://docs.riscv.org/reference/isa/v20260120/priv/priv-index.html)

---

© 2026 Henrry Andrian‍​‌​​‌​​​​‌‌​​‌​‌​‌‌​‌‌‌​​‌‌‌​​‌​​‌‌‌​​‌​​‌‌‌‌​​‌​‌​​​​​‌​‌‌​‌‌‌​​‌‌​​‌​​​‌‌‌​​‌​​‌‌​‌​​‌​‌‌​​​​‌​‌‌​‌‌‌​​​‌‌​​‌​​​‌‌​​​​​​‌‌​​‌​​​‌‌​‌‌​‍. All rights reserved.