// =============================================================================
// verif/uvm/rv32i_if.sv
//
// Minimal clock/reset interface for the UVM driver. Deliberately separate
// from retire_if.sv (rtl/retire_if.sv), which is a read-only, monitor-side
// commit boundary -- this interface is the *drive* side, and the only
// thing this verification environment is allowed to force onto the DUT
// is reset. Everything else the driver does (loading a program into
// memory) goes through mem_backdoor_if.sv instead of a synthesizable
// port, so this interface can never be mistaken for adding a new
// synthesizable input to the CPU.
// =============================================================================

interface rv32i_if(input logic clk);
  logic reset;
endinterface
