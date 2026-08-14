// =============================================================================
// retire_if.sv
//
// Commit/retire interface: the boundary the UVM monitor taps to observe one
// record per retiring instruction. Modelled on the commit_if.sv pattern used
// by UVM-based RISC-V verification environments (gopro-uvm-rtl-verification's
// RISC-V-CPU-Core-UVM-Based-ISA-Compliance-Verification exposes
// pc/insn/rd/val/commit_valid at exactly this boundary), and consumed by
// rv32i_monitor in verif/uvm/rv32i_uvm_pkg.sv.
//
// Bundling these as an `interface` rather than loose wires means a monitor
// connects with one handle instead of ten individual signal names kept in
// sync by hand across every module boundary between here and the testbench.
//
// The clocking block and MON modport give the monitor a synchronous,
// read-only view: it samples on posedge clk and cannot drive DUT signals.
//
// STYLE GUIDE EXCEPTION -- `interface` is generally discouraged by the
// lowRISC style guide for synthesizable RTL, because it can obscure
// hierarchy and complicate lint/CDC tooling. This one is deliberate and
// outside that concern: it is a verification-side tap point, driven by the
// DUT modport and read only by a monitor's MON modport, never a replacement
// for an ordinary port list on synthesizable logic. It is the same pattern
// the guide's own verification infrastructure uses.
// =============================================================================

interface retire_if(input logic clk, input logic reset);
  logic [31:0] pc;
  logic [31:0] instr;
  logic [4:0]  rd;
  logic [31:0] wdata;
  logic        regwrite_valid;   // 1 the cycle a real (non-bubble) instruction
                                   // retires with a register writeback
  logic        retire_valid;     // 1 the cycle a real (non-bubble) instruction
                                   // retires, regardless of whether it writes a
                                   // register. regwrite_valid alone cannot tell a
                                   // monitor "something real happened this cycle"
                                   // for a store or a branch; this can. Sourced
                                   // from datapath.sv's validW.

  // ---- store side of the same retirement ----
  //
  // Presented here rather than left for a monitor to scrape off the memory
  // bus. The store commits to dmem at MEM, one cycle before the instruction
  // retires at WB, so a bus-side monitor would have to re-derive which
  // retirement each bus event belongs to. datapath.sv carries the address,
  // data and width forward to WB so the pairing is structural instead.
  //
  // store_data is the full 32-bit register value. Only the low byte
  // (funct3=000) or halfword (001) is architecturally stored for SB/SH, so a
  // checker must mask by store_funct3 before comparing against a reference.
  logic        store_valid;      // 1 if this retiring instruction was a store
  logic [31:0] store_addr;
  logic [31:0] store_data;
  logic [2:0]  store_funct3;

  // ---- clocking block / MON modport: used ONLY by the UVM monitor ----
  //
  // rv32i_monitor (verif/uvm/rv32i_uvm_pkg.sv) samples through vif.mon_cb,
  // so this must be present for the UVM environment -- which is why it is
  // compiled in BY DEFAULT, and the UVM flows in verif/uvm/RUNNING.md need no
  // special flags.
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
    input pc, instr, rd, wdata, regwrite_valid, retire_valid,
          store_valid, store_addr, store_data, store_funct3;
  endclocking

  modport MON  (clocking mon_cb, input reset);
`endif
  modport DUT  (output pc, output instr, output rd, output wdata, output regwrite_valid,
                output retire_valid,
                output store_valid, output store_addr, output store_data,
                output store_funct3);
endinterface
