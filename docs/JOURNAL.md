# Build journal

How this core got built, what broke, and what found each break. The design
itself is described in [DESIGN_GUIDE.md](DESIGN_GUIDE.md); this is the record of
arriving at it.

It is kept for one reason: every bug below survived careful reading, and the
pattern in *what* eventually caught each one is more useful than the bug list.

## The sequence

1. A from-scratch C++ RV32I instruction-set simulator, as the golden reference.
2. A 13-instruction textbook single-cycle core extended to full RV32I.
3. That core pipelined to five stages, with forwarding, stalling and flushing.
4. Debug halt/resume reintegrated into the pipeline.
5. A code-quality pass: a constants package, a packed control struct, and a
   commit/retire interface.
6. M-mode CSRs, traps, a machine timer interrupt, and a memory-mapped UART.
7. A UVM environment.
8. First real simulation, under Icarus Verilog and Verilator.
9. The hand-written ISS replaced by Spike.
10. A lowRISC style-guide retrofit.

Steps 1 through 7 were done with no SystemVerilog simulator available at all.
That constraint shapes everything below.

## Bugs found by reading

These were caught during construction, by manual review.

**The ALU's SLT overflow gate.** SLT reuses the subtract-and-check-sign
hardware, which needs an overflow correction (`sum[31] ^ v`). When the ALU
control encoding was widened from 3 to 4 bits, the "is this an add/sub-style
operation" gate initially covered only add and sub, not SLT. That produces wrong
SLT results at the signed boundary and correct results everywhere else. It is
the exact bug class that passes almost every random test and fails only when
comparing something like `INT_MIN` against `1`.

**The forwarding mux argument order.** `mux3` selects its first data input on
`00`, second on `01`, third on `10`. The forwarding muxes were wired
`(RD1E, ALUResultM, ResultW)`, but the hazard unit's encoding is `01` = forward
from WB, `10` = forward from MEM, so the two sources were swapped. Right number
of arguments, right names, wrong order. No compile error, wrong answers only
under a hazard.

**The missing `Rs1UsedD`/`Rs2UsedD` gate.** The load-use check compares register
numbers against `InstrD[19:15]` and `InstrD[24:20]` without knowing instruction
types. JAL, LUI and AUIPC reuse those bit positions as immediate bits. An
immediate that collided numerically with a preceding load's destination would
stall spuriously, and `StallF` freezing `PCF` on the cycle a JAL needed to
redirect it would silently drop the jump.

All three are wiring bugs, which is why the code-quality pass introduced
`rv32i_pkg.sv`. A typo'd named constant either fails to compile or is wrong in
exactly one place; a magic literal is silently plausible.

## What static elaboration caught

Partway through the CSR milestone, `pip install pyslang` worked, which meant a
real SystemVerilog elaborator was available for the first time.

It found two genuine forward-reference bugs that had been present since the
pipeline was written and were invisible because Icarus tolerates module-scope
forward references that stricter tools reject: `ResultW` used in `datapath.sv`
before its declaration, and `enter_debug` used in `riscv_pipe.sv` before its
declaration. Both fixed by moving the declaration earlier.

It also caught a hierarchical path that had rotted: `tb_pipe_hazard`'s backdoor
memory check used `dut.dmem.mem[...]`, which broke the moment `mem_bus.sv`
started sitting between `top.sv` and `dmem.sv`.

With those fixed, everything elaborated cleanly under `-Weverything`.

**That clean elaboration meant less than it felt like it did.** Two real RTL
bugs were sitting behind it. Static checking bought structure, and nothing about
behaviour.

## What running it caught

The first real simulation run was not green.

### Distance-3 RAW hazards read stale registers

`tb_pipe_hazard` failed with `x12 = 0x55, expected 0x77`. The failing sequence:

```
ADDI x10, x0, 4       <- producer
ADDI x11, x0, 0x77
SW   x11, 0(x10)
LW   x12, 0(x10)      <- consumer, three instructions later
```

`0x55` was the value the previous test case had stored at address 0, so the load
had gone to address 0 rather than 4, meaning it read `x10` as 0. The store
immediately before it used the same `x10` and went to the right place, which
pointed straight at producer-consumer distance.

Forwarding covers a producer in MEM or WB relative to a consumer in EX, so
distance 1 and 2. The register file is read in ID. At distance 3 the producer is
in WB while the consumer is still in ID, the write lands on that same edge, and
a plain combinational read returns the stale value. By the time the consumer
reached EX the producer had retired and no forwarding path saw it either.

`regfile.sv` had been inherited unchanged from the single-cycle design, where
the question cannot arise because there is no ID stage to be early. Pipelining
it never revisited that assumption. Its header comment still said "UNCHANGED by
the RV32I extension", which in hindsight reads as a warning.

