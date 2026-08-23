# Bug record

Every defect this project found, what caused it, and the check that now stands
between it and a repeat.

Fifteen entries. Six are bugs in the CPU; nine are bugs in the things that were
supposed to be checking the CPU. Both halves are here on purpose: a broken
checker is the more expensive failure, because it ends with someone "fixing" a
working design.

The last part of each entry is the one that matters. A bug you fixed is history;
a bug you fixed *and can no longer reintroduce silently* is a result. Where no
automated check guards a fix, this file says so rather than implying otherwise.

Longer narrative for most of these is in [JOURNAL.md](JOURNAL.md); the design
they refer to is in [DESIGN_GUIDE.md](DESIGN_GUIDE.md).

---

## How they were found

| Found by | Count | Bugs |
|---|---|---|
| Reading the code | 3 | D1, D2, D3 |
| Static elaboration (`pyslang`) | 3 | V1, V2, V3 |
| Running a directed testbench | 2 | D4, D5 |
| Running the stimulus generator | 3 | V4, V5, V6 |
| The UVM environment | 1 | D6 |
| A second simulator disagreeing | 2 | V7, V8 |
| Reading a coverage report that was lying | 1 | V9 |
| Writing an assertion that fired | 1 | V10 |
| Disassembling with GNU binutils | 1 | V11 |

All three "found by reading" bugs were caught during construction, while the
code was still warm, and all three were wiring bugs. **No bug was ever found by
re-reading code that had already been reviewed.** Twelve of fifteen were found
by a tool, and the two most serious ones — D4 and D6 — had each survived several
deliberate review passes over exactly the file involved.

That is the argument for the whole verification stack in this repo, and it is
why the sections below spend more space on the check than on the fix.

---

# Design bugs

Bugs in the synthesizable RTL. These are the ones that would have shipped.

---

## D1 — SLT read the wrong sign at the overflow boundary

**Where** `rtl/alu.sv:33`

**Symptom** `SLT` returns the wrong result when the subtraction overflows —
`SLT x1, INT_MIN, 1` says "not less than". Correct everywhere else.

**Root cause** `SLT` is implemented by reusing the subtract hardware and
correcting the sign with the overflow bit (`sum[31] ^ v`). `v` is only
meaningful for add/sub-shaped operations, so it is gated by `isAddSub`. When the
ALU control encoding was widened from 3 bits to 4, that gate was rewritten to
list the add and sub encodings — and not the SLT one. `v` was then forced to 0
for `SLT`, and the sign correction silently stopped happening.

```systemverilog
// the fix: 4'b0101 is SLT, and it needs the overflow bit too
assign isAddSub = (alucontrol == 4'b0000) | (alucontrol == 4'b0001) |
                  (alucontrol == 4'b0101);
```

**Why it is a nasty one** It is wrong on a measure-zero slice of the input
space. Uniform random operands essentially never straddle the signed overflow
boundary, so this passes a very large number of random tests.

**The check now** Partial, and worth being precise about. Every retirement's
writeback is compared against Spike, and `gen_stream.py:139` randomises R-type
`funct3` across all eight values, so `SLT` and `SLTU` do execute and are
compared. But the operands are uniform random, so the failing corner is not
being aimed at. **This bug's specific corner is not directly targeted by any
current check.** Closing it properly means constraining operands toward
`INT_MIN`/`INT_MAX`/`0`/`-1`, which is a generator change, listed in
[ROADMAP.md](ROADMAP.md).

---

## D2 — The forwarding muxes had their inputs in the wrong order

**Where** `rtl/datapath.sv:198`

**Symptom** Wrong operand values, but only under a RAW hazard. No compile error.

**Root cause** `mux3` selects `d0` on `2'b00`, `d1` on `01`, `d2` on `10`. The
hazard unit's encoding is `FWD_WB = 01`, `FWD_MEM = 10`. The muxes were wired
`(RD1E, ALUResultM, ResultW)` — the MEM and WB sources swapped. Right number of
arguments, right names, plausible-looking line, wrong order.

```systemverilog
// FWD_WB=01 so ResultW is d1; FWD_MEM=10 so the MEM source is d2
mux3 #(32) forwardamux (.d0(RD1E), .d1(ResultW), .d2(FwdResultM), .s(SelectAE), .y(SrcAE_reg));
```

**The check now** Two halves, checked by two different mechanisms:

