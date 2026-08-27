// =============================================================================
// regfile.sv
//
// Three-ported register file: two combinational read ports, one write port on
// posedge clk. x0 is hardwired to 0 on the read path.
//
// The read ports bypass a write in progress. This is required, not an
// optimisation: forwarding covers RAW distance 1 and 2, and a distance-3
// dependency reads the register file in ID on the same edge the producer
// writes it from WB. docs/DESIGN_GUIDE.md section 4 has the worked example.
// =============================================================================

module regfile (
    input  logic        clk,
    input  logic        we3,
    input  logic [ 4:0]  a1,
    input  logic [ 4:0]  a2,
    input  logic [ 4:0]  a3,
    input  logic [31:0] wd3,
    output logic [31:0] rd1,
    output logic [31:0] rd2
);

  logic [31:0] rf[31:0];

  always_ff @(posedge clk)
    if (we3) rf[a3] <= wd3;

  assign rd1 = (a1 == 0) ? 32'b0 : (we3 && (a3 == a1)) ? wd3 : rf[a1];
  assign rd2 = (a2 == 0) ? 32'b0 : (we3 && (a3 == a2)) ? wd3 : rf[a2];
endmodule
