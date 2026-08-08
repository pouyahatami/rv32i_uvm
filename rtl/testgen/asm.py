# Minimal RV32I encoder for the instructions we need to directed-test.
# Used to (a) avoid hand-encoding hex by mistake and (b) generate a
# program we can run through the already-validated C++ ISS to get golden
# expected register/memory values for the SV testbench.

def r(rd, rs1, rs2, funct3, funct7, opcode):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def i(rd, rs1, imm, funct3, opcode):
    imm &= 0xFFF
    return (imm << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def s(rs1, rs2, imm, funct3, opcode):
    imm &= 0xFFF
    imm11_5 = (imm >> 5) & 0x7F
    imm4_0 = imm & 0x1F
    return (imm11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm4_0 << 7) | opcode

def b(rs1, rs2, imm, funct3, opcode):
    imm &= 0x1FFF
    b12 = (imm >> 12) & 1
    b10_5 = (imm >> 5) & 0x3F
    b4_1 = (imm >> 1) & 0xF
    b11 = (imm >> 11) & 1
    return (b12 << 31) | (b10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (b4_1 << 8) | (b11 << 7) | opcode

def u(rd, imm, opcode):
    return (imm & 0xFFFFF000) | (rd << 7) | opcode

def j(rd, imm, opcode):
    imm &= 0x1FFFFF
    b20 = (imm >> 20) & 1
    b10_1 = (imm >> 1) & 0x3FF
    b11 = (imm >> 11) & 1
    b19_12 = (imm >> 12) & 0xFF
    return (b20 << 31) | (b19_12 << 12) | (b11 << 20) | (b10_1 << 21) | (rd << 7) | opcode

# opcodes
LOAD, STORE, RTYPE, BRANCH, ITYPE, JAL, JALR_OP, LUI, AUIPC, SYSTEM = \
    0b0000011, 0b0100011, 0b0110011, 0b1100011, 0b0010011, 0b1101111, 0b1100111, 0b0110111, 0b0010111, 0b1110011

def ADDI(rd, rs1, imm): return i(rd, rs1, imm, 0b000, ITYPE)
def XORI(rd, rs1, imm): return i(rd, rs1, imm, 0b100, ITYPE)
def SLTIU(rd, rs1, imm): return i(rd, rs1, imm, 0b011, ITYPE)
def SLLI(rd, rs1, shamt): return i(rd, rs1, shamt & 0x1F, 0b001, ITYPE)
def SRLI(rd, rs1, shamt): return i(rd, rs1, shamt & 0x1F, 0b101, ITYPE)
def SRAI(rd, rs1, shamt): return i(rd, rs1, (shamt & 0x1F) | (0x20 << 5), 0b101, ITYPE)
def LB(rd, rs1, imm): return i(rd, rs1, imm, 0b000, LOAD)
def LH(rd, rs1, imm): return i(rd, rs1, imm, 0b001, LOAD)
def LW(rd, rs1, imm): return i(rd, rs1, imm, 0b010, LOAD)
def LBU(rd, rs1, imm): return i(rd, rs1, imm, 0b100, LOAD)
def LHU(rd, rs1, imm): return i(rd, rs1, imm, 0b101, LOAD)
def JALR(rd, rs1, imm): return i(rd, rs1, imm, 0b000, JALR_OP)

def SB(rs1, rs2, imm): return s(rs1, rs2, imm, 0b000, STORE)
def SH(rs1, rs2, imm): return s(rs1, rs2, imm, 0b001, STORE)
def SW(rs1, rs2, imm): return s(rs1, rs2, imm, 0b010, STORE)

def ADD(rd, rs1, rs2): return r(rd, rs1, rs2, 0b000, 0b0000000, RTYPE)
def SUB(rd, rs1, rs2): return r(rd, rs1, rs2, 0b000, 0b0100000, RTYPE)
def XOR(rd, rs1, rs2): return r(rd, rs1, rs2, 0b100, 0b0000000, RTYPE)
def SLTU(rd, rs1, rs2): return r(rd, rs1, rs2, 0b011, 0b0000000, RTYPE)
def SLL(rd, rs1, rs2): return r(rd, rs1, rs2, 0b001, 0b0000000, RTYPE)
def SRL(rd, rs1, rs2): return r(rd, rs1, rs2, 0b101, 0b0000000, RTYPE)
def SRA(rd, rs1, rs2): return r(rd, rs1, rs2, 0b101, 0b0100000, RTYPE)

def BEQ(rs1, rs2, imm): return b(rs1, rs2, imm, 0b000, BRANCH)
def BNE(rs1, rs2, imm): return b(rs1, rs2, imm, 0b001, BRANCH)
def BLT(rs1, rs2, imm): return b(rs1, rs2, imm, 0b100, BRANCH)
def BGE(rs1, rs2, imm): return b(rs1, rs2, imm, 0b101, BRANCH)
def BLTU(rs1, rs2, imm): return b(rs1, rs2, imm, 0b110, BRANCH)
def BGEU(rs1, rs2, imm): return b(rs1, rs2, imm, 0b111, BRANCH)

def LUI_(rd, imm20): return u(rd, imm20 << 12, LUI)
def AUIPC_(rd, imm20): return u(rd, imm20 << 12, AUIPC)
def JAL_(rd, imm): return j(rd, imm, JAL)
def EBREAK(): return i(0, 0, 0x001, 0, SYSTEM)

# ---- CSR/trap/interrupt milestone additions ----
# CSR instructions reuse the I-type encoding: imm[11:0] = csr address,
# rs1 = source register (CSRRW/S/C) or a raw 5b zero-extended immediate
# (CSRRWI/SI/CI -- i()'s rs1 slot just encodes whatever integer you pass
# into bits[19:15], so no separate helper is needed for the immediate
# encoding itself).
def CSRRW(rd, csr, rs1):  return i(rd, rs1, csr, 0b001, SYSTEM)
def CSRRS(rd, csr, rs1):  return i(rd, rs1, csr, 0b010, SYSTEM)
def CSRRC(rd, csr, rs1):  return i(rd, rs1, csr, 0b011, SYSTEM)
def CSRRWI(rd, csr, uimm): return i(rd, uimm, csr, 0b101, SYSTEM)
def CSRRSI(rd, csr, uimm): return i(rd, uimm, csr, 0b110, SYSTEM)
def CSRRCI(rd, csr, uimm): return i(rd, uimm, csr, 0b111, SYSTEM)

def ECALL(): return i(0, 0, 0x000, 0, SYSTEM)
def MRET():  return i(0, 0, 0x302, 0, SYSTEM)
# DRET already exists implicitly via the debug testgen program's literal
# encoding (0x7B200073); not re-added here since this milestone's test
# program doesn't exercise debug.

# CSR addresses -- must match rv32i_pkg.sv / csr_file.sv / rv32isim.cpp exactly.
CSR_MSTATUS  = 0x300
CSR_MIE      = 0x304
CSR_MTVEC    = 0x305
CSR_MSCRATCH = 0x340
CSR_MEPC     = 0x341
CSR_MCAUSE   = 0x342
CSR_MTVAL    = 0x343
CSR_MIP      = 0x344

# MMIO base addresses -- must match rv32i_pkg.sv exactly.
CLINT_BASE = 0x00020000
UART_BASE  = 0x00030000
