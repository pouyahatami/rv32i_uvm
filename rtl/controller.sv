// =============================================================================
// controller.sv
//
// Pure combinational decode -- instantiated ONCE, in the Decode stage.
// Branch/jump resolution and CSR read/write/trap logic live in
// datapath.sv's EX-stage logic (needs forwarded operands and the CSR
// file, which is instantiated inside datapath.sv alongside the regfile).
//
// Decodes the base RV32I opcodes in maindec/aludecoder, and ECALL, MRET,
// the CSR instructions (CSRRW/S/C and their *I immediate variants),
// EBREAK/DRET and a coarse illegal-instruction check as an overlay in the
// top-level `controller` module. The overlay reads Instr[31:20] directly
// rather than pushing SYSTEM decode down into maindec, which keeps the
// base-opcode case statements to one concern each.
//
// Illegal-instruction scope (documented simplification): this flags an
// unrecognized top-level opcode, or an unrecognized funct3/funct12 under
// SYSTEM. It does NOT attempt full illegal-instruction coverage (e.g. a
// bogus funct7 on an R-type ADD/SUB is not caught) -- that's a much
// larger decode surface for comparatively little verification payoff in
// a project this size; small teaching cores commonly scope it the same
// way.
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
  // CSR instructions: SYSTEM opcode, funct3 != 000 (privileged control
  // transfer) and != 100 (reserved/unassigned). funct3[1:0] doubles as
  // the RW/RS/RC selector; funct3[2] selects the *I (uimm) variants.
  assign is_csr    = system_instr & (funct3 != 3'b000) & (funct3 != 3'b100);

  // Coarse illegal-instruction check -- see file header.
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

  // CSR instructions read rs1 as a real register for CSRRW/S/C, but the
  // *I variants (funct3[2]=1) reuse InstrD[19:15] as a 5-bit zero-extended
  // immediate, not a register index -- same class of "these bits aren't
  // really rs1" issue JAL/LUI/AUIPC already required Rs1UsedD/Rs2UsedD
  // for. Get this wrong and hazard_unit.sv's load-use stall check can
  // spuriously stall (or worse, misforward) against whatever register the
  // immediate bits happen to numerically match.
  assign Rs1UsedD = is_csr ? ~funct3[2] : Rs1UsedD_md;
  assign Rs2UsedD = Rs2UsedD_md; // no CSR variant reads rs2

  // Package everything the ID/EX register needs to latch into one struct.
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

  // Rs1UsedD/Rs2UsedD: does this instruction actually read InstrD[19:15]/
  // [24:20] as register indices? JAL/LUI/AUIPC (U/J-type) reuse those same
  // bit positions as immediate bits -- without this, the load-use hazard
  // check in hazard_unit.sv would compare a JAL's immediate bits against
  // a preceding load's destination register and could spuriously stall
  // (and, worse, spuriously suppress the JAL's own PC redirect via
  // StallF).
  always_comb begin
    {RegWrite, ImmSrc, ALUSrc, MemWrite, ResultSrc,
     Branch, ALUOp, Jump, Jalr, AUIPCSel, Rs1UsedD, Rs2UsedD} = '0;

    // unique case: op is decoded from the fixed RV32I opcode map; the
    // default (all-zero decode, from the '0 fill above) is the fallback
    // for any opcode this design doesn't implement and is deliberately
    // NOT the same thing as is_illegal (see controller.sv) -- this is
    // just "assert nothing," is_illegal is the actual trap decision.
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
        ; // ebreak/dret/ecall/mret/CSR -- NOP here; controller.sv's
          // top-level always_comb overlays RegWrite/ResultSrc/
          // Rs1UsedD for the is_csr case, and is_ecall/is_mret
          // need no datapath ALU/RegWrite/MemWrite effect at all.
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

  // unique case: ALUOp is 2 bits and all 4 values are named in
  // rv32i_pkg.sv and produced somewhere below; the default is defensive
  // only and kept so this case is exhaustive without relying on the
  // 2-bit width alone to guarantee it.
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
          // funct3 is 3 bits and all 8 values are enumerated above, so this
          // default is unreachable -- included anyway per the style guide's
          // "always include default, even if all cases covered" rule, to
          // stay latch-safe under any future edit that narrows the case list.
          default:
            ALUControl = ALU_ADD;
        endcase
      default: // unreachable -- ALUOp is 2 bits and all 4 values are named above
        ALUControl = ALU_ADD;
    endcase
endmodule
