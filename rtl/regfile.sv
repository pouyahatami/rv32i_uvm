// =============================================================================
// regfile.sv
//
// Three-ported register file:
//   - two combinational read ports (A1/RD1, A2/RD2), with a read-during-write
//     bypass (see below)
//   - one write port on the rising edge of clk (A3/WD3/WE3)
// Register x0 is hardwired to 0 on the write path.
//
// ---- The read-during-write bypass, and why it is REQUIRED here ----
//
// In the 5-stage pipeline, hazard_unit.sv's forwarding covers a producer
// sitting in MEM or in WB relative to a consumer in EX -- that is, a RAW
// dependency at instruction distance 1 or 2. It cannot cover distance 3:
//
//     i+0 : ADDI x10, x0, 4    <- producer
//     i+1 : ADDI x11, x0, 0x77
//     i+2 : SW   x11, 0(x10)
//     i+3 : LW   x12, 0(x10)   <- consumer, distance 3
//
// When the consumer is in ID (where the register file is actually read), the
// producer is in WB. Its write lands on that same clock edge, so a plain
// "write on posedge, read the array combinationally" register file returns
// the STALE value -- and by the time the consumer reaches EX the producer has
// retired, so no forwarding path sees it either. Distance 3 falls straight
// through the gap between the two mechanisms.
//
// The bypass below closes it: an ID read that targets the register being
// written this cycle returns the write data directly. (Harris & Harris solve
// the same problem by clocking the write on the FALLING edge. The bypass is
// preferred here -- same behaviour, but no second clock edge, which keeps this
// synthesisable as ordinary single-edge logic.)
//
// Omitting it is a real bug, not a theoretical one -- docs/JOURNAL.md,
// "Distance-3 RAW hazards read stale registers".
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
