// =============================================================================
// Functional coverage: what the stimulus actually exercised, as opposed to how
// many instructions it ran.
//
// Subscribes to the same retirement stream the scoreboard checks. The
// scoreboard answers "was the DUT right?"; this answers "about what?" -- and
// without it a passing run reports 133 instructions with no way to tell
// whether those 133 covered the forwarding paths this design exists to
// implement, or were 133 independent ADDs.
//
// -----------------------------------------------------------------------------
// WHY THERE ARE TWO IMPLEMENTATIONS OF ONE COVERAGE MODEL
//
// SystemVerilog covergroups are the industry standard and are what belongs in
// a UVM environment. They are also a *licensed feature*: Questa FSE, the
// edition bundled with Altera Pro and the only simulator available on this
// machine, refuses them outright --
//
//   ** Error: (vsim-1) Unable to checkout verification license - required for
//      testbench features (randomize, randcase, randsequence, covergroup).
//
// Its license grants exactly one feature, `intelqsimstarter`. There is no flag
// that works around this.
//
// Shipping covergroups alone would mean a coverage model that has never been
// executed. This project has been bitten five times by code that survived
// careful review and was wrong the first time it ran, so that was not an
// acceptable outcome. Instead:
//
//   * The BIN TALLY below is plain SystemVerilog -- an associative array of
//     counters, no licensed constructs. It always runs, including on Questa
//     FSE, and it is what prints the coverage report. It is verified.
//   * The COVERGROUPS at the bottom express the identical model in the
//     standard form, compiled only under `ifdef RV32I_COVERAGE, for a
//     simulator that has the licence (EDA Playground's Riviera-PRO does; see
//     EDA_PLAYGROUND_SETUP.md). They are NOT verified here -- treat them as
//     untested until something runs them.
//
// The duplication is real and is the cost of the licence, not a design
// preference. The bin names are identical between the two so a report from
// either is comparable, and both are sampled from the same write() call, so
// neither can silently observe different traffic. If they ever disagree, the
// tally is the one that has actually run.
// -----------------------------------------------------------------------------
//
// WHAT IS SAMPLED, AND WHAT THAT MEASURES
//
// Everything here is derived from retire_if alone -- pc, instr, rd, wdata,
// regwrite -- so this is *architectural* coverage: it measures the stimulus,
// not the microarchitecture. That boundary is deliberate (same reasoning as
// the scoreboard's: check the committed contract, stay immune to pipeline
// changes) but it has a real consequence worth stating plainly:
//
//   The forwarding-mux selects (ForwardAE/ForwardBE) are NOT covered here.
//   They are internal to hazard_unit.sv and invisible at the retire boundary.
//   rs1_dist/rs2_dist cover the *stimulus condition* that drives forwarding --
//   a RAW dependency at distance 1/2/3 -- which is the thing the generator
//   controls and therefore the thing worth measuring for stimulus quality.
//   Covering the mux selects themselves needs a second collector bound into
//   hazard_unit. That is a genuine gap, not a solved problem.
//
// DEPENDENCY DISTANCE IS MEASURED IN RETIREMENTS, NOT CYCLES.
// Distance 1 means "the immediately preceding retired instruction wrote the
// register this one reads". Under stalls the pipeline distance differs from
// the retirement distance -- a load-use hazard stalls a cycle, so its
// architectural distance 1 becomes a longer pipeline gap. Retirement distance
// is the right metric for judging *stimulus*, because it is what the generator
// chooses; it is the wrong metric for judging forwarding-path activation. Read
// the numbers as "did we ask for the hard cases", not "did the hard paths run".
//
// Distance 3 is called out specifically because DESIGN_GUIDE.md Section 10
// records a real distance-3 RAW bug that survived every static review. A
// report showing rs1_dist.d3 at zero would mean this environment could not
// have found it.
//
// THE ZERO BINS ARE THE POINT. Bins exist for JAL/JALR/LUI/AUIPC/SYSTEM even
// though gen_stream.py cannot emit them. They are counted in a separate
// "out of scope" group so they do not silently drag the headline number down,
// but they are printed, which turns the scope gap documented in the package
// header into a number in the report instead of a sentence someone has to
// remember to read.
// =============================================================================
class rv32i_coverage extends uvm_subscriber #(rv32i_retire_txn);
  `uvm_component_utils(rv32i_coverage)

  // ---- sampled fields (covergroups sample class members, not arguments) ----
  bit [6:0]    opcode;
  bit [2:0]    funct3;
  bit [4:0]    rd;
  bit          writes_reg;
  int unsigned rs1_dist;      // 0 = no dependency, else 1..3 retirements back
  int unsigned rs2_dist;
  bit          br_taken;      // valid only while sampling a resolved branch

  // ---- history used to derive the above ----
  // prev_rd[0] is the immediately preceding retirement's destination, 0 if it
  // wrote nothing. Per-instruction slots (not per-write) so the index is a
  // true instruction distance.
  bit [4:0]    prev_rd[3];
  // Was the instruction in that slot a LOAD? A RAW dependency on a load's
  // result at distance 1 is the ONE hazard this pipeline cannot forward its
  // way out of -- the value is still in memory when the consumer needs it, so
  // hazard_unit must stall. Distinguishing it from an ALU-producer RAW is the
  // difference between covering "a hazard happened" and covering "the stall
  // path ran", and only the second one is interesting.
  bit          prev_is_load[3];

  bit          pending_branch; // previous retirement was a branch, not yet resolved
  bit [31:0]   pending_br_pc;
  bit [2:0]    pending_funct3;

  bit          finished;       // stop at the sentinel -- see rv32i_scoreboard
  int unsigned num_sampled;

  // ---- the bin tally: name -> hit count, plus the group each bin belongs to
  int unsigned hits[string];
  string       group_of[string];

  function new(string name, uvm_component parent);
    super.new(name, parent);
`ifdef RV32I_COVERAGE
    cg_instr  = new();
    cg_branch = new();
