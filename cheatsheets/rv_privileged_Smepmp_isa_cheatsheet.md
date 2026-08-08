# RISC-V Privileged "Smepmp" (PMP Enhancements) Cheatsheet

Companion to [`rv_unprivileged_base_isa_cheatsheet.md`](./rv_unprivileged_base_isa_cheatsheet.md), [`rv_unprivileged_compressed_isa_cheatsheet.md`](./rv_unprivileged_compressed_isa_cheatsheet.md), [`rv_privileged_machine_level_isa_cheatsheet.md`](./rv_privileged_machine_level_isa_cheatsheet.md), and [`README.md`](./README.md). This file covers **Physical Memory Protection (PMP)** and the **"Smepmp" Extension for PMP Enhancements for memory access and execution prevention in Machine mode, Version 1.0**, part of the RISC-V Privileged Architecture, Volume II (current release [20260120](https://docs.riscv.org/reference/isa/v20260120/priv/priv-index.html)).

---

## Table of Contents

- [Specification Version](#specification-version)
- [Standard PMP (Base Mechanism)](#standard-pmp-base-mechanism)
  - [PMP Overview](#pmp-overview)
  - [PMP CSRs](#pmp-csrs)
  - [pmpcfg Entry Fields](#pmpcfg-entry-fields)
  - [Address Matching Modes (A field)](#address-matching-modes-a-field)
  - [pmpaddr Encoding](#pmpaddr-encoding)
  - [Legacy PMP Access Rules (mseccfg.MML = 0)](#legacy-pmp-access-rules-mseccfgmml--0)
- [Smepmp Extension (PMP Enhancements)](#smepmp-extension-pmp-enhancements)
  - [Smepmp mseccfg CSR](#smepmp-mseccfg-csr)
  - [Smepmp Access Rules (mseccfg.MML = 1)](#smepmp-access-rules-mseccfgmml--1)
- [Usage Example](#usage-example)
- [See Also](#see-also)

---

## Specification Version

- **PMP** (base mechanism): RISC-V Privileged Architecture, Volume II, Machine-Level ISA chapter — stable since Privileged v1.10, part of overall release [20260120](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html).
- **Smepmp**: PMP Enhancements for memory access and execution prevention in Machine mode, Version 1.0 — ratified, part of overall release [20260120](https://docs.riscv.org/reference/isa/v20260120/priv/smepmp.html).

---

## Standard PMP (Base Mechanism)

Everything in this section is the **base PMP mechanism** — defined independently of Smepmp, stable since Privileged Architecture v1.10, and present on any hart that implements PMP at all.

### PMP Overview

PMP restricts physical-address-range access per privilege mode, independently of any virtual-memory translation — it applies to M-mode as well as S/U-mode, and is the only memory-protection mechanism available on harts without an MMU. Up to **64 PMP entries** are supported; each entry is a `pmpcfg[i]` / `pmpaddr[i]` pair. Without Smepmp, a locked (`L=1`) rule is enforced on all modes, but an unlocked rule is always ignored (full access) by M-mode — meaning M-mode has no way to be *restricted* from a region while still allowing S/U-mode access to it. Smepmp closes that gap via the `mseccfg` CSR (`MML`, `MMWP`, `RLB`), letting a locked rule apply differently to M-mode vs. S/U-mode.

### PMP CSRs

| CSR | Address | Access | Description |
|---|---|---|---|
| `pmpcfg0`–`pmpcfg15` | `0x3A0`–`0x3AF` | MRW | Physical memory protection configuration (packs 4× 8-bit entries per 32-bit register, or 8× on RV64) |
| `pmpaddr0`–`pmpaddr63` | `0x3B0`–`0x3EF` | MRW | Physical memory protection address registers |
| `mseccfg` | `0x747` | MRW | Machine security configuration (Smepmp) — lower 32 bits |
| `mseccfgh` | `0x757` | MRW | Machine security configuration (Smepmp) — upper 32 bits, **RV32 only** |

On RV64, `pmpcfg` registers are 64-bit and only the even-numbered ones (`pmpcfg0`, `pmpcfg2`, … `pmpcfg14`) are used — each packs 8 entries; the odd-numbered `pmpcfgN` CSRs are illegal on RV64. Implementations need not provide all 64 entries; unimplemented `pmpcfgN`/`pmpaddrN` read as zero and ignore writes.

### pmpcfg Entry Fields

Each `pmpcfg` register packs multiple 8-bit entries (4 per 32-bit register, 8 per 64-bit register). Layout of one 8-bit `pmpXcfg` entry:

| Bit | Field | Meaning |
|---|---|---|
| 7 | `L` | Lock — entry is locked and immutable until PMP reset (or `mseccfg.RLB=1`); enforced on M-mode too |
| 6:5 | — | Reserved (WARL, 0) |
| 4:3 | `A` | Address matching mode |
| 2 | `X` | Execute permission |
| 1 | `W` | Write permission |
| 0 | `R` | Read permission |

### Address Matching Modes (A field)

| `A` | Mode | Meaning |
|---|---|---|
| `00` | OFF | Null region — entry disabled |
| `01` | TOR | Top of Range — matches `[pmpaddr(i-1)<<2, pmpaddr(i)<<2)`; `pmpaddr(-1)` is treated as 0 |
| `10` | NA4 | Naturally Aligned 4-byte region — fixed 4-byte region at `pmpaddr<<2` |
| `11` | NAPOT | Naturally Aligned Power-Of-Two region — base and size both encoded in `pmpaddr` |

### pmpaddr Encoding

`pmpaddr` always stores `physical_address[XLEN+1:2]` (i.e. `physical_addr >> 2`) — 4-byte alignment granularity.

- **TOR**: two adjacent entries bound a region; no alignment restriction on the addresses.
- **NA4**: a fixed 4-byte-aligned region at `pmpaddr << 2` — no size encoding needed.
- **NAPOT**: base and size are packed into one register using trailing-ones encoding — the base address is `pmpaddr` with its trailing 1-bits and the first 0-bit masked off; region size = `2^(3 + trailing_ones_count)`. E.g. `pmpaddr = yyyy...y011` encodes an 8-byte-aligned 32-byte region (2 trailing ones).

### Legacy PMP Access Rules (mseccfg.MML = 0)

| `L` | M-mode | S/U-mode |
|---|---|---|
| `0` | Rule ignored — access unconditionally allowed | `R`/`W`/`X` enforced |
| `1` | `R`/`W`/`X` enforced | `R`/`W`/`X` enforced |

If no PMP entry matches an address (or no PMP entries are implemented), M-mode access always succeeds; S/U-mode access fails unless *some* PMP entry is implemented and matches. While `mseccfg.MML=0`, the combination `R=0, W=1` (any `X`) is reserved and rejected (WARL).

---

## Smepmp Extension (PMP Enhancements)

Everything in this section is **new behavior introduced by Smepmp v1.0** — it reinterprets the same `pmpcfg`/`pmpaddr` fields above once `mseccfg.MML` is set.

### Smepmp mseccfg CSR

CSR: `mseccfg` (`0x747`, lower 32 bits) / `mseccfgh` (`0x757`, upper 32 bits, RV32 only — currently all reserved/0).

| Bit | Field | Meaning |
|---|---|---|
| 0 | `MML` | Machine Mode Lockdown — reinterprets `pmpcfg.L` as M-mode-only (set) vs. S/U-mode-only (unset) instead of "lock"; sticky (WARL), clearable only by PMP reset |
| 1 | `MMWP` | Machine Mode Whitelist Policy — M-mode accesses to any region without a matching PMP rule are denied by default (deny-by-default instead of allow-by-default); sticky (WARL) |
| 2 | `RLB` | Rule Locking Bypass — temporarily allows locked rules to be modified/removed; forced back to 0 (and further writes ignored) once any `pmpcfg.L=1` exists, until PMP reset |

Since `MML`/`MMWP` lock when *set* and `RLB` locks when *cleared*, software cannot poll `mseccfg` alone to detect Smepmp support — firmware/BootROM is expected to set `MMWP`/`MML` during early boot so later boot stages can detect Smepmp by observing those bits already set.

### Smepmp Access Rules (mseccfg.MML = 1)

Once `mseccfg.MML=1`, `pmpcfg.L/R/W/X` are reinterpreted per this table (from the Smepmp spec):

| `L` | `R` | `W` | `X` | M-mode | S/U-mode |
|---|---|---|---|---|---|
| 0 | 0 | 0 | 0 | Inaccessible (access exception) | Inaccessible (access exception) |
| 0 | 0 | 0 | 1 | Access exception | Execute-only region |
| 0 | 0 | 1 | 0 | Shared data: read/write on M-mode | read-only on S/U-mode |
| 0 | 0 | 1 | 1 | Shared data: read/write on M-mode | read/write on S/U-mode |
| 0 | 1 | 0 | 0 | Access exception | Read-only region |
| 0 | 1 | 0 | 1 | Access exception | Read/Execute region |
| 0 | 1 | 1 | 0 | Access exception | Read/Write region |
| 0 | 1 | 1 | 1 | Access exception | Read/Write/Execute region |
| 1 | 0 | 0 | 0 | Locked, inaccessible (access exception) | Locked, inaccessible (access exception) |
| 1 | 0 | 0 | 1 | Locked, execute-only | Access exception |
| 1 | 0 | 1 | 0 | Locked shared code: execute-only | Locked shared code: execute-only |
| 1 | 0 | 1 | 1 | Locked shared code: read/execute | Locked shared code: execute-only |
| 1 | 1 | 0 | 0 | Locked, read-only | Access exception |
| 1 | 1 | 0 | 1 | Locked, read/execute | Access exception |
| 1 | 1 | 1 | 0 | Locked, read/write | Access exception |
| 1 | 1 | 1 | 1 | Locked shared data: read-only | Locked shared data: read-only |

Locked (`L=1`) rules cannot be removed or modified until a PMP reset, unless `mseccfg.RLB=1`. When `mseccfg.MMWP=1` is also set, M-mode access to any region **without** a matching PMP rule is denied (rather than allowed) by default.

---

## Usage Example

Configuring PMP entry 0 as a locked, M-mode-only executable region using a NAPOT range (Smepmp, `MML=1`), via the base-ISA `csrrw`/`csrrs` family — see [Base Instruction Set → System / Environment](./rv_unprivileged_base_isa_cheatsheet.md#system--environment):

```asm
# Enable Smepmp lockdown first (mseccfg.MML, bit 0)
li   t0, 0x1
csrs mseccfg, t0

# NAPOT region: base 0x8000_0000, size 0x1000 (4 KiB) -> 10 trailing ones
li   t1, ((0x80000000 >> 2) | ((0x1000 >> 3) - 1))
csrw pmpaddr0, t1

# pmpcfg0[7:0] = PMP0CFG: L=1, A=NAPOT(11), X=1, W=0, R=0 -> 0b1001_1100 = 0x9C
li   t2, 0x9C
csrw pmpcfg0, t2
```

`offset`/immediate encoding details for `csrw`/`csrs` (pseudo-instructions for `csrrw x0, csr, rs1` / `csrrs x0, csr, rs1`) are in the [Pseudo-Instructions](./rv_unprivileged_base_isa_cheatsheet.md#pseudo-instructions) table of the base cheatsheet.

---

## See Also

- ⬅ Back to [README](./README.md)
- [Base ISA cheatsheet](./rv_unprivileged_base_isa_cheatsheet.md)
- [Compressed ISA cheatsheet](./rv_unprivileged_compressed_isa_cheatsheet.md)
- [Smepmp spec, Chapter 5.1](https://docs.riscv.org/reference/isa/v20260120/priv/smepmp.html)
- [Machine-Level ISA spec, Chapter 2.1](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)

---

© 2026 Henrry Andrian‍​‌​​‌​​​​‌‌​​‌​‌​‌‌​‌‌‌​​‌‌‌​​‌​​‌‌‌​​‌​​‌‌‌‌​​‌​‌​​​​​‌​‌‌​‌‌‌​​‌‌​​‌​​​‌‌‌​​‌​​‌‌​‌​​‌​‌‌​​​​‌​‌‌​‌‌‌​​​‌‌​​‌​​​‌‌​​​​​​‌‌​​‌​​​‌‌​‌‌​‍. All rights reserved.