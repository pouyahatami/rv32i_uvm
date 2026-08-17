// =============================================================================
// Env: one agent, one scoreboard, one coverage collector. The monitor's
// analysis port is the only connection -- every check and every coverage
// sample in this environment hangs off the retirement stream.
//
// Scoreboard and coverage are independent subscribers to the same port, which
// is the point of the analysis port being one-to-many: "was it right?" and
// "what did we try?" are separate questions and neither should be able to
// break the other.
// =============================================================================
class rv32i_env extends uvm_env;
  `uvm_component_utils(rv32i_env)

  rv32i_agent      agt;
  rv32i_scoreboard sb;
  rv32i_coverage   cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agt = rv32i_agent::type_id::create("agt", this);
    sb  = rv32i_scoreboard::type_id::create("sb", this);
    cov = rv32i_coverage::type_id::create("cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agt.mon.ap.connect(sb.retire_imp);
    agt.mon.ap.connect(cov.analysis_export);
  endfunction
endclass
