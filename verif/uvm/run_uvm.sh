#!/usr/bin/env bash
# Run the UVM environment under the Questa FSE that ships with Altera Pro,
# which has precompiled UVM 1.1d/1.2 libraries. RUNNING.md option B covers the
# EDA Playground flow instead.
#
#   ./run_uvm.sh            # compile + run
#   ./run_uvm.sh -gui       # same, but open the Questa GUI on the waves
set -e

QUESTA=${QUESTA:-/c/altera_pro/25.3.1/questa_fse}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
UVM=$ROOT/verif/uvm
RTL=$ROOT/rtl
BUILD=$UVM/build

rm -rf "$BUILD"
mkdir -p "$BUILD"

# The testbench opens these by bare filename, so they have to sit in the
# directory the simulator runs from:
#   stream.hex        -- program the driver backdoor-loads   (sequence)
#   stream_trace.txt  -- Spike's expected retirements        (scoreboard)
#   riscvtest_pipe.txt-- placeholder for imem's $readmemh at time 0
cp "$UVM/stream.hex" "$UVM/stream_trace.txt" "$RTL/riscvtest_pipe.txt" "$BUILD/"

cd "$BUILD"

FILES="
  $RTL/rv32i_pkg.sv
  $RTL/cells.sv
  $RTL/regfile.sv
  $RTL/alu.sv
  $RTL/extend.sv
  $RTL/retire_if.sv
  $RTL/controller.sv
  $RTL/hazard_unit.sv
  $RTL/csr_file.sv
  $RTL/datapath.sv
  $RTL/debug_fsm.sv
  $RTL/riscv_pipe.sv
  $RTL/dmem.sv
  $RTL/clint.sv
  $RTL/uart_tx.sv
  $RTL/mem_bus.sv
  $RTL/reset_sync.sv
  $RTL/imem.sv
  $RTL/top.sv
  $ROOT/verif/sva/hazard_sva.sv
  $ROOT/verif/sva/hazard_sva_bind.sv
  $UVM/imem_backdoor_if.sv
  $UVM/dmem_backdoor_if.sv
  $UVM/imem_backdoor_bind.sv
  $UVM/dmem_backdoor_bind.sv
  $UVM/rv32i_if.sv
  $UVM/rv32i_uvm_pkg.sv
  $UVM/tb_uvm_top.sv
"

"$QUESTA/win64/vlib" work
# -mfcu/-cuname: the backdoor `bind` statements sit at compilation-unit scope.
# Without a shared compilation unit Questa warns (vlog-2650) the bind may not
# elaborate, which would make dut.imem.imem_backdoor silently not exist.
# +incdir+$UVM: rv32i_uvm_pkg.sv includes its classes from src/ by name.
"$QUESTA/win64/vlog" -sv -mfcu -cuname cu_top -timescale 1ns/1ps -L mtiUvm \
    +incdir+"$QUESTA/verilog_src/uvm-1.1d/src" \
    +incdir+"$UVM" \
    $FILES

# Two guard rails:
#   +UVM_MAX_QUIT_COUNT -- a systematic mismatch logs one error per retirement,
#     forever. Quit after 20.
#   run 500us (not -all) -- the test ends by waiting on the scoreboard's `done`
#     event, so anything blocking that event hangs until UVM's 9200s timeout.
#     The program is ~100 cycles; 500us is 50,000.
SIM_ARGS="+UVM_MAX_QUIT_COUNT=20"

if [ "${1:-}" = "-gui" ]; then
  "$QUESTA/win64/vsim" -L mtiUvm $SIM_ARGS tb_uvm_top -do "log -r /*; run 500us"
  exit 0
fi

"$QUESTA/win64/vsim" -c -L mtiUvm $SIM_ARGS tb_uvm_top -do "run 500us; quit -f" \
    | tee run.log

# The UVM verdict alone is not sufficient: bound SVA failures are simulator
# errors, not UVM report-server errors, so a run can print "UVM TEST PASSED"
# and "UVM_ERROR: 0" while assertions fire. The gate is the conjunction.
qerr=$(sed -n 's/^# Errors: \([0-9][0-9]*\),.*/\1/p' run.log | tail -1)
if ! grep -q "RV32I_UVM_VERDICT: PASS" run.log; then
  echo "FAIL: UVM verdict missing or not PASS"; exit 1
fi
if [ "${qerr:-1}" != "0" ]; then
  echo "FAIL: ${qerr:-unknown} simulator errors (assertion failures land here," \
       "not in the UVM error count) -- see $BUILD/run.log"
  exit 1
fi
echo "PASS: UVM verdict PASS, 0 simulator errors"
