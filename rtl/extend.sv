// =============================================================================
// extend.sv
//
// Sign-extends the immediate field of an RV32I instruction. The immediate
// layout depends on the instruction format, selected by `immsrc`, which
// controller.sv's maindec drives. The IMM_* encoding itself is defined once
// in rv32i_pkg.sv; this file names it rather than restating the bit patterns.
//
//   IMM_I  -> sign-extend instr[31:20]              (also JALR)
//   IMM_S  -> sign-extend {instr[31:25], instr[11:7]}
//   IMM_B  -> sign-extend {instr[31], instr[7], instr[30:25], instr[11:8], 0}
//   IMM_J  -> sign-extend {instr[31], instr[19:12], instr[20], instr[30:21], 0}
//   IMM_U  -> {instr[31:12], 12'b0}
// =============================================================================

import rv32i_pkg::*;

module extend (
    input  logic [31:7] instr,
    input  logic [ 2:0] immsrc,
    output logic [31:0] immext
);

  always_comb
    unique case (immsrc)
      IMM_I:
        immext = {{20{instr[31]}}, instr[31:20]};
      IMM_S:
        immext = {{20{instr[31]}}, instr[31:25], instr[11:7]};
      IMM_B:
        immext = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
      IMM_J:
        immext = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
      IMM_U:
        immext = {instr[31:12], 12'b0};
      default: // 101/110/111 are unassigned; latch-safety only
        immext = 32'b0;
    endcase
endmodule
