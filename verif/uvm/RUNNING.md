# Running the UVM environment

A UVM testbench for the pipelined RV32I core in `rtl/`. It backdoor-loads a
hazard-biased instruction stream into the DUT's instruction memory and
lockstep-checks every retiring instruction against a reference trace produced
by [Spike](https://github.com/riscv-software-src/riscv-isa-sim). See
`rv32i_uvm_pkg.sv`'s header for the architecture and `verif/spike/README.md`
for why the reference model is Spike.

## Status

Validated with Questa Altera Starter FPGA Edition 2025.2 on Windows: the
checked-in stream completes 133 of 133 reference retirements with zero UVM
warnings, errors, or fatals.

## Option A: Questa

```
cd verif/uvm
vsim -c -do run_questa.do
```

Builds into `verif/uvm/build/` and exits non-zero on failure. Drop `-c` for
the GUI. The script copies `stream.hex`, `stream_trace.txt` and a placeholder
`riscvtest_pipe.txt` into the build directory, because the testbench opens all
three by bare filename.

### On Starter Edition

The free Questa Starter licence withholds the `svverification` feature. That
feature gates exactly four SystemVerilog constructs: `randomize()`, `randcase`,
`randsequence` and `covergroup`. UVM itself compiles and elaborates without it.

This environment uses none of the four. The instruction stream is generated in
Python by `verif/spike/gen_stream.py` and replayed here, so nothing randomizes
at simulation time. That is a side effect of the reference model being Spike:
the program has to be generated wherever the reference trace is generated, and
Spike cannot be called from inside the simulator.

This flow is confirmed on Questa Altera Starter FPGA Edition 2025.2.

**This is a constraint to preserve deliberately.** The two most natural next
steps below, constrained-random generation and functional coverage, both
require `svverification` and would end Starter support. That is a real
tradeoff, not an oversight.

## Option B: EDA Playground

Free, no licence, and the environment was originally written against it.

1. Log in at edaplayground.com with a Google account. Aldec Riviera-PRO needs
   no extra licence step.
2. Language **SystemVerilog**, tool **Aldec Riviera-PRO**, and turn on the
   **UVM** option. Any offered UVM version works: this environment only uses
   constructs stable since UVM 1.1 (`uvm_component_utils`, `uvm_object_utils`,
   the sequencer/driver/monitor base classes, `uvm_analysis_port`,
   `uvm_analysis_imp`).
3. Add the source files in this order. Dependencies flow top to bottom:
   `rv32i_pkg.sv` first because everything imports it, `retire_if.sv` before
   the UVM package that declares `virtual retire_if.MON`, and
   `mem_backdoor_bind.sv` after both `imem.sv` and `mem_backdoor_if.sv`.

```
rtl/rv32i_pkg.sv     rtl/cells.sv        rtl/regfile.sv     rtl/alu.sv
rtl/extend.sv        rtl/retire_if.sv    rtl/controller.sv  rtl/hazard_unit.sv
rtl/csr_file.sv      rtl/clint.sv        rtl/uart_tx.sv     rtl/mem_bus.sv
rtl/datapath.sv      rtl/debug_fsm.sv    rtl/riscv_pipe.sv  rtl/dmem.sv
rtl/imem.sv          rtl/reset_sync.sv   rtl/top.sv
verif/uvm/rv32i_if.sv           verif/uvm/mem_backdoor_if.sv
verif/uvm/mem_backdoor_bind.sv  verif/uvm/rv32i_uvm_pkg.sv
verif/uvm/tb_uvm_top.sv
```

   Drop the directory prefixes but keep the filenames. You do not need
   `rtl/tb_pipe.sv` or the `golden_vals_pipe*.svh` files; those belong to the
   directed tests.

4. Add `stream.hex` and `stream_trace.txt` as plain files in the same flat
   list. No C files and no DPI-C: the reference is precomputed, so there is
   nothing to compile and no "enable DPI" toggle to find.
5. Top module `tb_uvm_top`. `run_test("rv32i_random_test")` is hardcoded, so no
   `+UVM_TESTNAME` is needed. Click **Run**.
6. For waveforms, tick **Open EPWave after run**; `tb_uvm_top.sv` already has
   the `$dumpfile`/`$dumpvars` block.

## Stimulus

`stream.hex` and `stream_trace.txt` are generated together and must stay
together. The scoreboard checks the DUT against a trace computed for that exact
program, so a mismatched pair checks nothing at all.

```bash
cd verif/spike
SPIKE=/path/to/spike ./gen_stream.py --seed 1 --num-instr 40
```

Program length is a generation-time argument, not a runtime plusarg, for the
same reason. `+STREAM=<file>` and `+TRACE=<file>` select which generated pair
to run, and must be changed as a pair.

## What success looks like

```
UVM_INFO ... [SCOREBOARD] loaded 133 reference retirements from stream_trace.txt
UVM_INFO ... [DRIVER] backdoor-loaded 147 instruction words
UVM_INFO ... [SCOREBOARD] sentinel retired -- 133 instructions checked, 0 mismatches
UVM_INFO ... [TEST] DONE -- 133 of 133 retirements checked, 0 mismatches
UVM_INFO ... [TEST] *** UVM TEST PASSED ***
RV32I_UVM_VERDICT: PASS
```

Things worth reading rather than skimming past:

- **`[BADTRACE]`** means `stream_trace.txt` is malformed or predates the store
  columns, so the run stops immediately. Regenerate the trace.
- **`[PC_MISMATCH]`, `[INSTR_MISMATCH]`, or `[TRACE_OVERRUN]`** means the RTL
  retirement stream diverged from the reference. Checking stops at the first
  divergence rather than emitting hundreds of meaningless follow-on errors.
- **`[TIMEOUT]`** means the core never retired the sentinel. Usually the
  program ran off the end of what was backdoor-loaded.
- **`[STORE_MISMATCH]`** compares only the architecturally-stored bits, masked
  by the store width, so a `0x000000ff` mask means an SB and only the low byte
  was compared.

A `[PC_MISMATCH]` or `[REG_MISMATCH]` is either a real RTL bug or a bug in this
environment. Given it has never run, assume the second until shown otherwise.

## Deliberately not done

- **JAL/JALR/LUI/AUIPC/SYSTEM** in the generated stream. The current stream is
  R-type, I-type ALU, LOAD, STORE and forward-only BRANCH only, so this
  environment does not exercise the CSR/trap/interrupt machinery at all;
  `tb_pipe_csr` is the directed test that covers it.
- **Constrained-random generation** in the sequence instead of Python
  generation. Costs Starter Edition support, and would need the program and the
  Spike reference to be generated together some other way.
- **Functional coverage**, a covergroup on instruction class by forwarding path
  by stall/flush reason. Also costs Starter Edition support.