- The *select* side — that `SelectAE`/`SelectBE` are only ever asserted when a
  real producer is in flight, and that MEM wins over WB when both match — is
  checked every cycle by bound assertions: `a_fwd_mem_legal`, `a_fwd_wb_legal`,
  `a_fwd_mem_priority`, `a_no_spurious_fwd`, `a_no_fwd_x0` in
  `verif/sva/hazard_sva.sv`.
- The *data* side — that the mux port order matches that encoding — is not
  visible to those assertions, because they are bound into `hazard_unit.sv` and
  this bug is in `datapath.sv`. It is caught by the scoreboard: a swapped mux
  delivers an architecturally wrong writeback, which the lockstep comparison
  against Spike reports.

For the scoreboard half to be meaningful the stimulus has to actually produce
hazards, so the coverage model reports `hazard.alu_raw_d1` and
`hazard.alu_raw_d2` explicitly. If those bins read zero, this check did not run.

---

## D3 — Immediate bits were mistaken for register numbers

**Where** `rtl/hazard_unit.sv:181`, gated from `rtl/controller.sv:78`

**Symptom** A spurious load-use stall, and — worse — a silently dropped jump.

**Root cause** The load-use interlock compares the EX-stage load's destination
against `InstrD[19:15]` and `InstrD[24:20]`. Those are `rs1` and `rs2` for most
instructions, but JAL, LUI and AUIPC reuse the same bit positions as *immediate*
bits. An immediate whose bits happened to equal a preceding load's destination
register number would trigger the interlock. The stall itself would only waste a
cycle — but `StallF` freezes `PCF`, and if the instruction being frozen was a JAL
that needed to redirect the PC that cycle, the jump is lost with no other
symptom.

```systemverilog
assign lwStallD = IsLoadE && (RdE != 0) &&
                  ((Rs1UsedD && (RdE == Rs1D)) || (Rs2UsedD && (RdE == Rs2D)));
```

`Rs1UsedD`/`Rs2UsedD` come from the decoder, which knows the instruction format.
`controller.sv:78` extends the same idea to the CSR immediate forms, where
`funct3[2]` distinguishes `csrrwi`-style instructions that encode an immediate in
the `rs1` field.

**The check now** Structurally guarded, not yet randomly stimulated:

- `a_stall_has_cause` and `a_lwstall_effect` (`verif/sva/hazard_sva.sv`) hold the
  interlock to its contract every cycle — a stall must have a cause, and must
  stall fetch and decode *and* bubble execute rather than doing some of those.
- **The specific case is not covered by the random environment.**
  `gen_stream.py` emits no JAL, LUI or AUIPC, so the exact instructions that
  trigger this bug never appear in a generated stream. The coverage report says
  so out loud: `opcode.jal`, `opcode.lui` and `opcode.auipc` are declared bins
  that print at zero in a separate `opcode_out_of_scope` group.
- The directed testbench `tb_pipe_hazard` does exercise it, against
  Spike-generated golden values.

Extending the generator to emit U-type and J-type instructions is the fix, and is
in [ROADMAP.md](ROADMAP.md).

---

## D4 — Distance-3 RAW dependencies read a stale register

**Where** `rtl/regfile.sv:53`

**Severity** The most serious bug in this record. It breaks essentially any
compiled program.

**Symptom** First real simulation run: `tb_pipe_hazard` reported
`x12 = 0x55, expected 0x77`.

```
ADDI x10, x0, 4       <- producer
ADDI x11, x0, 0x77
SW   x11, 0(x10)
LW   x12, 0(x10)      <- consumer, three instructions later
```

`0x55` was a value the *previous* test case had left at address 0, so the load
had gone to address 0 rather than 4 — meaning it read `x10` as zero.

**Root cause** A gap between two mechanisms that each individually looked
complete. Forwarding covers a producer in MEM or WB against a consumer in EX:
distances 1 and 2. The register file is read in ID. At distance 3 the producer is
in WB while the consumer is still in ID; the write commits on that same clock
edge as a nonblocking assignment, so a plain combinational read returns the old
value. By the time the consumer reached EX, the producer had retired and no
forwarding path saw it either.

`regfile.sv` had been inherited unchanged from the single-cycle design, where the
question cannot arise — there is no ID stage to be early. Its header comment
still read "UNCHANGED by the RV32I extension", which in hindsight was the
warning.

**Fix** A read-during-write bypass, rather than Harris & Harris's falling-edge
write, so the design stays single-edge and ordinarily synthesisable:

