#!/usr/bin/env bash
# build.sh — how to run the Makefile end-to-end for the reflexrv
# firmware (boot.S + main.c + linker.ld).
#
# Requires a riscv-none-elf-* toolchain on PATH (or pass CROSS=... to
# make, e.g. CROSS=riscv64-unknown-elf-).
#
# Usage:
#   ./build.sh            # clean, build, disassemble, print sizes (rv32imc)
#   ./build.sh rv64imac lp64   # override MARCH/MABI

set -euo pipefail

MARCH="${1:-rv32imc}"
MABI="${2:-ilp32}"

echo "==> Cleaning previous build"
make clean

echo "==> Building boot.elf (MARCH=$MARCH MABI=$MABI)"
make MARCH="$MARCH" MABI="$MABI"

echo "==> Disassembly"
make disasm MARCH="$MARCH" MABI="$MABI"

echo "==> Section sizes"
make size MARCH="$MARCH" MABI="$MABI"

echo "==> Done. boot.elf is ready — see boot.map for the link map."