Fixed with a read-during-write bypass. A distance-3 RAW dependency is what
ordinary compiled code looks like, so essentially any real program would have
hit this. It is also precisely the bug class the pipeline's whole verification
architecture was built to catch, and review had been over `hazard_unit.sv`
several times without finding it, because the bug is not in `hazard_unit.sv`. It
is in the gap between that file's stated coverage and an assumption buried in a
different file nobody had reason to re-read.

### `dret` never flushed the instructions behind it

`tb_pipe_debug` failed under Icarus with `x1 not advancing after resume`. The
core halted correctly, resumed correctly, then wedged.

`datapath.sv` redirects the PC to `dpc` on `ExitDebug`, but `ExitDebug` was
absent from both `FlushD` and `FlushE`. The two instructions already fetched
sequentially behind the `dret` were never squashed and executed for real after
the resume.

This is structurally identical to `mret_enE`, which *was* handled. `dret` is the
debug-mode spelling of the same "redirect the PC from EX" event. The debug
section had reasoned carefully about which stages to squash on debug *entry* and
never asked the same question about *exit*.

### Why two simulators

Bug 2 is the whole argument, and re-seeding it demonstrates rather than asserts
the point:

```
########## SEEDED: ExitDebug REMOVED from FlushD/FlushE ##########
  Icarus     debug : FAIL: x1 not advancing after resume (00000007 -> 00000007)
  Verilator  debug : PASS
```

Verilator does not catch it. The two simulators disagree about what the stray
fetches past the end of the program decode to. Verilator reads uninitialised
`imem` as 0, and `0x00000000` is an illegal opcode, so the core took an
illegal-instruction trap to `mtvec` = 0, which is the top of the test program,
so execution fell back into the loop and `x1` kept incrementing. The testbench
passed by luck, off the back of a trap handler firing for a bug that had nothing
to do with traps. Icarus is 4-state: those fetches read X, the PC went X, and
the core visibly wedged.

Neither tool is right. Real hardware would fetch whatever those addresses
physically contain, which is neither 0 nor X. The point is that a single
simulator's initialisation policy is a silent assumption baked into every result
it gives you, and the cheapest way to find where you are leaning on one is to
run a second tool that leans differently.

For symmetry: the seeded distance-3 bug is caught by both, which is what you
would expect for a bug in architectural data flow rather than in
initialisation-sensitive control.

### Two testbench bugs, which are not the same thing

Worth separating out, because a testbench failure that is the testbench's own
fault is the easiest way to "fix" a working design into a broken one.

**Sampled one delta-cycle too early.** Both `tb_pipe_hazard` and `tb_pipe_csr`
did `@(posedge clk)` and then read the register file array immediately. The last
instruction before `EBREAK` commits its write on exactly that edge as a
nonblocking assignment, which had not been scheduled yet. So the final register
read as its reset value and reported a mismatch against a perfectly correct DUT.
In the CSR test that register was the interrupt-preemption marker, which made it
look alarming and it was not. Fixed with a `#1` after the edge.

**The register file has no reset, and the simulators disagree about that too.**
`regfile.sv` is a RAM with no reset, which is correct hardware, and RISC-V does
not define reset values for `x1`–`x31`. Under Icarus every never-written
register reads X; under Verilator it reads 0, and the golden values expect 0.
Fixed in the testbench by forcing a known all-zero architectural start state.
Deliberately a testbench fix: adding a reset to `regfile.sv` would be inventing
hardware to satisfy a simulator.

### Portability changes

None affect behaviour, recorded so nobody rediscovers them.

| File | Change | Why |
|---|---|---|
| `rv32i_pkg.sv` | `ID_EX_CTRL_BUBBLE` written as a concatenation, not a named assignment pattern | Icarus 12 cannot parse named assignment patterns |
| `retire_if.sv` | clocking block and `MON` modport guarded by `RTL_ONLY_NO_CLOCKING` | Verilator rejects `modport clocking`; Icarus cannot parse a clocking block inside an interface |
| `tb_pipe.sv` | `fork`/`join_any` plus `disable` replaced by an independent watchdog block | Verilator cannot disable a named block from a sibling fork branch |
| `tb_pipe.sv` | `%p` on a queue replaced by element-by-element printing | Icarus rejects `%p` on a queue, aborting the run before the check could report |

## Replacing the ISS with Spike

Everything up to this point rested on one golden model: a from-scratch C++ RV32I
simulator written for this project. It was deleted.

### The argument

A golden model written by the same person as the RTL, from the same reading of
the specification, cannot catch a misreading of the specification. That splits
the old ISS's value in two, and the halves have opposite answers.

For **microarchitecture** it was genuinely independent: it had no pipeline, so
it could not share a hazard bug. It earned its keep, and both RTL bugs above
were found that way.

