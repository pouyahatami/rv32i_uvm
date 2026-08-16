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
//
// -----------------------------------------------------------------------------
// File layout: this package is a manifest. Every class lives in its own file
// under src/, included below. `include is textual substitution, so the compiler
// still sees exactly one package and one namespace -- splitting is a
// file-organisation choice, not an architectural one.
//
// INCLUDE ORDER IS A DEPENDENCY, not a style preference. Each class must be
// included after everything it references: transactions before the sequencer
// typedef that parameterises on them, components before the agent that
// instantiates them, agent and scoreboard before the env. Reordering these
// lines produces "type not found" errors that read like missing files.
//
// Requires +incdir+verif/uvm on the vlog command line; run_uvm.sh and
// run_seeds.sh both pass it.
// -----------------------------------------------------------------------------
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
