// =============================================================================
// datapath.sv
//
// 5-stage pipelined RV32I datapath: IF -> ID -> EX -> MEM -> WB.
//
// Owns regfile.sv, csr_file.sv and all four pipeline registers. Control
// arrives pre-decoded from controller.sv as an id_ex_ctrl_t bundle;
// forwarding, stall and flush decisions arrive from hazard_unit.sv. EX also
// holds the CSR read-modify-write, exception and interrupt detection, and the
// trap/mret PC redirect.
//
// docs/DESIGN_GUIDE.md sections 3-5 have the stage-by-stage walk, the trap
// priority table, and the validE/validM/validW chain.
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
    output logic        ValidW_retire,      // non-bubble retirement
    output logic        MemWriteW_retire,   // store side of the same retirement
    output logic [31:0] StoreAddrW_retire,
    output logic [31:0] StoreDataW_retire,
    output logic [2:0]  MemFunct3W_retire
);

  // ================= Fetch =================
  logic [31:0] PCNextF, PCPlus4F, PCTargetD, PCTargetE;
  logic [31:0] mtvec_w, mepc_w; // from csr_file, declared here so the PC mux can see them

  // Priority is highest-first: debug preempts a trap, a trap preempts mret,
  // and all three preempt an ordinary branch or jump.
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
  logic [31:0] ResultW; // declared ahead of its Writeback-stage assignment:
                        // slang requires declare-before-use, Icarus does not
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
      // validD, not 1'b1: on the first edge after reset deasserts, Decode still
      // holds the reset-cleared bubble rather than a fetched instruction.
      validE <= validD;
    end

  assign is_ebreakE = ctrlE.is_ebreak;
  assign is_dretE   = ctrlE.is_dret;
  // Full equality, not ResultSrc[0]: RESULT_CSR also has bit 0 set, and a CSR
  // read needs no load-use stall.
  assign IsLoadE = (ctrlE.ResultSrc == RESULT_MEM);

  // ================= Execute =================
  logic [31:0] SrcAE_reg, SrcAE, SrcBE_reg, WriteDataE, ALUResultE;
  logic [31:0] FwdResultM; // MEM-stage forward source -- defined in the MEM stage
  logic        ZeroE, LtE, take_branchE;
  logic [31:0] PCTargetBranchE;

  // Port order is fixed by rv32i_pkg.sv: FWD_WB=01 -> d1, FWD_MEM=10 -> d2.
  // d2 is FwdResultM, not ALUResultM -- see its definition in the MEM stage.
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

  // Forwarded rs1 for CSRRW/S/C; the raw 5-bit field for the *I variants.
  assign csr_operandE = ctrlE.csr_use_imm ? {27'b0, Rs1E} : SrcAE_reg;

  // Separate from the main ALU: CSRRC needs an AND-with-inverted-operand the
  // ALU has no control code for.
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

  always_comb begin
    misalignedE = 1'b0;
    if (is_load_or_storeE)
      unique case (funct3E[1:0])
        2'b00:   misalignedE = 1'b0;             // LB/LBU/SB, always aligned
        2'b01:   misalignedE = ALUResultE[0];    // LH/LHU/SH
        2'b10:   misalignedE = |ALUResultE[1:0]; // LW/SW
        default: misalignedE = 1'b0;             // no load/store uses 2'b11
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
  // Third arm is don't-care to csr_file.sv (trap_en is 0), but keeps a
  // waveform dump readable.
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

  // Nothing commits to the CSR file on an EnterDebug cycle: that instruction
  // is squashed and re-executes after resume. csr_we is additionally
  // suppressed under trap_en, since that instruction is the one excepting.
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

  // FlushM keeps the EX-stage instruction's own RegWrite/MemWrite from
  // reaching the regfile or dmem when it is excepting or being halted.
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

  // The value this MEM-stage instruction will write to rd -- not ALUResultM,
  // which is only correct for ALU results. RESULT_MEM is absent because the
  // loaded data does not exist yet; hazard_unit.sv stalls instead, which is
  // what makes `default` safe.
  always_comb
    unique case (ResultSrcM)
      RESULT_CSR:     FwdResultM = CsrRdataM;
      RESULT_PCPLUS4: FwdResultM = PCPlus4M;
      default:        FwdResultM = ALUResultM_r; // RESULT_ALU (RESULT_MEM stalls)
    endcase

  // ================= MEM/WB register =================
  logic [31:0] ALUResultW, ReadDataW, PCPlus4W, CsrRdataW;
  logic [1:0]  ResultSrcW;
  // Store address/data/width, carried one stage past the commit at MEM so
  // retire_if.sv can present the store and its retirement as one record.
  // Nothing in the core reads them back.
  logic [31:0] StoreAddrW, StoreDataW;
  logic [2:0]  MemFunct3W;
  logic        MemWriteW;
  // The signal a monitor gates on -- not `InstrW != NOP_INSTR`, since a real
  // ADDI x0,x0,0 is bit-identical to a flush-inserted bubble.
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
  // (ResultW is declared up in the Decode section)
  mux4 #(32) resultmux (
      .d0(ALUResultW), .d1(ReadDataW), .d2(PCPlus4W), .d3(CsrRdataW),
      .s(ResultSrcW), .y(ResultW));

  // retirement outputs -- WB-stage passthrough for retire_if.sv
  assign RdW_retire        = RdW;
  assign ResultW_retire    = ResultW;
  assign RegWriteW_retire  = RegWriteW;
  assign ValidW_retire     = validW;
  assign MemWriteW_retire  = MemWriteW;
  assign StoreAddrW_retire = StoreAddrW;
  assign StoreDataW_retire = StoreDataW;
  assign MemFunct3W_retire = MemFunct3W;

endmodule
