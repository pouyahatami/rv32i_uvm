// =============================================================================
// controller.sv
//
// Combinational decode, instantiated once in the Decode stage. Base opcodes
// go through maindec/aludecoder; SYSTEM (ECALL, MRET, EBREAK, DRET, the CSR
// instructions) is decoded as an overlay here from Instr[31:20].
//
// Illegal-instruction detection is coarse by design: an unknown top-level
// opcode, or an unknown funct3/funct12 under SYSTEM. A bogus funct7 on an
// R-type is not caught. See docs/GAPS.md.
// =============================================================================

import rv32i_pkg::*;

module controller (
    input  logic [6:0]   op,
    input  logic [2:0]   funct3,
    input  logic         funct7b5,
    input  logic [31:20] Instr,        // imm12 slice, SYSTEM decode
    output id_ex_ctrl_t  ctrlD,        // pipelined into E as-is (includes Branch)
    output logic [2:0]   ImmSrc,       // D-stage only -- extend.sv needs it in D
    output logic         Jump,         // D-stage only -- jal resolves in ID
    output logic         Rs1UsedD,
    output logic         Rs2UsedD
);

  logic [1:0] ALUOp;
  logic       system_instr;
  logic       is_ebreak, is_dret, is_ecall, is_mret, is_csr;
  logic       RegWrite, MemWrite, Branch, ALUSrc, Jalr, AUIPCSel;
  logic [1:0] ResultSrc;
  logic [3:0] ALUControl;
  logic       Rs1UsedD_md, Rs2UsedD_md; // maindec's raw outputs, before the CSR override below

  assign system_instr = (op == OP_SYSTEM);
  assign is_ebreak = system_instr & (Instr[31:20] == 12'b000000000001);
  assign is_dret   = system_instr & (Instr[31:20] == 12'b011110110010);
  assign is_ecall  = system_instr & (Instr[31:20] == 12'b000000000000);
  assign is_mret   = system_instr & (Instr[31:20] == 12'b001100000010);
  // funct3[1:0] is the RW/RS/RC selector; funct3[2] selects the *I variants.
  // 000 is a privileged control transfer and 100 is reserved.
  assign is_csr    = system_instr & (funct3 != 3'b000) & (funct3 != 3'b100);

  logic known_opcode, system_known;
  assign known_opcode = (op == OP_LOAD)  | (op == OP_STORE) | (op == OP_RTYPE) |
                        (op == OP_BRANCH)| (op == OP_ITYPE) | (op == OP_JAL)   |
                        (op == OP_JALR)  | (op == OP_LUI)   | (op == OP_AUIPC) |
                        (op == OP_SYSTEM);
  assign system_known = is_ecall | is_ebreak | is_mret | is_dret | is_csr;
  logic is_illegal;
  assign is_illegal = ~known_opcode | (system_instr & ~system_known);

  maindec md(op, ImmSrc, MemWrite, Branch, ALUSrc, RegWrite,
             Jump, Jalr, AUIPCSel, ALUOp, Rs1UsedD_md, Rs2UsedD_md, ResultSrc);
  aludecoder  ad(op[5], funct3, funct7b5, ALUOp, ALUControl);

  // The *I CSR variants reuse InstrD[19:15] as a zero-extended immediate,
  // not a register index.
  assign Rs1UsedD = is_csr ? ~funct3[2] : Rs1UsedD_md;
  assign Rs2UsedD = Rs2UsedD_md; // no CSR variant reads rs2

  always_comb begin
    ctrlD.RegWrite    = RegWrite | is_csr;         // CSR instructions write rd
    ctrlD.MemWrite    = MemWrite;
    ctrlD.Branch      = Branch;
    ctrlD.ALUSrc      = ALUSrc;
    ctrlD.Jalr        = Jalr;
    ctrlD.AUIPCSel    = AUIPCSel;
    ctrlD.ResultSrc   = is_csr ? RESULT_CSR : ResultSrc;
    ctrlD.ALUControl  = ALUControl;
    ctrlD.is_ebreak   = is_ebreak;
    ctrlD.is_dret     = is_dret;
    ctrlD.is_ecall    = is_ecall;
    ctrlD.is_mret     = is_mret;
    ctrlD.is_csr      = is_csr;
    ctrlD.csr_op      = funct3[1:0];
    ctrlD.csr_use_imm = funct3[2];
    ctrlD.is_illegal  = is_illegal;
  end
endmodule

module maindec (
    input  logic [6:0] op,
    output logic [2:0] ImmSrc,
    output logic       MemWrite,
    output logic       Branch,
    output logic       ALUSrc,
    output logic       RegWrite,
    output logic       Jump,
    output logic       Jalr,
    output logic       AUIPCSel,
    output logic [1:0] ALUOp,
    output logic       Rs1UsedD,
    output logic       Rs2UsedD,
    output logic [1:0] ResultSrc
);

  // Rs1UsedD/Rs2UsedD say whether this instruction reads InstrD[19:15]/[24:20]
  // as register indices at all; U/J-type reuse those bits as immediate bits.
  // hazard_unit.sv's load-use check depends on them.
  //
  // The default arm asserts nothing. That is not the same decision as
  // is_illegal, which is made in controller.sv.
  always_comb begin
    {RegWrite, ImmSrc, ALUSrc, MemWrite, ResultSrc,
     Branch, ALUOp, Jump, Jalr, AUIPCSel, Rs1UsedD, Rs2UsedD} = '0;

    unique case (op)
      OP_LOAD: begin
        RegWrite  = 1'b1;
        ImmSrc    = 3'b000;
        ALUSrc    = 1'b1;
        ResultSrc = RESULT_MEM;
        Rs1UsedD  = 1'b1;
      end
      OP_STORE: begin
        ImmSrc   = 3'b001;
        ALUSrc   = 1'b1;
        MemWrite = 1'b1;
        Rs1UsedD = 1'b1;
        Rs2UsedD = 1'b1;
      end
      OP_RTYPE: begin
        RegWrite = 1'b1;
        ALUOp    = ALUOP_RITYPE_FAMILY;
        Rs1UsedD = 1'b1;
        Rs2UsedD = 1'b1;
      end
      OP_BRANCH: begin
        ImmSrc   = 3'b010;
        Branch   = 1'b1;
        ALUOp    = ALUOP_BRANCH_FAMILY;
        Rs1UsedD = 1'b1;
        Rs2UsedD = 1'b1;
      end
      OP_ITYPE: begin
        RegWrite = 1'b1;
        ImmSrc   = 3'b000;
        ALUSrc   = 1'b1;
        ALUOp    = ALUOP_RITYPE_FAMILY;
        Rs1UsedD = 1'b1;
      end
      OP_JAL: begin
        RegWrite  = 1'b1;
        ImmSrc    = 3'b011;
        Jump      = 1'b1;
        ResultSrc = RESULT_PCPLUS4;
      end
      OP_JALR: begin
        RegWrite  = 1'b1;
        ImmSrc    = 3'b000;
        ALUSrc    = 1'b1;
        Jalr      = 1'b1;
        ResultSrc = RESULT_PCPLUS4;
        ALUOp     = ALUOP_ADD_FAMILY;
        Rs1UsedD  = 1'b1;
      end
      OP_LUI: begin
        RegWrite = 1'b1;
        ImmSrc   = 3'b100;
        ALUSrc   = 1'b1;
        ALUOp    = ALUOP_LUI_PASSTHRU;
      end
      OP_AUIPC: begin
        RegWrite = 1'b1;
        ImmSrc   = 3'b100;
        ALUSrc   = 1'b1;
        AUIPCSel = 1'b1;
        ALUOp    = ALUOP_ADD_FAMILY;
      end
      OP_SYSTEM:
        ; // decoded by controller.sv's overlay, not here
      default:
        ;
    endcase
  end
endmodule

module aludecoder (
    input  logic       opb5,
    input  logic [2:0] funct3,
    input  logic       funct7b5,
    input  logic [1:0] ALUOp,
    output logic [3:0] ALUControl
);

  logic RtypeSub;
  assign RtypeSub = funct7b5 & opb5;

  always_comb
    unique case (ALUOp)
      ALUOP_ADD_FAMILY:
        ALUControl = ALU_ADD;

      ALUOP_BRANCH_FAMILY:
        unique case (funct3)
          3'b000, 3'b001:
            ALUControl = ALU_SUB;
          3'b100, 3'b101:
            ALUControl = ALU_SLT;
          3'b110, 3'b111:
            ALUControl = ALU_SLTU;
          default:
            ALUControl = ALU_SUB;
        endcase

      ALUOP_LUI_PASSTHRU:
        ALUControl = ALU_PASSB;

      ALUOP_RITYPE_FAMILY:
        unique case (funct3)
          3'b000:
            ALUControl = RtypeSub ? ALU_SUB : ALU_ADD;
          3'b001:
            ALUControl = ALU_SLL;
          3'b010:
            ALUControl = ALU_SLT;
          3'b011:
            ALUControl = ALU_SLTU;
          3'b100:
            ALUControl = ALU_XOR;
          3'b101:
            ALUControl = funct7b5 ? ALU_SRA : ALU_SRL;
          3'b110:
            ALUControl = ALU_OR;
          3'b111:
            ALUControl = ALU_AND;
          default: // unreachable; latch-safety only
            ALUControl = ALU_ADD;
        endcase
      default: // unreachable; latch-safety only
        ALUControl = ALU_ADD;
    endcase
endmodule
