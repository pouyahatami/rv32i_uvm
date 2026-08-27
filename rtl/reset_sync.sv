// =============================================================================
// reset_sync.sv
//
// Reset synchronizer: asynchronous assert, synchronous deassert.
//
// One instance at the top of a single-clock design. docs/DESIGN_GUIDE.md
// section 2 covers why deassertion is the half that needs synchronizing.
// =============================================================================

module reset_sync #(
    // Two is the practical minimum; three buys MTBF margin at high frequency.
    parameter int Stages = 2
) (
    input  logic clk,
    input  logic arst_in,   // asynchronous, active high (raw pad/board reset)
    output logic rst_out    // async assert, synchronous deassert
);

  // These flops absorb metastability: synthesis must not merge or retime them
  // away. Spellings are vendor-specific; each is harmless where unrecognised.
  (* ASYNC_REG = "TRUE", PRESERVE, DONT_TOUCH = "TRUE" *)
  logic [Stages-1:0] sync_q;

  always_ff @(posedge clk, posedge arst_in)
    if (arst_in) sync_q <= {Stages{1'b1}};
    else         sync_q <= {sync_q[Stages-2:0], 1'b0};

  assign rst_out = sync_q[Stages-1];

endmodule
