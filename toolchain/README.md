# reflexrv — RISC-V GNU Toolchain Setup

Location in repo: `riscv/doc/toolchain.md`
Companion script: `riscv/toolchain/setup_toolchain.sh`

This document describes how to clone, configure, and build the RISC-V GNU toolchain used to
compile test programs for reflexrv, supporting **both RV32 and RV64** from a single install.

The toolchain itself is **not** committed to this repo (build output can be several GB). Only
this documentation and the setup script are version-controlled; the built toolchain lives
outside the repo at `/opt/riscv`.

---

## 1. Prerequisites

On Ubuntu/Debian (including WSL):

```bash
sudo apt update
sudo apt install -y autoconf automake autotools-dev curl python3 python3-pip python3-tomli \
  libmpc-dev libmpfr-dev libgmp-dev gawk build-essential bison flex texinfo gperf libtool \
  patchutils bc zlib1g-dev libexpat-dev ninja-build git cmake libglib2.0-dev libslirp-dev
```

> Package requirements shift slightly between toolchain releases — if `configure` or `make`
> complains about a missing dependency, check the "Prerequisites" section of the current
> [riscv-gnu-toolchain README](https://github.com/riscv-collab/riscv-gnu-toolchain#installation-newlibtoolchain)
> for the exact list at the version you're building.

---

## 2. Clone the Toolchain

```bash
git clone --recursive https://github.com/riscv-collab/riscv-gnu-toolchain
cd riscv-gnu-toolchain
```

`--recursive` is required — the repo pulls in GCC, binutils, newlib, and GDB as submodules.

### Pin to a specific release (recommended)

Building against a moving `master` branch means the toolchain you get today may differ from
what you get in six months. Pin to a tagged release for reproducibility:

```bash
git tag -l                     # list available release tags
git checkout <tag>              # e.g. a specific dated release tag
git submodule update --init --recursive
```

Record whichever tag/commit you chose in this doc (see [§6 Notes](#6-notes)) so the build is
reproducible later.

---

## 3. Configure & Build — Multilib (Recommended: one toolchain, both 32 and 64)

This builds a **single** install that supports both RV32 and RV64 — you switch widths per
compile with `-march=`/`-mabi=` flags, rather than maintaining two separate toolchains.

```bash
./configure --prefix=/opt/riscv \
  --with-multilib-generator="rv32imc-ilp32--;rv64imac-lp64--"
make -j$(nproc)
```

- `--prefix=/opt/riscv` — install location (outside this repo)
- `--with-multilib-generator="..."` — restricts the build to exactly the arch/ABI
  combinations reflexrv needs (`rv32imc`/`ilp32` and `rv64imac`/`lp64`), rather than the full
  default multilib set — meaningfully faster to build. Adjust these strings to match
  reflexrv's actual supported extensions if they change.

Build time is significant (expect well over 30 minutes depending on hardware) — this compiles
GCC, binutils, and newlib from source.

---

## 4. Alternative — Separate 32-bit / 64-bit Installs

Only use this if you specifically need isolated toolchain installs rather than one multilib
build (e.g. matching the repo's `toolchain/32/` and `toolchain/64/` folders to fully separate
installs instead of shared config). This means building twice and using twice the disk space.

```bash
# RV32 only
./configure --prefix=/opt/riscv32 --with-arch=rv32imc --with-abi=ilp32
make -j$(nproc)

# RV64 only — run in a fresh clone, or `make clean` between builds
./configure --prefix=/opt/riscv64 --with-arch=rv64imac --with-abi=lp64
make -j$(nproc)
```

---

## 5. Environment Setup & Verification

After the multilib build (§3):

```bash
export RISCV=/opt/riscv
export PATH=$RISCV/bin:$PATH
```

Add these lines to `~/.bashrc` (or your shell profile) so they persist across sessions, or
source them from `riscv/toolchain/32/env.sh` / `riscv/toolchain/64/env.sh` per width, as set
up in the companion scripts.

Verify the install and confirm both widths are available:

```bash
riscv64-unknown-elf-gcc --version
riscv64-unknown-elf-gcc -march=rv32imc -mabi=ilp32 --print-multi-lib
riscv64-unknown-elf-gcc -march=rv64imac -mabi=lp64 --print-multi-lib
```

Compile a quick test to confirm each width works end to end:

```bash
# RV32
riscv64-unknown-elf-gcc -march=rv32imc -mabi=ilp32 -nostartfiles -o test32.elf test.S
riscv64-unknown-elf-objdump -d test32.elf

# RV64
riscv64-unknown-elf-gcc -march=rv64imac -mabi=lp64 -nostartfiles -o test64.elf test.S
riscv64-unknown-elf-objdump -d test64.elf
```

---

## 6. Notes

- **Toolchain source**: `riscv-collab/riscv-gnu-toolchain`
- **Pinned tag/commit**: _fill in once chosen — e.g. `2024.xx.xx`_
- **Build type**: multilib (`rv32imc-ilp32`, `rv64imac-lp64`)
- **Install path convention**: `/opt/riscv`
- **Last verified**: _fill in date when this doc was last confirmed to work end-to-end_

Keep this section updated whenever the toolchain is rebuilt against a new tag — it's the
single source of truth for "how was the toolchain currently in use actually built."