For **ISA semantics** it was worth close to nothing, and the CSR milestone's own
notes say so without noticing: the ISS was extended to have "the same CSR
addresses, same mcause encoding, same trap priority" as the RTL. Written that
way, the golden model is a restatement of the design under test, and any
misreading of the privileged spec would sit in both files and pass.

### What the swap found: nothing, which is the point

Spike reproduced the old ISS's golden values exactly. All 32 registers plus both
memory words for the hazard test, and all 32 registers for the CSR test
including the trap counters, the `mcause` value `0x80000007`, and the
interrupt-preemption marker.

So the old ISS was right about everything these programs exercise. That is worth
stating plainly rather than burying: the previous work was not wrong. What
changed is that it is now checkable instead of assumed.

An independent check of a different layer came free. Disassembling all three
programs with GNU binutils confirmed every encoding `testgen/asm.py` produces,
which matters because a hand-rolled assembler feeding both the RTL and the model
is another way for one mistake to be invisible. It also showed that the
deliberate "illegal instruction" `0x0000007F` is not an unallocated opcode as
its comment claimed, but the RISC-V instruction-length encoding for
80-bit-or-longer instructions. The test still does something valid, since this
core does not implement variable-length instructions, but it is not testing what
it says, and the old ISS could never have told us because both sides agreed by
construction.

### Two more bugs, found by running the generator

`gen_stream.py` did not work first time, and both failures were the same
underlying mistake in different clothes: the reference model and the DUT must
start from the same state, and "the same state" is larger than it looks. Neither
was a bug in Spike or in the RTL.

**Memory.** The generated loads and stores used `x1` as a base seeded to 0, with
offsets up to 255. The DUT is Harvard, so those stores cannot touch the program.
Spike is von Neumann. The program overwrote its own instructions, executed the
corrupted words, trapped to an uninitialised `mtvec` = 0, jumped back to the top
and looped forever. The sentinel never retired.

It took a *random* generator scattering stores across low memory to expose this.
Every directed test in the project respects the invariant by construction,
because a human wrote each one and never thought to store over the code.

Worth noting the failure was loud rather than quiet. Had the corrupted program
happened to terminate, the generator would have emitted a plausible-looking
trace encoding a completely different execution, and the scoreboard would have
reported mismatches pointing at innocent RTL. The `sys.exit` on a missing
sentinel is doing real work.

**Registers.** With that fixed the script exited 0, and the trace was still
wrong. Its first five rows were at PC `0x40001000`: Spike's boot ROM, which runs
`auipc/addi/csrrs mhartid/lw/jalr` before jumping to the ELF entry. The DUT has
no boot ROM and resets straight to PC 0, so every comparison would have been
five out of step. Worse, that sequence leaves `x11` holding a device-tree
pointer, so any generated instruction reading `x11` before writing it would
diverge, and would look exactly like a forwarding bug, which is the most
expensive kind of false positive to hand a verification engineer.

This one is worth dwelling on because the script *reported success*. It was
caught only by reading the actual output instead of the exit code.

## The style retrofit

A pass against [lowRISC's Verilog Coding Style
Guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md).
Mostly mechanical: `unique case` everywhere, the guide's module declaration
layout, `UpperCamelCase` for tunable parameters, explicit `logic` typing, sized
1-bit literals, and `debug_fsm.sv`'s state encoding converted from two bare
`parameter` constants to a typedef enum with the same values.

One substantive change: `alu.sv` and `extend.sv` had defaulted unreachable cases
to `32'bx`. They now default to `32'b0`, a defined value on paths provably
unreachable from decode.

Two of the guide's rules were audited and deliberately not applied.

**Full `lower_snake_case` signal renaming.** The guide wants every signal in
`lower_snake_case`. This core uses Harris & Harris's stage-suffixed
`PascalCase`, and that convention is load-bearing: with five instructions in
flight, the suffix is how you avoid confusing which instruction a signal refers
to. lowRISC's `_d`/`_q` convention is designed for a single register, not a
five-deep pipeline. Swapping one deliberate scheme for another is not fixing an
oversight, and it would touch several hundred references across every file,
every testbench hierarchical path, and the wave-capture script.

**Active-low reset.** The guide wants `rst_ni`, asynchronous. This core's reset
is active-high, named `reset`, and used consistently everywhere. Inverting the
polarity means flipping the sense of every reset condition in every sequential
block in every file plus every testbench. A single missed inversion silently
holds the core permanently in or out of reset.

## The pattern

Nine bugs above. Three were found by reading, and all three were wiring bugs
found during construction, while the code was still warm.

Every bug found after that point was found by a tool: two by an elaborator, two
by a simulator, two by running a generator and reading its output, and two more
were testbench defects surfaced the same way. None of the six post-construction
bugs was found by re-reading code that had already been reviewed.

The two simulator-found bugs are the sharpest case, because both had survived
multiple deliberate review passes over exactly the files involved, and one of
them would have broken essentially any real program.