```systemverilog
assign rd1 = (a1 == 0) ? 32'b0 : (we3 && (a3 == a1)) ? wd3 : rf[a1];
```

**Why review kept missing it** Every review pass went over `hazard_unit.sv`,
because that is the file whose job is hazards. The bug is not in
`hazard_unit.sv`. It is in the gap between that file's stated coverage and an
assumption buried in a file nobody had reason to re-read.

**The check now** The strongest of any bug here:

- The directed sequence above is a permanent case in `tb_pipe_hazard`, checked
  against Spike under both Icarus Verilog and Verilator.
- The coverage model counts dependency distance explicitly, and `rs1_dist.d3` and
  `x_op_rs1.rtype_d3` are reported bins. A run showing them at zero is a run that
  could not have found this, and the report names the hole by name rather than
  leaving it inside a percentage.
- `c_fwd_both_stages` in `verif/sva/hazard_sva.sv` covers the adjacent
  condition — MEM and WB both writing the register an operand needs — proving the
  priority assertions are not passing vacuously.

---

## D5 — `dret` never flushed the instructions behind it

**Where** `rtl/hazard_unit.sv:194`

**Symptom** `tb_pipe_debug` under Icarus: `x1 not advancing after resume`. The
core halted correctly, resumed correctly, then wedged.

**Root cause** `datapath.sv` redirects the PC to `dpc` on `ExitDebug`, but
`ExitDebug` was missing from both `FlushD` and `FlushE`. The two instructions
already fetched sequentially behind the `dret` were never squashed, and executed
for real after the resume.

This is structurally identical to `mret_enE`, which *was* handled — `dret` is the
debug-mode spelling of the same "redirect the PC from EX" event. The debug work
had reasoned carefully about which stages to squash on debug *entry*, and never
asked the same question about *exit*.

```systemverilog
assign FlushD = PCSrcE | JumpD | EnterDebug | ExitDebug | trap_en | mret_enE;
assign FlushE = PCSrcE | lwStallD | EnterDebug | ExitDebug | trap_en | mret_enE;
```

**The check now, and its honest limit**

- `tb_pipe_debug`, under Icarus Verilog, is what catches it. Re-seeding the bug
  deliberately confirms that this check still works.
- The bound assertions `a_flushd_has_cause` and `a_flushe_has_cause` do *not*
  catch it, and it is worth saying why rather than listing them and moving on.
  They are written as `FlushD |-> (... || ExitDebug || ...)`: every flush must
  have a cause. This bug is the converse — a cause with no flush. The implication
  points the wrong way. An `a_exitdebug_flushes: ExitDebug |-> FlushD && FlushE`
  property would catch it directly and is not yet written.

**This bug is the reason the project runs two simulators.** Re-seeding it:

```
########## SEEDED: ExitDebug REMOVED from FlushD/FlushE ##########
  Icarus     debug : FAIL: x1 not advancing after resume (00000007 -> 00000007)
  Verilator  debug : PASS
```

Verilator does not see it. The two tools disagree about what the stray fetches
past the end of the program decode to. Verilator reads uninitialised `imem` as 0;
`0x00000000` is an illegal opcode, so the core trapped to `mtvec = 0`, which is
the top of the test program, so execution fell back into the loop and `x1` kept
incrementing. The testbench passed by luck, off the back of a trap handler firing
for a bug that had nothing to do with traps. Icarus is 4-state: those fetches
read X, the PC went X, and the core visibly wedged.

Neither tool is right — real hardware fetches whatever is physically there, which
is neither 0 nor X. The point is that a single simulator's initialisation policy
is a silent assumption baked into every result it gives you, and a second tool
that leans differently is the cheapest way to find where you are leaning.

---

## D6 — The MEM-stage forward delivered the ALU result for non-ALU instructions

**Where** `rtl/datapath.sv:401`

**Symptom** `tb_pipe_csr` hung forever, once a masking bug was removed.

**Root cause** Two bugs stacked, which is why this one lasted.

The MEM-stage forwarding source was `ALUResultM`, unconditionally. That is the
right value for an ALU instruction and the wrong value for a CSR read (which
needs `CsrRdataM`) and for JAL/JALR (which need `PCPlus4M`).

It had been masked by an accident of bit numbering. `IsLoadE` was computed as
`ResultSrc[0]`, which is true for both `RESULT_MEM` and `RESULT_CSR`. So CSR
reads were being treated as loads and *stalled* rather than forwarded, and the
mux was simply never asked for the CSR value. Fixing the aliasing —

