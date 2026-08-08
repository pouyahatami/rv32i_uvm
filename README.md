# RV32I CPU: single-cycle → 5-stage pipeline → CSRs/traps/interrupts/UART

Orientation doc only — this explains the directory layout. For the full
design writeup (architecture, verification methodology, what's been
built and why, known limitations) see `docs/DESIGN_GUIDE.md`.

## Layout

```
rtl/        current RTL — 5-stage pipelined RV32I core, external-debug
            halt/resume, M-mode CSRs, synchronous trap/exception
            handling, a machine-timer interrupt, and a memory-mapped
            UART. This is "the project" — everything else here either
            feeds it (iss/) or documents it (docs/).

verif/spike/ the reference model. Spike (riscv-isa-sim) generates the
            golden register/memory values every self-checking testbench in
            rtl/ diffs against, plus the UVM environment's instruction
            stream and expected retirement trace. Replaced a hand-written
            C++ ISS that used to live in iss/ -- see that directory's
            README.md for why, and DESIGN_GUIDE.md Section 11.

docs/       DESIGN_GUIDE.md -- the detailed writeup: architecture,
            every hazard/timing decision and why it's correct, the real
            bugs caught during construction, verification methodology
            (including what's actually been run vs. only statically
            reviewed), and what's explicitly out of scope.

verif/uvm/  a real UVM environment: randomized, hazard-biased
            instruction generation, backdoor program loading, and a
            scoreboard that lockstep-checks every retiring instruction
            against iss/ over DPI-C. Not yet run in a real simulator --
            see EDA_PLAYGROUND_SETUP.md in that directory for how to run
            it (free, no license needed), and DESIGN_GUIDE.md Section 9
            for the architecture and what's been verified about it so
            far (elaborated clean against the real Accellera UVM library,
            not run).
```

## Status

`rtl/` passes all three directed testbenches (`hazard`, `debug`, `csr`)
under both Icarus Verilog and Verilator. Getting there found two real RTL
bugs that had survived every static review — a distance-3 RAW hazard
reading stale registers, and `dret` failing to flush the wrong-path
instructions behind it. Both are written up in `docs/DESIGN_GUIDE.md` §10,
and both are demonstrated to fail the regression when deliberately
re-seeded.

The golden values those testbenches check against now come from Spike
rather than a hand-written ISS (§11). Spike reproduced the old ISS's
values exactly, so nothing about the passing result changed — what changed
is that the reference is no longer written by the same person as the
design.

The RTL regression has been re-run against the Spike-generated golden
values: all three testbenches pass on both simulators.
`verif/spike/gen_stream.py` runs clean and produces `verif/uvm/stream.hex`
plus `stream_trace.txt`.

**Not done, and honest about it:**

- The UVM environment's sequence and scoreboard were rewritten for the
  Spike trace and have **not been elaborated or run by anything** — no
  simulator here supports UVM. See the honesty note at the top of
  `verif/uvm/EDA_PLAYGROUND_SETUP.md`. Given that this project has now
  produced four real bugs that all survived careful reading, assume it is
  wrong until it runs.
- Functional coverage is unmeasured, and the official `riscv-arch-test`
  compliance suite has not been run (unblocked — §10.7).

There's no `archive/` — the earlier single-cycle and pipeline-without-CSR
milestones that used to be kept as separate snapshots were dropped. That
work is fully absorbed into `rtl/` (which is the pipelined, CSR/trap/
interrupt/UART-complete core); if you want that history, it's in the
narrative of `docs/DESIGN_GUIDE.md`, not as duplicate source trees.

## Regenerating golden values

The `.svh` golden-value files in `rtl/` are checked in, so running the RTL
regression needs no Spike. Regenerating them does:

```bash
cd verif/spike
SPIKE=/path/to/spike ./regen.sh
```

Do this after changing any test program in `rtl/testgen/`. See
`verif/spike/README.md` for building Spike, including the two platform
constants that have to move because this core resets to PC 0 and Spike
reserves the bottom of the address space for itself.

## Building and running

```bash
cd rtl && ./run_sim.sh          # all three testbenches, both simulators
```

`run_sim.sh` runs whichever of Icarus Verilog and Verilator is installed,
and reports PASS/FAIL per testbench. Both currently pass all three. Running
both is deliberate, not belt-and-braces: they disagree about uninitialised
memory, and one of the two RTL bugs found here is invisible to Verilator
for exactly that reason — see `docs/DESIGN_GUIDE.md` §10.3.

The ISS builds and runs with a plain C++17 compiler, no special toolchain
needed. See `docs/DESIGN_GUIDE.md` §6 and §8.4 for the underlying
`iverilog`/`g++` command lines and the golden-value generator, §10 for what
simulation found, and `verif/uvm/EDA_PLAYGROUND_SETUP.md` for the UVM
environment — which still needs a UVM-capable simulator and has not run.
