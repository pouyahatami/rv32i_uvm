// =============================================================================
// Constants shared across the environment.
//
// These must match gen_stream.py's COMPLETION_GPR / COMPLETION_VALUE /
// DATA_BASE_GPR. Nothing links the two at compile time; a mismatch shows up
// as a run that never terminates, because the scoreboard's `done` never fires.
// =============================================================================

parameter bit [31:0] COMPLETION_VALUE = 32'h000007FF;
parameter bit [4:0]  COMPLETION_GPR   = 5'd31;

// The generator's reserved base pointer for every load/store: written once by
// the first instruction, never any other instruction's destination, which is
// what makes every memory access legal by construction.
parameter bit [4:0]  DATA_BASE_GPR = 5'd1;
