// =============================================================================
// verif/uvm/tb_uvm_top.sv
//
// UVM entry point. Instantiates the DUT completely unmodified (same
// top.sv used by rtl/tb_pipe.sv's directed tests), then grabs virtual
// interface handles to two things the DUT ALREADY instantiates internally
// -- rtl/retire_if.sv's `retire` instance and the backdoor interface
// mem_backdoor_bind.sv attaches to imem -- via plain hierarchical
// reference. No port was added to top.sv/riscv_pipe.sv/imem.sv for any
// of this; the synthesizable RTL file list for this environment is
// identical to rtl/tb_pipe.sv's.
// =============================================================================

`include "uvm_macros.svh"
import uvm_pkg::*;
import rv32i_uvm_pkg::*;

module tb_uvm_top;
  logic clk = 0;
  always #5 clk = ~clk;

  rv32i_if vif(.clk(clk));

  logic [31:0] WriteData, DataAdr;
  logic        MemWrite, debug_halted_o;
  logic [7:0]  uart_tx_byte_o;
  logic        uart_tx_valid_o;

  // Placeholder TESTFILE -- $readmemh (in imem.sv) needs SOME file to
  // exist at time 0. Every word gets overwritten by the UVM driver's
  // backdoor load before reset deasserts, so this file's actual contents
  // never matter; riscvtest_pipe.txt is reused here only because it's
  // already guaranteed to exist and be the right word count.
  top #(.TestFile("riscvtest_pipe.txt")) dut(
      .clk                 (clk),
      .reset               (vif.reset),
      .debug_req_i         (1'b0),
      .dm_halt_addr_i      (32'h0),
      .dm_exception_addr_i (32'h0),
      .debug_halted_o      (debug_halted_o),
      .WriteData           (WriteData),
      .DataAdr             (DataAdr),
      .MemWrite            (MemWrite),
      .uart_tx_byte_o      (uart_tx_byte_o),
      .uart_tx_valid_o     (uart_tx_valid_o));

  initial begin
    virtual retire_if.MON   retire_vif;
    virtual mem_backdoor_if bd_vif;

    // grab handles to interfaces the DUT itself already instantiates --
    // see file header.
    retire_vif = dut.rvpipe.retire;
    bd_vif     = dut.imem.backdoor;

    uvm_config_db#(virtual rv32i_if)::set(null, "*", "vif", vif);
    uvm_config_db#(virtual retire_if.MON)::set(null, "*", "retire_vif", retire_vif);
    uvm_config_db#(virtual mem_backdoor_if)::set(null, "*", "bd_vif", bd_vif);

    // Default test hardcoded so this runs with zero required plusargs on
    // a first attempt -- run_test() still honors a +UVM_TESTNAME override
    // on the simulator command line if you add a second test later.
    run_test("rv32i_random_test");
  end

  // optional: dump waves for EPWave if you enable "Open EPWave after run"
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, tb_uvm_top);
  end
endmodule
