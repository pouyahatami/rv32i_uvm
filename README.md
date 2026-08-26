# RV32I pipelined core

A 5-stage pipelined RV32I CPU in SystemVerilog, with M-mode CSRs, synchronous
traps, a machine timer interrupt, external debug halt/resume, and two
memory-mapped peripherals. Verified against
[Spike](https://github.com/riscv-software-src/riscv-isa-sim), RISC-V
International's reference simulator.

```bash
cd rtl && ./run_sim.sh
```

Runs three self-checking testbenches under both Icarus Verilog and Verilator,
whichever are installed. All three pass on both. Both simulators are used
because they disagree about uninitialised memory, and one of the RTL bugs found
here is invisible to Verilator for that reason.

## Layout

```
rtl/           the core, its directed testbenches, and the test-program
               generator (testgen/).

verif/spike/   the reference model. Spike generates the golden values every
               directed testbench checks against, plus the UVM environment's
               instruction stream and expected retirement trace.

verif/uvm/     the UVM environment: hazard-biased instruction generation,
               backdoor program loading, a scoreboard that lockstep-checks
               every retirement against Spike, and functional coverage.

verif/sva/     assertions for the forwarding, interlock and flush logic, bound
               into riscv_pipe so the synthesizable RTL is never touched by
               verification code.

docs/          DESIGN_GUIDE.md, how the core works and why.
               VMATRIX.md, each feature against what stimulates and checks it.
               BUGS.md, every defect found, its root cause, and its guard.
```

## The UVM environment

![UVM environment: Spike generates the program image and expected retirements ahead of the run, the driver backdoor-loads the program, the monitor samples one transaction per retirement from a read-only tap, and the scoreboard compares against Spike in order](images/uvm_env.png)

Spike runs once, before simulation. The DUT is the unmodified core: the
retirement tap is read-only, and verification-only interfaces attached with
`bind` load the program and clear data memory while reset is asserted, so no
port or reset network is added to the synthesizable memories.

```bash
cd verif/uvm && ./run_uvm.sh        # one seed
cd verif/uvm && ./run_seeds.sh 30   # regression + cross-seed coverage
```

![RV32I UVM and Spike verification flow: generate a hazard-biased program, run Spike offline, load the program through the UVM driver, monitor DUT retirements, compare them in the scoreboard, and collect functional coverage](images/riscv_uvm_verification_flow.png)

Thirty seeds pass with zero mismatches, zero `UVM_ERROR` and zero simulator
errors, checking 49 to 76 instructions each against Spike. Per seed they reach
39 to 76 percent of the 93-bin coverage model; across the thirty, every bin is
hit.

That union measures stimulus quality, not ISA closure. The model bins the
instruction mix, the decoded ALU operation, memory widths, writeback operand
corners, and dependency distance against instruction type, which is what the
generator controls. It has no bins for CSRs, traps, interrupts or debug,
because the random stream does not reach them.
[docs/VMATRIX.md](docs/VMATRIX.md) records which checker covers each of those
instead.

A seed passes only if the UVM verdict is PASS *and* the simulator's own error
count is zero. Bound-assertion failures land in the second count, not the
first, and the regression's failure path is itself verified by a seeded
always-false assertion ([BUGS.md](docs/BUGS.md), V12).

![UVM report summary from a single-seed run: 0 errors, 0 warnings](images/uvm_run.png)

## What is checked

Every retirement is compared against Spike, in order, on four axes: the PC, the
instruction word, the register writeback, and the store address and data. A
divergence in PC or instruction is terminal, because once the two sides are out
of step every later comparison is meaningless.

Coverage is a plain-SystemVerilog bin tally, so it reports on any simulator,
with parallel `covergroup` blocks behind `` `ifdef RV32I_COVERAGE `` for
licensed tools. The regression names each unhit bin rather than leaving it
inside a percentage.

This is an RTL and verification project. It stops at the RTL boundary, with no
SDC, floorplan or STA.

## Where the trust boundary sits

Golden values come from Spike rather than from a model written alongside the
RTL. A reference written by the same person as the design, from the same
reading of the specification, cannot catch a misreading of it: both sides
express the same misunderstanding and the test passes anyway. Spike is
maintained by RISC-V International and is what the official compliance suite
uses to generate its reference signatures, so a disagreement between Spike and
this core is evidence about the core.

`clint.sv` and `uart_tx.sv` sit outside that boundary. They are
project-specific peripherals with no standard to conform to, so a small Spike
MMIO plugin models them: about 60 lines with no branching semantics.
[DESIGN_GUIDE.md](docs/DESIGN_GUIDE.md) section 8 has the full table of
legitimate model differences.

## Regenerating golden values

The `.svh` golden-value files in `rtl/` are committed, so the regression needs
no Spike. Regenerating them does:

```bash
cd verif/spike
SPIKE=/path/to/spike ./regen.sh
```

`run_seeds.sh` also needs Spike. Spike has no Windows build, so the script
invokes WSL to generate each seed's program and trace, then simulates natively
on Windows. `run_sim.sh` and `run_uvm.sh` need no Spike, since their stimulus
is committed. See `verif/spike/README.md` for building Spike, including the two
platform constants that have to move because this core resets to PC 0.
