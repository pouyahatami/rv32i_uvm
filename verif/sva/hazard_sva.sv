// =============================================================================
// verif/sva/hazard_sva.sv
//
// Assertions for the hazard/forwarding unit, attached by bind (see
// hazard_sva_bind.sv) so no verification code sits in a file synthesis reads,
// while still reaching internal signals like lwStallD that are not ports.
//
// These check microarchitectural intent, which the scoreboard cannot: it sees
// only that the right value landed in the right register, so a forwarding mux
// that is correct by luck, or a stall a cycle longer than necessary, passes it
// silently. a_fwd_mem_priority below is the property the distance-3 RAW bug
// violated.
//
// Concurrent assertions run under Questa FSE; covergroups do not.
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

  // A forward from MEM only when MEM is writing that exact register, never x0.
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

  // When both MEM and WB are writing the register the operand needs, MEM is
  // the younger value and must win; WB would be one instruction stale.
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

  // The interlock must stall fetch and decode AND bubble execute. Doing only
  // some of those is a half-stall, which corrupts state rather than delaying it.
  a_lwstall_effect: assert property (lwStallD |-> StallF && StallD && FlushE);

  // StallF/StallD serve only the load-use interlock in this design.
  a_stall_has_cause: assert property ((StallF || StallD) |-> lwStallD);

  // StallD and FlushD can legitimately coincide -- a redirect landing in the
  // same cycle an interlock holds Decode -- so they are not mutually
  // exclusive. What the design guarantees is a priority: datapath.sv's IF/ID
  // register tests FlushD first, so the redirect wins and the stalled
  // wrong-path instruction is not preserved.
  a_flush_beats_stall: assert property (
      (StallD && FlushD) |=> (InstrD == NOP_INSTR));

  // ---------------------------------------------------------------------------
  // Redirect / flush
  // ---------------------------------------------------------------------------

  // An unexplained flush silently discards a real instruction.
  a_flushd_has_cause: assert property (
      FlushD |-> (PCSrcE || JumpD || EnterDebug || ExitDebug || trap_en || mret_enE));

  a_flushe_has_cause: assert property (
      FlushE |-> (PCSrcE || lwStallD || EnterDebug || ExitDebug || trap_en || mret_enE));

  // A taken branch resolves in EX, so the two instructions behind it are on the
  // wrong path and both must go.
  a_branch_flushes_both: assert property (PCSrcE |-> FlushD && FlushE);

  // Stages behind the trap must go, and the trapping instruction itself must
  // not commit -- that last part is FlushM's job.
  a_trap_flushes: assert property (trap_en |-> FlushD && FlushE && FlushM);

  // Cause -> effect for every remaining redirect source. The *_has_cause
  // assertions above point the other way and are blind to a redirect that
  // flushes nothing at all; these close the converse.
  //
  // The random stream has no trap, mret or debug traffic, so those three pass
  // vacuously under it and are non-vacuous only under the directed tests,
  // which do not bind this file. docs/VMATRIX.md, hole 1.
  a_jump_flushes:       assert property (JumpD      |-> FlushD);
  a_mret_flushes:       assert property (mret_enE   |-> FlushD && FlushE);
  a_enterdebug_flushes: assert property (EnterDebug |-> FlushD && FlushE && FlushM);
  a_exitdebug_flushes:  assert property (ExitDebug  |-> FlushD && FlushE);
  c_jump:               cover  property (JumpD);
  c_mret:               cover  property (mret_enE);
  c_enterdebug:         cover  property (EnterDebug);
  c_exitdebug:          cover  property (ExitDebug);

  // ---------------------------------------------------------------------------
  // Cover properties, not checks: they prove the assertions above saw their
  // antecedents rather than passing vacuously.
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
  // Proves a_flush_beats_stall's priority rule is exercised rather than
  // asserted about a case that never happens.
  c_stall_and_flush: cover property (StallD && FlushD);

endmodule
