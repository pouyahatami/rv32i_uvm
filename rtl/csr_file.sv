// =============================================================================
// csr_file.sv
//
// Minimal M-mode-only CSR file: mstatus (MIE/MPIE bits only), mie (MTIE
// only), mip (MTIP mirror, read-only, driven by the CLINT's timer
// compare), mtvec (direct mode only -- the [1:0] mode field is stored
// but ignored on redirect, always treated as direct), mepc, mcause,
// mtval, mscratch, mhartid (hardwired 0).
//
// Timing (this is the part worth reading carefully): every write here
// commits at EX-stage timing -- one stage EARLIER than dmem, which
// commits from the registered MEM-stage signals. That's deliberate, not
// an oversight: since only one instruction occupies EX per cycle in this
// in-order pipeline, and CSR writes are called by the instruction
// currently IN EX (not a value pipelined forward), committing at EX
// preserves program order with no WAW risk. It also means the caller
// (datapath.sv) is responsible for suppressing csr_we/trap_en/mret_en
// on a cycle where EnterDebug is ALSO asserted, exactly the way MemWriteM
// gets zeroed by FlushM on a debug-preempted store -- see datapath.sv's
// EX-stage trap block for where that gating happens. Without it, a CSR
// write or trap-entry state change could commit the instant before
// debug halts the core, even though the pipeline's own bookkeeping
// treats that instruction as "squashed, will re-execute after resume."
//
// Write priority when multiple conditions are (in principle) live the
// same cycle: trap entry > mret > plain CSR-instruction write. In
// practice trap_en/mret_en/csr_we are mutually exclusive per-instruction
// except for the one genuine corner case -- a timer interrupt landing
// exactly on a cycle where EX holds an MRET or a CSR-writing instruction
// -- where trap entry wins and the preempted instruction re-executes
// cleanly after the handler's own mret (precise-interrupt semantics).
// =============================================================================

import rv32i_pkg::*;

module csr_file (
    input  logic        clk,
    input  logic        reset,

    // CSR instruction read/write -- committed at EX-stage timing (see above)
    input  logic [11:0] csr_addr,
    input  logic        csr_we,
    input  logic [31:0] csr_wdata,
    output logic [31:0] csr_rdata,

    // trap entry (synchronous exception OR interrupt), already gated by
    // the caller to exclude EnterDebug
    input  logic         trap_en,
    input  logic         trap_is_int,
    input  logic [4:0]   trap_cause,
    input  logic [31:0]  trap_pc,
    input  logic [31:0]  trap_val,

    // mret, already gated by the caller to exclude EnterDebug
    input  logic         mret_en,

    // external timer-pending mirror, from clint.sv
    input  logic         mtip_i,

    // consumed by datapath.sv's EX-stage trap/PC-redirect logic
    output logic [31:0]  mtvec_o,
    output logic [31:0]  mepc_o,
    output logic         mstatus_mie_o,
    output logic         mie_mtie_o
);

  logic        mstatus_mie, mstatus_mpie;
  logic        mie_mtie;
  logic [31:0] mtvec_r, mepc_r, mcause_r, mtval_r, mscratch_r;

  assign mtvec_o        = mtvec_r;
  assign mepc_o         = mepc_r;
  assign mstatus_mie_o  = mstatus_mie;
  assign mie_mtie_o     = mie_mtie;

  // ---- read port (combinational; reflects state as of the last edge) ----
  // unique case: csr_addr is a full 12-bit field, so it is not exhaustively
  // enumerable the way a 2- or 3-bit selector is -- `unique` here asserts
  // "at most one of the named addresses matches," which is trivially true
  // since they're all distinct constants; the default covers every
  // unimplemented CSR address.
  always_comb
    unique case (csr_addr)
      CSR_MSTATUS:
        csr_rdata = {24'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};
      CSR_MIE:
        csr_rdata = {24'b0, mie_mtie, 7'b0};
      CSR_MTVEC:
        csr_rdata = mtvec_r;
      CSR_MSCRATCH:
        csr_rdata = mscratch_r;
      CSR_MEPC:
        csr_rdata = mepc_r;
      CSR_MCAUSE:
        csr_rdata = mcause_r;
      CSR_MTVAL:
        csr_rdata = mtval_r;
      CSR_MIP:
        csr_rdata = {24'b0, mtip_i, 7'b0};
      CSR_MHARTID:
        csr_rdata = 32'b0;
      default:
        csr_rdata = 32'b0;
    endcase

  // ---- write port ----
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      mstatus_mie  <= 1'b0;
      mstatus_mpie <= 1'b0;
      mie_mtie     <= 1'b0;
      mtvec_r      <= 32'b0;
      mepc_r       <= 32'b0;
      mcause_r     <= 32'b0;
      mtval_r      <= 32'b0;
      mscratch_r   <= 32'b0;
    end else if (trap_en) begin
      mepc_r       <= trap_pc;
      mcause_r     <= {trap_is_int, 26'b0, trap_cause};
      mtval_r      <= trap_val;
      mstatus_mpie <= mstatus_mie;
      mstatus_mie  <= 1'b0;
    end else if (mret_en) begin
      mstatus_mie  <= mstatus_mpie;
      mstatus_mpie <= 1'b1;
    end else if (csr_we) begin
      unique case (csr_addr)
        CSR_MSTATUS: begin
          mstatus_mie  <= csr_wdata[3];
          mstatus_mpie <= csr_wdata[7];
        end
        CSR_MIE:
          mie_mtie <= csr_wdata[7];
        CSR_MTVEC:
          mtvec_r <= csr_wdata;
        CSR_MSCRATCH:
          mscratch_r <= csr_wdata;
        CSR_MEPC:
          mepc_r <= csr_wdata;
        CSR_MCAUSE:
          mcause_r <= csr_wdata;
        CSR_MTVAL:
          mtval_r <= csr_wdata;
        CSR_MIP: // hardware-driven (mirrors clint.sv's mtip_i) -- writes ignored
          ;
        CSR_MHARTID: // read-only, hardwired to 0 -- writes ignored
          ;
        default: // any other, unimplemented CSR address -- writes ignored
          ;
      endcase
    end
  end

endmodule
