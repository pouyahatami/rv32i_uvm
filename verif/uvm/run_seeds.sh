#!/usr/bin/env bash
# Multi-seed regression for the UVM environment.
#
#   ./run_seeds.sh              # 20 seeds, 40 instructions each
#   ./run_seeds.sh 100          # 100 seeds
#   ./run_seeds.sh 100 200      # 100 seeds, 200 instructions each
#
# WHY THIS SCRIPT STRADDLES TWO OPERATING SYSTEMS
#
# The reference model and the simulator cannot run in the same place:
#   * Spike has no Windows build -- it lives in WSL Ubuntu, along with the
#     riscv64-unknown-elf assembler gen_stream.py shells out to.
#   * Questa is the Windows-native Altera install.
# They meet through the filesystem: C:\Projects\... on one side is
# /mnt/c/Projects/... on the other, same bytes. Generation runs via `wsl`,
# simulation runs natively, and stream.hex/stream_trace.txt are the handoff.
#
# WHY COMPILE ONCE AND LOOP vsim
#
# The RTL and testbench do not change between seeds -- only the two data files
# do, and the testbench takes those as +STREAM/+TRACE plusargs at runtime. So
# vlog runs once and each additional seed costs one elaboration instead of a
# full recompile: roughly 8s for the first seed and ~2s for each one after.
#
# CROSS-SEED COVERAGE
#
# The coverage collector reports per-run holes. This script intersects them:
# a bin is only reported as a true hole if NO seed hit it. That distinction is
# the entire value of running more than one seed -- a hole in a single run may
# just be that program's luck, while a hole across 50 seeds is a statement
# about the generator.
set -u

NSEEDS=${1:-20}
NINSTR=${2:-40}

QUESTA=${QUESTA:-/c/altera_pro/25.3.1/questa_fse}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
UVM=$ROOT/verif/uvm
RTL=$ROOT/rtl
BUILD=$UVM/build_seeds
# /c/Projects/... -> /mnt/c/Projects/..., the same directory as WSL sees it
WROOT=$(echo "$ROOT" | sed 's|^/\([a-zA-Z]\)/|/mnt/\1/|')
SPIKE=${SPIKE:-\$HOME/.local/spike/bin/spike}

rm -rf "$BUILD"; mkdir -p "$BUILD"
cp "$RTL/riscvtest_pipe.txt" "$BUILD/"   # imem's $readmemh at time 0
cd "$BUILD"

FILES="
  $RTL/rv32i_pkg.sv $RTL/cells.sv $RTL/regfile.sv $RTL/alu.sv $RTL/extend.sv
  $RTL/retire_if.sv $RTL/controller.sv $RTL/hazard_unit.sv $RTL/csr_file.sv
  $RTL/datapath.sv $RTL/debug_fsm.sv $RTL/riscv_pipe.sv $RTL/dmem.sv
  $RTL/clint.sv $RTL/uart_tx.sv $RTL/mem_bus.sv $RTL/imem.sv
  $RTL/reset_sync.sv $RTL/top.sv
  $ROOT/verif/sva/hazard_sva.sv $ROOT/verif/sva/hazard_sva_bind.sv
  $UVM/mem_backdoor_if.sv $UVM/mem_backdoor_bind.sv $UVM/rv32i_if.sv
  $UVM/rv32i_uvm_pkg.sv $UVM/tb_uvm_top.sv
"

echo "=== compiling once ==="
"$QUESTA/win64/vlib" work >/dev/null
if ! "$QUESTA/win64/vlog" -sv -mfcu -cuname cu_top -timescale 1ns/1ps -L mtiUvm \
      +incdir+"$QUESTA/verilog_src/uvm-1.1d/src" +incdir+"$UVM" $FILES > vlog.log 2>&1; then
  echo "COMPILE FAILED -- see $BUILD/vlog.log"; tail -20 vlog.log; exit 1
fi

