// =============================================================================
// hazard_unit.sv
//
// All hazard detection for the 5-stage pipeline lives here: forwarding
// (data hazards resolved without a stall), the load-use stall (one data
// hazard forwarding can't fix, because the data doesn't exist yet), and
// flush control for control hazards (mispredicted branch/jalr, jal
// resolving in ID, debug-halt entry, and -- new this milestone -- a
// trap being taken or an mret redirecting the PC).
//
// ---- Forwarding ----
// (unchanged -- see rv32i_pkg.sv / datapath.sv's forwardamux/forwardbmux
// comments for the FWD_MEM/FWD_WB encoding this must match.)
//
// ---- Load-use stall ----
// (unchanged.)
//
// ---- Flushes (EXTENDED this milestone) ----
// FlushD/FlushE now also fire on trap_en (a trap is being taken this
// cycle -- exception or interrupt) or mret_enE (mret is redirecting the
// PC): exactly the same reasoning as a mispredicted branch -- whatever
// sequentially-fetched content is sitting in D/about-to-enter-E is
// wrong-path and must be squashed, the same way it would be for a taken
// branch.
//
// FlushD/FlushE also fire on ExitDebug (a dret resuming the core). This was
// MISSING and is a real bug found by simulation, not by review: exit_debug
// redirects PCNextF to dpc in datapath.sv's fetch mux, but with no flush the
// two instructions already fetched sequentially behind the dret -- at
// dm_halt_addr_i+4 and +8, i.e. whatever happens to sit after the debug ROM
// stub -- stayed in D/E and executed for real after the resume. Structurally
// identical to mret_enE, which was already handled here; dret is just the
// debug-mode spelling of the same "redirect the PC from EX" event.
//
// It went unnoticed because the two simulators disagreed about what those
// stray fetches decode to: Verilator reads uninitialised imem as 0, which is
// an illegal opcode, so the core trapped to mtvec=0 and fell back into the
// test's loop -- the testbench passed by luck. Icarus reads them as X, the PC
// went X, and the core wedged. See docs/DESIGN_GUIDE.md Section 10.
//
// FlushM gets trap_en added (NOT mret_enE, NOT ExitDebug): a trap means the EX-stage
// instruction itself is the one excepting/being interrupted, so ITS OWN
// RegWrite/MemWrite must not reach the register file/dmem as it moves
// into MEM -- same mechanism debug-halt already used to squash an
// in-flight instruction. mret has no such self-squash need: unlike a
// trap, mret doesn't correspond to "this instruction faulted," it's
// just a control-transfer with no RegWrite/MemWrite of its own to
// suppress, exactly like a taken branch/jalr never needed to be in
// FlushM either.
// =============================================================================

import rv32i_pkg::*;

module hazard_unit (
    input  logic       RegWriteM,
    input  logic       RegWriteW,
    input  logic [4:0] RdM,
    input  logic [4:0] RdW,
    input  logic [4:0] Rs1E,
    input  logic [4:0] Rs2E,
    output logic [1:0] ForwardAE,
    output logic [1:0] ForwardBE,

    input  logic [4:0] RdE,
    input  logic [4:0] Rs1D,
    input  logic [4:0] Rs2D,
    input  logic       Rs1UsedD,     // does D-stage instr actually read rs1?
    input  logic       Rs2UsedD,     // does D-stage instr actually read rs2?
    input  logic       ResultSrcE0,  // 1 when the EX-stage instruction is a load
    output logic       StallF,
    output logic       StallD,
    output logic       FlushE,

    input  logic        PCSrcE,      // taken branch / jalr resolved in EX
    input  logic        JumpD,       // jal resolved in ID
    input  logic        EnterDebug,  // debug halt request accepted this cycle
    input  logic        ExitDebug,   // dret resuming from debug this cycle
    input  logic        trap_en,     // exception/interrupt taken this cycle
    input  logic        mret_enE,    // mret redirecting the PC this cycle
    output logic        FlushD,
    output logic        FlushM
);

  logic lwStallD;

  // ---- forwarding ----
  always_comb begin
    if      (RegWriteM && (RdM != 0) && (RdM == Rs1E)) ForwardAE = FWD_MEM;
    else if (RegWriteW && (RdW != 0) && (RdW == Rs1E)) ForwardAE = FWD_WB;
    else                                                 ForwardAE = FWD_NONE;

    if      (RegWriteM && (RdM != 0) && (RdM == Rs2E)) ForwardBE = FWD_MEM;
    else if (RegWriteW && (RdW != 0) && (RdW == Rs2E)) ForwardBE = FWD_WB;
    else                                                 ForwardBE = FWD_NONE;
  end

  // ---- load-use stall ----
  assign lwStallD = ResultSrcE0 && (RdE != 0) &&
                    ((Rs1UsedD && (RdE == Rs1D)) || (Rs2UsedD && (RdE == Rs2D)));
  assign StallF   = lwStallD;
  assign StallD   = lwStallD;

  // ---- flushes ----
  assign FlushD = PCSrcE | JumpD | EnterDebug | ExitDebug | trap_en | mret_enE;
  assign FlushE = PCSrcE | lwStallD | EnterDebug | ExitDebug | trap_en | mret_enE;
  assign FlushM = EnterDebug | trap_en;

endmodule
