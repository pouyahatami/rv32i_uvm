# Running this UVM environment on EDA Playground

What this is: a real UVM testbench (`verif/uvm/`) for the pipelined RV32I
core in `rtl/`. It backdoor-loads a hazard-biased instruction stream into
the DUT's instruction memory and lockstep-checks every retiring
instruction against a reference trace produced by **Spike**, the RISC-V
reference simulator. See `rv32i_uvm_pkg.sv`'s header comment for the full
architecture, and `verif/spike/README.md` for why the reference model is
Spike and why it is precomputed rather than called live.

**Status: this environment runs and passes.** It is exercised locally under
the Questa FSE bundled with Altera Pro (`./run_uvm.sh`), and across a
multi-seed sweep (`./run_seeds.sh`). The scoreboard checks every retirement
against Spike and reports zero mismatches. EDA Playground is no longer the
only way to run it — it is the way to run it *without a local simulator*,
and the way to exercise the SystemVerilog covergroups (see below).

Two things are worth knowing before you start.

**Running it here found a real RTL bug.** `validE` was asserted
unconditionally, so the reset-cleared bubble sitting in Decode on the first
edge after reset was announced on `retire_if` as a retired instruction at
`PCW = 0xfffffffc`, shifting every subsequent retirement one slot late. It
had survived every static review; the lockstep comparison against Spike
caught it on the first run. That is the fifth bug in this project found by
running rather than reading — `DESIGN_GUIDE.md` §10 has the others.

**Covergroups need this platform specifically.** Questa FSE's licence grants
only the `intelqsimstarter` feature, and SystemVerilog covergroups require
the `svverification` feature it does not have:

```
** Error: (vsim-1) Unable to checkout verification license - required for
   testbench features (randomize, randcase, randsequence, covergroup).
```

So `src/rv32i_coverage.svh` carries the model twice: a plain-SystemVerilog
bin tally that runs everywhere and produces the coverage report locally, and
the equivalent covergroups behind `` `ifdef RV32I_COVERAGE ``. Aldec
Riviera-PRO on this site *does* have the licence — compile with
`+define+RV32I_COVERAGE` to exercise them. Those covergroups have not been
run by anything yet; the bin tally has.

## 1. Account

Go to edaplayground.com and log in with a Google account (free). Aldec
Riviera-PRO specifically doesn't require any extra license validation
step beyond that.

## 2. Create the project

- **Language**: SystemVerilog
- **Testbench + Design** template (the default two-pane layout is fine —
  everything below can go in the single "Design" pane; this project
  doesn't need the separate testbench pane split)
- **Tools & Simulators**: select **Aldec Riviera-PRO** (latest version
  offered)
- Look for a **UVM** dropdown/checkbox once Riviera-PRO is selected, and
  turn it on. Pick whichever UVM version is offered (1.2, or an IEEE
  1800.2 build) — this environment only uses UVM constructs that have
  been stable since UVM 1.1 (`uvm_component_utils`, `uvm_object_utils`,
  `uvm_sequencer`/`uvm_driver`/`uvm_monitor`, `uvm_analysis_port`,
  `uvm_analysis_imp_decl`), so version choice shouldn't matter here.

## 3. Paste the SystemVerilog design files

Add each file below via the "+" (add file) button in the Design Files
pane, **in this order** (dependencies flow top to bottom — packages and
interfaces before the modules/classes that use them):

```
rtl/rv32i_pkg.sv
rtl/cells.sv
rtl/regfile.sv
rtl/alu.sv
rtl/extend.sv
rtl/retire_if.sv
rtl/controller.sv
rtl/hazard_unit.sv
rtl/csr_file.sv
rtl/datapath.sv
rtl/debug_fsm.sv
rtl/riscv_pipe.sv
rtl/dmem.sv
rtl/clint.sv
rtl/uart_tx.sv
rtl/mem_bus.sv
rtl/imem.sv
rtl/top.sv
verif/uvm/mem_backdoor_if.sv
verif/uvm/mem_backdoor_bind.sv
verif/uvm/rv32i_if.sv
verif/uvm/rv32i_uvm_pkg.sv
verif/uvm/tb_uvm_top.sv
```

Use each file's own name when you add it (EDA Playground doesn't care
about the `rtl/`/`verif/uvm/` prefixes above — that's just this repo's
layout — just don't rename the files themselves, since `iss_dpi.cc`'s
`#include "rv32isim.hpp"` and the module/package names all assume the
original filenames).

