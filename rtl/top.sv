// =============================================================================
// top.sv
//
// Top-level wrapper: the core (riscv_pipe.sv), instruction memory (imem.sv),
// and the data-side bus (mem_bus.sv, which owns dmem.sv, clint.sv and
// uart_tx.sv). mtip closes the timer-interrupt loop from the CLINT back into
// the core.
//
// uart_tx_byte_o/uart_tx_valid_o exist only for testbench observation; the
// core never reads them back.
//
// This is the DUT: both the directed testbenches and the UVM environment
// instantiate it unmodified.
// =============================================================================

module top #(
    parameter        TestFile = "riscvtest.txt",
    parameter int    RamBytes = 16384
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        debug_req_i,
    input  logic [31:0] dm_halt_addr_i,
    output logic        debug_halted_o,
    output logic [31:0] WriteData,
    output logic [31:0] DataAdr,
    output logic        MemWrite,
    output logic [7:0]  uart_tx_byte_o,
    output logic        uart_tx_valid_o
);

  logic [31:0] PC, Instr, ReadData;
  logic [2:0]  MemFunct3;
  logic        mtip;

  // `reset` is a raw asynchronous input. Synchronized once here; everything
  // below consumes `rst`, which releases on a clock edge.
  logic rst;
  reset_sync #(.Stages(2)) u_reset_sync (
      .clk(clk), .arst_in(reset), .rst_out(rst));

  riscv_pipe rvpipe (.clk                 (clk),
                    .reset               (rst),
                    .PC                  (PC),
                    .Instr               (Instr),
                    .MemWrite            (MemWrite),
                    .ALUResult           (DataAdr),
                    .WriteData           (WriteData),
                    .ReadData            (ReadData),
                    .MemFunct3           (MemFunct3),
                    .mtip_i              (mtip),
                    .debug_req_i         (debug_req_i),
                    .dm_halt_addr_i      (dm_halt_addr_i),
                    .debug_halted_o      (debug_halted_o));

  imem #(.TestFile(TestFile)) imem (.a(PC), .rd(Instr));

  mem_bus #(.RamBytes(RamBytes)) bus (
      .clk(clk), .reset(rst),
      .we(MemWrite), .addr(DataAdr), .wdata(WriteData), .funct3(MemFunct3),
      .rdata(ReadData), .mtip_o(mtip),
      .uart_tx_byte_o(uart_tx_byte_o), .uart_tx_valid_o(uart_tx_valid_o));
endmodule