pass=0; fail=0; genfail=0
failed_seeds=""
# holes.txt accumulates every bin reported as never-hit, across all seeds;
# a bin appearing NSEEDS times was hit by nobody.
: > holes.txt

for s in $(seq 1 "$NSEEDS"); do
  # ---- generate program + golden trace in WSL ----
  if ! wsl -d Ubuntu -- bash -lc "cd $WROOT/verif/spike && python3 gen_stream.py \
        --seed $s --num-instr $NINSTR --spike $SPIKE \
        --out-hex $WROOT/verif/uvm/build_seeds/s$s.hex \
        --out-trace $WROOT/verif/uvm/build_seeds/s$s.trace" > gen_$s.log 2>&1; then
    echo "seed $s: GEN FAILED (see $BUILD/gen_$s.log)"
    genfail=$((genfail+1)); failed_seeds="$failed_seeds $s(gen)"; continue
  fi

  # ---- simulate ----
  "$QUESTA/win64/vsim" -c -L mtiUvm +UVM_MAX_QUIT_COUNT=20 \
      +STREAM=s$s.hex +TRACE=s$s.trace \
      tb_uvm_top -do "run 500us; quit -f" > sim_$s.log 2>&1

  # A seed passes only if the test says so AND the run logged no UVM_ERROR or
  # UVM_FATAL. Checking only for "UVM TEST PASSED" is not enough: that string
  # comes from the scoreboard's own mismatch count, so errors raised anywhere
  # else -- the coverage collector, a config_db lookup, a protocol check --
  # print it anyway. The first version of this script did exactly that and
  # reported 30/30 PASS on runs carrying 13 UVM_ERRORs each.
  nerr=$(sed -n 's/^# UVM_ERROR *: *\([0-9]*\).*/\1/p' sim_$s.log | tail -1)
  nfat=$(sed -n 's/^# UVM_FATAL *: *\([0-9]*\).*/\1/p' sim_$s.log | tail -1)
  if grep -q "UVM TEST PASSED" sim_$s.log && [ "${nerr:-1}" = "0" ] && [ "${nfat:-1}" = "0" ]; then
    checked=$(grep -oE "DONE -- [0-9]+ instructions" sim_$s.log | grep -oE "[0-9]+" | head -1)
    cov=$(grep -oE "TOTAL \(in scope\) +[0-9]+/ *[0-9]+ bins +[0-9.]+%" sim_$s.log \
          | grep -oE "[0-9.]+%$")
    printf "seed %-4s PASS  %4s instr  cov %s\n" "$s" "${checked:-?}" "${cov:-?}"
    pass=$((pass+1))
    grep -oE "never hit: [a-z0-9_.]+" sim_$s.log | sed 's/never hit: //' >> holes.txt
  else
    printf "seed %-4s FAIL  (%s UVM_ERROR, %s UVM_FATAL, see %s)\n" \
           "$s" "${nerr:-?}" "${nfat:-?}" "$BUILD/sim_$s.log"
    fail=$((fail+1)); failed_seeds="$failed_seeds $s"
  fi
done

echo
echo "=== $pass passed, $fail failed, $genfail generator failures, of $NSEEDS seeds ==="
[ -n "$failed_seeds" ] && echo "failing seeds:$failed_seeds"

# A bin is a real hole only if every passing seed reported it as never hit.
if [ "$pass" -gt 0 ]; then
  echo
  echo "=== coverage holes across all $pass passing seeds ==="
  echo "(a bin listed here was never hit by ANY seed -- these are generator gaps,"
  echo " not bad luck in one program)"
  sort holes.txt | uniq -c | awk -v n="$pass" '$1==n {print "  never hit by any seed: " $2}'
  nhole=$(sort holes.txt | uniq -c | awk -v n="$pass" '$1==n' | wc -l)
  echo "  ($nhole bins unreachable by the current generator)"
fi

[ "$fail" -eq 0 ] && [ "$genfail" -eq 0 ]
