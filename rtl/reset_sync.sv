// =============================================================================
// reset_sync.sv
//
// Reset synchronizer: asynchronous assert, synchronous deassert.
//
// WHY THIS EXISTS, AND WHY THE ANSWER IS NOT "USE A SYNCHRONOUS RESET"
//
// Every sequential block in this core resets on `always_ff @(posedge clk,
// posedge reset)` -- an asynchronous reset. That is not a mistake, and it is
// not the thing that was wrong. Asynchronous reset assertion is standard ASIC
// practice for a good reason: it works with no clock. At power-up, during a
// PLL relock, or in any clock-gated state, a synchronous reset cannot reach a
// single flip-flop, because a synchronous reset is just data on the D pin and
// data needs a clock edge to land. A chip whose reset depends on a clock that
// may not be running yet has no guaranteed initial state.
//
// The real hazard is asynchronous *deassertion*. Reset release is a single
// event seen by thousands of flops spread across the die, each with its own
// clock-tree delay. If release happens to land near a clock edge, some flops
// see the last reset cycle and some do not -- a recovery/removal timing
// violation. Half the design leaves reset one cycle after the other half, or
// a flop goes metastable outright. The failure is intermittent, corner- and
// temperature-dependent, invisible in RTL simulation (where reset release is
// a clean zero-delay event), and one of the classic ways a chip works on the
// bench and fails in the field.
//
// The standard fix, and the one used here, is to keep the asynchronous assert
// and make the deassert synchronous:
//
//   assert    : immediate, no clock required     <- the property worth keeping
//   deassert  : aligned to a clock edge          <- removes the race
//
// A shift register held at 1 while `arst_in` is high, then walking a 0 through
// on successive clock edges, does exactly that. The last stage's output
// asserts the instant `arst_in` does, and releases Stages clock edges after
// `arst_in` falls -- by which time the release is a synchronous event that
// every downstream flop samples the same way. The intermediate stages also
// give any metastability from the asynchronous edge time to settle, which is
// why two stages is the minimum and why they must not be optimised into one.
//
// SCOPE: single clock domain. This core has exactly one clock, so one
// synchronizer at the top is sufficient. A multi-clock design needs one of
// these per domain, each clocked by that domain's clock -- a reset
// synchronized to the wrong clock is no better than an unsynchronized one.
// =============================================================================

module reset_sync #(
    // Two is the practical minimum. Three is common on high-frequency or
    // safety-critical designs where the extra MTBF margin is cheap.
    parameter int Stages = 2
) (
    input  logic clk,
    input  logic arst_in,   // asynchronous, active high (raw pad/board reset)
    output logic rst_out    // async assert, synchronous deassert
);

  // ASYNC_REG / PRESERVE / DONT_TOUCH: these flops exist to absorb
  // metastability. Synthesis must not merge, retime, or optimise them away,
  // and place-and-route should keep them adjacent. The attribute spellings
  // differ per vendor; all three are harmless where unrecognised.
  (* ASYNC_REG = "TRUE", PRESERVE, DONT_TOUCH = "TRUE" *)
  logic [Stages-1:0] sync_q;

  always_ff @(posedge clk, posedge arst_in)
    if (arst_in) sync_q <= {Stages{1'b1}};
    else         sync_q <= {sync_q[Stages-2:0], 1'b0};

  assign rst_out = sync_q[Stages-1];

endmodule
