// =============================================================================
// datapath.sv
//
// 5-stage pipelined RV32I datapath: IF -> ID -> EX -> MEM -> WB.
//
// Owns the two register-like blocks, regfile.sv and csr_file.sv, and all
// four pipeline registers. Control comes in pre-decoded from controller.sv
// as an id_ex_ctrl_t bundle; forwarding/stall/flush decisions come in from
// hazard_unit.sv. See docs/DESIGN_GUIDE.md for the stage-by-stage walk.
//
// EX-stage work that is not just "run the ALU":
//   - CSR read-modify-write for CSRRW/S/C, in a small dedicated mux rather
//     than the main ALU. CSRRC needs an AND-with-inverted-operand that the
//     ALU has no control code for, and adding one would grow a shared
//     resource to solve a one-instruction problem.
//   - exception detection: illegal instruction (decoded in controller.sv),
//     ecall, and misaligned load/store address, which is computed here
//     because it needs ALUResultE.
//   - timer-interrupt detection, gated by validE (below).
//   - trap/mret PC redirect, above PCSrcE/JumpD in the fetch mux.
//
// `validE` is a 1-bit register, separate from ctrlE, that is 0 exactly when
// this cycle's ID/EX load was a flush-inserted bubble (FlushE or reset).
// ctrlE's fields already default to "do nothing" on a bubble
// (ID_EX_CTRL_BUBBLE), so exception detection does not strictly need the
// gate. The timer interrupt does: its condition depends on global
// mstatus/mie/mip state rather than on what is in EX, so without validE an
// interrupt landing on a bubble cycle right after a flush would capture
// mepc = 0 (or a stale PCE) instead of a real, resumable address.
//
// validE is carried through EX/MEM and MEM/WB as validM/validW, the same
// shape InstrE/InstrM/InstrW use, and surfaces on retire_if.sv as
// ValidW_retire. That is the signal a monitor must gate on, and it is not
// derivable from InstrW: a real program can contain a genuine ADDI x0,x0,0,
// bit-identical to a flush-inserted bubble, so instruction-word matching
// cannot separate the two. validW is 0 if and only if the WB slot was
// squashed, whatever value landed in it.
//
// The MEM/WB stage also carries MemWriteW/StoreAddrW/StoreDataW/
// MemFunct3W. Those exist purely so retire_if.sv can present a store
// alongside the retirement it belongs to; see the retirement-outputs block
// at the bottom of this file.
//
// `validD` (IF/ID) is the fetch-side half of the same idea: 0 until a real
// fetch has actually landed in Decode, and validE is loaded from it rather
// than from a constant 1. Without it, the first clock edge after reset
// deasserts loads validE = 1 from a Decode stage still holding the
// reset-cleared bubble, and that bubble is announced on retire_if as a
// retirement at PCW = 0xfffffffc -- putting every real retirement one slot
// late. Found by the UVM environment lockstep comparison against Spike.
// =============================================================================

import rv32i_pkg::*;

