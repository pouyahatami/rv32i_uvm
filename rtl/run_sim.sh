#!/usr/bin/env bash
# =============================================================================
# run_sim.sh -- run all three RTL testbenches, under Icarus Verilog and/or
# Verilator, whichever is installed. Run from this directory:
#
#   ./run_sim.sh            # every available simulator, every testbench
#   ./run_sim.sh verilator  # one simulator only
#   ./run_sim.sh icarus hazard
#
# Both simulators are run deliberately: they disagree about X-propagation,
# scheduling and unsupported constructs, so agreement between them is worth
# more than either alone. See docs/BUGS.md.
#
# The Verilator arm also binds verif/sva, so the redirect and interlock
# assertions are evaluated against the directed trap, mret and debug stimulus
# rather than only against the UVM environment's generated stream, which
# contains none of it.
# =============================================================================
set -u
cd "$(dirname "$0")" || exit 1

FILES="rv32i_pkg.sv cells.sv regfile.sv alu.sv extend.sv retire_if.sv \
controller.sv hazard_unit.sv csr_file.sv clint.sv uart_tx.sv mem_bus.sv \
datapath.sv debug_fsm.sv riscv_pipe.sv dmem.sv imem.sv reset_sync.sv top.sv tb_pipe.sv"

# The bound assertions, added to the Verilator arm only -- Icarus 12 parses
# `assert property` but does not evaluate it, so including them there would
# report a pass that never ran. Before this, verif/sva was bound in run_uvm.sh
# and nowhere else, and the generated stream has no trap, mret or debug
# traffic: a_trap_flushes, a_mret_flushes and the two debug properties had
# therefore never once been evaluated non-vacuously. tb_pipe_csr and
# tb_pipe_debug are exactly the stimulus they were written for.
SVA="../verif/sva/hazard_sva.sv ../verif/sva/hazard_sva_bind.sv"

WHICH="${1:-all}"
ONLY="${2:-}"
TBS="hazard debug csr"
[ -n "$ONLY" ] && TBS="$ONLY"

mkdir -p build
rc=0

run_icarus () {
  command -v iverilog >/dev/null || { echo "-- iverilog not found, skipping"; return; }
  echo "===== Icarus Verilog ====="
  for tb in $TBS; do
    printf '  %-7s : ' "$tb"
    if ! iverilog -g2012 -DRTL_ONLY_NO_CLOCKING -o "build/iv_$tb" \
         -s "tb_pipe_$tb" $FILES 2> "build/iv_$tb.log"; then
      echo "COMPILE FAILED (see build/iv_$tb.log)"; rc=1; continue
    fi
    out=$(vvp "build/iv_$tb" 2>&1)
    echo "$out" | grep -E '^(PASS|FAIL)' || echo "no PASS/FAIL line"
    echo "$out" | grep -q '^PASS' || rc=1
  done
}

run_verilator () {
  command -v verilator >/dev/null || { echo "-- verilator not found, skipping"; return; }
  echo "===== Verilator ====="
  for tb in $TBS; do
    printf '  %-7s : ' "$tb"
    # -j 1: Verilator 5.020 intermittently dies under -j 0 on this design
    # ("attempted to destroy locked Thread Pool"). Reproducible beats fast in
    # a regression script.
    if ! verilator --binary -j 1 --assert --top-module "tb_pipe_$tb" \
         -DRTL_ONLY_NO_CLOCKING -Wno-PINMISSING -Wno-fatal --timescale 1ns/1ps \
         -Mdir "build/vl_$tb" -o "sim_$tb" $FILES $SVA > "build/vl_$tb.log" 2>&1; then
      echo "BUILD FAILED (see build/vl_$tb.log)"; rc=1; continue
    fi
    out=$("./build/vl_$tb/sim_$tb" 2>&1)
    echo "$out" | grep -E '^(PASS|FAIL)' || echo "no PASS/FAIL line"
    echo "$out" | grep -q '^PASS' || rc=1
    # A bound-assertion failure is a Verilator %Error, not a FAIL line, so the
    # testbench's own verdict is not sufficient on its own. Same conjunction
    # run_uvm.sh applies to the Questa error count.
    if echo "$out" | grep -q 'Assertion failed'; then
      echo "$out" | grep 'Assertion failed' | head -3 | sed 's/^/            /'
      rc=1
    fi
  done
}

case "$WHICH" in
  icarus|iverilog) run_icarus ;;
  verilator)       run_verilator ;;
  all)             run_icarus; echo; run_verilator ;;
  *) echo "usage: $0 [all|icarus|verilator] [hazard|debug|csr]"; exit 2 ;;
esac

echo
[ $rc -eq 0 ] && echo "ALL GREEN" || echo "SOMETHING FAILED"
exit $rc
