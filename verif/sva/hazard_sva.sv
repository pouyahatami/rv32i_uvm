// =============================================================================
// verif/sva/hazard_sva.sv
//
// SystemVerilog assertions for the hazard/forwarding unit, bound into
// hazard_unit.sv rather than written inside it (see hazard_sva_bind.sv).
// Same philosophy as mem_backdoor_if.sv: the synthesizable RTL is never
// touched by verification code, and nothing here can reach a netlist.
//
// WHY BIND RATHER THAN `ifdef INSIDE THE RTL
// An `ifdef ASSERT_ON block inside hazard_unit.sv would put verification code
// in the same file a synthesis tool reads, and every tool has a different
// opinion about what it does with an assertion it does not understand. A bind
// keeps the two bodies of code physically separate while still giving the
// assertions full visibility of internal signals -- lwStallD included, which
// is not a port.
//
// WHAT THESE ARE FOR
// The scoreboard checks architectural results: did the right value land in
// the right register. It cannot see *why* a result was right, so a forwarding
// mux that picks the correct value by luck, or a stall that is one cycle
// longer than necessary, passes the scoreboard silently. These assertions
// check the microarchitectural intent directly, every cycle, whether or not
// the retiring instruction happened to expose it.
//
// This is the layer DESIGN_GUIDE.md Section 10 shows was missing: both RTL
// bugs found there were forwarding/flush bugs that a passing directed test
// hid for weeks. a_fwd_mem_priority below is precisely the property whose
// violation was the distance-3 RAW bug.
//
// NOTE ON LICENSING: concurrent assertions run under Questa FSE. Covergroups
// do not (see rv32i_coverage.svh). Assertions were free; coverage was not.
// =============================================================================

