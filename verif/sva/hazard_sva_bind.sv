// =============================================================================
// verif/sva/hazard_sva_bind.sv
//
// Binds hazard_sva into every riscv_pipe instance. Compilation-unit scope, so
// it needs -mfcu (see run_uvm.sh's note on the same requirement for
// mem_backdoor_bind.sv) -- without a shared compilation unit Questa warns the
// bind may not elaborate, and an assertion module that silently does not exist
// is worse than no assertions, because the run still looks clean.
//
// BOUND INTO riscv_pipe, NOT hazard_unit, and the reason is instructive.
// hazard_unit is purely combinational: no clk, no reset, nothing to sample on.
// The first version of this file bound into hazard_unit and reached upward for
// `datapath.clk`, which failed to elaborate --
//
//   (vopt-7063) Failed to find 'datapath' in hierarchical name 'datapath.clk'
//   Region: tb_uvm_top.dut.rvpipe.hu
//
// -- because hazard_unit is instantiated by riscv_pipe, not by datapath, and
// upward references resolve through instance paths rather than module names.
// Binding into the parent is the better construction anyway: clk and reset are
// local there, every hazard signal is already a named wire in that scope, and
// the one signal that is private to hazard_unit -- lwStallD -- is reachable by
// an ordinary downward reference through the instance.
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
