# RV32I core: design guide

A 5-stage pipelined RV32I core with M-mode CSRs, synchronous traps, a machine
timer interrupt, external debug halt/resume, and two memory-mapped peripherals.
This document describes the machine as it stands and why each decision is what
it is.

For how it came to be that way, including the bugs found along the route and
what found them, see [JOURNAL.md](JOURNAL.md). That separation is deliberate:
this file should be readable by someone who has never seen the project before,
without having to reconstruct its history first.

## Contents

1. [Scope](#1-scope)
2. [Structure](#2-structure)
3. [The pipeline](#3-the-pipeline)
4. [Hazards](#4-hazards)
5. [CSRs, traps and interrupts](#5-csrs-traps-and-interrupts)
6. [External debug](#6-external-debug)
7. [Memory map](#7-memory-map)
8. [Verification](#8-verification)
9. [Limitations](#9-limitations)
10. [Running it](#10-running-it)

---

## 1. Scope

Full RV32I plus Zicsr, M-mode only. Every base integer instruction, the six
branch conditions, all load/store widths with correct sign and zero extension,
JAL/JALR/LUI/AUIPC, and the CSR read-modify-write instructions with their
immediate variants.

Traps: illegal instruction, ECALL, misaligned load address, misaligned store
address, and the machine timer interrupt. `mret` returns from all of them.

Not implemented, deliberately: S-mode, U-mode, PMP, the M extension, compressed
instructions, vectored `mtvec`, and software or external interrupts. Section 9
covers these with reasons.

## 2. Structure

```
top.sv
├── riscv_pipe.sv          structural: wires the four blocks below
│   ├── controller.sv      combinational decode, ID stage
│   ├── hazard_unit.sv     forwarding, stalls, flushes
│   ├── datapath.sv        pipeline registers, regfile.sv, csr_file.sv,
│   │                      alu.sv, extend.sv, cells.sv
│   ├── debug_fsm.sv       halt/resume state
│   └── retire_if.sv       commit tap, verification only
├── imem.sv                instruction memory
└── mem_bus.sv             address decoder
    ├── dmem.sv            RAM
    ├── clint.sv           timer
    └── uart_tx.sv         transmit-only UART
```

`rv32i_pkg.sv` holds every named constant and the ID/EX control bundle. Every
other file imports it, and it is the only place opcodes, ALU codes, CSR
addresses, trap causes and MMIO base addresses are written down.

Control and hazard logic are deliberately separate modules from the datapath
rather than nested inside it. `datapath.sv` takes control and hazard signals as
inputs and computes neither. `hazard_unit.sv` is the file to read first if you
want to understand where the complexity actually lives.

## 3. The pipeline

IF → ID → EX → MEM → WB, with a pipeline register between each stage.

Signals carry a stage suffix: `PCF`, `InstrD`, `ALUResultE`, `ReadDataM`,
`ResultW`. This is Harris & Harris's convention and it is not cosmetic. With
five instructions in flight, the suffix is how you keep straight which
instruction a signal refers to. It is kept in preference to the lowRISC style
guide's `_d`/`_q` convention, which is designed for a single register rather
than a five-deep pipeline.

### Where each instruction class resolves

This decision has the most downstream consequences, so it is worth being
explicit about.

| Class | Resolves in | Bubbles on redirect |
|---|---|---|
| Branch, JALR | EX | 2 |
| JAL | ID | 1 |
| Trap, `mret`, debug entry/exit | EX | 2 |

Branches and JALR resolve in EX because they need forwarded operands: a branch
may compare against a value produced by the immediately preceding instruction,
and JALR needs an actual register value. Neither is available combinationally in
ID. The cost is that when one is taken, two already-fetched instructions are
wrong-path.

JAL resolves in ID because its target is `PC + imm` with no register dependency,
so there is no reason to wait. One bubble instead of two.

LUI passes its immediate through the ALU using a `PASSB` operation rather than
getting a dedicated writeback source. The alternative means carrying `ImmExt`
through three extra pipeline registers to serve one instruction.

### The PC mux

Priority, highest first:

```
EnterDebug > ExitDebug > trap_en > mret_enE > PCSrcE > JumpD > sequential
```

A halt request beats a simultaneously resolving branch. A trap beats a branch
resolving in the same instruction, which is what precise-exception semantics
requires: the branch is the instruction being excepted.

## 4. Hazards

### Forwarding

`SelectAE` and `SelectBE` steer the EX-stage ALU operands away from a stale
register-file read:

| Value | Source | Meaning |
|---|---|---|
| `FWD_NONE` (00) | `RD1E`/`RD2E` | no hazard, the regfile read is current |
| `FWD_MEM` (10) | `ALUResultM` | producer is in MEM, distance 1 |
| `FWD_WB` (01) | `ResultW` | producer is in WB, distance 2 |

MEM is checked before WB, because when both match, MEM holds the more recent
producer.

Store data needs identical treatment and is easy to forget: the value a store
writes to memory is just another consumer of `rs2`. `WriteDataE` feeds both the
ALU's B input and the EX/MEM store-data register, regardless of `ALUSrc`.

### Distance 3, and why the register file has a bypass

Forwarding covers distance 1 and 2, measured to a consumer in EX. The register
file is read in ID, one stage earlier. At distance 3 the producer is in WB while
the consumer is still in ID, so a plain write-on-posedge register file returns
the stale value, and by the time the consumer reaches EX the producer has
retired and no forwarding path sees it either.

`regfile.sv` closes the gap with a read-during-write bypass: an ID read
targeting the register being written this cycle returns the write data
directly. Harris & Harris instead clock the write on the falling edge so it
lands mid-cycle. The bypass is preferred here because it keeps the file
synthesisable as ordinary single-edge logic.

This is not a corner case. Distance-3 RAW is what ordinary compiled code looks
like.

### Load-use stall

Forwarding cannot produce data that does not exist yet. A load's result is not
available until MEM, one cycle later than EX-stage forwarding can supply it. If
the D-stage instruction reads the destination of a load currently in EX, the
pipeline stalls one cycle: freeze `PCF` and IF/ID via `StallF`/`StallD`, and
insert a bubble into ID/EX via `FlushE`.

Detection is gated by `Rs1UsedD`/`Rs2UsedD` from `controller.sv`. JAL, LUI,
AUIPC and the immediate-form CSR instructions reuse the `rs1`/`rs2` bit
positions as immediate bits, so without the gate an immediate that happens to
collide numerically with a preceding load's destination register would stall
spuriously. Worse, `StallF` freezing `PCF` on the cycle a JAL needs to redirect
it would silently drop the jump.

### Flushes

```
FlushD  (IF/ID  -> NOP)   : PCSrcE | JumpD | EnterDebug | ExitDebug | trap_en | mret_enE
FlushE  (ID/EX  -> bubble): PCSrcE | lwStallD | EnterDebug | ExitDebug | trap_en | mret_enE
FlushM  (EX/MEM -> bubble): EnterDebug | trap_en
```

`FlushD` and `FlushE` fire on every event that redirects the PC away from
sequential fetch. Whatever was fetched under the sequential assumption is
wrong-path and must be squashed.

`FlushM` is different and fires on only two of them. It exists to stop the
EX-stage instruction from committing its *own* `RegWrite`/`MemWrite`. A trapping
instruction must not commit because it excepted or was interrupted. A halting
instruction must not commit because `dpc = PCE` means it will re-execute for
real after resume. `mret` and `dret` are pure control transfers with no state
write of their own, so they are excluded.

The injected bubble is the real NOP encoding `32'h00000013` (`ADDI x0,x0,0`),
not all-zeros, which would decode as a LOAD opcode and do something.

## 5. CSRs, traps and interrupts

`csr_file.sv` implements `mstatus` (MIE and MPIE only), `mie`/`mip` (MTIE and
MTIP only), `mtvec` (direct mode only), `mepc`, `mcause`, `mtval`, `mscratch`
and `mhartid`.

### CSR writes commit at EX

Every other piece of committed state in this pipeline commits from a registered,
one-stage-later signal, specifically so `FlushM` can squash it. CSR writes do
not follow that pattern: they commit directly from EX-stage combinational logic,
gated by an explicit `~EnterDebug & ~trap_en` term instead.

This is a deliberate simplification. Only one instruction occupies EX per cycle
in an in-order pipeline, so there is no WAW risk, and threading `csr_we`/
`csr_wdata` through EX/MEM purely to reuse the squash mechanism would be more
code for no behavioural difference. The gate lives in `datapath.sv` rather than
inside `csr_file.sv`, because it is the caller that knows about debug and traps.

If you extend this CSR file, that gate is the one place a new CSR-writing path
can silently reintroduce a debug-preemption bug.

The CSR read-modify-write value is computed in a small dedicated mux rather than
the main ALU: CSRRC needs an AND-with-inverted-operand that the ALU has no
control code for, and adding one would grow a shared resource to serve one
instruction.

### `validE`

A 1-bit register, separate from the control bundle, that is 0 exactly when this
cycle's ID/EX load was a flush-inserted bubble.

Exception detection does not strictly need it, because the control bundle
already defaults to "do nothing" on a bubble. The timer interrupt does: its
condition depends on global `mstatus`/`mie`/`mip` state rather than on what is
in EX. Without the gate, an interrupt landing on a bubble cycle right after a
flush would capture `mepc = 0` or a stale PC instead of a real resumable
address.

`validE` is carried forward as `validM` and `validW`, and `validW` is what a
monitor must gate on. It is not derivable from `InstrW`, because a real program
can contain a genuine `ADDI x0,x0,0`, bit-identical to a flush-inserted bubble.

### Trap priority

Illegal instruction, then ECALL, then misaligned store, then misaligned load,
then the timer interrupt. Synchronous exceptions beat the interrupt because the
faulting instruction cannot complete.

### The handler rule that is easy to get wrong

A synchronous exception's faulting instruction genuinely cannot complete.
`mepc` points at it, and if the handler `mret`s without advancing past it the
core re-faults forever. The handler must do `mepc += 4`.

An interrupt is different. It preempts an instruction that would otherwise have
executed correctly. `mepc` points at that not-yet-executed instruction and the
handler must leave it alone, so `mret` resumes exactly where it left off.

`testgen/program_csr.py`'s handler branches on `mcause[31]` to give the two
paths different epilogues. The interrupt path also defers `mtimecmp`, so the
condition does not immediately refire when `mret` restores `mstatus.MIE`.

## 6. External debug

`debug_fsm.sv` is a two-state machine: running, or parked at the debug halt
address. Entry is on an external request or an EBREAK; exit is on DRET, which
resumes at `dpc`.

The pipeline question the single-cycle original does not have to answer is
*which* in-flight PC to snapshot. The answer here is `PCE`, the EX-stage PC.
Entering debug squashes the two youngest in-flight instructions, in D and E,
while whatever is in M and W completes normally because it is already committed.

`is_ebreak` and `is_dret` are decoded once in ID and pipelined into EX. That has
a useful consequence for free: if an EBREAK is flushed by an earlier branch
misprediction before it would have retired, its control bits are zeroed by that
same flush, so a never-really-executed EBREAK correctly never halts the core.

Debug entry and exit are symmetric in the flush logic. Both appear in `FlushD`
and `FlushE`, because both redirect the PC from EX. Only entry appears in
`FlushM`, because only entry has an instruction of its own to suppress.

## 7. Memory map

`mem_bus.sv` presents exactly `dmem.sv`'s interface upward, so neither
`riscv_pipe.sv` nor `datapath.sv` knows the peripherals exist.

| Range | Target |
|---|---|
| `[0, RamBytes)` | RAM, `dmem.sv`, 16 KB by default |
| `[0x0002_0000, +0x10)` | CLINT: `mtime` at +0x0, `mtimecmp` at +0x4 |
| `[0x0003_0000, +0x10)` | UART: `txdata` at +0x0, `status` at +0x4 |
| anything else | reads return RAM's out-of-range output; writes are dropped |

Instruction and data memory are separate arrays both based at 0. The core is
Harvard. This matters for verification and is covered in section 8.

Both peripherals are deliberately simplified. The CLINT is 32-bit where real
ones are 64-bit, and `mtime` increments once per clock cycle. The UART is
transmit-only with an instant-transmit model: `status` bit 0 is always 1 and
there is no baud model.

## 8. Verification

Three layers, checking different things.

### Directed tests

`rtl/tb_pipe.sv` holds three self-checking testbenches, run by `run_sim.sh`
under both Icarus Verilog and Verilator.

- `tb_pipe_hazard` runs a program isolating each hazard category: back-to-back
  RAW, two-apart RAW, load-use, store-data forwarding, taken branch followed by
  dependent instructions, JAL followed by a dependent instruction, and a write
  to `x0` followed by use of `x0` as an operand. Diffs all 32 registers plus two
  memory words.
- `tb_pipe_debug` runs a two-instruction loop with a `dret` stub at 0x0C,
  asserts halt mid-loop, and confirms resume and forward progress.
- `tb_pipe_csr` runs CSR read/write semantics, an ECALL trap, an illegal
  instruction trap, a misaligned load, a misaligned store, UART writes and a
  timer interrupt. Diffs all 32 registers and independently monitors the UART
  byte stream at the top-level ports.

Both simulators are run deliberately, not out of caution. They disagree about
uninitialised memory: Verilator reads 0, Icarus reads X. That difference is a
silent assumption baked into every result a single simulator gives you, and one
real bug in this project's history is invisible to Verilator for exactly that
reason. Green on one is not treated as green.

### Golden values

The expected register and memory contents come from Spike, RISC-V
International's reference simulator, via `verif/spike/gen_golden.py`. The
generated `.svh` files are committed, so running the regression needs no Spike;
only regenerating them does.

The reference is Spike rather than a model written alongside the RTL because a
golden model written by the same person as the design, from the same reading of
the specification, cannot catch a misreading of the specification. Both sides
express the same misunderstanding and the test passes carrying no information.

An assembler sits in that path too, and does real work beyond file format:
`gen_golden.py` builds an ELF from the same words the RTL's `imem` is loaded
with, which makes GNU binutils an independent check on `testgen/asm.py`'s
hand-rolled encodings.

### The UVM environment

`verif/uvm/` backdoor-loads a hazard-biased instruction stream and
lockstep-checks every retirement against a Spike trace. It has never been run;
see `verif/uvm/RUNNING.md` for how to, and for what that means.

Spike is not called from the simulator. `verif/spike/gen_stream.py` generates
the program and runs it through Spike ahead of time, emitting `stream.hex` and
`stream_trace.txt`. The testbench reads both as text. This is forced: the
environment's free run target compiles DPI C by upload, and Spike is a library
with boost and libfdt dependencies that cannot be uploaded, so a live
Spike-over-DPI bridge would leave the environment with no way to run at all.

Generating the program in the same place as the reference then follows. Two
generators seeded independently would drift apart and the comparison would mean
nothing.

Per retirement the scoreboard checks the PC, the instruction word, the register
write, and the store address and data. It is indexed by retirement count, so a
divergence in PC or instruction is treated as terminal: reported once, then
checking stops, because every later index would be meaningless.

### Where the trust boundary sits

Everything with a specification comes from Spike: every instruction, every CSR
side effect, trap cause encoding, trap priority, `mstatus` stacking, `mret`.

Two things cannot. `clint.sv` and `uart_tx.sv` are project-specific peripherals
with no standard to conform to, so `verif/spike/rvproj_devices.cc` models them
for Spike. That is a restatement of a design decision rather than an independent
claim about correctness, and it is about 60 lines with no branching semantics.
It is the smallest surface that keeps the timer and UART coverage.

`tb_pipe_debug` has no golden values at all, because debug halt/resume is not
architectural state and no ISS models it.

### The model-difference table

The naive picture of co-simulation is "run both, diff the answers." The actual
work is enumerating every way two models can legitimately differ and either
eliminating it or excluding it from the comparison. For this project:

| Difference | How it is handled |
|---|---|
| Harvard versus von Neumann memory | data window placed past the code image |
| Uninitialised data memory, 0 versus X | prologue stores zeros before any load |
| Spike's boot ROM leaves registers set | prologue zeros `x2`–`x30` |
| Spike's boot ROM retirements | trimmed from the trace |
| Spike's debug module and boot ROM sit at address 0 | two `platform.h` constants relocated |
| CLINT and UART do not exist in Spike | MMIO plugin, `rvproj_devices.cc` |
| `mtime` counts cycles versus instructions | tests assert final state, not timing |
| Debug halt/resume is not architectural | no reference model, separate test |

Every one of those is a place where a passing test could have meant nothing.
That table is the co-simulation environment. The diff is trivial by comparison.

## 9. Limitations

Stated once, here, rather than scattered.

**Privilege and memory.** M-mode only. No S-mode, U-mode or PMP. This is a
defensible scope: plenty of real embedded RISC-V cores ship M-mode only.

**Interrupts.** Only the machine timer is wired up. `mie`/`mip`'s MSIP and MEIP
bits do not exist. `mtvec` stores its low two bits but always behaves as direct
mode.

**Illegal-instruction coverage is coarse.** An unrecognised opcode, or an
unrecognised `funct3`/`funct12` under SYSTEM, traps. A bogus `funct7` on a known
R-type opcode does not. Full coverage is a much larger decode surface for
comparatively little payoff at this scale.

**No branch prediction.** A static predictor would reuse the flush-and-redirect
mechanism that already exists, so it is a bounded addition rather than a
redesign.

**No M extension, no compressed instructions.** RV32IC in particular is a
different fetch and decode shape entirely.

**Coverage is unmeasured.** The directed programs exercise what section 8
describes and nothing else, so "these three pass" is not "the ISA is correct."

**The official compliance suite has not been run.** `riscv-arch-test` via RISCOF
is the highest-value next step and is no longer blocked: a RISC-V cross-compiler
is available and the core survives real compiled code now that the distance-3
hazard is fixed.

**The UVM environment has never been executed.** Not by a simulator, not by an
elaborator. Assume it is wrong until it runs.

## 10. Running it

```bash
cd rtl && ./run_sim.sh          # all three testbenches, both simulators
./run_sim.sh verilator hazard   # or narrow it
```

`run_sim.sh` passes `-DRTL_ONLY_NO_CLOCKING`, which both free simulators need in
order to skip `retire_if.sv`'s clocking block. Verilator rejects `modport
clocking` and Icarus cannot parse a clocking block inside an interface at all.
The guard is keyed on what the compile is for rather than on tool name, because
an `ifndef VERILATOR` would have left Icarus broken and per-tool macros grow a
branch per simulator.

Regenerating golden values needs Spike:

```bash
cd verif/spike
SPIKE=/path/to/spike ./regen.sh
```

See `verif/spike/README.md` for building Spike, including the two `platform.h`
constants that have to move because this core resets to PC 0.

For the UVM environment, see `verif/uvm/RUNNING.md`.