```systemverilog
assign IsLoadE = (ctrlE.ResultSrc == RESULT_MEM);
```

— exposed the real bug immediately: the trap handler's `mepc += 4` wrote back a
stale value, so `mret` returned to the `ecall` that had trapped, and re-trapped,
forever.

**Fix** A proper source mux in the MEM stage:

```systemverilog
always_comb
  unique case (ResultSrcM)
    RESULT_CSR:     FwdResultM = CsrRdataM;
    RESULT_PCPLUS4: FwdResultM = PCPlus4M;
    default:        FwdResultM = ALUResultM_r; // RESULT_ALU (RESULT_MEM stalls)
  endcase
```

**The JAL/JALR half was wrong in every version of this file and was never covered
by any test.** It was fixed by reasoning about the mux, not by a failure.

**The check now**

- The CSR path is checked by `tb_pipe_csr` against Spike golden values, and the
  hang is a hard failure rather than a quiet mismatch.
- The JAL/JALR path is **still not covered by any automated check**, for the same
  reason as D3: `gen_stream.py` emits no jumps, and the coverage report prints
  `opcode.jal` and `opcode.jalr` at zero. This is the largest known verification
  hole in the project and it is stated as such in [ROADMAP.md](ROADMAP.md).
- `unique case` makes an unhandled `ResultSrcM` encoding a simulation error
  rather than a latch.

---

# Verification bugs

Bugs in the testbenches, the stimulus generator, the coverage model and the
assertions. These found no design defect, and they are here because each one
either hid a real bug or accused an innocent one — and because a project whose
bug list contains only design bugs is a project that has not been watching its
checkers.

---

## V1, V2 — Forward references that only one simulator tolerated

**Where** `rtl/datapath.sv` (`ResultW`), `rtl/riscv_pipe.sv` (`enter_debug`)

**Root cause** Both signals were used at module scope before their declaration.
Icarus tolerates this; stricter elaborators reject it. They had been present
since the pipeline was first written and were invisible for as long as only one
tool ever read the code.

**Found by** `pip install pyslang` working for the first time, which put a real
SystemVerilog elaborator on the machine.

**The check now** Everything elaborates clean under `pyslang -Weverything`. There
is no lint step wired into `run_sim.sh` yet — adding `verilator --lint-only
-Wall` is the open item in [ROADMAP.md](ROADMAP.md), and it is the mechanical
guard this class of bug actually wants.

**Worth recording** That clean elaboration meant much less than it felt like it
did at the time. Two real RTL bugs (D4 and D5) were sitting behind it. Static
checking bought structure, and nothing whatsoever about behaviour.

---

## V3 — A hierarchical path that rotted when a module was inserted

**Where** `rtl/tb_pipe.sv`, `tb_pipe_hazard`'s backdoor memory check

**Root cause** The check reached into `dut.dmem.mem[...]`. That path broke the
moment `mem_bus.sv` was introduced between `top.sv` and `dmem.sv`. Hierarchical
paths are a dependency on structure that no interface declares, so nothing warns
when a refactor invalidates one.

**Found by** the same `pyslang` elaboration pass as V1/V2.

**The check now** Elaboration resolves the path, so a broken one is a build
failure rather than a silent skip. The UVM environment avoids the problem class
entirely: `verif/uvm/mem_backdoor_if.sv` reaches memory through a `bind` and a
`ref` port instead of a literal path, so the connection is made once, in one
place, and checked by the compiler.

---

## V4 — The generated program overwrote its own code

**Where** `verif/spike/gen_stream.py`

**Symptom** The generator hung: Spike never retired the sentinel instruction.

**Root cause** A state mismatch between reference and DUT, of a kind larger than
it first looks. The generated stores used `x1` as a base seeded to 0, with
offsets up to 255. **The DUT is Harvard** — separate `imem` and `dmem`, both
based at 0 — so those stores cannot touch the program. **Spike is von Neumann**,
one address space. On Spike the program overwrote its own instructions, executed
the corrupted words, trapped to an uninitialised `mtvec = 0`, jumped to the top
and looped forever.

Every directed test in the project respects this invariant by construction,
because a human wrote each one and never thought to store over the code. It took
a random generator scattering stores across low memory to expose it.

**Fix** `data_base_for()` places the data window clear of the program, and `x1`
is seeded to that base rather than to 0.

