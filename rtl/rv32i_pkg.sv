// =============================================================================
// rv32i_pkg.sv
//
// A SystemVerilog package holding named opcode, ALU-control, CSR-address,
// trap-cause, and MMIO-base constants, plus the ID/EX pipeline control
// bundle -- the single source of truth every other RTL file in this
// directory imports (`import rv32i_pkg::*;`).
// =============================================================================

package rv32i_pkg;

  // ---- opcodes (instr[6:0]) ----
  parameter logic [6:0] OP_LOAD   = 7'b0000011;
  parameter logic [6:0] OP_STORE  = 7'b0100011;
  parameter logic [6:0] OP_RTYPE  = 7'b0110011;
  parameter logic [6:0] OP_BRANCH = 7'b1100011;
  parameter logic [6:0] OP_ITYPE  = 7'b0010011;
  parameter logic [6:0] OP_JAL    = 7'b1101111;
  parameter logic [6:0] OP_JALR   = 7'b1100111;
  parameter logic [6:0] OP_LUI    = 7'b0110111;
  parameter logic [6:0] OP_AUIPC  = 7'b0010111;
  parameter logic [6:0] OP_SYSTEM = 7'b1110011;

  // ---- ALU control codes ----
  parameter logic [3:0] ALU_ADD   = 4'b0000;
  parameter logic [3:0] ALU_SUB   = 4'b0001;
  parameter logic [3:0] ALU_AND   = 4'b0010;
  parameter logic [3:0] ALU_OR    = 4'b0011;
  parameter logic [3:0] ALU_XOR   = 4'b0100;
  parameter logic [3:0] ALU_SLT   = 4'b0101;
  parameter logic [3:0] ALU_SLL   = 4'b0110;
  parameter logic [3:0] ALU_SRL   = 4'b0111;
  parameter logic [3:0] ALU_SRA   = 4'b1000;
  parameter logic [3:0] ALU_SLTU  = 4'b1001;
  parameter logic [3:0] ALU_PASSB = 4'b1010;

  // ---- ALUOp ---------------
  parameter logic [1:0] ALUOP_ADD_FAMILY    = 2'b00; // loads/stores/jalr/auipc
  parameter logic [1:0] ALUOP_BRANCH_FAMILY = 2'b01; // funct3 selects sub/slt/sltu
  parameter logic [1:0] ALUOP_RITYPE_FAMILY = 2'b10; // funct3 selects the op
  parameter logic [1:0] ALUOP_LUI_PASSTHRU  = 2'b11; // forces ALU_PASSB

  // ---- ResultSrc -----------
  parameter logic [1:0] RESULT_ALU     = 2'b00;
  parameter logic [1:0] RESULT_MEM     = 2'b01;
  parameter logic [1:0] RESULT_PCPLUS4 = 2'b10;
  parameter logic [1:0] RESULT_CSR     = 2'b11; // CSR read-back value

  // ---- forwarding mux select -------------
  parameter logic [1:0] FWD_NONE = 2'b00;
  parameter logic [1:0] FWD_WB   = 2'b01;
  parameter logic [1:0] FWD_MEM  = 2'b10;

  parameter logic [31:0] NOP_INSTR = 32'h00000013; // addi x0,x0,0

  // ---- CSR addresses (subset of the M-mode CSR space actually wired up) ----
  parameter logic [11:0] CSR_MSTATUS  = 12'h300;
  parameter logic [11:0] CSR_MIE      = 12'h304;
  parameter logic [11:0] CSR_MTVEC    = 12'h305;
  parameter logic [11:0] CSR_MSCRATCH = 12'h340;
  parameter logic [11:0] CSR_MEPC     = 12'h341;
  parameter logic [11:0] CSR_MCAUSE   = 12'h342;
  parameter logic [11:0] CSR_MTVAL    = 12'h343;
  parameter logic [11:0] CSR_MIP      = 12'h344;
  parameter logic [11:0] CSR_MHARTID  = 12'hF14;

  // ---- trap cause codes (RISC-V standard numbering; mcause[31] is the
  //      separate interrupt/exception bit, added on top of these) ----
  parameter logic [4:0] EXC_ILLEGAL_INSTR  = 5'd2;
  parameter logic [4:0] EXC_LOAD_MISALIGN  = 5'd4;
  parameter logic [4:0] EXC_STORE_MISALIGN = 5'd6;
  parameter logic [4:0] EXC_ECALL_M        = 5'd11;
  parameter logic [4:0] INT_MTIMER         = 5'd7;

  // ---- MMIO map (see mem_bus.sv). RAM occupies [0, RamBytes). ----
  parameter logic [31:0] CLINT_BASE = 32'h0002_0000; // +0x0 mtime, +0x4 mtimecmp
  parameter logic [31:0] UART_BASE  = 32'h0003_0000; // +0x0 txdata, +0x4 status

  // ---- ID/EX pipeline register control bundle ----
  typedef struct packed {
    logic       RegWrite;
    logic       MemWrite;
    logic       Branch;
    logic       ALUSrc;
    logic       Jalr;
    logic       AUIPCSel;
    logic [1:0] ResultSrc;
    logic [3:0] ALUControl;
    logic       is_ebreak;
    logic       is_dret;
    logic       is_ecall;
    logic       is_mret;
    logic       is_csr;
    logic [1:0] csr_op;     // 01=RW, 10=RS, 11=RC (== funct3[1:0])
    logic       csr_use_imm;// 1 for CSRRWI/SI/CI (rs1 field is a 5b uimm)
    logic       is_illegal;
  } id_ex_ctrl_t;

  // Written as a plain concatenation rather than a named assignment pattern
  // ('{RegWrite: 1'b0, ...}), which Icarus Verilog 12 cannot parse -- and
  // Icarus is one of the two simulators this core is regressed under. Fields
  // MUST stay in the same order as the typedef above, first field = MSB. If a
  // field is ever added to id_ex_ctrl_t and not added here, the width no
  // longer matches and every tool errors out, which is the failure mode you
  // want.
  parameter id_ex_ctrl_t ID_EX_CTRL_BUBBLE = {
    1'b0,      // RegWrite
    1'b0,      // MemWrite
    1'b0,      // Branch
    1'b0,      // ALUSrc
    1'b0,      // Jalr
    1'b0,      // AUIPCSel
    RESULT_ALU,// ResultSrc
    ALU_ADD,   // ALUControl
    1'b0,      // is_ebreak
    1'b0,      // is_dret
    1'b0,      // is_ecall
    1'b0,      // is_mret
    1'b0,      // is_csr
    2'b00,     // csr_op
    1'b0,      // csr_use_imm
    1'b0       // is_illegal
  };

endpackage
