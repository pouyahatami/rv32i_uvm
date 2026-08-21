// =============================================================================
// top.sv
//
// Top-level wrapper: the core (riscv_pipe.sv), instruction memory
// (imem.sv), and the data-side bus (mem_bus.sv, which owns dmem.sv,
// clint.sv and uart_tx.sv).
//
// mtip comes out of mem_bus.sv's CLINT and goes back into riscv_pipe.sv,
// closing the timer-interrupt loop. uart_tx_byte_o/uart_tx_valid_o are
// exposed only so a testbench can observe transmitted bytes; nothing in the
// core reads them back (see tb_pipe_csr in tb_pipe.sv).
//
// This is the module both the directed testbenches and the UVM environment
// instantiate, unmodified and with the same port list.
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

  // `reset` arrives here as a raw asynchronous input -- a pad, a board button,
  // or a testbench assignment -- with no defined relationship to clk. It is
  // synchronized once, here, and nothing downstream ever sees the raw signal:
  // every module below consumes `rst`, which asserts asynchronously and
  // releases on a clock edge. See reset_sync.sv for why deassertion is the
  // half that matters.
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