**The check now** The generator exits non-zero if Spike never retires the
sentinel (`gen_stream.py:234`). That guard is doing real work: had the corrupted
program happened to *terminate*, the generator would have emitted a
plausible-looking trace encoding a completely different execution, and the
scoreboard would have reported mismatches pointing at innocent RTL.

---

## V5 — The golden trace started five instructions before the program did

**Where** `verif/spike/gen_stream.py`

**Symptom** None. The script exited 0 and produced a trace that looked fine.

**Root cause** The trace's first five rows were at PC `0x40001000` — Spike's boot
ROM, which runs `auipc/addi/csrrs mhartid/lw/jalr` before jumping to the ELF
entry. The DUT has no boot ROM and resets straight to PC 0, so every comparison
would have been five instructions out of step.

Worse than the offset: that boot sequence leaves `x11` holding a device-tree
pointer. Any generated instruction reading `x11` before writing it would diverge
for reasons entirely unconnected to the DUT — and would look exactly like a
forwarding bug, which is the most expensive kind of false positive to hand a
verification engineer.

**Fix** Two guards, because there are two problems:

- The trace is skipped forward to `ENTRY_PC`, and the generator exits non-zero if
  Spike never reaches it (`gen_stream.py:247`).
- The generated program opens with an explicit register-zeroing prologue, so both
  models start from an architectural state that is stated rather than assumed.

**Worth dwelling on** This one *reported success*. It was caught only by reading
the actual output instead of trusting the exit code.

---

## V6 — Loads from never-written memory read 0 on one simulator and X on another

**Where** `verif/spike/gen_stream.py`

**Root cause** A generated load can target a location nothing has written. Spike
returns 0. A 4-state simulator returns X. Every such load mismatches, for a
reason with nothing to do with the DUT.

**Fix** A memory-zeroing prologue that stores 0 to every word the generated loads
can reach. Deliberately done with **real stores rather than a backdoor write**,
so the prologue sits inside the checked trace and verifies itself instead of
being a trusted side-channel.

---

## V7 — Both testbenches sampled one delta-cycle too early

**Where** `rtl/tb_pipe.sv:129`, `rtl/tb_pipe.sv:354`

**Symptom** A correct DUT reported as failing. In `tb_pipe_csr` the register in
question was the interrupt-preemption marker, which made it look considerably
more alarming than it was.

**Root cause** Both testbenches did `@(posedge clk)` and then read the register
file array immediately. The last instruction before `EBREAK` commits its write on
exactly that edge, as a nonblocking assignment, which has not been scheduled yet
at that point in the delta cycle. The register read as its reset value.

**Fix** `#1` after the edge, in both.

**Why it is in this file** This is the failure mode that makes a verification bug
more dangerous than a design bug. The testbench said the design was broken. The
design was fine. The available next move was to "fix" working RTL until the
testbench went green.

---

## V8 — The register file has no reset, and the simulators disagree about that too

**Where** `rtl/tb_pipe.sv`

**Root cause** `regfile.sv` is a RAM with no reset. That is correct hardware —
RISC-V does not define reset values for `x1`–`x31`. Under Icarus every
never-written register reads X; under Verilator it reads 0, and the golden values
expect 0.

**Fix, and the deliberate choice in it** Fixed in the *testbench*, by forcing a
known all-zero architectural start state. Adding a reset to `regfile.sv` would
have been inventing hardware to satisfy a simulator — 31 flops' worth of reset
logic that no specification asks for, added because a tool printed X.

---

## V9 — The coverage model's own bin names were silently corrupted

**Where** `verif/uvm/src/rv32i_coverage.svh`

**Symptom** The `hazard.alu_raw_*` bins read zero across 30 seeds, suggesting the
generator could not produce ALU RAW hazards at all. It was producing them
constantly.

**Root cause** A conditional operator over two string literals:

```systemverilog
hit($sformatf("hazard.%s_%s", prev_is_load[d-1] ? "load_use" : "alu_raw", ...));
```

In SystemVerilog those literals are *packed byte arrays*, not strings. The
conditional operator sizes both operands to the wider one, so `"alu_raw"`
acquires a leading NUL byte and the assembled bin name silently stops matching
the declared one.

**The check now** The `hit()` function raises a `uvm_error` on an undeclared bin
name rather than creating one on the fly. That turns this exact failure from a
bin that reads zero forever into a loud error. The call sites were also rewritten
as explicit `if`/`else` over separate `$sformatf` calls, and both sites carry a
comment saying why they are not ternaries.

