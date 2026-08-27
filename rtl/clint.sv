// =============================================================================
// clint.sv
//
// Simplified CLINT: a free-running mtime counter and an mtimecmp compare
// register at rv32i_pkg::CLINT_BASE (+0x0 mtime, +0x4 mtimecmp). The spec
// defines both as 64-bit; 32-bit here is a scope simplification.
//
// mtip_o feeds mip.MTIP in csr_file.sv and is just mtime >= mtimecmp, so
// software defers a pending interrupt by writing a further-out mtimecmp.
//
// mem_bus.sv has already range-checked `addr` before asserting `we`, so only
// addr[3:0] is decoded here.
// =============================================================================

module clint (
    input  logic        clk,
    input  logic        reset,
    input  logic        we,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        mtip_o
);

  logic [31:0] mtime_r, mtimecmp_r;

  always_ff @(posedge clk or posedge reset)
    if (reset) begin
      mtime_r    <= 32'b0;
      mtimecmp_r <= 32'hFFFF_FFFF; // far in the future -- no spurious interrupt at reset
    end else begin
      if (we && addr[3:0] == 4'h0) mtime_r <= wdata;      // software may rewrite mtime
      else                          mtime_r <= mtime_r + 32'b1;

      if (we && addr[3:0] == 4'h4) mtimecmp_r <= wdata;
    end

  always_comb
    unique case (addr[3:0])
      4'h0:
        rdata = mtime_r;
      4'h4:
        rdata = mtimecmp_r;
      default:
        rdata = 32'b0;
    endcase

  assign mtip_o = (mtime_r >= mtimecmp_r);

endmodule
