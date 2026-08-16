# Viewing waveforms

This project's standard local waveform flow is two free, open-source tools:
**Icarus Verilog** (simulates the RTL and writes a `.vcd` file) and
**GTKWave** (opens that `.vcd` file as a timing diagram). Both are now
installed on this machine at `C:\iverilog\bin` and
`C:\iverilog\gtkwave\bin`, and both directories were added to your user
`PATH` — open a **new** terminal for `iverilog`, `vvp`, and `gtkwave` to be
directly runnable (an already-open terminal won't pick up the PATH change).

Everything below uses `tb_pipe_hazard` as the example, but the same
commands work for `tb_pipe_debug` and `tb_pipe_csr` — just swap the `-s`
target and the `$dumpfile` name (see `rtl/tb_pipe.sv`'s header comment).

## 1. Compile with waveform dumping turned on

From `rtl/`:

```bash
iverilog -g2012 -DRTL_ONLY_NO_CLOCKING -DDUMP_VCD \
    -o build/iv_hazard_wave -s tb_pipe_hazard \
    rv32i_pkg.sv cells.sv regfile.sv alu.sv extend.sv retire_if.sv \
    controller.sv hazard_unit.sv csr_file.sv datapath.sv debug_fsm.sv \
    riscv_pipe.sv dmem.sv clint.sv uart_tx.sv mem_bus.sv imem.sv top.sv \
    tb_pipe.sv
```

Two flags matter here beyond what `run_sim.sh` normally passes:

- `-DRTL_ONLY_NO_CLOCKING` — always required for Icarus; skips a
  `clocking`/`modport` construct in `retire_if.sv` that Icarus can't parse.
  `run_sim.sh` already passes this for you; a manual `iverilog` command has
  to add it back.
- `-DDUMP_VCD` — the one that actually matters for this guide. It's an
  `` `ifdef `` around the `$dumpfile`/`$dumpvars` block in each testbench
  module in `tb_pipe.sv`, **off by default** so the everyday pass/fail
  regression doesn't pay the cost of writing a waveform file every run.
  Pass it and the testbench writes `build/wave_hazard.vcd` (or
  `wave_debug.vcd` / `wave_csr.vcd` for the other two).

## 2. Run it

```bash
vvp build/iv_hazard_wave
```

You'll see the usual `PASS`/`FAIL` line, plus a new line like:

```
VCD info: dumpfile build/wave_hazard.vcd opened for output.
```

That file now exists at `rtl/build/wave_hazard.vcd`.

## 3. Open it in GTKWave

```bash
gtkwave build/wave_hazard.vcd
```

## 4. Reading the window

- **Left pane (SST/hierarchy tree)**: click down through
  `tb_pipe_hazard → dut → rvpipe → ...` to find the module whose signals you
  want (e.g. `hazard_unit` for `ForwardAE`/`StallF`/`FlushD` signals,
  `datapath` for `PCF`/`InstrD`/pipeline register contents).
- **Signals pane**: signals inside whatever module is selected on the left.
  Select the ones you want, right-click → **Insert**, or drag them into the
  waveform pane.
- **Waveform pane (right)**: the actual timing diagram. Each row is one
  signal; each column position is a point in simulation time. Use the
  toolbar's zoom-in/zoom-out/zoom-fit icons, or scroll, to navigate.
- **Time markers**: click anywhere in the waveform pane to drop the primary
  cursor; the value of every displayed signal at that instant shows in the
  narrow value column just left of the waveform pane.

## What to actually look for

Straight from `docs/COURSE.html` Chapter 9 — the vocabulary that makes a
waveform readable on this specific core:

- **Rising-edge sampling.** Every register updates on `posedge clk`. Read
  each signal's value *between* two clock edges — mid-cycle wiggles are
  just combinational logic settling, not new state.
- **X means unknown, not zero.** Icarus is a 4-state simulator, so any bit
  that's never been driven shows as `x` — expected for a while after reset,
  not automatically a bug.
- **A stall looks like a repeated value.** When `StallF`/`StallD` assert,
  `PCF` and `InstrD` hold their previous value for an extra clock edge
  instead of advancing.
- **A flush looks like a value jumping to `0x00000013`** — this design's
  injected-bubble NOP encoding (deliberately not all-zeros, which would
  decode as a `LOAD`).
- **A forward looks like a value arriving one cycle earlier than the
  register file alone could have supplied it** — that's the entire reason
  forwarding logic exists. Concretely, in the `tb_pipe_hazard` program, look
  around cycle 3-4 for `ForwardAE`/`ForwardBE` reading `2` (`FWD_MEM`) on
  `ADD x2,x1,x1`, then `1` (`FWD_WB`) a cycle later on `ADD x3,x2,x1`.

## Useful signals to add first

For hazard/forwarding work (`hazard_unit.sv`, `datapath.sv`):
`PCF`, `InstrD`, `ForwardAE`, `ForwardBE`, `StallF`, `StallD`, `FlushD`,
`FlushE`, `FlushM`, `PCSrcE`.

For CSR/trap/interrupt work (`tb_pipe_csr`):
`trap_en`, plus the same `Flush*` signals — check that `trap_en` pulses on
the interrupt path with no following `FlushM`, unlike the exception path
(see `docs/DESIGN_GUIDE.md`'s note on that asymmetry).

## Notes

- `build/` is not committed — regenerate the `.vcd` locally whenever you
  need it; don't check waveform files into git.
- There's also `verif/wave/vcd_extract.py`, which turns a `.vcd` into a
  plain-text per-cycle CSV (useful for diffing two runs or grepping a
  signal's history without a GUI). It only reads an existing `.vcd`, so
  step 2 above still has to happen first:
  ```bash
  python3 verif/wave/vcd_extract.py --vcd rtl/build/wave_hazard.vcd \
      --clock clk --signals PCF,InstrD,ForwardAE,ForwardBE,StallF,FlushD \
      --out trace_hazard.csv
  ```
