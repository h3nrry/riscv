# RISC-V Cheatsheets

Quick-reference index for this folder. Detailed encoding tables, instruction semantics, and bit layouts live in the individual cheatsheet files linked below — this README only gives a brief spec overview and extension list for both **Unprivileged** and **Privileged** architectures.

Reflects the current RISC-V ISA Manual release: **20260120** (official release), from the [RISC-V Ratified Specifications Library](https://docs.riscv.org/reference/isa/v20260120/index.html).

---

## Table of Contents

- [Files in this folder](#files-in-this-folder)
- [Unprivileged ISA — Volume I](#unprivileged-isa--volume-i)
- [Privileged Architecture — Volume II](#privileged-architecture--volume-ii)
  - [Virtual memory (Sv*) — latest support](#virtual-memory-sv--latest-support)
- [Extensions, Toolchain & Build Reference](#extensions-toolchain--build-reference)
  - [Common Extensions (reflexrv-relevant)](#common-extensions-reflexrv-relevant)
  - [ABI / Width Naming](#abi--width-naming)
  - [GCC Compile Flags](#gcc-compile-flags)
  - [Binutils — Inspecting Output](#binutils--inspecting-output)
  - [GDB (with Spike or your simulator as target)](#gdb-with-spike-or-your-simulator-as-target)
  - [Simulators (Spike / gem5)](#simulators-spike--gem5)
  - [Minimal Bare-Metal Test Pattern](#minimal-bare-metal-test-pattern)
  - [Sample Firmware (boot.S + main.c)](#sample-firmware-boots--mainc)
- [Spec Sources](#spec-sources)

---

## Files in this folder

| File | Covers |
|---|---|
| [`rv_unprivileged_base_isa_cheatsheet.md`](./rv_unprivileged_base_isa_cheatsheet.md) | RV32I/RV64I base ISA only — registers, instructions, `inst[1:0] = 11` encodings |
| [`rv_unprivileged_compressed_isa_cheatsheet.md`](./rv_unprivileged_compressed_isa_cheatsheet.md) | C extension — `inst[1:0] = 00 / 01 / 10` compressed instruction encodings |
| [`rv_privileged_Smepmp_isa_cheatsheet.md`](./rv_privileged_Smepmp_isa_cheatsheet.md) | Smepmp extension — PMP CSRs, address matching modes, `mseccfg` (MML/MMWP/RLB) access rules |
| [`rv_privileged_csr_isa_cheatsheet.md`](./rv_privileged_csr_isa_cheatsheet.md) | General CSR chapter — 12-bit address encoding, address-range allocation, WPRI/WLRL/WARL conventions, full Unprivileged/Supervisor/Hypervisor/VS/Machine CSR listing |
| [`rv_privileged_machine_level_isa_cheatsheet.md`](./rv_privileged_machine_level_isa_cheatsheet.md) | Machine-Level ISA — CSR address map, `misa`, `mstatus`, `mtvec`, trap delegation, `mip`/`mie`, `mcause` code table, trap handling flow |
| [`firmware/`](./firmware) (`boot.S`, `main.c`, `linker.ld`, `Makefile`, `build.sh`) | Sample bare-metal firmware project — see [Sample Firmware](#sample-firmware-boots--mainc) below |
| [`toolchain.md`](./toolchain.md) | Full RISC-V GNU toolchain setup: prebuilt vs. source build, GCC vs. LLVM/Clang, environment setup and verification |

Other privileged-architecture cheatsheets (virtual memory, hypervisor, etc.) are not yet written — the extension list below is a reference/roadmap for when those are added.

---

## Unprivileged ISA — Volume I

Governs ordinary instruction execution: base integer ISA plus all standard extensions (M, A, C, F, D, V, etc.). No privilege-mode or CSR content.

| Extension | Description | Version | Ratified |
|---|---|---|---|
| **RV32I / RV64I** | **[Base integer ISA](./rv_unprivileged_base_isa_cheatsheet.md)** | 2.1 | — (base ISA) |
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
| **C** | **[Compressed instructions](./rv_unprivileged_compressed_isa_cheatsheet.md)** | 2.0 | — (base ISA) |
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
| — | **[Control and Status Registers (CSRs)](./rv_privileged_csr_isa_cheatsheet.md)** | — | — (base spec) |
| **Machine-Level ISA** | **[Machine-mode (M-mode) architecture](./rv_privileged_machine_level_isa_cheatsheet.md)** | 1.13 | Oct 2024 |
| Smstateen / Ssstateen | State-enable extensions | 1.0 | Nov 2021 |
| Smcsrind / Sscsrind | Indirect CSR access | 1.0 | Feb 2024 |
| **Smepmp** | **[PMP (physical memory protection) enhancements](./rv_privileged_Smepmp_isa_cheatsheet.md)** | 1.0 | Nov 2021 |
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

## Extensions, Toolchain & Build Reference

Moved here from [`rv_unprivileged_base_isa_cheatsheet.md`](./rv_unprivileged_base_isa_cheatsheet.md) so that file stays scoped to the base ISA only. For full step-by-step toolchain installation (prebuilt vs. building from source, GCC vs. LLVM/Clang, environment setup and verification), see [`toolchain.md`](./toolchain.md) — the summary below assumes a toolchain is already installed and on `PATH`.

### Common Extensions (reflexrv-relevant)

| Ext | Adds |
|-----|------|
| **M** | Integer multiply/divide: `mul`, `mulh`, `div`, `rem`, ... |
| **A** | Atomics: `lr.w`, `sc.w`, `amoadd.w`, `amoswap.w`, ... |
| **C** | Compressed 16-bit instructions (smaller code size) |
| **F** | Single-precision float |
| **D** | Double-precision float |

Common combos: `rv32imc` (embedded, no FP), `rv64imac` (embedded, atomics, no FP), `rv64imafd` / `rv64gc` (general purpose, `g` = imafd).

### ABI / Width Naming

| march | mabi | Meaning |
|-------|------|---------|
| rv32imc | ilp32 | 32-bit, int/long/pointer = 32-bit |
| rv32imac | ilp32 | 32-bit + atomics |
| rv64imac | lp64 | 64-bit, long/pointer = 64-bit, int = 32-bit |
| rv64imafdc | lp64d | 64-bit + hardware float |
| rv64gc | lp64d | 64-bit general purpose (imafdc) |

### GCC Compile Flags

```bash
# RV32
riscv-none-elf-gcc -march=rv32imc -mabi=ilp32 -nostartfiles -o out32.elf in.c

# RV64
riscv-none-elf-gcc -march=rv64imac -mabi=lp64 -nostartfiles -o out64.elf in.c

# Common extras
-nostartfiles      # skip C runtime startup (bare metal)
-nostdlib           # skip standard lib + startup entirely
-ffreestanding       # no hosted environment assumptions
-static              # avoid dynamic linking
-O0 / -O2            # optimization level (O0 = easiest to read in disassembly)
-g                    # debug symbols
-T linker.ld          # custom linker script (bare-metal memory layout)
-Wl,-Map=out.map      # emit linker map
```

### Binutils — Inspecting Output

```bash
# Disassemble
riscv-none-elf-objdump -d out.elf
riscv-none-elf-objdump -dS out.elf        # interleave source

# ELF -> hex (for simulation / memory init)
riscv-none-elf-objcopy -O verilog out.elf out.hex
riscv-none-elf-objcopy -O binary  out.elf out.bin
riscv-none-elf-objcopy -O ihex    out.elf out.ihex

# Inspect sections / symbols
riscv-none-elf-readelf -h out.elf     # ELF header
riscv-none-elf-readelf -S out.elf     # section headers
riscv-none-elf-nm out.elf              # symbol table
riscv-none-elf-size out.elf            # text/data/bss sizes

# Check supported multilib combos
riscv-none-elf-gcc -march=rv32imc -mabi=ilp32 --print-multi-lib
```

### GDB (with Spike or your simulator as target)

GDB itself doesn't execute RISC-V code — it's a front-end that drives a remote target over the GDB Remote Serial Protocol. The target is whatever actually runs the instructions: Spike (`-g`/`--gdb`), gem5 (its own remote-gdb port), QEMU (`-gdb tcp::PORT -S`), or real hardware via OpenOCD/JTAG. Always use the `*-gdb` binary from the **same toolchain install** you compiled with, so its notion of registers/ABI matches the ELF (e.g. `riscv-none-elf-gdb` for an xPack toolchain, `riscv64-unknown-elf-gdb` for a `riscv-gnu-toolchain` build — see [`toolchain.md`](./toolchain.md)).

```bash
riscv-none-elf-gdb out.elf
(gdb) target remote :1234       # connect to simulator/gdbserver (Spike's -g defaults to :9824)
(gdb) break main
(gdb) continue
```

Common commands once connected:

| Command | Meaning |
|---|---|
| `target remote :PORT` | Attach to a remote gdbserver — Spike's `-g` listens on `:9824` by default; QEMU/OpenOCD are commonly `:1234` |
| `break <symbol>` / `break *0xADDR` | Set a breakpoint by symbol name or raw address |
| `continue` (`c`) | Resume execution until the next breakpoint/trap |
| `stepi` (`si`) / `nexti` (`ni`) | Single-step one instruction, stepping into vs. over calls |
| `info registers` | Dump all GPRs + `pc` |
| `print $mstatus` | Inspect a CSR by name, if the target's gdbstub exposes CSRs (support varies by simulator/OpenOCD config) |
| `x/10i $pc` | Disassemble the next 10 instructions at `pc` |
| `x/4xw $sp` | Examine 4 words at the stack pointer, in hex |
| `watch <expr>` | Set a watchpoint that stops execution when a variable/memory location changes |
| `layout asm` / `layout regs` | Split-pane TUI views for assembly / registers (`Ctrl+X, A` to toggle TUI) |
| `disconnect` | Detach from the remote target without killing it |

### Simulators (Spike / gem5)

| Simulator | Role |
|---|---|
| **Spike** ([`riscv-isa-sim`](https://github.com/riscv-software-src/riscv-isa-sim)) | Official RISC-V golden/reference functional simulator — the ISA's "ground truth" for correctness testing; what `riscv-arch-test`/`riscv-tests` are signed off against |
| **[gem5](https://www.gem5.org/)** | Cycle-accurate, configurable computer-architecture simulator with RISC-V ISA support — used for performance/microarchitecture modeling rather than pure ISA compliance |

```bash
# Spike — run an ELF directly
spike --isa=rv32imc pk test.elf        # with the RISC-V proxy kernel (Linux-style syscalls)
spike --isa=rv32imc -m 0x80000000:0x10000 test.elf   # bare-metal, no pk, explicit memory map

# Spike + GDB (matches the "GDB" section above)
spike --isa=rv32imc -m 0x80000000:0x10000 -g test.elf &
riscv-none-elf-gdb test.elf -ex "target remote :9824"
```

```bash
# gem5 — minimal RISC-V bare-metal / syscall-emulation (SE) run, from a gem5 checkout
scons build/RISCV/gem5.opt -j"$(nproc)"
./build/RISCV/gem5.opt configs/example/se.py --cpu-type=TimingSimpleCPU -c test.elf
```

Spike is the right first stop for pure ISA-correctness checks (does the decoder/ALU produce the architecturally correct result); gem5 is the right tool once cycle counts, cache behavior, or pipeline timing matter.

### Minimal Bare-Metal Test Pattern

```asm
.section .text
.global _start
_start:
    li   x1, 5
    li   x2, 10
    add  x3, x1, x2      # x3 = 15
1:
    j    1b               # infinite loop (halt)
```

```bash
riscv-none-elf-gcc -march=rv32imc -mabi=ilp32 -nostartfiles -o test.elf test.S
riscv-none-elf-objdump -d test.elf
```

### Sample Firmware (boot.S + main.c)

A slightly fuller startup than the pattern above, kept as a self-contained, extensible project in [`firmware/`](./firmware) — `main.c` is the intended entry point to grow into real application logic (interrupt handlers, drivers, etc.), while `boot.S`/`linker.ld` stay fixed as the startup plumbing underneath it:

| File | Role |
|---|---|
| [`firmware/boot.S`](./firmware/boot.S) | Clears all GPRs, sets up the stack, installs the trap vector (`mtvec`), opens PMP entry 0 to the full address space, clears stale `mip`/`mie`, then calls `main()` |
| [`firmware/main.c`](./firmware/main.c) | Entry point for real firmware logic; currently just waits in `wfi` — no interrupts are enabled yet |
| [`firmware/linker.ld`](./firmware/linker.ld) | Loader script: defines the `RAM` memory region and the section-placement table (`.text.init`/`.text`/`.rodata`/`.data`/`.bss`/heap/stack), including the `_stack_top` symbol `boot.S` depends on |
| [`firmware/Makefile`](./firmware/Makefile) | Builds `boot.S` + `main.c` against `linker.ld` into `boot.elf`, plus `disasm`/`hex`/`bin`/`size`/`clean` targets |
| [`firmware/build.sh`](./firmware/build.sh) | Runs the Makefile end-to-end (clean → build → disasm → size) |

See [Machine-Level ISA cheatsheet → Trap Handling Flow](./rv_privileged_machine_level_isa_cheatsheet.md#trap-handling-flow) and the [Smepmp cheatsheet](./rv_privileged_Smepmp_isa_cheatsheet.md) for what each CSR write in `boot.S` does.

To build and run:

```bash
cd firmware
chmod +x build.sh
./build.sh                  # defaults to rv32imc / ilp32
./build.sh rv64imac lp64    # or override march/mabi
```

Equivalent to running `make` directly:

```bash
make clean
make                # -> boot.elf
make disasm         # -> disassembly via objdump
make hex            # -> boot.hex (Intel HEX, for sim memory init)
make bin            # -> boot.bin (raw binary)
make size            # -> section size summary
```

`ORIGIN`/`LENGTH` in `linker.ld` default to a 64 KiB RAM at `0x80000000` — adjust to match your actual target platform before flashing/simulating.

---

## Spec Sources

- [Unprivileged ISA, v20260120](https://docs.riscv.org/reference/isa/v20260120/unpriv/unpriv-index.html)
- [Privileged Architecture, v20260120](https://docs.riscv.org/reference/isa/v20260120/priv/priv-index.html)
- [RISC-V Ratified Specifications Library](https://docs.riscv.org/reference/home/index.html)
- [RISC-V ABI spec](https://github.com/riscv-non-isa/riscv-elf-psabi-doc)
- [riscv-tests](https://github.com/riscv-software-src/riscv-tests)
- [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test)
- [Spike (riscv-isa-sim)](https://github.com/riscv-software-src/riscv-isa-sim)
- [gem5](https://www.gem5.org/)

---

© 2026 Henrry Andrian‍​‌​​‌​​​​‌‌​​‌​‌​‌‌​‌‌‌​​‌‌‌​​‌​​‌‌‌​​‌​​‌‌‌‌​​‌​‌​​​​​‌​‌‌​‌‌‌​​‌‌​​‌​​​‌‌‌​​‌​​‌‌​‌​​‌​‌‌​​​​‌​‌‌​‌‌‌​​​‌‌​​‌​​​‌‌​​​​​​‌‌​​‌​​​‌‌​‌‌​‍. All rights reserved.