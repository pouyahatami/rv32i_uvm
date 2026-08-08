#!/usr/bin/env bash
# =============================================================================
# regen.sh -- regenerate every testbench's golden values from Spike.
#
# Run this after changing any test program (rtl/testgen/*.py) or after
# changing anything in the RTL that the golden values depend on. The
# generated .svh files are checked in so that running the RTL regression
# does not require Spike; only regenerating them does.
#
#   ./regen.sh
#
# Environment:
#   SPIKE       path to the spike binary        [default: spike on PATH]
#   CROSS       cross-toolchain prefix          [default: riscv64-unknown-elf-]
#   SPIKE_SRC   riscv-isa-sim checkout          [default: ~/src/riscv-isa-sim]
#
# See README.md in this directory for how to build Spike, including the two
# platform.h constants that have to move and why.
# =============================================================================
set -eu
cd "$(dirname "$0")"

SPIKE="${SPIKE:-spike}"
CROSS="${CROSS:-riscv64-unknown-elf-}"
SPIKE_SRC="${SPIKE_SRC:-$HOME/src/riscv-isa-sim}"
RTL="../../rtl"

# RAM in two pieces with a hole at [0x1000,0x2000) for Spike's boot ROM, and
# stopping at 0x20000 so the CLINT/UART plugin devices have somewhere to live.
# The core's own RAM is 16 KiB from 0, so this is a superset of what the test
# programs can legally touch.
MEMMAP='0x0:0x1000,0x2000:0x1e000'

# Must match rv32i_pkg.sv's CLINT_BASE / UART_BASE.
CLINT_BASE=0x20000
UART_BASE=0x30000

command -v "$SPIKE" >/dev/null 2>&1 || { echo "spike not found (set SPIKE=)"; exit 1; }
command -v "${CROSS}as" >/dev/null 2>&1 || { echo "${CROSS}as not found (set CROSS=)"; exit 1; }

echo "== building MMIO plugin =="
make SPIKE_SRC="$SPIKE_SRC" SPIKE_BUILD="$SPIKE_SRC/build"
PLUGIN="$PWD/librvproj_devices.so"

echo
echo "== tb_pipe_hazard =="
SPIKE="$SPIKE" CROSS="$CROSS" python3 gen_golden.py \
    --hex "$RTL/riscvtest_pipe.txt" \
    --out "$RTL/golden_vals_pipe.svh" \
    --memmap "$MEMMAP" \
    --mem 0x0 --mem 0x4

echo
echo "== tb_pipe_csr =="
SPIKE="$SPIKE" CROSS="$CROSS" python3 gen_golden.py \
    --hex "$RTL/riscvtest_pipe_csr.txt" \
    --out "$RTL/golden_vals_pipe_csr.svh" \
    --memmap "$MEMMAP" \
    --extlib "$PLUGIN" \
    --device "rvproj_clint,$CLINT_BASE" \
    --device "rvproj_uart,$UART_BASE"

echo
echo "done. tb_pipe_debug has no golden values -- debug halt/resume is not"
echo "architectural state, so no ISS models it (see DESIGN_GUIDE.md Section 4)."
