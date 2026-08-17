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
//    match. Skipped for rd==x0
//  - store: if the instruction wrote memory, the address and the
//    architecturally-stored bits must match.
//
// The trace is indexed by retirement count, so a single dropped
// retirement would put every later comparison out of step.
// Divergence in PC or instruction is therefore treated as terminal.
// ===========================================================================
class rv32i_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(rv32i_scoreboard)

  typedef struct {
    bit [31:0] pc;
    bit [31:0] instr;
    bit [4:0]  rd;
    bit [31:0] wdata;
    bit        regwrite;
    bit        store_valid;
    bit [31:0] store_addr;
    bit [31:0] store_data;
  } ref_retire_t;

  typedef enum bit [1:0] {
    CHECKER_ACTIVE,
    CHECKER_FINISHED,
    CHECKER_DESYNCED
  } checker_state_e;

  // Reference trace, loaded from stream_trace.txt in build_phase.
  ref_retire_t reference_trace[$];

  uvm_analysis_imp #(rv32i_retire_txn, rv32i_scoreboard) retire_imp;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    retire_imp = new("retire_imp", this);
  endfunction

  int unsigned num_checked;
  int unsigned num_mismatches;
  checker_state_e checker_state;
  event        done;

  // Mask the word according to the store width (byte, halfword, or word).
  function bit [31:0] store_mask(bit [2:0] funct3);
    case (funct3)
      3'b000:  return 32'h0000_00FF; //SB
      3'b001:  return 32'h0000_FFFF; //SH
      3'b010:  return 32'hFFFF_FFFF; //SW
      default: return 32'h0000_0000; //illegal store width
    endcase
  endfunction

  function int unsigned reference_count();
    return reference_trace.size();
  endfunction

  function void build_phase(uvm_phase phase);
    int    fd, code, line_number;
    bit [31:0] pc, instr, wdata, saddr, sdata;
    bit [4:0]  rd;
    bit        rw, svalid;
    string     trace_file, line, first_token;
    ref_retire_t reference;
    super.build_phase(phase);

    // Initializing the scoreboard state 
    num_checked    = 0;
    num_mismatches = 0;
    reference_trace.delete();
    checker_state  = CHECKER_ACTIVE;
    line_number    = 0;

    if (!$value$plusargs("TRACE=%s", trace_file)) begin 
      trace_file = "stream_trace.txt";
    end 

    fd = $fopen(trace_file, "r");
    if (fd == 0) begin 
      `uvm_fatal("NOTRACE",
        $sformatf("cannot open reference trace '%s' -- generate it with verif/spike/gen_stream.py",
                  trace_file))
    end 

    // Spike Columns: pc instr rd wdata regwrite store_valid store_addr store_data.
    // Blank lines and lines whose first token is // are ignored
    // Every other line must contain all eight fields
    while ($fgets(line, fd) != 0) begin
      line_number++;

      if ($sscanf(line, "%s", first_token) == 0)
        continue;
      if ((first_token.len() >= 2) && (first_token.substr(0, 1) == "//"))
        continue;

      code = $sscanf(line, "%h %h %d %h %d %d %h %h",
                     pc, instr, rd, wdata, rw, svalid, saddr, sdata);
      if (code == 8) begin
        reference.pc          = pc;
        reference.instr       = instr;
        reference.rd          = rd;
        reference.wdata       = wdata;
        reference.regwrite    = rw;
        reference.store_valid = svalid;
        reference.store_addr  = saddr;
        reference.store_data  = sdata;
        reference_trace.push_back(reference);
      end else begin
        `uvm_fatal("BADTRACE",
          $sformatf({"malformed reference trace '%s' at line %0d: expected 8 columns, ",
                     "parsed %0d"}, trace_file, line_number, code))
      end
    end
    $fclose(fd);

    if (reference_trace.size() == 0)
      `uvm_fatal("NOTRACE",
        $sformatf("reference trace '%s' contained no rows", trace_file))

    `uvm_info("SCOREBOARD",
      $sformatf("loaded %0d reference retirements from %s",
                reference_trace.size(), trace_file), UVM_LOW)
  endfunction

  // Report a divergence that makes every later index meaningless, then stop.
  function void diverge(string id, string msg);
    `uvm_error(id,
      $sformatf({"%s; RTL and reference diverged at retirement #%0d. ",
                 "Later comparisons would be meaningless, so checking stops."},
                msg, num_checked))
    num_mismatches++;
    checker_state = CHECKER_DESYNCED;
    -> done;
  endfunction

  function void write(rv32i_retire_txn t);
    ref_retire_t expected;
    bit [31:0] mask;
    bit [2:0]  expected_store_funct3;
    bit        dut_writes_reg;
    bit        ref_writes_reg;

    // Ignore retirements after normal completion or terminal divergence.
    if (checker_state != CHECKER_ACTIVE) return;

    if (num_checked >= reference_trace.size()) begin
      diverge("TRACE_OVERRUN",
        $sformatf("retirement #%0d but the reference trace has only %0d entries (instr=0x%08h)",
                  num_checked, reference_trace.size(), t.instr));
      return;
    end
    expected = reference_trace[num_checked];

    // ---- control flow ----
    if (expected.pc !== t.pc) begin
      diverge("PC_MISMATCH",
        $sformatf("retirement #%0d: RTL pc=0x%08h, Spike expected pc=0x%08h (instr=0x%08h)",
                  num_checked, t.pc, expected.pc, t.instr));
      return;
    end

    // ---- the instruction itself must be the one Spike executed ----
    if (expected.instr !== t.instr) begin
      diverge("INSTR_MISMATCH",
        $sformatf("retirement #%0d: RTL retired instr=0x%08h, Spike executed 0x%08h (pc=0x%08h)",
                  num_checked, t.instr, expected.instr, t.pc));
      return;
    end

    // A write to x0 has no architectural effect, so treat it as no write on
    // either side. All other writes must agree in both presence and value.
    dut_writes_reg = t.regwrite && (t.rd != 5'd0);
    ref_writes_reg = expected.regwrite && (expected.rd != 5'd0);
    if (dut_writes_reg !== ref_writes_reg) begin
      `uvm_error("REGWRITE_MISMATCH",
        $sformatf({"retirement #%0d: RTL architectural regwrite=%0d, Spike regwrite=%0d ",
                   "(RTL rd=x%0d, Spike rd=x%0d, instr=0x%08h, pc=0x%08h)"},
                  num_checked, dut_writes_reg, ref_writes_reg,
                  t.rd, expected.rd, t.instr, t.pc))
      num_mismatches++;
    end else if (ref_writes_reg &&
                 (expected.rd !== t.rd || expected.wdata !== t.wdata)) begin
      `uvm_error("REG_MISMATCH",
        $sformatf({"retirement #%0d: RTL wrote x%0d=0x%08h, Spike wrote ",
                   "x%0d=0x%08h (instr=0x%08h, pc=0x%08h)"},
                  num_checked, t.rd, t.wdata, expected.rd, expected.wdata,
                  t.instr, t.pc))
      num_mismatches++;
    end

    // ---- store address and data ----
    if (t.store_valid !== expected.store_valid) begin
      `uvm_error("STORE_MISMATCH",
        $sformatf("retirement #%0d: RTL %s a store, Spike %s (instr=0x%08h, pc=0x%08h)",
                  num_checked,
                  t.store_valid ? "performed" : "did not perform",
                  expected.store_valid ? "did" : "did not",
                  t.instr, t.pc))
      num_mismatches++;
    end else if (expected.store_valid) begin
      expected_store_funct3 = expected.instr[14:12];
      if (t.store_funct3 !== expected_store_funct3) begin
        `uvm_error("STORE_WIDTH_MISMATCH",
          $sformatf({"retirement #%0d: RTL store funct3=%03b, expected %03b ",
                     "(instr=0x%08h, pc=0x%08h)"},
                    num_checked, t.store_funct3, expected_store_funct3,
                    t.instr, t.pc))
        num_mismatches++;
      end

      mask = store_mask(expected_store_funct3);
      if (mask == 32'b0) begin
        `uvm_error("BAD_STORE_WIDTH",
          $sformatf("retirement #%0d: invalid store funct3=%03b in reference instruction 0x%08h",
                    num_checked, expected_store_funct3, expected.instr))
        num_mismatches++;
      end else if (expected.store_addr !== t.store_addr ||
                   (expected.store_data & mask) !== (t.store_data & mask)) begin
        `uvm_error("STORE_MISMATCH",
          $sformatf({"retirement #%0d: RTL stored 0x%08h to 0x%08h, Spike stored 0x%08h ",
                     "to 0x%08h (width mask 0x%08h, instr=0x%08h, pc=0x%08h)"},
                    num_checked, t.store_data & mask, t.store_addr,
                    expected.store_data & mask, expected.store_addr,
                    mask, t.instr, t.pc))
        num_mismatches++;
      end
    end

    num_checked++;

    if (t.regwrite && (t.rd == SENTINEL_REG) && (t.wdata == SENTINEL_VAL)) begin
      checker_state = CHECKER_FINISHED;
      `uvm_info("SCOREBOARD",
        $sformatf("sentinel retired -- %0d instructions checked, %0d mismatches",
                  num_checked, num_mismatches), UVM_LOW)
      -> done;
    end
  endfunction
endclass
