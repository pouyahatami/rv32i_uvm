// =============================================================================
// cells.sv
//
// Reusable building-block cells:
//   - adder : 32-bit combinational adder
//   - mux2  : parameterized 2-to-1 mux
//   - mux3  : parameterized 3-to-1 mux
//   - mux4  : parameterized 4-to-1 mux (added for debug PC redirection)
//
// UNCHANGED by the RV32I extension — the new muxes needed (SrcA select
// for AUIPC, PC-target base select for JALR) reuse mux2, and resultmux
// now uses mux4 (already existed for the debug PC redirect) instead of
// mux3. No new cell types were needed.
//
// STYLE (lowRISC Verilog Coding Style): tunable parameters use UpperCamelCase
// (Width, not WIDTH) -- callers all pass it positionally (e.g. mux3 #(32)),
// which the guide's own instantiation rule explicitly allows for a single,
// obvious parameter like a register width, so this rename needed no update
// at any call site.
// =============================================================================

module adder (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] y
);

  assign y = a + b;
endmodule

module mux2 #(
    parameter int Width = 8
) (
    input  logic [Width-1:0] d0,
    input  logic [Width-1:0] d1,
    input  logic             s,
    output logic [Width-1:0] y
);

  assign y = s ? d1 : d0;
endmodule

module mux3 #(
    parameter int Width = 8
) (
    input  logic [Width-1:0] d0,
    input  logic [Width-1:0] d1,
    input  logic [Width-1:0] d2,
    input  logic [1:0]       s,
    output logic [Width-1:0] y
);

  assign y = s[1] ? d2 : (s[0] ? d1 : d0);
endmodule

module mux4 #(
    parameter int Width = 8
) (
    input  logic [Width-1:0] d0,
    input  logic [Width-1:0] d1,
    input  logic [Width-1:0] d2,
    input  logic [Width-1:0] d3,
    input  logic [1:0]       s,
    output logic [Width-1:0] y
);

  assign y = s[1] ? (s[0] ? d3 : d2) : (s[0] ? d1 : d0);
endmodule