module hazard_sva (
    input logic       clk,
    input logic       reset,

    input logic       RegWriteM,
    input logic       RegWriteW,
    input logic [4:0] RdM,
    input logic [4:0] RdW,
    input logic [4:0] Rs1E,
    input logic [4:0] Rs2E,
    input logic [1:0] SelectAE,
    input logic [1:0] SelectBE,

    input logic [4:0] RdE,
    input logic       IsLoadE,
    input logic       lwStallD,
    input logic [31:0] InstrD,   // to prove a redirect beats an interlock
    input logic       StallF,
    input logic       StallD,
    input logic       FlushE,
    input logic       FlushD,
    input logic       FlushM,

    input logic       PCSrcE,
    input logic       JumpD,
    input logic       EnterDebug,
    input logic       ExitDebug,
    input logic       trap_en,
    input logic       mret_enE
);

  import rv32i_pkg::*;

  default clocking cb @(posedge clk); endclocking
  default disable iff (reset);

  // ---------------------------------------------------------------------------
  // Forwarding correctness
  // ---------------------------------------------------------------------------

  // A forward from MEM must only happen when MEM really is writing that exact
  // register, and never for x0. Forwarding a stale RdM, or forwarding x0
  // (which must always read as zero), are both silent data-corruption bugs.
  property p_fwd_mem_legal(sel, rs);
    sel == FWD_MEM |-> RegWriteM && (RdM == rs) && (rs != 5'd0);
  endproperty
  a_fwd_mem_legal_a: assert property (p_fwd_mem_legal(SelectAE, Rs1E));
  a_fwd_mem_legal_b: assert property (p_fwd_mem_legal(SelectBE, Rs2E));

  property p_fwd_wb_legal(sel, rs);
    sel == FWD_WB |-> RegWriteW && (RdW == rs) && (rs != 5'd0);
  endproperty
  a_fwd_wb_legal_a: assert property (p_fwd_wb_legal(SelectAE, Rs1E));
  a_fwd_wb_legal_b: assert property (p_fwd_wb_legal(SelectBE, Rs2E));

  // THE distance bug, as a property. When BOTH MEM and WB are writing the same
  // register the operand needs, MEM is the younger value and must win.
  // Selecting WB here returns a value that is one instruction stale -- which is
  // exactly the class of failure DESIGN_GUIDE.md Section 10 records as a real
  // bug that survived every static review.
  property p_fwd_mem_priority(sel, rs);
    (rs != 5'd0) && RegWriteM && (RdM == rs) && RegWriteW && (RdW == rs)
      |-> sel == FWD_MEM;
  endproperty
  a_fwd_mem_priority_a: assert property (p_fwd_mem_priority(SelectAE, Rs1E));
  a_fwd_mem_priority_b: assert property (p_fwd_mem_priority(SelectBE, Rs2E));

  // If nothing in flight is writing the register, the operand must come from
  // the register file. A spurious forward is as wrong as a missing one.
  property p_no_spurious_fwd(sel, rs);
    !( (RegWriteM && (RdM == rs) && (rs != 5'd0)) ||
       (RegWriteW && (RdW == rs) && (rs != 5'd0)) )
      |-> sel == FWD_NONE;
  endproperty
  a_no_spurious_fwd_a: assert property (p_no_spurious_fwd(SelectAE, Rs1E));
  a_no_spurious_fwd_b: assert property (p_no_spurious_fwd(SelectBE, Rs2E));

  // x0 is architecturally hardwired to zero, so it can never be forwarded.
  a_no_fwd_x0_a: assert property ((Rs1E == 5'd0) |-> SelectAE == FWD_NONE);
  a_no_fwd_x0_b: assert property ((Rs2E == 5'd0) |-> SelectBE == FWD_NONE);

  // ---------------------------------------------------------------------------
  // Load-use interlock
  // ---------------------------------------------------------------------------

  // The one hazard forwarding cannot fix: a load's data is still in memory when
  // the next instruction needs it, so the pipeline must stall. Whenever the
  // interlock fires it must stall fetch and decode AND bubble execute -- doing
  // only some of those is a half-stall, which corrupts state rather than
  // delaying it.
  a_lwstall_effect: assert property (lwStallD |-> StallF && StallD && FlushE);

  // A stall must have a reason. StallF/StallD exist only to serve the load-use
  // interlock in this design, so either implies it.
  a_stall_has_cause: assert property ((StallF || StallD) |-> lwStallD);

  // Stall and flush of the same stage look contradictory -- one says "hold
  // what you have", the other "replace it with a bubble" -- and the first
  // version of this file asserted they were mutually exclusive:
  //
  //     a_no_stall_flush_conflict: assert property (!(StallD && FlushD));
  //
  // That was wrong, and it fired 11 times on the first run. The two CAN
  // legitimately coincide: a trap or a resolved taken branch redirects the PC
  // in the same cycle a load-use interlock is holding Decode. Nothing forbids
  // that, and forbidding it would be a constraint on the stimulus rather than
  // a property of the design.
  //
  // What the design actually guarantees is a PRIORITY: datapath.sv's IF/ID
  // register tests FlushD before StallD, so a redirect always wins over an
  // interlock -- which is the only correct choice, since the stalled
  // instruction is on the wrong path and must not be preserved. That is the
  // real property, and it is the one worth checking.
  a_flush_beats_stall: assert property (
      (StallD && FlushD) |=> (InstrD == NOP_INSTR));

  // ---------------------------------------------------------------------------
  // Redirect / flush
  // ---------------------------------------------------------------------------

  // Every FlushD must be caused by something that actually redirects the PC.
  // An unexplained flush silently discards a real instruction.
  a_flushd_has_cause: assert property (
      FlushD |-> (PCSrcE || JumpD || EnterDebug || ExitDebug || trap_en || mret_enE));

  a_flushe_has_cause: assert property (
      FlushE |-> (PCSrcE || lwStallD || EnterDebug || ExitDebug || trap_en || mret_enE));

  // A taken branch resolves in EX, so the two instructions behind it are on the
  // wrong path and both must go.
  a_branch_flushes_both: assert property (PCSrcE |-> FlushD && FlushE);

  // A trap must flush the pipeline stages behind it, otherwise wrong-path
  // instructions retire *after* the trap was taken.
  a_trap_flushes: assert property (trap_en |-> FlushD && FlushE);

  // ---------------------------------------------------------------------------
  // Coverage of the interesting conditions, as cover properties. These are NOT
  // checks -- they prove the assertions above were actually exercised rather
  // than passing vacuously. An assertion that never sees its antecedent is a
  // comment, and cover directives are how you tell the difference.
  // ---------------------------------------------------------------------------
  c_fwd_mem_a:       cover property (SelectAE == FWD_MEM);
  c_fwd_wb_a:        cover property (SelectAE == FWD_WB);
  c_fwd_mem_b:       cover property (SelectBE == FWD_MEM);
  c_fwd_wb_b:        cover property (SelectBE == FWD_WB);
  c_fwd_both_stages: cover property (
      (Rs1E != 5'd0) && RegWriteM && (RdM == Rs1E) && RegWriteW && (RdW == Rs1E));
  c_lwstall:         cover property (lwStallD);
  c_branch_taken:    cover property (PCSrcE);
  c_trap:            cover property (trap_en);
  c_lwstall_branch:  cover property (lwStallD && PCSrcE);
  // The coincidence that broke the first version of a_flush_beats_stall.
  // Covering it proves the priority rule is actually exercised rather than
  // asserted about a case that never happens.
  c_stall_and_flush: cover property (StallD && FlushD);

endmodule
