// =============================================================================
// tb_pipe.sv
//
// Three independent self-checking testbenches in this file -- compile
// once, select which one to run with iverilog's -s flag (all three are
// valid simulation roots, so the tool needs to be told which):
//
//   tb_pipe_hazard : runs riscvtest_pipe.txt (forwarding, load-use
//     stall, store-data forwarding, branch/jal flush, x0-as-forward-
//     source) to completion, diffs all 32 registers + 2 dmem words
//     against golden_vals_pipe.svh. Architectural end-state must match
//     regardless of the pipeline's internal timing, which is the level
//     every directed test here compares at.
//
//   tb_pipe_debug : runs riscvtest_pipe_debug.txt (a 2-instruction
//     increment loop) and a "debug ROM" dret stub at 0x0C. Asserts
//     debug_req_i mid-loop, confirms debug_halted_o and
//     PC == dm_halt_addr_i, lets the dret resume, confirms forward
//     progress. See hazard_unit.sv's header comment for why the resume
//     point is dpc = PCE specifically.
//
//   tb_pipe_csr : runs riscvtest_pipe_csr.hex (program_csr.py) -- CSR
//     read/write semantics, an ecall trap, an illegal-instruction trap,
//     a misaligned-load trap, a misaligned-store trap, UART TX writes,
//     and a machine-timer interrupt, in that order -- to completion,
//     diffs all 32 registers against golden_vals_pipe_csr.svh, and
//     independently monitors top.sv's uart_tx_byte_o/uart_tx_valid_o to
//     check the transmitted byte stream directly.
//
// The golden .svh files are generated from Spike by verif/spike/regen.sh
// and are checked in, so running these needs no ISS. See
// verif/spike/README.md.
//
// Prefer ./run_sim.sh, which runs all three under both simulators. The
// explicit command lines below are what it does. Every testbench needs the
// full file list including csr_file/clint/uart_tx/mem_bus, because mem_bus.sv
// sits between top.sv and dmem.sv unconditionally -- even tb_pipe_hazard and
// tb_pipe_debug, which never touch a CSR:
//   iverilog -g2012 -o sim_hazard -s tb_pipe_hazard rv32i_pkg.sv cells.sv \
//       regfile.sv alu.sv extend.sv retire_if.sv controller.sv \
//       hazard_unit.sv csr_file.sv datapath.sv debug_fsm.sv riscv_pipe.sv \
//       dmem.sv clint.sv uart_tx.sv mem_bus.sv imem.sv top.sv tb_pipe.sv
//   vvp sim_hazard
//
//   iverilog -g2012 -o sim_debug -s tb_pipe_debug rv32i_pkg.sv cells.sv \
//       regfile.sv alu.sv extend.sv retire_if.sv controller.sv \
//       hazard_unit.sv csr_file.sv datapath.sv debug_fsm.sv riscv_pipe.sv \
//       dmem.sv clint.sv uart_tx.sv mem_bus.sv imem.sv top.sv tb_pipe.sv
//   vvp sim_debug
//
//   iverilog -g2012 -o sim_csr -s tb_pipe_csr rv32i_pkg.sv cells.sv \
//       regfile.sv alu.sv extend.sv retire_if.sv controller.sv \
//       hazard_unit.sv csr_file.sv datapath.sv debug_fsm.sv riscv_pipe.sv \
//       dmem.sv clint.sv uart_tx.sv mem_bus.sv imem.sv top.sv tb_pipe.sv
//   vvp sim_csr
//
// Waveforms: add `-DDUMP_VCD` to any of the iverilog compile lines above to
// make that testbench write build/wave_{hazard,debug,csr}.vcd, openable in
// GTKWave. Off by default so the everyday pass/fail regression (run_sim.sh)
// doesn't pay the dump-file cost.
// =============================================================================

