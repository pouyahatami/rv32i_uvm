#!/usr/bin/env bash
# Run the UVM environment locally under Questa (Altera/Intel FSE install).
#
# The environment was written for EDA Playground (see EDA_PLAYGROUND_SETUP.md)
# and had never been compiled by anything. This runs it on the Questa that
# ships with Altera Pro, which has precompiled UVM 1.1d/1.2 libraries.
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
  $UVM/mem_backdoor_if.sv
  $UVM/mem_backdoor_bind.sv
  $UVM/rv32i_if.sv
  $UVM/rv32i_uvm_pkg.sv
  $UVM/tb_uvm_top.sv
"

"$QUESTA/win64/vlib" work
# -mfcu/-cuname: mem_backdoor_bind.sv's `bind` sits at compilation-unit scope.
# Without a single shared compilation unit Questa warns (vlog-2650) that the
# bind may not elaborate at all -- which would make dut.imem.backdoor, the
# driver's only way to load a program, silently not exist.
# +incdir+$UVM: rv32i_uvm_pkg.sv is a manifest of `include "src/*.svh" lines,
# one class per file. Without this the package can't find them.
"$QUESTA/win64/vlog" -sv -mfcu -cuname cu_top -timescale 1ns/1ps -L mtiUvm \
    +incdir+"$QUESTA/verilog_src/uvm-1.1d/src" \
    +incdir+"$UVM" \
    $FILES

# Two guard rails, both learned the hard way on the first run:
#   +UVM_MAX_QUIT_COUNT -- the scoreboard logs one error per retirement, so a
#     systematic mismatch produces an error every 10ns forever. Quit after 20.
#   run 500us (not -all) -- the test ends by waiting on the scoreboard's `done`
#     event, so anything that stops that event from firing hangs `run -all`
#     until UVM's 9200s default timeout. The program is ~160 cycles; 500us is
#     50,000 cycles, generous by any measure, and bounds the wreckage.
SIM_ARGS="+UVM_MAX_QUIT_COUNT=20"

if [ "$1" = "-gui" ]; then
  "$QUESTA/win64/vsim" -L mtiUvm $SIM_ARGS tb_uvm_top -do "log -r /*; run 500us"
else
  "$QUESTA/win64/vsim" -c -L mtiUvm $SIM_ARGS tb_uvm_top -do "run 500us; quit -f"
fi