`endif
  endfunction

  // Declare a bin so it appears in the report at 0 even if never hit. An
  // undeclared bin that is never hit is invisible, and an invisible hole is
  // the failure mode this whole class exists to prevent.
  function void declare(string grp, string bin_name);
    hits[bin_name]     = 0;
    group_of[bin_name] = grp;
  endfunction

  function void hit(string bin_name);
    if (hits.exists(bin_name)) hits[bin_name]++;
    else `uvm_error("COVERAGE", $sformatf("undeclared coverage bin '%s'", bin_name))
  endfunction

  function void build_phase(uvm_phase phase);
    string ops[5];
    string dists[4];
    super.build_phase(phase);

    foreach (prev_rd[i]) begin prev_rd[i] = 5'd0; prev_is_load[i] = 1'b0; end
    pending_branch = 1'b0;
    finished       = 1'b0;
    num_sampled    = 0;

    ops   = '{"rtype", "itype", "load", "store", "branch"};
    dists = '{"none", "d1", "d2", "d3"};

    // in-scope opcodes
    foreach (ops[i]) declare("opcode", $sformatf("opcode.%s", ops[i]));

    // deliberately out of scope for the v1 generator -- reported separately
    declare("opcode_out_of_scope", "opcode.jal");
    declare("opcode_out_of_scope", "opcode.jalr");
    declare("opcode_out_of_scope", "opcode.lui");
    declare("opcode_out_of_scope", "opcode.auipc");
    declare("opcode_out_of_scope", "opcode.system");

    foreach (dists[d]) begin
      declare("rs1_dist", $sformatf("rs1_dist.%s", dists[d]));
      declare("rs2_dist", $sformatf("rs2_dist.%s", dists[d]));
    end

    declare("rd", "rd.x0");
    declare("rd", "rd.base_ptr");
    declare("rd", "rd.sentinel");
    declare("rd", "rd.general");

    // The hazard the pipeline must STALL for, versus the ones it forwards
    // around. load_use.d1 is the stall path; everything else is forwarding.
    foreach (dists[d]) begin
      if (dists[d] == "none") continue;
      declare("hazard_kind", $sformatf("hazard.load_use_%s", dists[d]));
      declare("hazard_kind", $sformatf("hazard.alu_raw_%s",  dists[d]));
    end

    declare("branch", "branch.taken");
    declare("branch", "branch.not_taken");
    declare("branch", "branch.beq");
    declare("branch", "branch.bne");

    // cross: dependency distance against instruction type. This is the single
    // most informative group in the report -- "did we ever get a distance-1
    // hazard feeding a store address?" is answered here and nowhere else.
    foreach (ops[i])
      foreach (dists[d])
        declare("x_op_rs1", $sformatf("x_op_rs1.%s_%s", ops[i], dists[d]));

    // rs2 is only read by R-type, store, and branch.
    foreach (dists[d]) begin
      declare("x_op_rs2", $sformatf("x_op_rs2.rtype_%s",  dists[d]));
      declare("x_op_rs2", $sformatf("x_op_rs2.store_%s",  dists[d]));
      declare("x_op_rs2", $sformatf("x_op_rs2.branch_%s", dists[d]));
    end
  endfunction

  // Dependency distance of a source register against the last three
  // retirements. Returns 0 for "no dependency", including reads of x0 --
  // x0 always reads zero, so a match on it is never a real hazard.
  function int unsigned dep_dist(bit [4:0] rs);
    if (rs == 5'd0) return 0;
    for (int i = 0; i < 3; i++)
      if (prev_rd[i] == rs) return i + 1;
    return 0;
  endfunction

  function bit uses_rs1(bit [6:0] op);
    return (op inside {OP_RTYPE, OP_ITYPE, OP_LOAD, OP_STORE, OP_BRANCH, OP_JALR});
  endfunction

  function bit uses_rs2(bit [6:0] op);
    return (op inside {OP_RTYPE, OP_STORE, OP_BRANCH});
  endfunction

  function string op_name(bit [6:0] op);
    case (op)
      OP_RTYPE:  return "rtype";
      OP_ITYPE:  return "itype";
      OP_LOAD:   return "load";
      OP_STORE:  return "store";
      OP_BRANCH: return "branch";
      OP_JAL:    return "jal";
      OP_JALR:   return "jalr";
      OP_LUI:    return "lui";
      OP_AUIPC:  return "auipc";
      OP_SYSTEM: return "system";
      default:   return "";
    endcase
  endfunction

  function string dist_name(int unsigned d);
    case (d)
      0: return "none";
      1: return "d1";
      2: return "d2";
      3: return "d3";
      default: return "none";
    endcase
  endfunction

  // uvm_subscriber supplies the analysis_export; this is its callback.
  function void write(rv32i_retire_txn t);
    bit [4:0] rs1, rs2;
    string    op_s;

    // Past the sentinel the core is fetching unwritten memory. Those
    // retirements are not stimulus anyone chose, and counting them would
    // inflate coverage with noise. Same guard, same reason, as the scoreboard.
    if (finished) return;

    opcode = t.instr[6:0];
    funct3 = t.instr[14:12];
    rs1    = t.instr[19:15];
    rs2    = t.instr[24:20];
    rd     = t.rd;
    writes_reg = t.regwrite;

    rs1_dist = uses_rs1(opcode) ? dep_dist(rs1) : 0;
    rs2_dist = uses_rs2(opcode) ? dep_dist(rs2) : 0;

    op_s = op_name(opcode);
    num_sampled++;

    // ---- bin tally (always runs) ----
    if (op_s != "") hit($sformatf("opcode.%s", op_s));

    if (uses_rs1(opcode)) hit($sformatf("rs1_dist.%s", dist_name(rs1_dist)));
    if (uses_rs2(opcode)) hit($sformatf("rs2_dist.%s", dist_name(rs2_dist)));

    if (t.regwrite) begin
      if      (t.rd == 5'd0)          hit("rd.x0");
      else if (t.rd == SAFE_BASE_REG) hit("rd.base_ptr");
      else if (t.rd == SENTINEL_REG)  hit("rd.sentinel");
      else                            hit("rd.general");
    end

    // Nearest dependency across both source operands, and what produced it.
    begin
      int unsigned d;
      d = 0;
      if (rs1_dist != 0) d = rs1_dist;
      if (rs2_dist != 0 && (d == 0 || rs2_dist < d)) d = rs2_dist;
      // NOT a ternary over the two names. `"load_use" : "alu_raw"` are packed
      // byte arrays, not strings: the conditional operator sizes both operands
      // to the wider one, so "alu_raw" acquires a leading NUL and the bin name
      // silently stops matching. That bug shipped once here and made alu_raw
      // look unreachable across 30 seeds while it was firing constantly.
      if (d != 0) begin
        if (prev_is_load[d-1]) hit($sformatf("hazard.load_use_%s", dist_name(d)));
        else                   hit($sformatf("hazard.alu_raw_%s",  dist_name(d)));
      end
    end

    if (uses_rs1(opcode) && (op_s inside {"rtype","itype","load","store","branch"}))
      hit($sformatf("x_op_rs1.%s_%s", op_s, dist_name(rs1_dist)));
    if (uses_rs2(opcode) && (op_s inside {"rtype","store","branch"}))
      hit($sformatf("x_op_rs2.%s_%s", op_s, dist_name(rs2_dist)));

`ifdef RV32I_COVERAGE
    cg_instr.sample();
`endif

    // A branch's outcome is only observable once the next instruction
    // retires: sequential PC means not-taken, anything else means taken.
    if (pending_branch) begin
      br_taken = (t.pc !== (pending_br_pc + 32'd4));
      if (br_taken) hit("branch.taken");   // see the NUL-padding note above --
      else          hit("branch.not_taken"); // never a ternary over bin names
`ifdef RV32I_COVERAGE
      cg_branch.sample();
`endif
      pending_branch = 1'b0;
    end

    if (opcode == OP_BRANCH) begin
      pending_branch = 1'b1;
      pending_br_pc  = t.pc;
      pending_funct3 = funct3;
      hit((funct3 == 3'b000) ? "branch.beq" : "branch.bne");
    end

    // Shift the destination history. Instructions that write nothing (and
    // writes to x0) push a 0, which dep_dist() never matches -- so a
    // non-writing instruction correctly breaks a dependency chain rather than
    // being skipped over.
    prev_rd[2] = prev_rd[1];
    prev_rd[1] = prev_rd[0];
    prev_rd[0] = (t.regwrite && t.rd != 5'd0) ? t.rd : 5'd0;
    prev_is_load[2] = prev_is_load[1];
    prev_is_load[1] = prev_is_load[0];
    prev_is_load[0] = (opcode == OP_LOAD);

    if (t.regwrite && (t.rd == SENTINEL_REG) && (t.wdata == SENTINEL_VAL))
      finished = 1'b1;
  endfunction

  // ---- reporting -----------------------------------------------------------
  // Headline coverage deliberately EXCLUDES the out-of-scope opcode group.
  // Including it would peg the number below 100% for a reason that has nothing
  // to do with stimulus quality, and a metric nobody can ever move is a metric
  // nobody reads. It is printed on its own line instead.
  function void report_phase(uvm_phase phase);
    string   grp, b;
    string   groups[$];
    int unsigned g_hit[string], g_tot[string];
    int unsigned tot_hit, tot_bins;
    super.report_phase(phase);

    foreach (hits[b]) begin
      grp = group_of[b];
      if (!g_tot.exists(grp)) begin
        g_tot[grp] = 0; g_hit[grp] = 0; groups.push_back(grp);
      end
      g_tot[grp]++;
      if (hits[b] > 0) g_hit[grp]++;
      if (grp != "opcode_out_of_scope") begin
        tot_bins++;
        if (hits[b] > 0) tot_hit++;
      end
    end

    groups.sort();
    `uvm_info("COVERAGE",
      $sformatf("functional coverage over %0d sampled retirements", num_sampled),
      UVM_LOW)
    foreach (groups[i]) begin
      grp = groups[i];
      `uvm_info("COVERAGE",
        $sformatf("  %-22s %2d/%2d bins  %6.2f%%%s",
                  grp, g_hit[grp], g_tot[grp],
                  100.0 * real'(g_hit[grp]) / real'(g_tot[grp]),
                  (grp == "opcode_out_of_scope") ?
                    "   (excluded from total -- v2 scope)" : "                                    "),
        UVM_LOW)
    end
    `uvm_info("COVERAGE",
      $sformatf("  %-22s %2d/%2d bins  %6.2f%%", "TOTAL (in scope)",
                tot_hit, tot_bins, 100.0 * real'(tot_hit) / real'(tot_bins)), UVM_LOW)

    // Name the holes outright. A percentage tells you there is a gap; this
    // tells you which one, which is the difference between a number and an
    // action item.
    foreach (hits[b])
      if (hits[b] == 0 && group_of[b] != "opcode_out_of_scope")
        `uvm_info("COVERAGE_HOLE", $sformatf("  never hit: %s", b), UVM_LOW)
  endfunction

  // ---------------------------------------------------------------------------
  // The same model as standard covergroups, for a simulator with the
  // verification licence. Compiled only under +define+RV32I_COVERAGE.
  // UNVERIFIED -- see this class's header.
  // ---------------------------------------------------------------------------
`ifdef RV32I_COVERAGE
  covergroup cg_instr;
    option.per_instance = 1;
    option.name         = "instruction_mix";

    cp_opcode : coverpoint opcode {
      bins rtype  = {OP_RTYPE};
      bins itype  = {OP_ITYPE};
      bins load   = {OP_LOAD};
      bins store  = {OP_STORE};
      bins branch = {OP_BRANCH};
      bins jal    = {OP_JAL};
      bins jalr   = {OP_JALR};
      bins lui    = {OP_LUI};
      bins auipc  = {OP_AUIPC};
      bins system = {OP_SYSTEM};
    }

    cp_rd : coverpoint rd iff (writes_reg) {
      bins x0       = {0};
      bins base_ptr = {SAFE_BASE_REG};
      bins sentinel = {SENTINEL_REG};
      bins general  = {[2:30]};
    }

    cp_rs1_dist : coverpoint rs1_dist {
      bins none = {0}; bins d1 = {1}; bins d2 = {2}; bins d3 = {3};
    }

    cp_rs2_dist : coverpoint rs2_dist {
      bins none = {0}; bins d1 = {1}; bins d2 = {2}; bins d3 = {3};
    }

    x_op_rs1 : cross cp_opcode, cp_rs1_dist {
      ignore_bins not_generated =
        binsof(cp_opcode) intersect {OP_JAL, OP_JALR, OP_LUI, OP_AUIPC, OP_SYSTEM};
    }

    x_op_rs2 : cross cp_opcode, cp_rs2_dist {
      ignore_bins no_rs2 =
        binsof(cp_opcode) intersect {OP_ITYPE, OP_LOAD, OP_JAL, OP_JALR,
                                     OP_LUI, OP_AUIPC, OP_SYSTEM};
    }
  endgroup

  covergroup cg_branch;
    option.per_instance = 1;
    option.name         = "branch_outcome";

    cp_taken : coverpoint br_taken {
      bins taken = {1}; bins not_taken = {0};
    }
    cp_kind  : coverpoint pending_funct3 {
      bins beq = {3'b000}; bins bne = {3'b001};
    }
    x_kind_taken : cross cp_kind, cp_taken;
  endgroup
`endif
endclass