module tb_pipe_hazard;
  logic clk = 0, reset;
  logic [31:0] dm_halt_addr_i = 32'h0, dm_exception_addr_i = 32'h0;
  logic debug_halted_o;
  logic [31:0] WriteData, DataAdr;
  logic MemWrite;

  top #(.TestFile("riscvtest_pipe.txt")) dut(
      .clk(clk), .reset(reset),
      .debug_req_i(1'b0),
      .dm_halt_addr_i(dm_halt_addr_i), .dm_exception_addr_i(dm_exception_addr_i),
      .debug_halted_o(debug_halted_o),
      .WriteData(WriteData), .DataAdr(DataAdr), .MemWrite(MemWrite));

  always #5 clk = ~clk;

`ifdef DUMP_VCD
  initial begin
    $dumpfile("build/wave_hazard.vcd");
    $dumpvars(0, tb_pipe_hazard);
  end
`endif

  // ---- power-on architectural state ----
  // The register file is a RAM with no reset, which is correct hardware: the
  // RISC-V spec does not define reset values for x1-x31, and real cores do
  // not spend 31 registers' worth of reset logic on it. The consequence for
  // verification is that a 4-state simulator (Icarus) reads every
  // never-written register as X, while a 2-state one (Verilator) reads 0 --
  // so the two disagree on exactly the registers this test expects to still
  // be 0, and neither answer means anything on its own.
  //
  // The ISS golden model starts from all-zero, so the DUT is forced to that
  // same known architectural start state here. This is a testbench concern,
  // not an RTL one -- putting a reset in regfile.sv would be inventing
  // hardware to satisfy a simulator.
  initial
    for (int i = 0; i < 32; i++) dut.rvpipe.dp.rf.rf[i] = 32'h0;

  // Timeout watchdog. This was originally a fork/join_any whose second branch
  // did `disable timeout` -- Verilator does not support disabling a named
  // block from a sibling fork branch, so it's an independent initial block
  // instead. Same behaviour, and portable across Icarus/Verilator/Riviera.
  bit halt_seen = 0;
  initial begin : watchdog
    repeat (200) @(posedge clk);
    if (!halt_seen) begin
      $display("FAIL: never reached debug_halted_o (ebreak should have halted by now)");
      $finish;
    end
  end

  logic [31:0] expect_reg[0:31];
  logic [31:0] expect_mem_w0, expect_mem_w1;

  initial begin
`include "golden_vals_pipe.svh"

    reset = 1;
    repeat (2) @(posedge clk);
    reset = 0;

    @(posedge debug_halted_o);
    halt_seen = 1;

    @(posedge clk);
    #1;  // Let this edge's nonblocking register-file write settle before
         // sampling. The last instruction before EBREAK commits on exactly
         // this edge, so reading rf[] in the active region here would miss
         // it -- which is what made x22 read 0 the first time this ran.

    begin
      int errors = 0;
      for (int i = 0; i < 32; i++) begin
        logic [31:0] actual;
        actual = dut.rvpipe.dp.rf.rf[i];
        if (i == 0) actual = 32'h0;
        if (actual !== expect_reg[i]) begin
          $display("FAIL: x%0d = %h, expected %h", i, actual, expect_reg[i]);
          errors++;
        end
      end

      begin
        logic [31:0] mem_w0, mem_w1;
        // dmem is two levels down, not one: top.sv instantiates mem_bus.sv
        // (instance 'bus'), which owns dmem.sv (instance 'dmem_inst')
        // alongside clint.sv and uart_tx.sv.
        mem_w0 = {dut.bus.dmem_inst.mem[3], dut.bus.dmem_inst.mem[2], dut.bus.dmem_inst.mem[1], dut.bus.dmem_inst.mem[0]};
        mem_w1 = {dut.bus.dmem_inst.mem[7], dut.bus.dmem_inst.mem[6], dut.bus.dmem_inst.mem[5], dut.bus.dmem_inst.mem[4]};
        if (mem_w0 !== expect_mem_w0) begin
          $display("FAIL: dmem word0 = %h, expected %h", mem_w0, expect_mem_w0);
          errors++;
        end
        if (mem_w1 !== expect_mem_w1) begin
          $display("FAIL: dmem word1 = %h, expected %h", mem_w1, expect_mem_w1);
          errors++;
        end
      end

      if (errors == 0) $display("PASS: all 32 registers + 2 dmem words match ISS golden values");
      else              $display("FAIL: %0d mismatch(es)", errors);
    end

    $finish;
  end
endmodule


module tb_pipe_debug;
  logic clk = 0, reset;
  logic debug_req_i = 0;
  logic [31:0] dm_halt_addr_i = 32'h0000000C;  // the dret stub, same address
                                                 // convention as the original
                                                 // (unmodified) tb_debug.sv
  logic [31:0] dm_exception_addr_i = 32'h0;
  logic debug_halted_o;
  logic [31:0] WriteData, DataAdr;
  logic MemWrite;
  int   errors = 0;

  top #(.TestFile("riscvtest_pipe_debug.txt")) dut(
      .clk(clk), .reset(reset),
      .debug_req_i(debug_req_i),
      .dm_halt_addr_i(dm_halt_addr_i), .dm_exception_addr_i(dm_exception_addr_i),
      .debug_halted_o(debug_halted_o),
      .WriteData(WriteData), .DataAdr(DataAdr), .MemWrite(MemWrite));

  always #5 clk = ~clk;

`ifdef DUMP_VCD
  initial begin
    $dumpfile("build/wave_debug.vcd");
    $dumpvars(0, tb_pipe_debug);
  end
