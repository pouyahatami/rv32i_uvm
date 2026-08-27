// =============================================================================
// hazard_unit.sv
//
// Combinational hazard resolution for the 5-stage pipeline: EX-stage operand
// forwarding, the load-use interlock, and the pipeline-register flushes.
// Instantiated in riscv_pipe.sv alongside datapath.sv, which consumes these
// outputs at its forwarding muxes and pipeline-register load conditions.
//
// docs/DESIGN_GUIDE.md section 4 derives each condition.
// =============================================================================

import rv32i_pkg::*;

module hazard_unit (
    input  logic       RegWriteM,
    input  logic       RegWriteW,
    input  logic [4:0] RdM,
    input  logic [4:0] RdW,
    input  logic [4:0] Rs1E,
    input  logic [4:0] Rs2E,
    output logic [1:0] SelectAE,
    output logic [1:0] SelectBE,

    input  logic [4:0] RdE,
    input  logic [4:0] Rs1D,
    input  logic [4:0] Rs2D,
    input  logic       Rs1UsedD,     // does D-stage instr actually read rs1?
    input  logic       Rs2UsedD,     // does D-stage instr actually read rs2?
    input  logic       IsLoadE,      // 1 when the EX-stage instruction is a load
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

  // FWD_* encoding must match the mux3 port order in datapath.sv.
  // MEM is tested before WB so the nearer producer wins.
  always_comb begin
    if      (RegWriteM && (RdM != 0) && (RdM == Rs1E)) SelectAE = FWD_MEM;
    else if (RegWriteW && (RdW != 0) && (RdW == Rs1E)) SelectAE = FWD_WB;
    else                                                 SelectAE = FWD_NONE;

    if      (RegWriteM && (RdM != 0) && (RdM == Rs2E)) SelectBE = FWD_MEM;
    else if (RegWriteW && (RdW != 0) && (RdW == Rs2E)) SelectBE = FWD_WB;
    else                                                 SelectBE = FWD_NONE;
  end

  // Rs*UsedD gates the compare: U/J-type and the CSR-immediate ops reuse the
  // rs1/rs2 bit positions as immediate bits.
  assign lwStallD = IsLoadE && (RdE != 0) &&
                    ((Rs1UsedD && (RdE == Rs1D)) || (Rs2UsedD && (RdE == Rs2D)));
  assign StallF   = lwStallD;
  assign StallD   = lwStallD;

  // FlushM suppresses the EX-stage instruction's own RegWrite/MemWrite.
  // mret and dret are excluded: neither has architectural state to suppress.
  assign FlushD = PCSrcE | JumpD | EnterDebug | ExitDebug | trap_en | mret_enE;
  assign FlushE = PCSrcE | lwStallD | EnterDebug | ExitDebug | trap_en | mret_enE;
  assign FlushM = EnterDebug | trap_en;

endmodule
