// =============================================================================
// top.sv
//
// Top-level wrapper. EXTENDED (CSR/trap/interrupt/UART milestone):
// instantiates mem_bus.sv instead of dmem.sv directly -- mem_bus.sv
// internally owns dmem.sv, clint.sv, and uart_tx.sv, and exposes the
// exact same we/addr/wdata/funct3/rdata shape dmem.sv always had, so
// riscv_pipe.sv needed no interface changes for its data-memory port.
// Two new signals surface here: mtip_i feeds back into riscv_pipe.sv
// (closing the interrupt loop), and uart_tx_byte_o/uart_tx_valid_o are
// exposed as new top-level outputs purely for a testbench monitor to
// observe transmitted bytes (see tb_pipe.sv's tb_pipe_csr).
// =============================================================================

module top #(
    parameter        TestFile = "riscvtest.txt",
    parameter int    RamBytes = 16384
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        debug_req_i,
    input  logic [31:0] dm_halt_addr_i,
    input  logic [31:0] dm_exception_addr_i,
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

  riscv_pipe rvpipe (.clk                 (clk),
                    .reset               (reset),
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
                    .dm_exception_addr_i (dm_exception_addr_i),
                    .debug_halted_o      (debug_halted_o));

  imem #(.TestFile(TestFile)) imem (.a(PC), .rd(Instr));

  mem_bus #(.RamBytes(RamBytes)) bus (
      .clk(clk), .reset(reset),
      .we(MemWrite), .addr(DataAdr), .wdata(WriteData), .funct3(MemFunct3),
      .rdata(ReadData), .mtip_o(mtip),
      .uart_tx_byte_o(uart_tx_byte_o), .uart_tx_valid_o(uart_tx_valid_o));
endmodule