`endif

  // See tb_pipe_hazard's power-on-state comment for why this is here.
  initial
    for (int i = 0; i < 32; i++) dut.rvpipe.dp.rf.rf[i] = 32'h0;

  // See tb_pipe_hazard's watchdog comment -- same rewrite, same reason.
  bit halt_seen = 0;
  initial begin : watchdog
    repeat (120) @(posedge clk);
    if (!halt_seen) begin
      $display("FAIL: debug_req_i asserted but debug_halted_o never went high");
      $finish;
    end
  end

  function automatic logic [31:0] x1();
    x1 = dut.rvpipe.dp.rf.rf[1];
  endfunction

  initial begin
    reset = 1;
    repeat (2) @(posedge clk);
    reset = 0;

    // let the loop run a few iterations so x1 is clearly nonzero and moving
    repeat (20) @(posedge clk);
    if (x1() == 0) begin
      $display("FAIL: loop never incremented x1 before halt request");
      errors++;
    end

    debug_req_i = 1;
    @(posedge debug_halted_o);
    halt_seen = 1;
    debug_req_i = 0;

    // Check PC immediately, same simulation step as the halt edge --
    // NOT a cycle later. This debug ROM is a bare `dret` at 0x0C (same
    // minimal convention as the original, unmodified tutorial test
    // program), not a real parking loop the debugger explicitly breaks
    // out of, so the halted window is only a few pipeline-depths wide
    // before it auto-resumes. That means there's no robust window to
    // also assert "x1 frozen while halted" without risking a race
    // against auto-resume -- a real Debug Module would hold haltreq
    // asserted and keep the core in a genuine parking loop, which WOULD
    // make that check safe to add. Flagging this rather than writing an
    // assertion whose pass/fail depends on exact cycle counts I can't
    // verify without a simulator.
    if (dut.rvpipe.PC !== dm_halt_addr_i) begin
      $display("FAIL: PC = %h after halt, expected dm_halt_addr_i = %h", dut.rvpipe.PC, dm_halt_addr_i);
      errors++;
    end

    // let the dret at 0x0C propagate through the pipeline and resume
    repeat (15) @(posedge clk);
    if (debug_halted_o !== 1'b0) begin
      $display("FAIL: debug_halted_o still high after dret should have resumed execution");
      errors++;
    end

    // confirm forward progress: x1 should be incrementing again
    begin
      logic [31:0] x1_after_resume;
      x1_after_resume = x1();
      repeat (20) @(posedge clk);
      if (x1() <= x1_after_resume) begin
        $display("FAIL: x1 not advancing after resume (%h -> %h)", x1_after_resume, x1());
        errors++;
      end
    end

    if (errors == 0) $display("PASS: debug halt/resume works on the pipelined core");
    else              $display("FAIL: %0d mismatch(es)", errors);

    $finish;
  end
endmodule


module tb_pipe_csr;
  // ===========================================================================
  // tb_pipe_csr
  //
  // Runs riscvtest_pipe_csr.hex (program_csr.py) -- the CSR/trap/
  // interrupt/UART directed test -- to completion and diffs all 32
  // registers against golden_vals_pipe_csr.svh, generated from Spike.
  //
  // Final architectural state only, not cycle-by-cycle timing, and that
  // matters most for the interrupt: clint.sv increments mtime once per
  // clock, while Spike has no clock and its CLINT model increments once
  // per retired instruction. The two therefore reach any given mtime after
  // different amounts of program progress, so "the interrupt fired on
  // cycle N" is not a comparable claim. Where the handler leaves the
  // machine is. See verif/spike/rvproj_devices.cc.
  //
  // Also independently monitors top.sv's uart_tx_byte_o/uart_tx_valid_o
  // pulses and checks the transmitted byte sequence directly -- a second,
  // more direct check than relying solely on x26's readback value.
  // ===========================================================================
  logic clk = 0, reset;
  logic [31:0] dm_halt_addr_i = 32'h0, dm_exception_addr_i = 32'h0;
  logic debug_halted_o;
  logic [31:0] WriteData, DataAdr;
  logic MemWrite;
  logic [7:0] uart_tx_byte_o;
  logic uart_tx_valid_o;

  top #(.TestFile("riscvtest_pipe_csr.txt")) dut(
      .clk(clk), .reset(reset),
      .debug_req_i(1'b0),
      .dm_halt_addr_i(dm_halt_addr_i), .dm_exception_addr_i(dm_exception_addr_i),
      .debug_halted_o(debug_halted_o),
      .WriteData(WriteData), .DataAdr(DataAdr), .MemWrite(MemWrite),
      .uart_tx_byte_o(uart_tx_byte_o), .uart_tx_valid_o(uart_tx_valid_o));

  always #5 clk = ~clk;

`ifdef DUMP_VCD
  initial begin
    $dumpfile("build/wave_csr.vcd");
    $dumpvars(0, tb_pipe_csr);
  end
