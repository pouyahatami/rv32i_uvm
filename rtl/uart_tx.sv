// =============================================================================
// uart_tx.sv
//
// Deliberately-simplified, TX-only, memory-mapped UART: no baud-rate
// timing is modeled (real UART bit-serialization is out of scope for
// this project). A write to UART_TXDATA (rv32i_pkg::UART_BASE+0x0) is
// treated as an instantly-transmitted byte -- tx_valid_o pulses for one
// cycle with tx_byte_o holding the value, for a testbench monitor to
// capture. UART_STATUS (+0x4) is read-only and always reports
// TX_READY=1 (bit 0), consistent with the instant-transmit model -- a
// real driver polling this status register before every write would
// work identically against real hardware that actually takes cycles to
// drain, since it degrades gracefully to "always immediately ready."
// =============================================================================

module uart_tx (
    input  logic        clk,
    input  logic        reset,
    input  logic        we,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic [7:0]  tx_byte_o,
    output logic        tx_valid_o
);

  logic [7:0] last_byte_r;

  always_ff @(posedge clk or posedge reset)
    if (reset) begin
      last_byte_r <= 8'b0;
      tx_valid_o  <= 1'b0;
    end else begin
      tx_valid_o <= 1'b0;
      if (we && addr[3:0] == 4'h0) begin
        last_byte_r <= wdata[7:0];
        tx_valid_o  <= 1'b1;
      end
    end

  assign tx_byte_o = last_byte_r;

  // unique case: addr[3:0] is only ever range-checked into the UART window
  // by mem_bus.sv, but only two of its sixteen possible nibble values are
  // real registers -- default covers the rest.
  always_comb
    unique case (addr[3:0])
      4'h0:
        rdata = {24'b0, last_byte_r};
      4'h4: // TX_READY always 1 -- instant-transmit model
        rdata = 32'h0000_0001;
      default:
        rdata = 32'b0;
    endcase

endmodule
