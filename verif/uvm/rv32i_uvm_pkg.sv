// =============================================================================
// verif/uvm/rv32i_uvm_pkg.sv
//
// The UVM environment: transactions, a sequence that replays a generated
// instruction stream, a backdoor-loading driver, a retirement monitor, and a
// scoreboard that lockstep-checks every real retirement against Spike.
//
// The golden model is Spike, but it is NOT called from here. There is no
// DPI-C in this environment and no C compiler is needed to run it.
// verif/spike/gen_stream.py runs Spike ahead of time and emits two text
// files, stream.hex (the program) and stream_trace.txt (the expected
// retirements); this package reads both with $fopen/$sscanf. See that
// script's docstring for why the reference is precomputed rather than live.
//
// Shape: a commit/retire interface sampled by a monitor and checked against
// a reference model, the same architecture used by the UVM-for-RISC-V
// environments this was modelled on (gopro-uvm-rtl-verification, OpenHW
// core-v-verif).
//
// Scope, stated explicitly rather than left implicit: the stream covers
// R-type ALU, I-type ALU excluding shift-immediate, LOAD, STORE, and
// forward-only BRANCH. JAL/JALR/LUI/AUIPC/SYSTEM (ECALL, CSR ops, MRET) are
// out of scope, which is a bounded extension rather than a gap that was
// missed. Excluding SYSTEM means this environment does not exercise the
// trap/interrupt/CSR machinery at all; tb_pipe_csr in rtl/tb_pipe.sv is the
// directed test covering that path.
//
// Nothing here randomizes at simulation time -- the stream is generated in
// Python. That is why the environment runs under licences that withhold
// SystemVerilog randomization, Questa Starter Edition among them. See
// RUNNING.md. Do not add a randomize() call, a covergroup, a constraint or a
// randcase without knowing you are giving that up.
// =============================================================================

