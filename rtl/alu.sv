// =============================================================================
// alu.sv
//
// Combinational ALU, decoding the ALU_* codes defined in rv32i_pkg.sv.
//
// The encoding is not arbitrary and this module depends on that. Three codes
// use the adder -- ALU_ADD (0000), ALU_SUB (0001), ALU_SLT (0101) -- and among
// those, bit 0 is exactly "subtract". So bit 0 is reused as the adder's
// "invert b, carry in 1" control (`condinvb`/`sum`) and one adder serves all
// three. Other codes also have bit 0 set (ALU_OR, ALU_SRL, ALU_SLTU); they
// simply never read `sum`, which is what makes the shortcut safe.
//
// Renumbering ALU_* in the package without preserving that property silently
// breaks the subtract path here, and `isAddSub` -- which gates the overflow
// bit ALU_SLT depends on, and was D1 -- has to be kept in step by hand. That
// is why this file names the codes instead of open-coding the bit patterns.
//
// ALU_PASSB returns b untouched, so LUI's U-immediate can use the normal EX
// path and writeback mux instead of a dedicated source threaded from D to W.
// =============================================================================

import rv32i_pkg::*;

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
  assign isAddSub = (alucontrol == ALU_ADD) | (alucontrol == ALU_SUB) |
                    (alucontrol == ALU_SLT);

  // The default drives 0 rather than X: an unreachable path should still
  // produce a known value.
  always_comb
    unique case (alucontrol)
      ALU_ADD:
        result = sum;
      ALU_SUB:
        result = sum;
      ALU_AND:
        result = a & b;
      ALU_OR:
        result = a | b;
      ALU_XOR:
        result = a ^ b;
      ALU_SLT:
        result = {31'b0, sum[31] ^ v};
      ALU_SLL:
        result = a << b[4:0];
      ALU_SRL:
        result = a >> b[4:0];
      ALU_SRA:
        result = $signed(a) >>> b[4:0];
      ALU_SLTU:
        result = {31'b0, a < b};
      ALU_PASSB:
        result = b;                     // lui
      default:
        result = 32'b0;
    endcase

  assign zero = (result == 32'b0);
  assign lt   = result[0];
  assign v = ~(alucontrol[0] ^ a[31] ^ b[31]) & (a[31] ^ sum[31]) & isAddSub;

endmodule
