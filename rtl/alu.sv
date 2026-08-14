// =============================================================================
// alu.sv
//
// Combinational ALU. Operation codes are named in rv32i_pkg.sv:
//
//   0000 add   0100 xor    1000 sra
//   0001 sub   0101 slt    1001 sltu
//   0010 and   0110 sll    1010 passb
//   0011 or    0111 srl
//
// PASSB returns b untouched. It exists for LUI, so the U-immediate can flow
// through the normal EX-stage path and the normal writeback mux. The
// alternative is a dedicated writeback source threaded from D to W, which
// means carrying ImmExt through three extra pipeline registers to serve one
// instruction.
// =============================================================================

module alu (
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [ 3:0] alucontrol,
    output logic [31:0] result,
    output logic        zero,
    output logic        lt
);

  logic [31:0] condinvb, sum;
  logic        v;
  logic        isAddSub;

  assign condinvb = alucontrol[0] ? ~b : b;
  assign sum = a + condinvb + alucontrol[0];
  assign isAddSub = (alucontrol == 4'b0000) | (alucontrol == 4'b0001) |
                    (alucontrol == 4'b0101);

  // unique case: every alucontrol encoding this design ever produces is
  // listed explicitly (see rv32i_pkg.sv); the default below is defensive
  // only -- aludecoder never emits the 5 remaining 4-bit combinations. A
  // defined fallback (32'b0) is used rather than 32'bx, per the style
  // guide's "RTL must not assert X to indicate don't-care" rule: an
  // unreachable path should still drive a known value, not propagate
  // unknowns into anything that happens to read result speculatively.
  always_comb
    unique case (alucontrol)
      4'b0000:
        result = sum;
      4'b0001:
        result = sum;
      4'b0010:
        result = a & b;
      4'b0011:
        result = a | b;
      4'b0100:
        result = a ^ b;
      4'b0101:
        result = {31'b0, sum[31] ^ v};
      4'b0110:
        result = a << b[4:0];
      4'b0111:
        result = a >> b[4:0];
      4'b1000:
        result = $signed(a) >>> b[4:0];
      4'b1001:
        result = {31'b0, a < b};
      4'b1010:
        result = b;                     // passb (lui)
      default:
        result = 32'b0;
    endcase

  assign zero = (result == 32'b0);
  assign lt   = result[0];
  assign v = ~(alucontrol[0] ^ a[31] ^ b[31]) & (a[31] ^ sum[31]) & isAddSub;

endmodule
