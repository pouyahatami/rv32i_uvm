// =============================================================================
// mem_bus.sv
//
// Address decoder between the core's single load/store port and three
// memory-mapped targets: RAM (dmem.sv), the CLINT timer block (clint.sv),
// and the UART (uart_tx.sv).
//
// It presents exactly dmem.sv's interface upward -- we/addr/wdata/funct3 in,
// rdata out -- so from riscv_pipe.sv's point of view the core is still
// talking to one flat memory and neither it nor datapath.sv knows the MMIO
// devices exist. top.sv instantiates this in dmem.sv's place.
//
// Map (see rv32i_pkg.sv for the base-address constants):
//   [0, RamBytes)                   -> RAM
//   [CLINT_BASE, CLINT_BASE+0x10)   -> CLINT (mtime, mtimecmp)
//   [UART_BASE,  UART_BASE+0x10)    -> UART (txdata, status)
//   anything else                   -> reads as RAM's (out-of-range)
//                                      output; writes are simply dropped
//                                      (we is gated per-target below)
// =============================================================================

import rv32i_pkg::*;

module mem_bus #(
    parameter int RamBytes = 16384
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        we,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    input  logic [2:0]  funct3,
    output logic [31:0] rdata,
    output logic        mtip_o,
    output logic [7:0]  uart_tx_byte_o,
    output logic        uart_tx_valid_o
);

  logic is_clint, is_uart;
  assign is_clint = (addr >= CLINT_BASE) && (addr < CLINT_BASE + 32'h10);
  assign is_uart  = (addr >= UART_BASE)  && (addr < UART_BASE  + 32'h10);

  logic [31:0] ram_rdata, clint_rdata, uart_rdata;

  dmem #(.MemBytes(RamBytes)) dmem_inst (
      .clk(clk), .we(we & ~is_clint & ~is_uart),
      .a(addr), .wd(wdata), .funct3(funct3), .rd(ram_rdata));

  clint clint_inst (
      .clk(clk), .reset(reset), .we(we & is_clint),
      .addr(addr), .wdata(wdata), .rdata(clint_rdata), .mtip_o(mtip_o));

  uart_tx uart_inst (
      .clk(clk), .reset(reset), .we(we & is_uart),
      .addr(addr), .wdata(wdata), .rdata(uart_rdata),
      .tx_byte_o(uart_tx_byte_o), .tx_valid_o(uart_tx_valid_o));

  always_comb
    if      (is_clint) rdata = clint_rdata;
    else if (is_uart)  rdata = uart_rdata;
    else                rdata = ram_rdata;

endmodule
