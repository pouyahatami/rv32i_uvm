// =============================================================================
// verif/sva/hazard_sva_bind.sv
//
// Binds hazard_sva into every riscv_pipe instance. Compilation-unit scope, so
// it needs -mfcu, same as the memory backdoor binds; without it Questa warns
// the bind may not elaborate, and assertions that silently do not exist leave
// the run looking clean.
//
// Bound into riscv_pipe rather than hazard_unit, which is combinational and
// has no clk or reset to sample on. riscv_pipe has both as local signals,
// carries every hazard signal as a named wire, and reaches the two private
// ones by ordinary downward reference through the instance.
// =============================================================================

bind riscv_pipe hazard_sva u_hazard_sva (
    .clk       (clk),
    .reset     (reset),

    .RegWriteM (RegWriteM),
    .RegWriteW (RegWriteW),
    .RdM       (RdM),
    .RdW       (RdW),
    .Rs1E      (Rs1E),
    .Rs2E      (Rs2E),
    .SelectAE  (SelectAE),
    .SelectBE  (SelectBE),

    .RdE       (RdE),
    .IsLoadE   (IsLoadE),
    .lwStallD  (hu.lwStallD),   // private to hazard_unit -- downward reference
    .InstrD    (dp.InstrD),     // private to datapath    -- downward reference
    .StallF    (StallF),
    .StallD    (StallD),
    .FlushE    (FlushE),
    .FlushD    (FlushD),
    .FlushM    (FlushM),

    .PCSrcE    (PCSrcE),
    .JumpD     (JumpD),
    .EnterDebug(enter_debug),
    .ExitDebug (exit_debug),
    .trap_en   (trap_en),
    .mret_enE  (mret_enE)
);
