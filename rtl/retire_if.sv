// =============================================================================
// retire_if.sv
//
// Commit/retire interface -- the exact boundary a future UVM monitor taps
// for the scoreboard described in PROJECT_GUIDE.md's UVM section. Modeled
// directly on the commit_if.sv pattern used by real UVM-based RISC-V
// verification environments (e.g. gopro-uvm-rtl-verification's
// RISC-V-CPU-Core-UVM-Based-ISA-Compliance-Verification, which exposes
// pc/insn/rd/val/commit_valid at exactly this boundary and compares
// against a DPI golden model -- the same architecture PROJECT_GUIDE.md's
// UVM section describes).
//
// Using a bundled `interface` instead of loose wires means a monitor
// connects with one `.retire_if(rvpipe.retire)` port instead of six
// individual signal names that have to be kept in sync by hand across
// every module boundary between here and the testbench -- exactly the
// kind of thing that produced real wiring bugs earlier in this project.
//
// clocking block + modport give the monitor a synchronous, read-only
// view (samples on posedge clk, can't accidentally drive DUT signals).
//
// STYLE GUIDE EXCEPTION -- `interface` is generally discouraged by the
// lowRISC style guide for synthesizable RTL (it can obscure hierarchy and
// complicate lint/CDC tooling). This one is deliberate and out of scope
// for that concern: it exists purely as a verification-side monitor tap
// point, driven by the DUT's DUT modport and read only by a UVM monitor's
// MON modport -- never a replacement for an ordinary port list on
// synthesizable logic. This is the same accepted pattern the guide's own
// verification infrastructure and the two reference UVM environments
// cited above use `commit_if`/similar interfaces for.
// =============================================================================

interface retire_if(input logic clk, input logic reset);
  logic [31:0] pc;
  logic [31:0] instr;
  logic [4:0]  rd;
  logic [31:0] wdata;
  logic        regwrite_valid;   // 1 the cycle a real (non-bubble) instruction
                                   // retires with a register writeback
  logic        retire_valid;     // NEW (UVM milestone) -- 1 the cycle a real
                                   // (non-bubble) instruction retires, full stop,
                                   // regardless of whether it writes a register.
                                   // regwrite_valid alone can't tell a monitor
                                   // "something real happened this cycle" for a
                                   // store/branch/non-writing instruction; this
                                   // can. See datapath.sv's validW for the source.

  // ---- clocking block / MON modport: used ONLY by the UVM monitor ----
  //
  // rv32i_monitor (verif/uvm/rv32i_uvm_pkg.sv) samples through vif.mon_cb,
  // so this must be present for the UVM environment -- which is why it is
  // compiled in BY DEFAULT, and the UVM flow in EDA_PLAYGROUND_SETUP.md needs
  // no special flags.
  //
  // Neither free simulator supports it, though: Verilator 5.x rejects
  // "modport clocking" outright, and Icarus 12 cannot parse a clocking block
  // inside an interface at all. Since the three RTL testbenches in tb_pipe.sv
  // never touch either construct, the RTL-only regression defines
  // RTL_ONLY_NO_CLOCKING to skip it -- run_sim.sh passes that flag for both
  // simulators, so it is not something anyone has to remember.
  //
  // Deliberately keyed on what the compile is FOR rather than on which tool
  // is running: a `ifndef VERILATOR` guard would have left Icarus broken, and
  // chasing per-tool macros here would grow a new branch per simulator.
`ifndef RTL_ONLY_NO_CLOCKING
  clocking mon_cb @(posedge clk);
    input pc, instr, rd, wdata, regwrite_valid, retire_valid;
  endclocking

  modport MON  (clocking mon_cb, input reset);
`endif
  modport DUT  (output pc, output instr, output rd, output wdata, output regwrite_valid,
                output retire_valid);
endinterface
