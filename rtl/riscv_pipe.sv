// =============================================================================
// riscv_pipe.sv
//
// Top-level pipelined core: wires controller.sv (D-stage decode),
// hazard_unit.sv (forwarding/stall/flush), datapath.sv (the pipeline,
// which now also owns csr_file.sv internally), debug_fsm.sv (unchanged),
// and retire_if.sv.
//
// EXTENDED (CSR/trap/interrupt milestone): one new port, mtip_i (the
// timer-pending signal from clint.sv, threaded in from top.sv), passed
// straight through to datapath.sv. Two new internal wires, trap_en and
// mret_enE, now flow datapath.sv -> hazard_unit.sv (for FlushD/E/M) --
// the same shape as the existing PCSrcE/JumpD wiring for a mispredicted
// branch.
// =============================================================================

import rv32i_pkg::*;

module riscv_pipe (
    input  logic        clk,
    input  logic        reset,
    output logic [31:0] PC,
    input  logic [31:0] Instr,
    output logic        MemWrite,
    output logic [31:0] ALUResult,
    output logic [31:0] WriteData,
    input  logic [31:0] ReadData,
    output logic [2:0]  MemFunct3,
    input  logic        mtip_i,
    // Debug interface
    input  logic        debug_req_i,
    input  logic [31:0] dm_halt_addr_i,
    input  logic [31:0] dm_exception_addr_i,
    output logic        debug_halted_o
);

  // ---- controller <-> datapath ----
  logic [31:0]  InstrD;
  id_ex_ctrl_t  ctrlD;
  logic [2:0]   ImmSrcD;
  logic         JumpD;
  logic         Rs1UsedD, Rs2UsedD;

  controller ctrl(.op        (InstrD[6:0]),
                  .funct3    (InstrD[14:12]),
                  .funct7b5  (InstrD[30]),
                  .Instr     (InstrD[31:20]),
                  .ctrlD     (ctrlD),
                  .ImmSrc    (ImmSrcD),
                  .Jump      (JumpD),
                  .Rs1UsedD  (Rs1UsedD),
                  .Rs2UsedD  (Rs2UsedD));

  // ---- hazard_unit <-> datapath ----
  logic [1:0] SelectAE, SelectBE;
  logic       StallF, StallD, FlushD, FlushE, FlushM;
  logic [4:0] Rs1D, Rs2D, Rs1E, Rs2E, RdE, RdM, RdW;
  logic       IsLoadE, RegWriteM, RegWriteW, PCSrcE, JumpD_out;
  logic       trap_en, mret_enE;

  // Declared here (ahead of hazard_unit's instantiation below, which
  // references enter_debug) rather than down by debug_fsm's own
  // instantiation -- SystemVerilog module scoping makes either position
  // legal, but slang (unlike Icarus Verilog) requires textual
  // declare-before-use ordering; same fix as ResultW in datapath.sv.
  logic        debug_mode_o, enter_debug, exit_debug;

  hazard_unit hu(.RegWriteM   (RegWriteM),
                 .RegWriteW   (RegWriteW),
                 .RdM         (RdM),
                 .RdW         (RdW),
                 .Rs1E        (Rs1E),
                 .Rs2E        (Rs2E),
                 .SelectAE    (SelectAE),
                 .SelectBE    (SelectBE),
                 .RdE         (RdE),
                 .Rs1D        (Rs1D),
                 .Rs2D        (Rs2D),
                 .Rs1UsedD    (Rs1UsedD),
                 .Rs2UsedD    (Rs2UsedD),
                 .IsLoadE     (IsLoadE),
                 .StallF      (StallF),
                 .StallD      (StallD),
                 .FlushE      (FlushE),
                 .PCSrcE      (PCSrcE),
                 .JumpD       (JumpD_out),
                 .EnterDebug  (enter_debug),
                 .ExitDebug   (exit_debug),
                 .trap_en     (trap_en),
                 .mret_enE    (mret_enE),
                 .FlushD      (FlushD),
                 .FlushM      (FlushM));

  // ---- debug_fsm (fed EX-stage signals; see debug_fsm.sv's header for its
  //      own style-retrofit note -- naming/typing only, no behavior change) ----
  // (debug_mode_o/enter_debug/exit_debug declared above, ahead of hazard_unit)
  logic [31:0] dpc, dcsr, dscratch0, dscratch1;
  logic [31:0] PCE;
  logic        is_ebreakE, is_dretE;

  debug_fsm debug_fsm_inst(.clk                 (clk),
                           .reset               (reset),
                           .debug_req_i         (debug_req_i),
                           .dm_halt_addr_i      (dm_halt_addr_i),
                           .dm_exception_addr_i (dm_exception_addr_i),
                           .is_ebreak           (is_ebreakE),
                           .is_dret             (is_dretE),
                           .pc                  (PCE),
                           .debug_halted_o      (debug_halted_o),
                           .debug_mode_o        (debug_mode_o),
                           .enter_debug         (enter_debug),
                           .exit_debug          (exit_debug),
                           .dpc                 (dpc),
                           .dcsr                (dcsr),
                           .dscratch0           (dscratch0),
                           .dscratch1           (dscratch1));

  // ---- retirement interface, for a future UVM monitor ----
  retire_if retire(.clk(clk), .reset(reset));

  // ---- datapath ----
  datapath dp(.clk           (clk), .reset(reset),
             .ctrlD_c       (ctrlD),
             .JumpD_c       (JumpD),
             .ImmSrcD_c     (ImmSrcD),
             .InstrD        (InstrD),
             .SelectAE      (SelectAE), .SelectBE(SelectBE),
             .StallF        (StallF), .StallD(StallD),
             .FlushD        (FlushD), .FlushE(FlushE), .FlushM(FlushM),
             .Rs1D          (Rs1D), .Rs2D(Rs2D),
             .Rs1E          (Rs1E), .Rs2E(Rs2E), .RdE(RdE),
             .IsLoadE       (IsLoadE),
             .RdM           (RdM), .RdW(RdW),
             .RegWriteM     (RegWriteM), .RegWriteW(RegWriteW),
             .PCSrcE        (PCSrcE),
             .JumpD         (JumpD_out),
             .trap_en       (trap_en),
             .mret_enE      (mret_enE),
             .EnterDebug    (enter_debug), .ExitDebug(exit_debug),
             .dm_halt_addr_i(dm_halt_addr_i), .dpc(dpc),
             .PCE           (PCE),
             .is_ebreakE    (is_ebreakE), .is_dretE(is_dretE),
             .InstrF_in     (Instr),
             .PCF           (PC),
             .ALUResultM    (ALUResult), .WriteDataM(WriteData),
             .MemFunct3M    (MemFunct3),
             .ReadDataM     (ReadData),
             .MemWriteM     (MemWrite),
             .mtip_i        (mtip_i),
             .InstrW        (retire.instr),
             .PCW           (retire.pc),
             .RdW_retire    (retire.rd),
             .ResultW_retire(retire.wdata),
             .RegWriteW_retire(retire.regwrite_valid),
             .ValidW_retire (retire.retire_valid));

endmodule