package rv32i_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import rv32i_pkg::*;

  // ===========================================================================
  // rv32i_instr_txn: one instruction word to be written into imem.
  //
  //   instr   - the 32-bit instruction word.
  //   last_word - set on the final word of a program. Signals the driver to
  //               stop pulling items and release reset.
  // ===========================================================================
  // Deliberately not `rand`. The instruction word is read from stream.hex,
  // never randomized here, and a `rand` qualifier on a field nothing
  // randomizes is both misleading and a needless dependency on a
  // randomization licence feature. See this file's header.
  class rv32i_instr_txn extends uvm_sequence_item;
    bit [31:0] instr;
    bit        last_word;

    `uvm_object_utils_begin(rv32i_instr_txn)
      `uvm_field_int(instr, UVM_ALL_ON)
      `uvm_field_int(last_word, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "rv32i_instr_txn");
      super.new(name);
    endfunction
  endclass

  // ===========================================================================
  // rv32i_retire_txn: one retired instruction, as observed at writeback.
  // Emitted exactly once per instruction, gated on retire_if.sv's retire_valid.
  //
  //   pc           - PC of the retiring instruction
  //   instr        - the retiring instruction
  //   rd           - destination register, if any
  //   wdata        - value written to rd
  //   regwrite     - set if this instruction wrote a register
  //   store_valid  - set if this instruction was a store
  //   store_addr   - the address it wrote
  //   store_data   - the full 32-bit register value; only the low byte or
  //                  halfword is architecturally stored for SB/SH, so mask by
  //                  store_funct3 before comparing (see the scoreboard)
  //   store_funct3 - store width: 000 = SB, 001 = SH, 010 = SW
  // ===========================================================================
  class rv32i_retire_txn extends uvm_sequence_item;
    bit [31:0] pc;
    bit [31:0] instr;
    bit [4:0]  rd;
    bit [31:0] wdata;
    bit        regwrite;
    bit        store_valid;
    bit [31:0] store_addr;
    bit [31:0] store_data;
    bit [2:0]  store_funct3;

    `uvm_object_utils_begin(rv32i_retire_txn)
      `uvm_field_int(pc, UVM_ALL_ON)
      `uvm_field_int(instr, UVM_ALL_ON)
      `uvm_field_int(rd, UVM_ALL_ON)
      `uvm_field_int(wdata, UVM_ALL_ON)
      `uvm_field_int(regwrite, UVM_ALL_ON)
      `uvm_field_int(store_valid, UVM_ALL_ON)
      `uvm_field_int(store_addr, UVM_ALL_ON)
      `uvm_field_int(store_data, UVM_ALL_ON)
      `uvm_field_int(store_funct3, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "rv32i_retire_txn");
      super.new(name);
    endfunction
  endclass

  typedef uvm_sequencer #(rv32i_instr_txn) rv32i_sequencer;

  // ===========================================================================
  // Sequence: replays the instruction stream from stream.hex, which
  // verif/spike/gen_stream.py generates together with its reference trace.
  //
  // The program is generated in Python rather than here because the reference
  // model is. A precomputed Spike trace only means something if the program it
  // was computed from is the program the DUT runs, so both come out of one
  // generator and one seed. Two generators, seeded independently, would be a
  // scoreboard that checks nothing.
  //
  // The generation policy lives in gen_stream.py. Summarised, because it is
  // what makes the stream legal without post-hoc constraints:
  //  - ~40% of instructions take rs1 from the previous instruction's rd, so
  //    RAW hazards appear far more often than uniform-random choice gives.
  //  - x1 is reserved as a safe base pointer for every load and store, and is
  //    never another instruction's destination, so every offset is known at
  //    generation time to be small, aligned, and clear of the MMIO window at
  //    0x00020000. This is the same "reserve a pointer register" technique
  //    riscv-dv uses. x1 points PAST the end of the program image, never at 0:
  //    the DUT is Harvard and Spike is von Neumann, so stores into low memory
  //    would corrupt Spike's copy of the program and not the DUT's. See
  //    data_base_for() in gen_stream.py, which exists for that reason.
  //  - branches only ever jump forward by a small bounded amount, and padding
  //    NOPs before the sentinel keep every branch target inside the program.
  //  - the last instruction is a fixed sentinel (rd=x31, a recognisable
  //    immediate) that the scoreboard watches for as the "program fully
  //    retired" signal, rather than inferring completion from pipeline timing.
  //
  // Stimulus is therefore fixed per seed rather than per simulation run: new
  // stimulus means re-running gen_stream.py with a new --seed. For a
  // regression that is arguably an improvement, since a failing seed is
  // reproducible by name.
  // ===========================================================================
  class rv32i_random_seq extends uvm_sequence #(rv32i_instr_txn);
    `uvm_object_utils(rv32i_random_seq)

    // Program length is a gen_stream.py argument (--num-instr) rather than a
    // runtime plusarg, because the reference trace is computed from the same
    // program and the two have to agree. +STREAM/+TRACE select which
    // generated pair to run.

    function new(string name = "rv32i_random_seq");
      super.new(name);
    endfunction

    task send(bit [31:0] w, bit last = 1'b0);
      rv32i_instr_txn req;
      req = rv32i_instr_txn::type_id::create("req");
      start_item(req);
      req.instr   = w;
      req.last_word = last;
      finish_item(req);
    endtask

    task body();
      int        fd, code;
      int        word;
      bit [31:0] words[$];
      string     hex_file;

      if (!$value$plusargs("STREAM=%s", hex_file))
        hex_file = "stream.hex";

      fd = $fopen(hex_file, "r");
      if (fd == 0)
        `uvm_fatal("NOSTREAM",
          $sformatf("cannot open instruction stream '%s' -- generate it with verif/spike/gen_stream.py",
                    hex_file))

      while (!$feof(fd)) begin
        code = $fscanf(fd, "%h\n", word);
        if (code == 1) words.push_back(word);
      end
      $fclose(fd);

      if (words.size() == 0)
        `uvm_fatal("NOSTREAM", $sformatf("instruction stream '%s' was empty", hex_file))

      `uvm_info("SEQ", $sformatf("loaded %0d instruction words from %s",
                                 words.size(), hex_file), UVM_LOW)

      foreach (words[i])
        send(words[i], (i == words.size() - 1));
    endtask
  endclass

  // ===========================================================================
  // Driver: holds reset, backdoor-loads the sequence's instruction stream
  // into imem's RAM via mem_backdoor_if (see mem_backdoor_if.sv/
  // mem_backdoor_bind.sv), then releases reset and lets the DUT run.
  // ===========================================================================
  class rv32i_driver extends uvm_driver #(rv32i_instr_txn);
    `uvm_component_utils(rv32i_driver)

    virtual rv32i_if        vif;
    virtual mem_backdoor_if bd_vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual rv32i_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "rv32i_driver: no rv32i_if found in config_db")
      if (!uvm_config_db#(virtual mem_backdoor_if)::get(this, "", "bd_vif", bd_vif))
        `uvm_fatal("NOVIF", "rv32i_driver: no mem_backdoor_if found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
      rv32i_instr_txn req;
      int             idx;
      bit             done;

      // hold the DUT in reset while the program is backdoor-loaded
      vif.reset = 1'b1;
      repeat (2) @(posedge vif.clk);

      idx  = 0;
      done = 1'b0;
      while (!done) begin
        seq_item_port.get_next_item(req);
        bd_vif.load_word(idx, req.instr);
        idx++;
        done = req.last_word;
        seq_item_port.item_done();
      end
      `uvm_info("DRIVER", $sformatf("backdoor-loaded %0d instruction words", idx), UVM_LOW)

      // release reset -- the loaded program starts fetching from word 0
      repeat (2) @(posedge vif.clk);
      vif.reset = 1'b0;
    endtask
  endclass

  // ===========================================================================
  // Monitor: samples retire_if.sv's MON modport every cycle, publishes one
  // rv32i_retire_txn per cycle where retire_valid is set -- the
  // definitive "a real instruction retired" signal (see retire_if.sv).
  // ===========================================================================
  class rv32i_monitor extends uvm_monitor;
    `uvm_component_utils(rv32i_monitor)

    virtual retire_if.MON            vif;
    uvm_analysis_port #(rv32i_retire_txn) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual retire_if.MON)::get(this, "", "retire_vif", vif))
        `uvm_fatal("NOVIF", "rv32i_monitor: no retire_if.MON found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
      rv32i_retire_txn txn;
      forever begin
        @(vif.mon_cb);
        if (vif.mon_cb.retire_valid) begin
          txn = rv32i_retire_txn::type_id::create("txn");
          txn.pc           = vif.mon_cb.pc;
          txn.instr        = vif.mon_cb.instr;
          txn.rd           = vif.mon_cb.rd;
          txn.wdata        = vif.mon_cb.wdata;
          txn.regwrite     = vif.mon_cb.regwrite_valid;
          txn.store_valid  = vif.mon_cb.store_valid;
          txn.store_addr   = vif.mon_cb.store_addr;
          txn.store_data   = vif.mon_cb.store_data;
          txn.store_funct3 = vif.mon_cb.store_funct3;
          ap.write(txn);
        end
      end
    endtask
  endclass

  // ===========================================================================
  // Scoreboard: lockstep-checks every real retirement against the Spike
  // reference trace, read from stream_trace.txt at build time.
  //
  // Four checks per retirement, each a real bug class for a pipeline:
  //  - control flow: the retiring PC must equal the reference PC for this
  //    retirement index. Catches wrong branch targets and conditions.
  //  - instruction identity: the retiring instruction word must be the one
  //    Spike executed at that point.
  //  - register value: if the instruction wrote a register, the value must
  //    match. Skipped for rd==x0, an architectural no-op on both sides and
  //    the same convention the directed tests use.
  //  - store: if the instruction wrote memory, the address and the
  //    architecturally-stored bits must match.
  //
  // On the store check, both sides are masked to the store width before
  // comparing. Spike's --log-commits prints the masked value for SB/SH (a
  // byte store logs `0x2a`, not the source register), while the DUT presents
  // the full 32-bit register value on retire_if. Masking both sides makes the
  // comparison independent of which convention either model uses.
  //
  // The trace is indexed by retirement count, so a single spurious or dropped
  // retirement would put every later comparison out of step and produce a
  // cascade of errors instead of a diagnosis. Divergence in PC or instruction
  // is therefore treated as terminal: it is reported once, further checking is
  // suppressed, and the done event fires so the test finishes rather than
  // waiting for a sentinel that will never arrive.
  // ===========================================================================
  `uvm_analysis_imp_decl(_retire)

  class rv32i_scoreboard extends uvm_component;
    `uvm_component_utils(rv32i_scoreboard)

    localparam bit [31:0] SENTINEL_VAL = 32'h000007FF;
    localparam bit [4:0]  SENTINEL_REG = 5'd31;

    // Reference trace, loaded from stream_trace.txt in build_phase. Queues
    // rather than fixed arrays so the trace length is whatever was generated.
    bit [31:0] ref_pc    [$];
    bit [31:0] ref_instr [$];
    bit [4:0]  ref_rd    [$];
    bit [31:0] ref_wdata [$];
    bit        ref_rw    [$];
    bit        ref_sv    [$];
    bit [31:0] ref_saddr [$];
    bit [31:0] ref_sdata [$];
    int unsigned ref_len;

    // 0 when the trace predates the store columns -- see build_phase.
    bit store_checking;

    uvm_analysis_imp_retire #(rv32i_retire_txn, rv32i_scoreboard) retire_export;

    int unsigned num_checked;
    int unsigned num_mismatches;
    bit          desynced;
    event        done;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      retire_export = new("retire_export", this);
    endfunction

    // Architecturally-stored bits for a given store width. funct3 000 = SB,
    // 001 = SH, 010 = SW; anything else is not a legal store and is treated
    // as full width so a decode bug shows up as a data mismatch rather than
    // being masked away to equality.
    function automatic bit [31:0] store_mask(bit [2:0] funct3);
      case (funct3)
        3'b000:  return 32'h0000_00FF;
        3'b001:  return 32'h0000_FFFF;
        default: return 32'hFFFF_FFFF;
      endcase
    endfunction

    function void build_phase(uvm_phase phase);
      int    fd, code, n_short;
      int    pc, instr, rd, wdata, rw, sv, saddr, sdata;
      string trace_file, line;
      super.build_phase(phase);

      num_checked    = 0;
      num_mismatches = 0;
      ref_len        = 0;
      desynced       = 1'b0;
      n_short        = 0;

      if (!$value$plusargs("TRACE=%s", trace_file))
        trace_file = "stream_trace.txt";

      fd = $fopen(trace_file, "r");
      if (fd == 0)
        `uvm_fatal("NOTRACE",
          $sformatf("cannot open reference trace '%s' -- generate it with verif/spike/gen_stream.py",
                    trace_file))

      // Columns: pc instr rd wdata regwrite store_valid store_addr store_data.
      // Read whole lines and $sscanf them rather than $fscanf'ing the stream
      // directly: $sscanf reports how many fields it assigned, which is what
      // distinguishes a current 8-column row from a 5-column one written
      // before store checking existed, and lets comment lines fall out as a
      // zero-field match. It also means the discard path needs no scratch
      // buffer: do not be tempted to reuse trace_file as one, because it is
      // still needed for the messages below.
      while ($fgets(line, fd) != 0) begin
        code = $sscanf(line, "%h %h %d %h %d %d %h %h",
                       pc, instr, rd, wdata, rw, sv, saddr, sdata);
        if (code == 5 || code == 8) begin
          if (code == 5) begin
            n_short++;
            sv = 0; saddr = 0; sdata = 0;
          end
          ref_pc.push_back(pc);
          ref_instr.push_back(instr);
          ref_rd.push_back(rd[4:0]);
          ref_wdata.push_back(wdata);
          ref_rw.push_back(rw[0]);
          ref_sv.push_back(sv[0]);
          ref_saddr.push_back(saddr);
          ref_sdata.push_back(sdata);
          ref_len++;
        end
      end
      $fclose(fd);

      if (ref_len == 0)
        `uvm_fatal("NOTRACE",
          $sformatf("reference trace '%s' contained no rows", trace_file))

      store_checking = (n_short == 0);
      if (!store_checking)
        `uvm_warning("TRACE_FORMAT",
          $sformatf({"'%s' has %0d rows without store columns, so STORE CHECKING IS OFF ",
                     "and every store in this run is unverified. Regenerate the trace: ",
                     "cd verif/spike && ./gen_stream.py --seed <n>"},
                    trace_file, n_short))

      `uvm_info("SCOREBOARD",
        $sformatf("loaded %0d reference retirements from %s (store checking %s)",
                  ref_len, trace_file, store_checking ? "on" : "OFF"), UVM_LOW)
    endfunction

    // Report a divergence that makes every later index meaningless, and stop.
    function void diverge(string id, string msg);
      `uvm_error(id, msg)
      num_mismatches++;
      desynced = 1'b1;
      `uvm_error("DESYNC",
        $sformatf({"RTL and reference have diverged at retirement #%0d; the trace is ",
                   "indexed by retirement count, so all later comparisons would be ",
                   "meaningless. Checking stops here."}, num_checked))
      -> done;
    endfunction

    function void write_retire(rv32i_retire_txn t);
      bit [31:0] mask;

      if (desynced) return;

      if (num_checked >= ref_len) begin
        diverge("TRACE_OVERRUN",
          $sformatf("retirement #%0d but the reference trace has only %0d entries (instr=0x%08h)",
                    num_checked, ref_len, t.instr));
        return;
      end

      // ---- control flow ----
      if (ref_pc[num_checked] !== t.pc) begin
        diverge("PC_MISMATCH",
          $sformatf("retirement #%0d: RTL pc=0x%08h, Spike expected pc=0x%08h (instr=0x%08h)",
                    num_checked, t.pc, ref_pc[num_checked], t.instr));
        return;
      end

      // ---- the instruction itself must be the one Spike executed ----
      if (ref_instr[num_checked] !== t.instr) begin
        diverge("INSTR_MISMATCH",
          $sformatf("retirement #%0d: RTL retired instr=0x%08h, Spike executed 0x%08h (pc=0x%08h)",
                    num_checked, t.instr, ref_instr[num_checked], t.pc));
        return;
      end

      // ---- register value, skipped for x0 ----
      if (t.regwrite && (t.rd != 5'd0)) begin
        if (!ref_rw[num_checked] || ref_rd[num_checked] !== t.rd ||
            ref_wdata[num_checked] !== t.wdata) begin
          `uvm_error("REG_MISMATCH",
            $sformatf("retirement #%0d: RTL wrote x%0d=0x%08h, Spike wrote x%0d=0x%08h (rw=%0d, instr=0x%08h, pc=0x%08h)",
                      num_checked, t.rd, t.wdata,
                      ref_rd[num_checked], ref_wdata[num_checked], ref_rw[num_checked],
                      t.instr, t.pc))
          num_mismatches++;
        end
      end

      // ---- store address and data ----
      if (store_checking) begin
        if (t.store_valid !== ref_sv[num_checked]) begin
          `uvm_error("STORE_MISMATCH",
            $sformatf("retirement #%0d: RTL %s a store, Spike %s (instr=0x%08h, pc=0x%08h)",
                      num_checked,
                      t.store_valid ? "performed" : "did not perform",
                      ref_sv[num_checked] ? "did" : "did not",
                      t.instr, t.pc))
          num_mismatches++;
        end else if (t.store_valid) begin
          mask = store_mask(t.store_funct3);
          if (ref_saddr[num_checked] !== t.store_addr ||
              (ref_sdata[num_checked] & mask) !== (t.store_data & mask)) begin
            `uvm_error("STORE_MISMATCH",
              $sformatf({"retirement #%0d: RTL stored 0x%08h to 0x%08h, Spike stored 0x%08h ",
                         "to 0x%08h (width mask 0x%08h, instr=0x%08h, pc=0x%08h)"},
                        num_checked, t.store_data & mask, t.store_addr,
                        ref_sdata[num_checked] & mask, ref_saddr[num_checked],
                        mask, t.instr, t.pc))
            num_mismatches++;
          end
        end
      end

      num_checked++;

      if (t.regwrite && (t.rd == SENTINEL_REG) && (t.wdata == SENTINEL_VAL)) begin
        `uvm_info("SCOREBOARD",
          $sformatf("sentinel retired -- %0d instructions checked, %0d mismatches",
                    num_checked, num_mismatches), UVM_LOW)
        -> done;
      end
    endfunction
  endclass

  // ===========================================================================
  // Agent, env, test -- standard UVM wiring, nothing project-specific here.
  // ===========================================================================
  class rv32i_agent extends uvm_agent;
    `uvm_component_utils(rv32i_agent)

    rv32i_sequencer sqr;
    rv32i_driver    drv;
    rv32i_monitor   mon;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sqr = rv32i_sequencer::type_id::create("sqr", this);
      drv = rv32i_driver::type_id::create("drv", this);
      mon = rv32i_monitor::type_id::create("mon", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  class rv32i_env extends uvm_env;
    `uvm_component_utils(rv32i_env)

    rv32i_agent      agt;
    rv32i_scoreboard sb;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agt = rv32i_agent::type_id::create("agt", this);
      sb  = rv32i_scoreboard::type_id::create("sb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agt.mon.ap.connect(sb.retire_export);
    endfunction
  endclass

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
                    WATCHDOG_CYCLES, env.sb.num_checked, env.sb.ref_len))

      `uvm_info("TEST",
        $sformatf("DONE -- %0d of %0d retirements checked, %0d mismatches, store checking %s",
                  env.sb.num_checked, env.sb.ref_len, env.sb.num_mismatches,
                  env.sb.store_checking ? "on" : "OFF"), UVM_LOW)

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

endpackage
