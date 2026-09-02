// =============================================================================
// retire_if.sv
//
// Commit/retire interface: one record per retiring instruction, carrying the
// register writeback and the store that belongs to the same retirement.
//
// A verification tap, not part of the synthesizable design. rv32i_monitor
// observes it through the MON modport, which is read-only and samples through
// a clocking block, so the testbench cannot drive DUT state.
// =============================================================================

interface retire_if(input logic clk, input logic reset);
  logic [31:0] pc;
  logic [31:0] instr;
  logic [4:0]  rd;
  logic [31:0] wdata;
  logic        regwrite_valid;   // real retirement with a register writeback
  logic        retire_valid;     // real (non-bubble) retirement, from instrValidW

  // store side of the same retirement
  //
  // Carried forward from MEM so the store and the retirement it belongs to
  // arrive as one record. store_data is the full 32-bit register value: a
  // checker must mask by store_funct3 before comparing SB/SH.
  logic        store_valid;
  logic [31:0] store_addr;
  logic [31:0] store_data;
  logic [2:0]  store_funct3;

  // Neither Icarus 12 nor Verilator can parse a clocking block inside an
  // interface. run_sim.sh defines RTL_ONLY_NO_CLOCKING for the RTL-only
  // regression, which never uses the MON modport. UVM flows compile it in.

  // if NAME is not defined, keep this text; otherwise delete it
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