module datapath (
    input  logic        clk,
    input  logic        reset,

    // ---- D-stage control, from controller.sv ----
    input  id_ex_ctrl_t ctrlD_c,
    input  logic        JumpD_c,
    input  logic [2:0]  ImmSrcD_c,
    output logic [31:0] InstrD,                  // fed back out to controller.sv

    // ---- hazard_unit.sv ----
    input  logic [1:0]  SelectAE,
    input  logic [1:0]  SelectBE,
    input  logic        StallF,
    input  logic        StallD,
    input  logic        FlushD,
    input  logic        FlushE,
    input  logic        FlushM,
    output logic [4:0]  Rs1D,
    output logic [4:0]  Rs2D,
    output logic [4:0]  Rs1E,
    output logic [4:0]  Rs2E,
    output logic [4:0]  RdE,
    output logic        IsLoadE,
    output logic [4:0]  RdM,
    output logic [4:0]  RdW,
    output logic        RegWriteM,
    output logic        RegWriteW,
    output logic        PCSrcE,
    output logic        JumpD,
    output logic        trap_en,     // to hazard_unit.sv's flush logic
    output logic        mret_enE,    // to hazard_unit.sv's flush logic

    // ---- debug ----
    input  logic         EnterDebug,
    input  logic         ExitDebug,
    input  logic [31:0]  dm_halt_addr_i,
    input  logic [31:0]  dpc,
    output logic [31:0]  PCE,
    output logic         is_ebreakE,
    output logic         is_dretE,

    // ---- memory interfaces ----
    input  logic [31:0] InstrF_in,
    output logic [31:0] PCF,
    output logic [31:0] ALUResultM,
    output logic [31:0] WriteDataM,
    output logic [2:0]  MemFunct3M,
    input  logic [31:0] ReadDataM,
    output logic        MemWriteM,

    // ---- CSR / timer interrupt ----
    input  logic         mtip_i,      // from clint.sv, via riscv_pipe.sv/top.sv

    // ---- retirement (WB-stage), for retire_if.sv / the UVM monitor ----
    output logic [31:0] InstrW,
    output logic [31:0] PCW,
    output logic [4:0]  RdW_retire,
    output logic [31:0] ResultW_retire,
    output logic        RegWriteW_retire,
    output logic        ValidW_retire,      // see validE/validM/validW note above
    output logic        MemWriteW_retire,   // store side of the same retirement
    output logic [31:0] StoreAddrW_retire,
    output logic [31:0] StoreDataW_retire,
    output logic [2:0]  MemFunct3W_retire
);

  assign JumpD = JumpD_c;

  // ================= Fetch =================
  logic [31:0] PCNextF, PCPlus4F, PCTargetD, PCTargetE;
  logic [31:0] mtvec_w, mepc_w; // from csr_file, declared here so the PC mux can see them

  always_comb begin //should this not happen on posedge clk?
    if      (EnterDebug) PCNextF = dm_halt_addr_i;
    else if (ExitDebug)  PCNextF = dpc;
    else if (trap_en)    PCNextF = mtvec_w;   // exception or interrupt -- direct mode only
    else if (mret_enE)   PCNextF = mepc_w;
    else if (PCSrcE)     PCNextF = PCTargetE;
    else if (JumpD)      PCNextF = PCTargetD;
    else                 PCNextF = PCPlus4F;
  end

  always_ff @(posedge clk, posedge reset)
    if (reset)          PCF <= 32'h0;
    else if (!StallF)   PCF <= PCNextF;

  adder pcadd4 (.a(PCF), .b(32'd4), .y(PCPlus4F));

  logic [31:0] InstrF;
  assign InstrF = InstrF_in;

  // ================= IF/ID register =================
  logic [31:0] PCD, PCPlus4D;
  logic        validD; // 0 until the first real fetch reaches Decode -- see below

  always_ff @(posedge clk, posedge reset)
    if (reset)         begin InstrD <= NOP_INSTR; PCD <= 32'h0; PCPlus4D <= 32'h0;
                             validD <= 1'b0; end
    else if (FlushD)   begin InstrD <= NOP_INSTR; validD <= 1'b0; end
    else if (!StallD)  begin InstrD <= InstrF; PCD <= PCF; PCPlus4D <= PCPlus4F;
                             validD <= 1'b1; end

  // ================= Decode =================
  assign Rs1D = InstrD[19:15];
  assign Rs2D = InstrD[24:20];
  logic [4:0] RdD;
  assign RdD = InstrD[11:7];

  logic [31:0] RD1D, RD2D, ImmExtD;
  logic [31:0] ResultW; // declared here (not at its Writeback-stage point of use below) so
                        // it's visible to regfile's WD3 port and forwardamux/forwardbmux in
                        // Execute -- SystemVerilog module scoping makes this legal either way,
                        // but slang (unlike Icarus Verilog) requires declare-before-use.
  regfile rf (
      .clk(clk),
      .we3(RegWriteW),
      .a1(Rs1D), .a2(Rs2D), .a3(RdW),
      .wd3(ResultW),
      .rd1(RD1D), .rd2(RD2D));

  extend  ext (.instr(InstrD[31:7]), .immsrc(ImmSrcD_c), .immext(ImmExtD));

  adder pcaddjal (.a(PCD), .b(ImmExtD), .y(PCTargetD));

  // ================= ID/EX register =================
  id_ex_ctrl_t ctrlE;
  logic [2:0]  funct3E;
  logic [31:0] RD1E, RD2E, PCPlus4E, ImmExtE, InstrE;
  logic        validE; // 0 only on a flush-inserted bubble -- see file header

  always_ff @(posedge clk, posedge reset)
    if (reset || FlushE) begin
      ctrlE <= ID_EX_CTRL_BUBBLE;
      RdE <= 5'b0; Rs1E <= 5'b0; Rs2E <= 5'b0; funct3E <= 3'b0;
      RD1E <= 32'b0; RD2E <= 32'b0; PCE <= 32'b0; PCPlus4E <= 32'b0; ImmExtE <= 32'b0;
      InstrE <= NOP_INSTR;
      validE <= 1'b0;
    end else begin
      ctrlE <= ctrlD_c;
      RdE <= RdD; Rs1E <= Rs1D; Rs2E <= Rs2D; funct3E <= InstrD[14:12];
      RD1E <= RD1D; RD2E <= RD2D; PCE <= PCD; PCPlus4E <= PCPlus4D; ImmExtE <= ImmExtD;
      InstrE <= InstrD;
      // NOT an unconditional 1'b1. On the first edge after reset deasserts, the
      // Decode stage still holds the reset-cleared bubble, not a fetched
      // instruction -- asserting validE here announced that bubble as a retired
      // instruction one cycle later at PCW = PCPlus4M - 4 = 0xfffffffc, shifting
      // every subsequent retirement by one. Found by the UVM environment's
      // lockstep comparison against Spike (verif/uvm/), which is exactly the
      // class of bug a commit-log check exists to catch.
      validE <= validD;
    end

  assign is_ebreakE = ctrlE.is_ebreak;
  assign is_dretE   = ctrlE.is_dret;
  // Explicit equality, not a bit-0 shortcut: RESULT_MEM (2'b01) and RESULT_CSR
  // (2'b11) both have bit 0 set, so `ctrlE.ResultSrc[0]` would also fire on a
  // CSR read reaching EX. A CSR read has no load-use-style delay -- csr_file.sv
  // commits/reads at EX-stage timing, same as an ALU op -- so that would only
  // have cost hazard_unit.sv an unnecessary stall cycle, not produced a wrong
  // answer, but it made this signal say something other than what its name
  // (and hazard_unit.sv's use of it) claims.
  assign IsLoadE = (ctrlE.ResultSrc == RESULT_MEM);

  // ================= Execute =================
  logic [31:0] SrcAE_reg, SrcAE, SrcBE_reg, WriteDataE, ALUResultE;
  logic [31:0] FwdResultM; // MEM-stage forward source -- defined in the MEM stage
  logic        ZeroE, LtE, take_branchE;
  logic [31:0] PCTargetBranchE;

  // mux3 selects d0 on s=00, d1 on s=01, d2 on s=10. FWD_WB=01, FWD_MEM=10
  // (rv32i_pkg.sv), so ResultW is d1 and ALUResultM is d2 -- this ordering
  // is exactly the thing that was wired backwards in an earlier pass; the
  // named constants don't prevent that class of mistake by themselves,
  // but make it easier to grep/verify against hazard_unit.sv's encoding.
  // d2 is FwdResultM, NOT ALUResultM. See FwdResultM's definition in the MEM
  // stage below: ALUResultM is only the correct forwarded value for ALU
  // results, and forwarding it for a CSR read or a JAL/JALR silently delivers
  // the wrong operand.
  mux3 #(32) forwardamux (.d0(RD1E), .d1(ResultW), .d2(FwdResultM), .s(SelectAE), .y(SrcAE_reg));
  mux3 #(32) forwardbmux (.d0(RD2E), .d1(ResultW), .d2(FwdResultM), .s(SelectBE), .y(WriteDataE));

  mux2 #(32) srcamux (.d0(SrcAE_reg), .d1(PCE), .s(ctrlE.AUIPCSel), .y(SrcAE));
  mux2 #(32) srcbmux (.d0(WriteDataE), .d1(ImmExtE), .s(ctrlE.ALUSrc), .y(SrcBE_reg));

  alu alu_e (
      .a(SrcAE), .b(SrcBE_reg),
      .alucontrol(ctrlE.ALUControl),
      .result(ALUResultE), .zero(ZeroE), .lt(LtE));

  adder pcaddbranch (.a(PCE), .b(ImmExtE), .y(PCTargetBranchE));
  assign PCTargetE = ctrlE.Jalr ? {ALUResultE[31:1], 1'b0} : PCTargetBranchE;

  // unique case: funct3E enumerates all 6 legal RV32I branch conditions;
  // the default (untaken) covers the 2 funct3 values BRANCH never uses.
  always_comb
    unique case (funct3E)
      3'b000:
        take_branchE = ZeroE;
      3'b001:
        take_branchE = ~ZeroE;
      3'b100:
        take_branchE = LtE;
      3'b101:
        take_branchE = ~LtE;
      3'b110:
        take_branchE = LtE;
      3'b111:
        take_branchE = ~LtE;
      default:
        take_branchE = 1'b0;
    endcase

  assign PCSrcE = (ctrlE.Branch & take_branchE) | ctrlE.Jalr;

  // ---- CSR file (owned by the datapath, like regfile) ----
  logic [31:0] csr_rdataE;
  logic [31:0] csr_operandE, csr_wdataE;
  logic        mstatus_mieE, mie_mtieE;

  // rs1, forwarded, for CSRRW/S/C; the raw 5-bit field itself (already
  // sitting in Rs1E) for the *I immediate variants -- Rs1E holds the same
  // bit positions either way, only the interpretation differs.
  assign csr_operandE = ctrlE.csr_use_imm ? {27'b0, Rs1E} : SrcAE_reg;

  // unique case: ctrlE.csr_op == funct3[1:0], and controller.sv only ever
  // sets is_csr (which gates whether this mux's output is used at all) for
  // the three legal RW/RS/RC encodings -- the default covers the 4th,
  // structurally-unreachable value defensively.
  always_comb
    unique case (ctrlE.csr_op)
      2'b01: // CSRRW(I)
        csr_wdataE = csr_operandE;
      2'b10: // CSRRS(I)
        csr_wdataE = csr_rdataE | csr_operandE;
      2'b11: // CSRRC(I)
        csr_wdataE = csr_rdataE & ~csr_operandE;
      default:
        csr_wdataE = csr_rdataE;
    endcase

  // ---- exception detection (EX stage) ----
  logic is_load_or_storeE, misalignedE;
  assign is_load_or_storeE = ctrlE.MemWrite | (ctrlE.ResultSrc == RESULT_MEM);

  // unique case: funct3E[1:0] narrows to exactly the 3 load/store width
  // encodings this ISA defines (byte/half/word); 2'b11 is not a legal
  // width for any load/store and is unreachable.
  always_comb begin
    misalignedE = 1'b0;
    if (is_load_or_storeE)
      unique case (funct3E[1:0])
        2'b00: // LB/LBU/SB -- byte ops are always aligned
          misalignedE = 1'b0;
        2'b01: // LH/LHU/SH -- must be 2B aligned
          misalignedE = ALUResultE[0];
        2'b10: // LW/SW -- must be 4B aligned
          misalignedE = |ALUResultE[1:0];
        default: // 2'b11 is not a valid funct3[1:0] for any load/store -- unreachable
          misalignedE = 1'b0;
      endcase
  end

  logic       exceptionE;
  logic [4:0] exc_codeE;
  logic [31:0] trap_valE;

  always_comb begin
    exceptionE = 1'b0;
    exc_codeE  = 5'd0;
    trap_valE  = 32'b0;
    if (ctrlE.is_illegal) begin
      exceptionE = 1'b1; exc_codeE = EXC_ILLEGAL_INSTR; trap_valE = InstrE;
    end else if (ctrlE.is_ecall) begin
      exceptionE = 1'b1; exc_codeE = EXC_ECALL_M; trap_valE = 32'b0;
    end else if (misalignedE && ctrlE.MemWrite) begin
      exceptionE = 1'b1; exc_codeE = EXC_STORE_MISALIGN; trap_valE = ALUResultE;
    end else if (misalignedE && (ctrlE.ResultSrc == RESULT_MEM)) begin
      exceptionE = 1'b1; exc_codeE = EXC_LOAD_MISALIGN; trap_valE = ALUResultE;
    end
  end

  // ---- timer interrupt (gated by validE -- see file header) ----
  logic timer_intE;
  assign timer_intE = validE & mstatus_mieE & mie_mtieE & mtip_i;

  logic        trap_is_intE;
  logic [4:0]  trap_causeE;
  // Explicit three-way (not if/else) so trap_causeE/trap_is_intE never
  // silently default to "looks like an interrupt" garbage when neither
  // condition holds -- they're don't-cares in that case (trap_en is 0,
  // so csr_file.sv never latches them), but writing it this way means a
  // waveform dump reads correctly instead of misleadingly.
  always_comb begin
    if (exceptionE) begin
      trap_is_intE = 1'b0; trap_causeE = exc_codeE;
    end else if (timer_intE) begin
      trap_is_intE = 1'b1; trap_causeE = INT_MTIMER;
    end else begin
      trap_is_intE = 1'b0; trap_causeE = 5'd0;
    end
  end

  assign trap_en   = exceptionE | timer_intE;
  assign mret_enE  = ctrlE.is_mret;

  // A CSR write, or the trap/mret state commit, must NOT happen on a
  // cycle where EnterDebug is also asserted -- that instruction is being
  // squashed (it will re-execute identically after resume). See
  // csr_file.sv's header for why this gate lives here instead of inside
  // csr_file itself. A plain CSR write is additionally suppressed when
  // trap_en fires the same cycle (this exact instruction is the one
  // being interrupted/excepted -- precise-interrupt semantics, it
  // re-executes cleanly after the handler's mret).
  logic csr_we_gated, trap_en_gated, mret_en_gated;
  assign csr_we_gated  = ctrlE.is_csr & ~EnterDebug & ~trap_en;
  assign trap_en_gated = trap_en  & ~EnterDebug;
  assign mret_en_gated = mret_enE & ~EnterDebug;

  csr_file csrs (
      .clk(clk), .reset(reset),
      .csr_addr(InstrE[31:20]),
      .csr_we(csr_we_gated),
      .csr_wdata(csr_wdataE),
      .csr_rdata(csr_rdataE),
      .trap_en(trap_en_gated),
      .trap_is_int(trap_is_intE),
      .trap_cause(trap_causeE),
      .trap_pc(PCE),
      .trap_val(trap_valE),
      .mret_en(mret_en_gated),
      .mtip_i(mtip_i),
      .mtvec_o(mtvec_w),
      .mepc_o(mepc_w),
      .mstatus_mie_o(mstatus_mieE),
      .mie_mtie_o(mie_mtieE));

  // ================= EX/MEM register =================
  logic [31:0] ALUResultM_r, WriteDataM_r, PCPlus4M, InstrM;
  logic [1:0]  ResultSrcM;
  logic [31:0] CsrRdataM;
  logic        validM; // validE, one stage later -- see validE/validM/validW note above

  // FlushM (an input, driven by hazard_unit.sv from EnterDebug | trap_en)
  // squashes this instruction's own commit for two reasons: EnterDebug
  // (original) and trap_en (new -- the EX-stage instruction itself is
  // the one excepting/being interrupted, so its RegWrite/MemWrite must
  // not reach dmem/regfile). mret needs no such self-squash: it has no
  // RegWrite/MemWrite of its own, so it's deliberately NOT part of
  // FlushM's condition (see hazard_unit.sv).
  always_ff @(posedge clk, posedge reset)
    if (reset || FlushM) begin
      RegWriteM <= 0; MemWriteM <= 0; ResultSrcM <= 2'b0; MemFunct3M <= 3'b0;
      ALUResultM_r <= 32'b0; WriteDataM_r <= 32'b0; RdM <= 5'b0; PCPlus4M <= 32'b0;
      InstrM <= NOP_INSTR; CsrRdataM <= 32'b0;
      validM <= 1'b0;
    end else begin
      RegWriteM <= ctrlE.RegWrite; MemWriteM <= ctrlE.MemWrite; ResultSrcM <= ctrlE.ResultSrc;
      MemFunct3M <= funct3E;
      ALUResultM_r <= ALUResultE; WriteDataM_r <= WriteDataE; RdM <= RdE; PCPlus4M <= PCPlus4E;
      InstrM <= InstrE; CsrRdataM <= csr_rdataE;
      validM <= validE;
    end

  assign ALUResultM = ALUResultM_r;
  assign WriteDataM = WriteDataM_r;

  // ---- the value this MEM-stage instruction will actually write to rd ----
  //
  // The forwarding muxes used to take ALUResultM directly. That is correct
  // only when the instruction's result IS the ALU result. It is wrong for:
  //
  //   RESULT_CSR     - a CSR read writes CsrRdataM to rd, not ALUResultM.
  //   RESULT_PCPLUS4 - JAL/JALR write the link address PCPlus4M, not the
  //                    jump target the ALU computed.
  //
  // RESULT_MEM (a load) is deliberately absent: its data does not exist yet at
  // MEM-forward time, which is precisely why hazard_unit.sv stalls instead of
  // forwarding it. That interlock is what makes `default` safe here.
  //
  // THIS WAS A REAL BUG, and the way it hid is worth recording. IsLoadE used
  // to be `ctrlE.ResultSrc[0]`, which is true for RESULT_MEM (2'b01) *and*
  // RESULT_CSR (2'b11). CSR reads were therefore stalled by the load-use
  // interlock as an accident of bit numbering, and never reached the broken
  // forward path. Commit b27d00d removed that aliasing on the reasoning that
  // it "would only have cost an unnecessary stall cycle, not produced a wrong
  // answer" -- correct about the stall, wrong about the answer. With the
  // accidental protection gone, a CSR read followed immediately by a dependent
  // instruction forwarded the ALU result instead of the CSR value.
  //
  // The observable failure was tb_pipe_csr hanging forever: the trap handler's
  // `csrr x24, mepc / addi x24, x24, 4 / csrw mepc, x24` sequence wrote back a
  // stale mepc, so `mret` returned to the ECALL that trapped, which trapped
  // again, indefinitely.
  //
  // The JAL/JALR case was never covered by any test and was wrong in every
  // version of this file, including before b27d00d. It is fixed here too.
  always_comb
    unique case (ResultSrcM)
      RESULT_CSR:     FwdResultM = CsrRdataM;
      RESULT_PCPLUS4: FwdResultM = PCPlus4M;
      default:        FwdResultM = ALUResultM_r; // RESULT_ALU (RESULT_MEM stalls)
    endcase

  // ================= MEM/WB register =================
  logic [31:0] ALUResultW, ReadDataW, PCPlus4W, CsrRdataW;
  logic [1:0]  ResultSrcW;
  // Store address/data/width, carried one stage past the point the store
  // actually commits (dmem sees it at MEM). Nothing in the core reads these
  // back -- they exist so retire_if.sv can hand a monitor the store and the
  // retirement it belongs to as one record, instead of making the monitor
  // correlate a MEM-stage bus event with a WB-stage retirement by hand.
  logic [31:0] StoreAddrW, StoreDataW;
  logic [2:0]  MemFunct3W;
  logic        MemWriteW;
  logic        validW; // validM, one stage later -- see validE/validM/validW note above.
                        // This is the signal a UVM monitor should actually gate on, NOT
                        // "InstrW != NOP_INSTR" -- a real program can legally contain a
                        // real ADDI x0,x0,0 (bit-identical to a flush-inserted bubble), so
                        // instruction-word matching can't tell the two apart. validW can:
                        // it's 0 only when this WB-stage slot was squashed, never based on
                        // what value happened to land in it.

  always_ff @(posedge clk, posedge reset)
    if (reset) begin
      RegWriteW <= 0; ResultSrcW <= 2'b0;
      ALUResultW <= 32'b0; ReadDataW <= 32'b0; RdW <= 5'b0; PCPlus4W <= 32'b0;
      InstrW <= NOP_INSTR; PCW <= 32'b0; CsrRdataW <= 32'b0;
      validW <= 1'b0;
      MemWriteW <= 1'b0; StoreAddrW <= 32'b0; StoreDataW <= 32'b0; MemFunct3W <= 3'b0;
    end else begin
      RegWriteW <= RegWriteM; ResultSrcW <= ResultSrcM;
      ALUResultW <= ALUResultM; ReadDataW <= ReadDataM; RdW <= RdM; PCPlus4W <= PCPlus4M;
      InstrW <= InstrM; PCW <= PCPlus4M - 32'd4; // PC of the retiring instruction
      CsrRdataW <= CsrRdataM;
      validW <= validM;
      MemWriteW <= MemWriteM; StoreAddrW <= ALUResultM; StoreDataW <= WriteDataM;
      MemFunct3W <= MemFunct3M;
    end

  // ================= Writeback =================
  // (ResultW itself is declared up in the Decode section -- see the comment there)
  // widened to mux4: d3 = CsrRdataW, selected when ResultSrcW == RESULT_CSR (2'b11)
  mux4 #(32) resultmux (
      .d0(ALUResultW), .d1(ReadDataW), .d2(PCPlus4W), .d3(CsrRdataW),
      .s(ResultSrcW), .y(ResultW));

  // retirement outputs -- straight passthrough of WB-stage signals under
  // clean names for retire_if.sv to expose to a monitor
  assign RdW_retire        = RdW;
  assign ResultW_retire    = ResultW;
  assign RegWriteW_retire  = RegWriteW;
  assign ValidW_retire     = validW;
  assign MemWriteW_retire  = MemWriteW;
  assign StoreAddrW_retire = StoreAddrW;
  assign StoreDataW_retire = StoreDataW;
  assign MemFunct3W_retire = MemFunct3W;

endmodule
