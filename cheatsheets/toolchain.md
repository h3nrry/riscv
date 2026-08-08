# reflexrv — RISC-V GNU Toolchain Setup

Location in repo: `riscv/doc/toolchain.md`
Companion script: `riscv/toolchain/setup_toolchain.sh`

This document describes how to get a working RISC-V GNU toolchain (GCC-based) for compiling
test programs for reflexrv, supporting **both RV32 and RV64**.

The toolchain itself is **not** committed to this repo (build/install output can be several
GB). Only this documentation and setup scripts are version-controlled; the toolchain lives
outside the repo (e.g. `/opt/riscv32`, `/opt/riscv64`, or `/opt/riscv` for a multilib build).

---

## 0. Quick Start — Prebuilt Binaries (Recommended)

Building from source (§3) requires cloning several large upstream repos as git submodules,
including `binutils-gdb` from `sourceware.org` — which is known to fail or time out
intermittently on many networks. **Unless you specifically need a custom source build, start
here instead** and skip straight to a working toolchain.

### Option A — Official prebuilt releases (riscv-collab)

Same trusted source as the source-build repo, no submodules involved:

```
https://github.com/riscv-collab/riscv-gnu-toolchain/releases
```

Nightly and tagged releases publish prebuilt tarballs per host OS and target width, e.g.
`riscv32-elf-ubuntu-22.04-gcc.tar.xz` / `riscv64-elf-ubuntu-22.04-gcc.tar.xz`. Pick the ones
matching your OS (WSL Ubuntu 22.04, most likely) and both widths you need:

```bash
mkdir -p /opt/riscv32 /opt/riscv64
tar -xf riscv32-elf-ubuntu-22.04-gcc.tar.xz -C /opt/riscv32 --strip-components=1
tar -xf riscv64-elf-ubuntu-22.04-gcc.tar.xz -C /opt/riscv64 --strip-components=1
```

> Note: these official prebuilt packages are split by width (`riscv32-elf-...` vs
> `riscv64-elf-...`) rather than one combined multilib package — you'll end up with two
> separate installs (which maps cleanly onto this repo's `toolchain/32` / `toolchain/64`
> layout), not a single multilib toolchain. That's fine for reflexrv's needs.

### Option B — xPack GNU RISC-V Embedded GCC

A well-maintained, actively updated, cross-platform prebuilt distribution — good alternative
if Option A doesn't have a build matching your host OS:

```
https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases
```

Download and extract the archive matching your platform (e.g.
`xpack-riscv-none-elf-gcc-<version>-linux-x64.tar.gz`) to your install path of choice. Same
caveat as Option A — packaged per-target rather than multilib.

Either option gets you a working `riscv32-unknown-elf-*` / `riscv64-unknown-elf-*` (or
`riscv-none-elf-*` for xPack) toolchain in minutes, with no build step and no submodule risk.
Skip to **§5 Environment Setup & Verification** once extracted.

---

## 1. Prerequisites (source build only)

Only needed if you're building from source (§3) — not required for §0.

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

## 2. Clone the Toolchain (source build only)

```bash
git clone --recursive --shallow-submodules https://github.com/riscv-collab/riscv-gnu-toolchain
cd riscv-gnu-toolchain
```

