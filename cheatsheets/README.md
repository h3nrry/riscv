# RISC-V Cheatsheets

Quick-reference index for this folder. Detailed encoding tables, instruction semantics, and bit layouts live in the individual cheatsheet files linked below — this README only gives a brief spec overview and extension list for both **Unprivileged** and **Privileged** architectures.

Reflects the current RISC-V ISA Manual release: **20260120** (official release), from the [RISC-V Ratified Specifications Library](https://docs.riscv.org/reference/isa/v20260120/index.html).

---

## Files in this folder

| File | Covers |
|---|---|
| [`rv_unprivileged_base_isa_cheatsheet.md`](./rv_unprivileged_base_isa_cheatsheet.md) | RV32I/RV64I base ISA — registers, instructions, `inst[1:0] = 11` encodings, GCC/binutils/GDB usage |
| [`rv_unprivileged_compressed_isa_cheatsheet.md`](./rv_unprivileged_compressed_isa_cheatsheet.md) | C extension — `inst[1:0] = 00 / 01 / 10` compressed instruction encodings |

Privileged-architecture cheatsheets (CSRs, trap handling, virtual memory, etc.) are not yet written — the extension list below is a reference/roadmap for when those are added.

---

## Unprivileged ISA — Volume I

Governs ordinary instruction execution: base integer ISA plus all standard extensions (M, A, C, F, D, V, etc.). No privilege-mode or CSR content.

| Extension | Description | Version | Ratified |
|---|---|---|---|
| RV32I / RV64I | Base integer ISA | 2.1 | — (base ISA) |
| RV32E / RV64E | Reduced base integer ISA (embedded) | 2.0 | Jan 2023 |
| Zifencei | Instruction-fetch fence | 2.0 | — (base ISA) |
| Zicsr | CSR read/modify-write instructions | 2.0 | — (base ISA) |
| Zicntr / Zihpm | Base counters / hardware performance counters | 2.0 | Mar 2023 |
| Zihintntl | Non-temporal locality hints | 1.0 | May 2023 |
| Zihintpause | Pause hint | 2.0 | Feb 2021 |
| Zimop | May-be-operations | 1.0 | Mar 2024 |
| Zicond | Integer conditional operations | 1.0.0 | Nov 2023 |
| M | Integer multiply/divide | 2.0 | — (base ISA) |
| A | Atomic instructions | 2.1 | — (base ISA) |
| Zawrs | Wait-on-reservation-set | 1.01 | Nov 2022 |
| Zacas | Atomic compare-and-swap | 1.0.0 | Nov 2023 |
| Zabha | Byte/halfword atomics | 1.0 | Apr 2024 |
| Zalasr | Atomic load-acquire / store-release | 1.0 | — (recent, see spec) |
| Ztso | Total store ordering | 1.0 | Jan 2023 |
| CMO | Cache management operations | 1.0.0 | Nov 2021 |
| F / D / Q | Single / double / quad-precision floating-point | 2.2 | — (base ISA) |
| Zfh / Zfhmin | Half-precision floating-point | 1.0 | Nov 2021 |
| BF16 | BFloat16 floating-point | 1.0 | Jun 2024 |
| Zfa | Additional floating-point instructions | 1.0 | Sep 2023 |
| Zfinx / Zdinx / Zhinx / Zhinxmin | Floating-point in integer registers | 1.0 | Nov 2021 |
| **C** | **Compressed instructions** — see `rv_unprivileged_compressed_isa_cheatsheet.md` | 2.0 | — (base ISA) |
| Zc* | Code-size reduction extensions | 1.0.0 | Apr 2023 |
| B | Bit manipulation | 1.0.0 | Apr 2024 |
| V | Vector extension | 1.0 | Nov 2021 |
| Scalar Crypto | Scalar & entropy-source cryptography | 1.0.1 | Nov 2021 |
| Vector Crypto | Vector cryptography | 1.0 | Sep 2023 |
| CFI (Zicfiss/Zicfilp) | Control-flow integrity — shadow stacks & landing pads | — | Jun 2024 |
| Zilsd / Zclsd | Load/store pair for RV32 | 1.0 | Feb 2025 |

reflexrv targets **RV32IMC** / **RV64IMAC** — everything else in the table above is scoped out of the decoder (treated as illegal-instruction) unless the design is later extended.

---

## Privileged Architecture — Volume II

Governs machine/supervisor-mode execution: CSRs, traps, interrupts, virtual memory, and hypervisor support. Applies once reflexrv needs an OS/supervisor mode rather than pure bare-metal execution.

| Extension | Description | Version | Ratified |
|---|---|---|---|
| — | Control and Status Registers (CSRs) | — | — (base spec) |
| Machine-Level ISA | Machine-mode (M-mode) architecture | 1.13 | Oct 2024 |
| Smstateen / Ssstateen | State-enable extensions | 1.0 | Nov 2021 |
| Smcsrind / Sscsrind | Indirect CSR access | 1.0 | Feb 2024 |
| Smepmp | PMP (physical memory protection) enhancements | 1.0 | Nov 2021 |
| Smcntrpmf | Cycle/instret privilege-mode filtering | 1.0 | Nov 2023 |
| Smrnmi | Resumable non-maskable interrupts | 1.0 | Jun 2024 |
| Smcdeleg / Ssccfg | Counter delegation | 1.0 | Mar 2024 |
| Smdbltrp | Double-trap (M-mode) | 1.0 | Aug 2024 |
| Smctr / Ssctr | Control transfer records | 1.0 | Nov 2024 |
| Supervisor-Level ISA | Supervisor-mode (S-mode) architecture | 1.13 | Oct 2024 |
| Sstc | Supervisor-mode timer interrupts | 1.0 | Nov 2021 |
| Sscofpmf | Count-overflow / mode-based filtering | 1.0 | Nov 2021 |
| H | Hypervisor support | 1.0 | Nov 2021 |
| Ssdbltrp | Double-trap (S-mode) | 1.0 | Aug 2024 |
| Smmpm / Smnpm / Ssnpm / Supm / Sspm | Pointer masking | 1.0.0 | Oct 2024 |
| Smaia / Ssaia | Advanced Interrupt Architecture | — | Jun 2023 |
| Ssqosid | Quality-of-Service (QoS) identifiers | — | Jun 2024 |

### Virtual memory (Sv*) — latest support

Address-translation schemes and their supporting extensions, defined within the Supervisor-Level ISA chapter:

| Scheme / Extension | Applies to | Notes | Ratified |
|---|---|---|---|
| Sv32 | RV32 | 2-level page table | — (base spec) |
| Sv39 | RV64 | 3-level, most common RV64 default | — (base spec) |
| Sv48 | RV64 | 4-level, larger address space | — (base spec) |
| Sv57 | RV64 | 5-level, current largest standardized scheme | Nov 2021 |
| Svnapot | RV32/RV64 | Naturally aligned power-of-2 pages | Nov 2021 |
| Svpbmt | RV32/RV64 | Page-based memory types | Nov 2021 |
| Svinval | RV32/RV64 | Fine-grained address-translation cache invalidation | Nov 2021 |
| Svadu | RV32/RV64 | Hardware A/D (accessed/dirty) bit updates | Nov 2023 |
| Svvptc | RV32/RV64 | **Latest** — obviates memory-management instructions after marking PTEs valid | Jun 2024 |

---

## Spec Sources

- [Unprivileged ISA, v20260120](https://docs.riscv.org/reference/isa/v20260120/unpriv/unpriv-index.html)
- [Privileged Architecture, v20260120](https://docs.riscv.org/reference/isa/v20260120/priv/priv-index.html)
- [RISC-V Ratified Specifications Library](https://docs.riscv.org/reference/home/index.html)

---

© 2026 Henrry Andrian‍​‌​​‌​​​​‌‌​​‌​‌​‌‌​‌‌‌​​‌‌‌​​‌​​‌‌‌​​‌​​‌‌‌‌​​‌​‌​​​​​‌​‌‌​‌‌‌​​‌‌​​‌​​​‌‌‌​​‌​​‌‌​‌​​‌​‌‌​​​​‌​‌‌​‌‌‌​​​‌‌​​‌​​​‌‌​​​​​​‌‌​​‌​​​‌‌​‌‌​‍. All rights reserved.