# =============================================================================
# run_questa.do -- compile and run the UVM environment under Questa.
#
#   cd verif/uvm
#   vsim -c -do run_questa.do
#
# Batch by default; pass -gui to vsim for the waveform viewer. Everything is
# built into verif/uvm/build/, which is disposable and gitignored.
#
# Written as a .do rather than a Makefile because Questa's TCL shell behaves
# identically on Windows and Linux, and this environment's most likely home is
# a Windows install with no make on PATH.
#
# ---- On Questa Starter Edition ----
#
# The free Starter licence withholds the `svverification` feature, which gates
# exactly four SystemVerilog constructs: randomize(), randcase, randsequence
# and covergroup. This environment uses none of them -- the instruction stream
# is generated in Python by verif/spike/gen_stream.py and replayed here, so
# nothing randomizes at simulation time. UVM itself compiles and elaborates
# without that feature.
#
# If you add constrained-random stimulus or functional coverage later, this
# stops running on Starter. That tradeoff is discussed in RUNNING.md.
# =============================================================================

# Questa reports its executable, rather than this .do file, from [info script]
# on some Windows installations. The documented invocation starts in this
# directory, so pwd is the reliable source root.
set here  [file normalize [pwd]]
set root  [file normalize $here/../..]
set rtl   $root/rtl
set build $here/build

# ---- source list -------------------------------------------------------
#
# rv32i_pkg.sv must come first: every other RTL file imports it. retire_if.sv
# must precede rv32i_uvm_pkg.sv, which declares `virtual retire_if.MON`.
# mem_backdoor_bind.sv must follow both imem.sv (the bind target) and
# mem_backdoor_if.sv (the bound interface).
#
# RTL_ONLY_NO_CLOCKING is deliberately NOT defined here. It exists for Icarus
# and Verilator, neither of which can parse a clocking block inside an
# interface; the UVM monitor samples through exactly that clocking block, so
# defining it would compile away the thing this environment depends on.

set rtl_files [list \
  $rtl/rv32i_pkg.sv   $rtl/cells.sv      $rtl/regfile.sv    $rtl/alu.sv \
  $rtl/extend.sv      $rtl/retire_if.sv  $rtl/controller.sv $rtl/hazard_unit.sv \
  $rtl/csr_file.sv    $rtl/clint.sv      $rtl/uart_tx.sv    $rtl/mem_bus.sv \
  $rtl/datapath.sv    $rtl/debug_fsm.sv  $rtl/riscv_pipe.sv $rtl/dmem.sv \
  $rtl/imem.sv        $rtl/reset_sync.sv $rtl/top.sv]

set uvm_files [list \
  $here/rv32i_if.sv          $here/mem_backdoor_if.sv \
  $here/mem_backdoor_bind.sv $here/rv32i_uvm_pkg.sv \
  $here/tb_uvm_top.sv]

# ---- run directory -----------------------------------------------------
#
# vsim runs from build/ because the sequence and scoreboard $fopen
# "stream.hex" and "stream_trace.txt" by bare relative name, and imem.sv
# $readmemh's its TestFile the same way. Copying the three data files in
# beside the simulation keeps those opens working without teaching the
# testbench about paths, and without writing simulator droppings into the
# source tree.
#
# riscvtest_pipe.txt is only a placeholder so $readmemh has something to read
# at time 0; the UVM driver backdoor-loads over every word of it before reset
# is released, so its contents never reach the checked trace.

file mkdir $build
foreach f [list $here/stream.hex $here/stream_trace.txt $rtl/riscvtest_pipe.txt] {
  if {![file exists $f]} {
    puts "ERROR: missing $f"
    if {[string match *stream* $f]} {
      puts "  Generate it with:  cd verif/spike && ./gen_stream.py --seed 1"
    }
    quit -code 2
  }
  file copy -force $f $build
}
cd $build

# ---- compile -----------------------------------------------------------

if {[file exists work]} { vdel -all }
vlib work

if {[catch {vlog -sv -mfcu -quiet {*}$rtl_files {*}$uvm_files} msg]} {
  puts "\n==== COMPILE FAILED ===="
  puts $msg
  if {[string match -nocase *svverification* $msg] ||
      [string match -nocase "*verification license*" $msg]} {
    puts "\nThat is a licence error, not a code error. This environment is"
    puts "written to avoid needing the svverification feature -- if you are"
    puts "seeing this, something was added that randomizes at simulation time"
    puts "(randomize/randcase/randsequence/covergroup). See RUNNING.md."
  }
  quit -code 1
}

# ---- run ---------------------------------------------------------------

if {[catch {vsim -quiet -l run.log -onfinish stop tb_uvm_top} msg]} {
  puts "\n==== ELABORATION FAILED ===="
  puts $msg
  if {[string match -nocase *svverification* $msg] ||
      [string match -nocase "*verification license*" $msg]} {
    puts "\nLicence error: this Questa licence does not include the"
    puts "svverification feature. See the note at the top of this file."
  }
  quit -code 1
}

run -all

# Pass/fail comes from the SV side. rv32i_random_test's report_phase asks the
# UVM report server for its own error count and prints exactly one verdict
# line; this reads that back out of the log so the exit code is usable from a
# script or a CI step. The count cannot be queried from TCL -- uvm_report_server
# is a SystemVerilog class, not a simulator object.
set verdict "NOT REACHED"
if {[catch {set fh [open run.log r]} openmsg] == 0} {
  foreach line [split [read $fh] "\n"] {
    if {[string match "*RV32I_UVM_VERDICT:*" $line]} {
      set verdict [string trim [lindex [split $line ":"] end]]
    }
  }
  close $fh
}

puts "\n==== verdict: $verdict ===="
if {$verdict eq "PASS"} {
  quit -code 0
} else {
  puts "full log: [file normalize run.log]"
  quit -code 1
}
