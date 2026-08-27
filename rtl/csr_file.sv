// =============================================================================
// csr_file.sv
//
// Minimal M-mode CSR file: mstatus (MIE/MPIE), mie (MTIE), mip (MTIP mirror,
// read-only), mtvec (direct mode only), mepc, mcause, mtval, mscratch,
// mhartid (hardwired 0).
//
// Writes commit at EX-stage timing, one stage ahead of dmem. Callers must
// therefore gate csr_we/trap_en/mret_en with ~EnterDebug themselves;
// datapath.sv does this. Write priority is trap entry > mret > csr_we.
//
// docs/DESIGN_GUIDE.md section 5 covers the timing and the trap rules.
// =============================================================================

import rv32i_pkg::*;

module csr_file (
    input  logic        clk,
    input  logic        reset,

    input  logic [11:0] csr_addr,
    input  logic        csr_we,
    input  logic [31:0] csr_wdata,
    output logic [31:0] csr_rdata,

    // trap entry (exception or interrupt); gated by the caller
    input  logic         trap_en,
    input  logic         trap_is_int,
    input  logic [4:0]   trap_cause,
    input  logic [31:0]  trap_pc,
    input  logic [31:0]  trap_val,

    input  logic         mret_en,

    input  logic         mtip_i,      // timer-pending mirror, from clint.sv

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

  // ---- read port ----
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
