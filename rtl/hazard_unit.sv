// =============================================================================
// hazard_unit.sv
//
// Central hazard-detection unit for the 5-stage RV32I pipeline. Purely
// combinational: computes EX-stage operand forwarding, the load-use stall,
// and every pipeline-register flush condition from state exposed by
// datapath.sv and debug_fsm.sv. Instantiated alongside those modules (not
// nested inside them) in riscv_pipe.sv, which wires its outputs back into
// datapath.sv's forwarding muxes and pipeline-register load conditions.
//
// ---- Forwarding ----
// ForwardAE/ForwardBE steer the EX-stage ALU operands away from a stale
// register-file read toward the MEM- or WB-stage result when an in-flight
// producer matches. MEM is checked before WB in priority so that three
// back-to-back dependent instructions correctly forward from the more
// recent producer. The FWD_MEM/FWD_WB encoding must match rv32i_pkg.sv and
// the forwardamux/forwardbmux port order in datapath.sv.
//
// ---- Load-use stall ----
// lwStallD detects a load in EX whose destination register is read by the
// D-stage instruction -- a hazard forwarding cannot cover, since the loaded
// value does not exist until MEM. Detection is gated by Rs1UsedD/Rs2UsedD
// (from controller.sv) so that JAL/LUI/AUIPC and the *I-immediate CSR ops,
// which reuse the rs1/rs2 bit positions as immediate bits, cannot trigger a
// spurious stall.
//
// ---- Flushes ----
// FlushD  (IF/ID  -> NOP)   : PCSrcE | JumpD | EnterDebug | ExitDebug | trap_en | mret_enE
// FlushE  (ID/EX  -> bubble): PCSrcE | lwStallD | EnterDebug | ExitDebug | trap_en | mret_enE
// FlushM  (EX/MEM -> bubble): EnterDebug | trap_en
//
// FlushD/FlushE fire on every event that redirects the PC away from
// sequential fetch: a taken branch/jalr (PCSrcE), a jal resolved in ID
// (JumpD), debug-mode entry or exit (EnterDebug/ExitDebug), a trap
// (trap_en), or an mret (mret_enE). In each case, whatever was fetched
// under the sequential-PC assumption is now wrong-path relative to the new
// target and must be squashed before it can retire.
//
// FlushM fires only on EnterDebug or trap_en, the two cases where the
// EX-stage instruction itself must be prevented from committing its own
// RegWrite/MemWrite: a trapping instruction because it excepted or is being
// interrupted, a halting instruction because dpc = PCE means it re-executes
// for real after resume. mret and dret are pure control transfers with no
// state write of their own to suppress, so they are deliberately excluded
// from FlushM. See docs/DESIGN_GUIDE.md Section 10 for the verification
// history behind this flush set.
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
