// =============================================================================
// datapath.sv
//
// 5-stage pipelined RV32I datapath: IF -> ID -> EX -> MEM -> WB.
//
// Owns regfile.sv, csr_file.sv and all four pipeline registers. Control
// arrives pre-decoded from controller.sv as an id_ex_ctrl_t bundle; forwarding,
// stall and flush decisions arrive from hazard_unit.sv. EX does more than run
// the ALU: it also holds the CSR read-modify-write, exception and interrupt
// detection, and the trap/mret PC redirect.
//
// docs/DESIGN_GUIDE.md has the stage-by-stage walk, the trap priority table,
// and why the validE/validM/validW chain exists.
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
    output logic        ValidW_retire,      // non-bubble retirement; see DESIGN_GUIDE.md
    output logic        MemWriteW_retire,   // store side of the same retirement
    output logic [31:0] StoreAddrW_retire,
    output logic [31:0] StoreDataW_retire,
    output logic [2:0]  MemFunct3W_retire
);

  // ================= Fetch =================
  logic [31:0] PCNextF, PCPlus4F, PCTargetD, PCTargetE;
  logic [31:0] mtvec_w, mepc_w; // from csr_file, declared here so the PC mux can see them

  // Combinational, not clocked: this is the next-PC input to the PCF register
  // below, not a register itself. Registering it here would insert a bubble on
  // every redirect. Priority runs highest-first -- debug preempts a trap, a
  // trap preempts mret, and all three preempt an ordinary branch or jump.
  always_comb begin
    if      (EnterDebug) PCNextF = dm_halt_addr_i;
    else if (ExitDebug)  PCNextF = dpc;
    else if (trap_en)    PCNextF = mtvec_w;   // exception or interrupt -- direct mode only
    else if (mret_enE)   PCNextF = mepc_w;
    else if (PCSrcE)     PCNextF = PCTargetE;
    else if (JumpD_c)    PCNextF = PCTargetD;
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
  logic        validE; // 0 only on a flush-inserted bubble (DESIGN_GUIDE.md)

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

  // A dedicated mux rather than the main ALU: CSRRC needs an
  // AND-with-inverted-operand that the ALU has no control code for, and adding
  // one would grow a shared resource to serve a single instruction.
  //
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

  // ---- timer interrupt (gated by validE -- DESIGN_GUIDE.md) ----
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
  logic        validM; // validE, one stage later

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
  // NOT ALUResultM. That is only the right value when the result IS the ALU
  // result; a CSR read writes CsrRdataM and JAL/JALR write the link address.
  //
  // RESULT_MEM (a load) is deliberately absent: its data does not exist yet at
  // MEM-forward time, which is why hazard_unit.sv stalls instead of forwarding
  // it. That interlock is what makes `default` safe here.
  //
  // Getting this wrong hung tb_pipe_csr -- docs/JOURNAL.md, "The MEM-stage
  // forwarding mux", has the history.
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
  // validM one stage later, and the signal a monitor must gate on -- NOT
  // "InstrW != NOP_INSTR". A real program can contain a genuine ADDI x0,x0,0,
  // bit-identical to a flush-inserted bubble; validW is 0 only when the slot
  // was squashed, whatever value landed in it.
  logic        validW;

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
