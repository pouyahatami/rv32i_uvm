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
// Scope: R-type ALU, the full I-type ALU set including immediate shifts, LOAD,
// STORE, forward-only BRANCH and JAL, AUIPC-paired JALR, and LUI. SYSTEM
// (ECALL, CSR ops, MRET) is deliberately out of scope -- tb_pipe_csr in
// rtl/tb_pipe.sv is the directed test covering that path, and docs/VMATRIX.md
// maps every feature to what checks it.
//
// Nothing here randomizes at simulation time, which is why the environment
// runs under licences that withhold SystemVerilog randomization (Questa
// Starter among them). Adding a randomize(), covergroup, constraint or
// randcase gives that up -- see RUNNING.md.
//
// This package is a manifest: each class lives in its own file under src/.
// Include order is a dependency -- each class must follow everything it
// references. Requires +incdir+verif/uvm, which both run scripts pass.
// =============================================================================

package rv32i_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import rv32i_pkg::*;

  // ---- shared constants ----
  `include "src/rv32i_uvm_defs.svh"

  // ---- transactions ----
  `include "src/rv32i_instr_txn.svh"
  `include "src/rv32i_retire_txn.svh"

  // ---- sequencer and stimulus ----
  `include "src/rv32i_sequencer.svh"
  `include "src/rv32i_random_seq.svh"

  // ---- agent internals ----
  `include "src/rv32i_driver.svh"
  `include "src/rv32i_monitor.svh"

  // ---- checking and measuring ----
  `include "src/rv32i_scoreboard.svh"
  `include "src/rv32i_coverage.svh"

  // ---- hierarchy ----
  `include "src/rv32i_agent.svh"
  `include "src/rv32i_env.svh"
  `include "src/rv32i_random_test.svh"

endpackage