`--recursive` pulls in GCC, binutils-gdb, and newlib as submodules. `--shallow-submodules`
avoids pulling the full history of each (binutils-gdb's history in particular is huge) —
meaningfully reduces the chance of the clone timing out.

### If the `binutils-gdb` submodule clone fails

This is a common, known issue — `sourceware.org` (binutils/gdb's official git host) is
frequently slow or unreachable on some networks. Try, in order:

```bash
# 1. Just retry — often transient
git submodule update --init --recursive

# 2. Shallow-clone just the submodules to reduce data transferred
git submodule update --init --recursive --depth 1

# 3. Increase git's buffer/timeout for large transfers
git config --global http.postBuffer 524288000
git config --global http.lowSpeedLimit 0
git config --global http.lowSpeedTime 999999

# 4. Fallback: point at the GitHub mirror instead of sourceware.org
git config submodule.binutils.url https://github.com/bminor/binutils-gdb.git
git submodule update --init binutils
```

If `curl -I https://sourceware.org/git/binutils-gdb.git` hangs or fails outright (not just
slow), it's a network-level block/DNS issue on your end (possible with WSL2, VPNs, or
corporate proxies) — worth ruling out before retrying repeatedly.

### Pin to a specific release (recommended)

Building against a moving `master` branch means the toolchain you get today may differ from
what you get in six months. Pin to a tagged release for reproducibility:

```bash
git tag -l                     # list available release tags
git checkout <tag>              # e.g. a specific dated release tag
git submodule update --init --recursive
```

Record whichever tag/commit you chose in this doc (see [§6 Notes](#6-notes)).

---

## 3. Configure & Build — Multilib (source build only)

Builds a **single** install supporting both RV32 and RV64 — switch widths per compile with
`-march=`/`-mabi=` flags rather than maintaining two separate toolchains.

```bash
./configure --prefix=/opt/riscv \
  --with-multilib-generator="rv32imc-ilp32--;rv64imac-lp64--"
make -j$(nproc)
```

- `--prefix=/opt/riscv` — install location (outside this repo)
- `--with-multilib-generator="..."` — restricts the build to exactly the arch/ABI
  combinations reflexrv needs, rather than the full default multilib set — meaningfully
  faster. Adjust to match reflexrv's actual supported extensions if they change.

Build time is significant (30+ minutes depending on hardware) — this compiles GCC, binutils,
and newlib from source.

### Alternative — fully separate 32-bit / 64-bit installs

```bash
# RV32 only
./configure --prefix=/opt/riscv32 --with-arch=rv32imc --with-abi=ilp32
make -j$(nproc)

# RV64 only — run in a fresh clone, or `make clean` between builds
./configure --prefix=/opt/riscv64 --with-arch=rv64imac --with-abi=lp64
make -j$(nproc)
```

---

## 4. GCC vs. LLVM/Clang

`riscv-gnu-toolchain` (this doc) builds **GCC**. GCC is the recommended choice for reflexrv
specifically because `riscv-tests` and `riscv-arch-test` — the test suites used to verify
reflexrv — are written and validated against GCC by default across the open-source RISC-V
ecosystem. LLVM/Clang has solid RISC-V support too (permissive license, often clearer
diagnostics) but is a later optimization to consider, not the default starting point.

---

## 5. Environment Setup & Verification

After installing (via §0 prebuilt or §3 source build):

```bash
export RISCV=/opt/riscv          # or /opt/riscv32 + /opt/riscv64 if using separate installs
export PATH=$RISCV/bin:$PATH
```

Add to `~/.bashrc` to persist, or source from `riscv/toolchain/32/env.sh` /
`riscv/toolchain/64/env.sh` per width.

Verify the install:

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

- **Method used**: _prebuilt (§0) or source build (§3) — fill in which_
- **Toolchain source**: `riscv-collab/riscv-gnu-toolchain` (or xPack, if Option B used)
- **Pinned tag/commit/release**: _fill in once chosen_
- **Install path convention**: `/opt/riscv32` + `/opt/riscv64` (or `/opt/riscv` if multilib)
- **Last verified**: _fill in date this doc was last confirmed to work end-to-end_

### Updating the toolchain later

1. Check the new release's changelog before pulling it — don't update blindly.
2. Install the new version to a **new** path (don't overwrite the working install) so you can
   roll back instantly if needed.
3. Re-run the reflexrv test suite (`riscv-tests` / `riscv-arch-test`) against the new
   toolchain before trusting it — a toolchain change can shift code generation enough to
   expose (or mask) reflexrv bugs.
4. If everything still passes, switch `env.sh`/`PATH` to the new install and update this
   section (pinned version + last verified date). Commit that change.