You do **not** need `rtl/tb_pipe.sv` (the directed Icarus testbenches) or
`rtl/golden_vals_pipe*.svh` here — this environment doesn't use them.

## 4. Add the two generated data files (no C files, no DPI-C)

**This step changed.** There used to be a DPI-C bridge here that called a
hand-written C++ ISS live, one step per retirement, and you had to upload
four C++ files alongside the SystemVerilog. That ISS was deleted — a
golden model written by the same author as the RTL cannot catch a
misreading of the spec (see `verif/spike/README.md`).

Spike replaced it, but not in the same place: Spike is a large library
with boost and libfdt dependencies, so it cannot be uploaded to EDA
Playground the way four self-contained files could. Instead the reference
is **precomputed**. This environment now needs **no C files, no DPI-C, and
no "enable DPI" toggle** — just two text files:

```
verif/uvm/stream.hex          the instruction stream the DUT will run
verif/uvm/stream_trace.txt    the retirement trace Spike produced for it
```

Add them as plain files in the same flat file list (drop the directory
prefixes, keep the filenames — the testbench opens them by name). They are
generated together, and must stay together:

```bash
cd verif/spike
SPIKE=/path/to/spike ./gen_stream.py --seed 1 --num-instr 40
```

Regenerate with a different `--seed` for different stimulus. Do not edit
one without regenerating the other: the scoreboard checks the DUT against
a trace computed for *that exact program*, so a mismatched pair would be a
scoreboard that checks nothing.

## 5. Set the top-level module and run

- **Top module**: `tb_uvm_top`
- Nothing else needs to be set — `tb_uvm_top.sv` hardcodes
  `run_test("rv32i_random_test")`, so there's no required `+UVM_TESTNAME`
  plusarg for a first run.
- Optional: to change the random program length from the default of 40
  body instructions, add `+NUM_INSTR=<n>` as a simulator run-time
  argument/plusarg (look for a "Run options"/"Simulation args" field).
- Click **Run**.

## 6. What "it worked" looks like

The UVM log should end with something like:

```
UVM_INFO ... [DRIVER] backdoor-loaded 42 instruction words
UVM_INFO ... [SCOREBOARD] sentinel retired -- 42 instructions checked, 0 mismatches
UVM_INFO ... [TEST] DONE -- 42 instructions checked, 0 mismatches
UVM_INFO ... [TEST] *** UVM TEST PASSED ***
```

If instead you see `UVM_ERROR ... [PC_MISMATCH]` or `[REG_MISMATCH]`
lines, that's either a real RTL bug this environment just caught (exciting
— that's the whole point) or a bug in the environment itself (also
possible, since this hasn't run yet) — paste me the first mismatch line
and the instruction word it names, and I'll help figure out which.

## 7. Waveforms

`tb_uvm_top.sv` already has a `$dumpfile("dump.vcd")`/`$dumpvars` block.
If EDA Playground has an **"Open EPWave after run"** checkbox, turn it on
before running to get a waveform view of the failing (or passing) cycles
directly.

## 8. Natural next steps (not done in this pass, scoped out deliberately)

- **JAL/JALR/LUI/AUIPC/SYSTEM** (ECALL, MRET, CSRRW/S/C) instructions in
  the random sequence — v1 only generates R-type/I-type-ALU/LOAD/STORE/
  BRANCH. Adding these is what would start exercising the CSR/trap/
  interrupt/UART machinery through this environment instead of only
  through the existing directed `tb_pipe_csr` test.
- **True `rand`/`constraint`-based generation** instead of the current
  procedural `$urandom_range()` calls in `rv32i_random_seq::body()` — a
  reasonable upgrade once this is confirmed running, not before (see
  that class's header comment for why procedural generation was the
  lower-risk choice for a first, never-yet-compiled-in-a-real-simulator
  pass).
- **Functional coverage** (a `covergroup` on instruction class × forwarding
  path × stall/flush reason, per `docs/DESIGN_GUIDE.md` Section 7 Step 5)
  once the environment itself is confirmed working.
