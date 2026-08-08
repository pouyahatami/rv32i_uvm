// =============================================================================
// extend.sv
//
// Sign-extends the immediate field of an RV32I instruction. The immediate
// layout depends on the instruction format, selected by `immsrc`.
//
//   000  I-type     -> sign-extend instr[31:20]              (also JALR)
//   001  S-type     -> sign-extend {instr[31:25], instr[11:7]}
//   010  B-type     -> sign-extend {instr[31], instr[7], instr[30:25],
//                                   instr[11:8], 1'b0}
//   011  J-type     -> sign-extend {instr[31], instr[19:12], instr[20],
//                                   instr[30:21], 1'b0}
//   100  U-type     -> {instr[31:12], 12'b0}
// =============================================================================

module extend (
    input  logic [31:7] instr,
    input  logic [ 2:0] immsrc,
    output logic [31:0] immext
);

  // unique case: controller.sv only ever emits 000-100 (see maindec); the
  // default is defensive only. A defined fallback (32'b0), not 32'bx --
  // see alu.sv's identical note.
  always_comb
    unique case (immsrc)
      3'b000: // I-type
        immext = {{20{instr[31]}}, instr[31:20]};
      3'b001: // S-type (stores)
        immext = {{20{instr[31]}}, instr[31:25], instr[11:7]};
      3'b010: // B-type (branches)
        immext = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
      3'b011: // J-type (jal)
        immext = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
      3'b100: // U-type (lui, auipc)
        immext = {instr[31:12], 12'b0};
      default:
        immext = 32'b0;
    endcase
endmodule
