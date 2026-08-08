// =============================================================================
// clint.sv
//
// Deliberately-simplified CLINT (Core-Local Interruptor): a free-running
// 32-bit mtime counter and a 32-bit mtimecmp compare register, memory-
// mapped at rv32i_pkg::CLINT_BASE (+0x0 mtime, +0x4 mtimecmp). Real
// CLINTs (and the RISC-V priv spec) define these as 64-bit; 32-bit is a
// scope simplification appropriate for a project that isn't running
// anything with multi-hour uptimes. mtip_o (feeds mip.MTIP in
// csr_file.sv) is simply the combinational compare mtime >= mtimecmp --
// software clears/defers a pending interrupt by writing a new,
// further-out mtimecmp, exactly as on real hardware.
//
// `addr` arrives as the full 32-bit bus address; mem_bus.sv has already
// range-checked it's within the CLINT window before asserting `we`, so
// only addr[3:0] is decoded here.
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
      if (we && addr[3:0] == 4'h0) mtime_r <= wdata;      // software can rewrite mtime directly
      else                          mtime_r <= mtime_r + 32'b1;

      if (we && addr[3:0] == 4'h4) mtimecmp_r <= wdata;
    end

  // unique case: addr[3:0] is only ever range-checked into the CLINT
  // window by mem_bus.sv, but the mtime/mtimecmp registers only occupy
  // two of its sixteen possible nibble values -- default covers the rest.
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
