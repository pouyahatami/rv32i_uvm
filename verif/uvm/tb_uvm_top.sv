// =============================================================================
// verif/uvm/tb_uvm_top.sv
//
// UVM entry point. Instantiates the DUT unmodified -- the same top.sv the
// directed tests use -- then takes virtual interface handles to three hooks:
// retire_if's `retire` instance, and the two backdoor interfaces attached to
// imem and dmem by bind. No synthesizable port was added for any of it.
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

  // Placeholder: imem.sv's $readmemh needs a file at time 0. The driver's
  // backdoor load overwrites every word before reset deasserts, so the
  // contents never matter.
  top #(.TestFile("riscvtest_pipe.txt")) dut(
      .clk                 (clk),
      .reset               (vif.reset),
      .debug_req_i         (1'b0),
      .dm_halt_addr_i      (32'h0),
      .debug_halted_o      (debug_halted_o),
      .WriteData           (WriteData),
      .DataAdr             (DataAdr),
      .MemWrite            (MemWrite),
      .uart_tx_byte_o      (uart_tx_byte_o),
      .uart_tx_valid_o     (uart_tx_valid_o));

  initial begin
    virtual retire_if.MON   retire_vif;
    virtual imem_backdoor_if imem_bd_vif;
    virtual dmem_backdoor_if dmem_bd_vif;

    // handles to interfaces the DUT already instantiates -- see file header
    retire_vif = dut.rvpipe.retire;
    imem_bd_vif = dut.imem.imem_backdoor;
    dmem_bd_vif = dut.bus.dmem_inst.dmem_backdoor;

    uvm_config_db#(virtual rv32i_if)::set(null, "*", "vif", vif);
    uvm_config_db#(virtual retire_if.MON)::set(null, "*", "retire_vif", retire_vif);
    uvm_config_db#(virtual imem_backdoor_if)::set(
        null, "*", "imem_bd_vif", imem_bd_vif);
    uvm_config_db#(virtual dmem_backdoor_if)::set(null, "*", "dmem_bd_vif", dmem_bd_vif);

    // Default so the environment runs with no required plusargs;
    // +UVM_TESTNAME still overrides it.
    run_test("rv32i_random_test");
  end

  // optional: dump waves for EPWave if you enable "Open EPWave after run"
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, tb_uvm_top);
  end
endmodule
