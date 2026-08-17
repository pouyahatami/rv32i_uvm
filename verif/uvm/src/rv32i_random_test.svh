class rv32i_random_test extends uvm_test;
  `uvm_component_utils(rv32i_random_test)

  // Generous: the default 40-instruction stream retires in a few hundred
  // cycles including the register-zeroing and memory-zeroing prologues, so
  // this only fires on a genuine hang, never on a slow but healthy run.
  localparam int unsigned WATCHDOG_CYCLES = 100000;

  rv32i_env env;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = rv32i_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    rv32i_random_seq seq;
    bit              timed_out;

    phase.raise_objection(this);

    // Program length is not a runtime plusarg: the program and its Spike
    // reference trace are generated together by verif/spike/gen_stream.py
    // --num-instr, and changing one without the other would give a
    // scoreboard checking against the wrong program. +STREAM=<file> and
    // +TRACE=<file> select which generated pair to use.
    seq = rv32i_random_seq::type_id::create("seq");
    seq.start(env.agt.sqr);

    // Wait for the scoreboard to see the sentinel retire (or to give up on
    // a divergence), plus a small margin for the pipeline to drain. The
    // watchdog covers the case where the core never reaches the sentinel at
    // all: without it a fetch into unloaded memory or a lost retirement
    // hangs the simulation with no diagnosis, which is the least useful
    // failure mode a regression can have.
    timed_out = 1'b1;
    fork
      begin
        @(env.sb.done);
        timed_out = 1'b0;
      end
      repeat (WATCHDOG_CYCLES) @(posedge env.agt.drv.vif.clk);
    join_any
    disable fork;

    repeat (10) @(posedge env.agt.drv.vif.clk);

    if (timed_out)
      `uvm_error("TIMEOUT",
        $sformatf({"no sentinel after %0d cycles -- the core retired %0d of %0d expected ",
                   "instructions and then stopped making progress"},
                  WATCHDOG_CYCLES, env.sb.num_checked, env.sb.reference_count()))

    `uvm_info("TEST",
      $sformatf("DONE -- %0d of %0d retirements checked, %0d mismatches",
                env.sb.num_checked, env.sb.reference_count(), env.sb.num_mismatches), UVM_LOW)

    if (env.sb.num_mismatches == 0 && !timed_out)
      `uvm_info("TEST", "*** UVM TEST PASSED ***", UVM_NONE)
    else
      `uvm_error("TEST",
        $sformatf("*** UVM TEST FAILED -- %0d mismatches ***", env.sb.num_mismatches))

    phase.drop_objection(this);
  endtask

  // One machine-readable verdict line, emitted after every other component
  // has reported. run_questa.do greps the log for this to set its exit code,
  // because the report server's error count is a SystemVerilog object and
  // cannot be queried from the simulator's TCL shell. Counting UVM_ERROR and
  // UVM_FATAL rather than this test's own num_mismatches means a failure
  // raised anywhere in the environment -- a missing stream file, a config_db
  // miss in a driver build_phase -- also fails the run, instead of being
  // reported and then quietly passing.
  function void report_phase(uvm_phase phase);
    uvm_report_server svr;
    int unsigned      n_err;
    super.report_phase(phase);

    svr   = uvm_report_server::get_server();
    n_err = svr.get_severity_count(UVM_ERROR) + svr.get_severity_count(UVM_FATAL);

    $display("RV32I_UVM_VERDICT: %s", (n_err == 0) ? "PASS" : "FAIL");
  endfunction
endclass
