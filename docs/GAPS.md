# Stimulus generator gaps

Known gaps in `verif/spike/gen_stream.py` and the reasoning behind them.
Companion to [ROADMAP.md](ROADMAP.md), which tracks the wider verification
plan, and to the "Deliberately not done" list in `verif/uvm/RUNNING.md`. This
file is specifically about the generator: what it does not do, why, and what
it would take to change that.

## Why a hand-rolled generator instead of riscv-dv?

The obvious alternative to writing our own generator is
[riscv-dv](https://github.com/chipsalliance/riscv-dv), the CHIPS
Alliance/Google generator and the de facto industry standard. It was
considered and rejected for this environment, for four reasons:

1. **It would end Questa Starter support.** riscv-dv's main flow is a
   SystemVerilog UVM generator built entirely on `randomize()` -- exactly the
   `svverification` feature the free Starter licence withholds. The whole
   point of generating the stream in Python and replaying it is that nothing
   randomizes at simulation time (see RUNNING.md). riscv-dv's Python "PyFlow"
   variant dodges the licence problem but not the points below.

2. **It assumes a machine this DUT is not.** riscv-dv emits full programs
   with boot code, trap handlers, CSR setup and jumps, and assumes exceptions
   can be taken and recovered from. This environment deliberately exercises
   none of that: the scoreboard lockstep-checks every retirement against
   Spike, so any divergence in trap behaviour would be noise, not signal.
   `tb_pipe_csr` is the directed test that covers the CSR/trap machinery.
   Configuring riscv-dv *down* to this subset costs more than gen_stream.py
   costs to write.

3. **The DUT-specific safety invariants are the generator.** Loads and stores
   go only through the x1 window placed past the program image (Spike is von
   Neumann, the DUT is Harvard -- a store into the code image corrupts
   Spike's execution but not the DUT's), branches are forward-only and
   bounded so the padding and trace trimming work, and the sentinel
   terminates both models identically. A generic tool knows none of this.

4. **The interesting knob is hazard distance, and that is ~20 lines.**
   `biased_src()` steering sources at the last three architectural producers
   is the core value of the generator -- it targets the forwarding paths and
   the regfile bypass directly -- and it is tiny, pinned by
   `test_gen_stream.py`, and fully understood. riscv-dv brings tens of
   thousands of lines and its own learning curve to get an equivalent bias.

**Where the answer flips:** if the goal grows to full-ISA random coverage --
JAL/JALR, CSRs, traps and interrupts in the random stream, privilege modes,
compressed instructions -- then extending gen_stream.py becomes reinventing
riscv-dv badly. At that point riscv-dv PyFlow plus its Spike co-simulation
flow (which matches this project's reference-model choice) is the right move,
at the cost of adding a trap handler to the generated programs and losing
some of the lockstep simplicity.

## biased_src() is a closure nested inside generate()

`biased_src()` lives inside `generate()` and shares the `recent_rd` list and
`rng` with the loop around it through closure capture. That keeps the file
short, but the producer-tracking state and the code that updates it (the
`writes_rd` push at the bottom of the loop) are separated, and the coupling
between them is invisible at the call site -- exactly the shape that produced
bug V14 in [BUGS.md](BUGS.md), where stores and branches pushed phantom
producers.

A small class -- say `ProducerTracker` with `pick_src()` and
`retire(rd, writes_rd)` -- would put the state and both operations on it in
one place, make the invariant ("a slot holds 0 unless that instruction
architecturally wrote a register") a class docstring instead of folklore, and
let `test_gen_stream.py` test the bias distribution directly instead of only
through generated programs. Worth doing the next time the generator is
touched for any other reason; not worth a standalone churn commit.

## The stimulus path is UVM ceremony around a file copy

The sequence reads `stream.hex`, wraps each 32-bit word in a
`uvm_sequence_item`, and pushes it through a sequencer to a driver that writes
it into the imem array in zero simulation time while reset is held. There is
no protocol, no timing, no randomization and no reactivity anywhere on that
path -- functionally it is `$readmemh` carrying three classes of overhead.
"What does the sequencer buy you here?" is a fair question, and the code
currently gives no answer.

What the ceremony buys today is structural, not functional: the program
arrives through the standard UVM stimulus path, so a future front-door driver
-- one that loads over a real bus with real timing, or a reactive sequence
that responds to DUT state -- slots into the existing agent instead of
requiring the environment to grow one. That is a defensible position, but it
is a bet on future work, and it should be stated where the ceremony lives
(the package header or the sequence) rather than left for a reader to
reconstruct.

Two related conventions would draw the same interview probe: the transactions
use `uvm_field_int(UVM_ALL_ON)` field macros, which many teams ban outright
for their compile-time and runtime cost (hand-written `do_copy`/`do_print` is
the usual house style), and the agent has no active/passive configuration --
it is always active, which is true today and unenforced tomorrow.

**To close it:** either write the future-driver rationale into
`rv32i_uvm_pkg.sv`'s header and accept the overhead knowingly, or collapse
the load into the driver reading the file directly and delete the sequence,
sequencer and transaction. The middle ground -- keeping the ceremony with no
stated reason -- is the only wrong option.

## Why are shifts left out of the I-type pool?

They are only half left out. Register-register shifts (SLL, SRL, SRA) are
generated: the R-type arm draws `funct3` from all eight values, and handles
the funct7 bit that splits SRL from SRA. What is never generated is the
immediate forms -- SLLI, SRLI, SRAI.

The reason is the encoding. For every other I-type ALU op the top 12 bits are
a plain immediate and any value of `randrange(4096)` is legal. For shifts,
bits [4:0] of that field are the shift amount and bits [11:5] are required to
be `0000000` (SLLI, SRLI) or `0100000` (SRAI); every other upper-bit pattern
is a reserved encoding in RV32I. Drawing a random 12-bit immediate would
produce illegal encodings that Spike traps on but the DUT happily executes --
`controller.sv` deliberately does not decode bogus funct7 patterns (see its
header comment), and its ALU decoder looks only at bit 30 -- a guaranteed
lockstep divergence that says nothing about the pipeline. Rather than special-case the immediate, the generator drops
those two funct3 values from the I-type pool.

**The cost:** shift-immediate decode and the shamt path through the immediate
extender are never exercised by the random stream (the directed tests cover
them). Shift amounts still vary via the R-type forms, but only through
whatever values registers happen to hold.

**To close it:** add a sixth-ish arm that picks `funct3` from {001, 101},
draws `shamt = rng.randrange(32)`, and sets the upper seven bits to
`0000000`, or `0100000` for the SRAI case -- the same funct7 trick the R-type
arm already does. Small, safe, and it would let the coverage model grow
shift-immediate bins.