`endif

  // See tb_pipe_hazard's power-on-state comment for why this is here.
  initial
    for (int i = 0; i < 32; i++) dut.rvpipe.dp.rf.rf[i] = 32'h0;

  // See tb_pipe_hazard's watchdog comment -- same rewrite, same reason.
  bit halt_seen = 0;
  initial begin : watchdog
    repeat (400) @(posedge clk);
    if (!halt_seen) begin
      $display("FAIL: never reached debug_halted_o (ebreak should have halted by now)");
      $finish;
    end
  end

  logic [31:0] expect_reg[0:31];

  // ---- independent UART monitor ----
  logic [7:0] uart_captured[$];
  always @(posedge clk)
    if (uart_tx_valid_o) uart_captured.push_back(uart_tx_byte_o);

  initial begin
`include "golden_vals_pipe_csr.svh"

    reset = 1;
    repeat (2) @(posedge clk);
    reset = 0;

    @(posedge debug_halted_o);
    halt_seen = 1;

    @(posedge clk);
    #1;  // see tb_pipe_hazard -- same nonblocking-write settling requirement

    begin
      int errors = 0;
      for (int i = 0; i < 32; i++) begin
        logic [31:0] actual;
        actual = dut.rvpipe.dp.rf.rf[i];
        if (i == 0) actual = 32'h0;
        if (actual !== expect_reg[i]) begin
          $display("FAIL: x%0d = %h, expected %h", i, actual, expect_reg[i]);
          errors++;
        end
      end

      if (uart_captured.size() != 2 || uart_captured[0] !== 8'h41 || uart_captured[1] !== 8'h42) begin
        // Printed element-by-element rather than with %p: Icarus 12 rejects
        // %p on a queue outright ("$display does not support argument type"),
        // which aborted the whole run before this check could even report.
        $write("FAIL: UART TX stream = [");
        for (int k = 0; k < uart_captured.size(); k++) $write(" %02h", uart_captured[k]);
        $display(" ], expected [ 41 42 ]");
        errors++;
      end

      if (errors == 0) $display("PASS: all 32 registers match ISS golden values (CSR/trap/interrupt/UART), UART TX stream correct");
      else              $display("FAIL: %0d mismatch(es)", errors);
    end

    $finish;
  end
endmodule
