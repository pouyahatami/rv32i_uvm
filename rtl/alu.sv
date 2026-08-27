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
// PASSB returns b untouched, so LUI's U-immediate can use the normal EX path
// and writeback mux instead of a dedicated source threaded from D to W.
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

  // The default drives 0 rather than X: an unreachable path should still
  // produce a known value.
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
