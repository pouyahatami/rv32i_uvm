// =============================================================================
// verif/uvm/rv32i_if.sv
//
// Minimal clock/reset interface for the UVM driver -- the drive side, as
// opposed to retire_if.sv's read-only monitor tap. Reset is the only thing the
// environment forces onto the DUT; program loading goes through
// imem_backdoor_if.sv rather than a synthesizable port.
// =============================================================================

interface rv32i_if(input logic clk);
  logic reset;
endinterface
