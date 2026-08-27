// =============================================================================
// tb_pipe.sv
//
// Three self-checking testbenches, all valid simulation roots -- select one
// with iverilog's -s flag or Verilator's --top-module:
//
//   tb_pipe_hazard : forwarding, load-use stall, store-data forwarding,
//     branch/jal flush, x0 as a forward source. Diffs all 32 registers and
//     2 dmem words against golden_vals_pipe.svh.
//
//   tb_pipe_debug : asserts debug_req_i mid-loop, checks debug_halted_o and
//     PC == dm_halt_addr_i, then confirms forward progress after dret.
//
//   tb_pipe_csr : CSR read/write, ecall, illegal-instruction, misaligned
//     load and store traps, UART TX, and a timer interrupt. Diffs all 32
//     registers against golden_vals_pipe_csr.svh and independently checks
//     the transmitted UART byte stream.
//
// All three compare architectural end state, not cycle timing. The golden
// .svh files come from verif/spike/regen.sh and are checked in, so running
// these needs no ISS.
//
// Prefer ./run_sim.sh, which runs all three under both simulators. Add
// -DDUMP_VCD for build/wave_*.vcd.
// =============================================================================

module tb_pipe_hazard;
  logic clk = 0, reset;
  logic [31:0] dm_halt_addr_i = 32'h0;
  logic debug_halted_o;
  logic [31:0] WriteData, DataAdr;
  logic MemWrite;

  top #(.TestFile("riscvtest_pipe.txt")) dut(
      .clk(clk), .reset(reset),
      .debug_req_i(1'b0),
      .dm_halt_addr_i(dm_halt_addr_i),
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
  // The register file has no reset, which is correct hardware -- the spec
  // defines no reset values for x1-x31. Icarus then reads never-written
  // registers as X and Verilator reads 0. Spike starts from all-zero, so the
  // DUT is forced to the same known state here rather than in the RTL.
  initial
    for (int i = 0; i < 32; i++) dut.rvpipe.dp.rf.rf[i] = 32'h0;

  // Timeout watchdog. An independent initial block rather than a fork/join_any
  // with `disable`, which Verilator does not support.
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
    #1;  // Let this edge's nonblocking regfile write settle: the last
         // instruction before EBREAK commits on exactly this edge.

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
  logic debug_halted_o;
  logic [31:0] WriteData, DataAdr;
  logic MemWrite;
  int   errors = 0;

  top #(.TestFile("riscvtest_pipe_debug.txt")) dut(
      .clk(clk), .reset(reset),
      .debug_req_i(debug_req_i),
      .dm_halt_addr_i(dm_halt_addr_i),
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

    // Same simulation step as the halt edge, not a cycle later: the debug ROM
    // is a bare dret at 0x0C, so the halted window is only a few cycles wide
    // before it auto-resumes. That window is too narrow to also assert "x1
    // frozen while halted" without racing the resume -- a real Debug Module
    // would hold haltreq and make that check safe to add.
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
  // End-state comparison only, which matters most for the timer interrupt:
  // clint.sv increments mtime once per clock, while Spike's CLINT model
  // increments once per retired instruction. The two reach a given mtime after
  // different amounts of program progress, so "the interrupt fired on cycle N"
  // is not a comparable claim; where the handler leaves the machine is.
  // See verif/spike/rvproj_devices.cc.
  // ===========================================================================
  logic clk = 0, reset;
  logic [31:0] dm_halt_addr_i = 32'h0;
  logic debug_halted_o;
  logic [31:0] WriteData, DataAdr;
  logic MemWrite;
  logic [7:0] uart_tx_byte_o;
  logic uart_tx_valid_o;

  top #(.TestFile("riscvtest_pipe_csr.txt")) dut(
      .clk(clk), .reset(reset),
      .debug_req_i(1'b0),
      .dm_halt_addr_i(dm_halt_addr_i),
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
