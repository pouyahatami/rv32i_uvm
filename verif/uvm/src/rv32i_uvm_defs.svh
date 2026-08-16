// =============================================================================
// Constants shared across the environment.
//
// The sentinel lived as a pair of localparams inside rv32i_scoreboard until
// the coverage collector needed to recognise it too. Two copies of a magic
// number that must agree with a third copy in verif/spike/gen_stream.py is
// exactly the drift this project has already been bitten by, so it moved to
// package scope the first time a second reader appeared -- not the third.
//
// These must match gen_stream.py's SENTINEL_REG/SENTINEL_VAL/SAFE_BASE_REG.
// There is no compile-time link between the two; a mismatch shows up as a run
// that never terminates, because the scoreboard's `done` event never fires.
// =============================================================================

parameter bit [31:0] SENTINEL_VAL  = 32'h000007FF;
parameter bit [4:0]  SENTINEL_REG  = 5'd31;

// x1 is the generator's reserved "safe base pointer" for every load/store.
// It is written once by the first instruction and is never any other
// instruction's destination, which is what makes every memory access legal by
// construction. Coverage bins it separately so that reservation is visible in
// the report rather than implied.
parameter bit [4:0]  SAFE_BASE_REG = 5'd1;