**Why it belongs in a bug list** A coverage hole that is real and a coverage hole
that is a reporting artefact look identical in the report, and only one of them
is worth acting on. This one was being read as evidence about the generator.

---

## V10 — An assertion that was itself wrong, and fired 11 times

**Where** `verif/sva/hazard_sva.sv`

**Root cause** The first version of the file asserted that stalling and flushing
the same stage were mutually exclusive:

```systemverilog
a_no_stall_flush_conflict: assert property (!(StallD && FlushD));
```

They read as contradictory — one says "hold what you have", the other "replace it
with a bubble" — but they legitimately coincide. A trap or a resolved taken
branch redirects the PC in the same cycle a load-use interlock is holding decode.
Nothing forbids that, and forbidding it constrains the *stimulus* rather than
describing the *design*.

**Fix** The design's actual guarantee is a **priority**: `datapath.sv`'s IF/ID
register tests `FlushD` before `StallD`, so a redirect always beats an interlock
— which is the only correct choice, since the stalled instruction is on the wrong
path and must not be preserved.

```systemverilog
a_flush_beats_stall: assert property ((StallD && FlushD) |=> (InstrD == NOP_INSTR));
c_stall_and_flush:   cover  property (StallD && FlushD);
```

The `cover` is the other half. Without it, the assertion could be describing a
case that never occurs, and would pass forever while proving nothing.

---

## V11 — The "illegal instruction" was not the instruction it claimed to be

**Where** `rtl/testgen/asm.py`

**Root cause** A directed test injects `0x0000007F` with a comment describing it
as an unallocated opcode. It is not. `0x7F` in the low seven bits is the RISC-V
*instruction-length encoding* for instructions of 80 bits or longer.

The test still does something valid — this core implements no variable-length
instructions, so the word does raise an illegal-instruction trap — but it is not
testing the thing it says it is testing.

**Found by** disassembling all three test programs with GNU binutils, as an
independent check on `testgen/asm.py`. A hand-rolled assembler feeding both the
RTL and the reference model is one more way for a single mistake to be invisible
on both sides.

**Why the old golden model could never have told us** It agreed by construction.
See below.

---

# The reference model, and why it was replaced

Not a bug, but the reason several of the above can be trusted once found.

Everything up to a certain point rested on a from-scratch C++ RV32I simulator
written for this project. It was deleted and replaced with
[Spike](https://github.com/riscv-software-src/riscv-isa-sim).

A golden model written by the same person as the RTL, from the same reading of
the specification, cannot catch a misreading of the specification. That splits
the old model's value in two, and the halves have opposite answers:

- For **microarchitecture** it was genuinely independent. It had no pipeline, so
  it could not share a hazard bug. D4 and D5 were both found against it. It
  earned its keep.
- For **ISA semantics** it was worth close to nothing. The CSR milestone's own
  notes say so without noticing: the model was extended to have "the same CSR
  addresses, same mcause encoding, same trap priority" as the RTL. Written that
  way, the golden model is a restatement of the design under test, and any
  misreading of the privileged spec sits in both files and passes.

**What the swap found: nothing.** Spike reproduced the old model's golden values
exactly — all 32 registers plus both memory words for the hazard test, all 32
registers for the CSR test including the trap counters, the `mcause` value
`0x80000007`, and the interrupt-preemption marker.

That is worth stating plainly rather than burying. The previous work was not
wrong. What changed is that it is now *checkable* instead of assumed.

---

# What this record does not cover

Stated so the list is not read as claiming more than it does.

- **No official compliance run.** The core is checked instruction-by-instruction
  against Spike on generated streams, which is a strong claim, but it is not the
  same as passing `riscv-arch-test`. Until that suite runs, "verified against
  Spike" is the accurate phrasing and "compliant" is not.
- **Jumps and upper-immediates are not randomly stimulated.** D3 and half of D6
  live in exactly that gap. The coverage report prints those bins at zero rather
  than hiding them.
- **The covergroups have never executed.** Questa Starter Edition withholds
  `covergroup` under licence, so only the plain-SystemVerilog bin tally has run.
  The covergroups are written and unverified, and are labelled as such in
  `rv32i_coverage.svh`.
- **No physical design.** No SDC, no floorplan, no STA, so no fmax, area or
  critical-path numbers anywhere in this repo.

[ROADMAP.md](ROADMAP.md) tracks all of these.
