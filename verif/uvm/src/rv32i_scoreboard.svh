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

  // SENTINEL_VAL/SENTINEL_REG are package-scope now (src/rv32i_uvm_defs.svh) --
  // the coverage collector recognises the same marker.

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

  // Set the moment the sentinel retires. Past that point the program is
  // over, but the core keeps fetching -- off the end of the loaded stream,
  // into memory that was never written -- and keeps retiring whatever it
  // decodes there, all of it past the end of the reference trace. Those
  // retirements are not the DUT being wrong, they are the DUT having nothing
  // left to run, so checking them is a false failure. The test's own
  // post-`done` drain loop keeps the simulation alive long enough for this
  // to matter (~9 retirements, all reported as TRACE_OVERRUN).
  bit finished;

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
    finished       = 1'b0;

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

    // Two separate stopping conditions, and both are needed.
    //   desynced - a divergence happened, so every later index is meaningless.
    //   finished - the program ended normally at the sentinel. Past that the
    //              core keeps fetching unwritten memory and retiring whatever
    //              it decodes, all of it past the end of the reference trace.
    // Without `finished`, that normal end-of-program overrun trips
    // TRACE_OVERRUN, which calls diverge(), which sets desynced -- so the run
    // self-limits to one error instead of nine, but still reports a mismatch
    // for a DUT that did nothing wrong.
    if (desynced || finished) return;

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
      finished = 1'b1;
      `uvm_info("SCOREBOARD",
        $sformatf("sentinel retired -- %0d instructions checked, %0d mismatches",
                  num_checked, num_mismatches), UVM_LOW)
      -> done;
    end
  endfunction
endclass
