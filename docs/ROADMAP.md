# Roadmap

Candid working notes: what is done, what is deliberately out of scope, and what
would have to happen next. Kept out of the README on purpose -- that file is the
front door. This one is the honest ledger.

## Verification

**Run `riscv-arch-test`.** The single highest-value remaining task. The core is
checked instruction-by-instruction against Spike on generated streams, which is
a strong claim, but it is not the same as passing the official compliance suite.
Until that suite runs, "verified against Spike" is the accurate phrasing and
"compliant" is not.

**Write a requirements-derived coverage plan.** The current 59-bin model was
built outward from the hazard machinery, which is why its percentage moves when
the hazard stimulus improves and why it says nothing about CSRs, trap causes,
interrupt timing, load/store widths, individual ALU operations, operand
corners, or debug entry/exit. A real plan starts from the RV32I and privileged
specs plus this design's feature list, derives bins from requirements, and
only then reports a percentage. Until that exists, every coverage number below
is a hazard-stimulus metric and is labelled as such.

**Close the hazard coverage model.** *Mostly done.* `gen_stream.py` used to
bias only `rs1`, and only toward the immediately preceding destination. It now
biases both source registers toward a uniformly chosen one of the last three
*architectural producers* -- stores, branches and x0-writes push nothing, which
was its own bug once (V14 in [BUGS.md](BUGS.md)). Measured on the same ten
seeds across three generator states and the reset-time dmem initialization:

| | rs1-only bias | both biased (phantom producers) | producers tracked correctly | reset-time dmem clear |
|---|---|---|---|---|
| per-seed coverage | 59-69% | 66-83% | 71-81% | 68-80% |
| union across 10 seeds | 48/59, 81.4% | 56/59, 94.9% | 56/59, 94.9% | **59/59, 100%** |
| bins no seed reached | 11 | 3 | 3 | 0 |

Those four columns are all measured against the **59-bin hazard-only model**,
which is what made them comparable. The model has since grown to 93 bins
(instruction mix including jumps, decoded ALU operation, memory width,
writeback corners), so its numbers are not a fifth column of the same table:
against the 93-bin model, 30 seeds give 39-76% per seed and **93/93, 100%**
union. The per-seed figure dropped because the model got harder, not because
the stimulus got worse.

The generator's invariants are now pinned by `verif/spike/test_gen_stream.py`.

No hazard-model bin remains unreachable across the ten seeds. Removing the
64-store memory prologue put the `x1` base-pointer write immediately before the
random body, so early loads now reach `x_op_rs1.load_d{1,2,3}`. Those hits are
confined to program startup: recurring dependent-base loads still need the
generator to emit a safe scratch base -- `ADDI rt, x1, off` followed by a load
off `rt`. That change must preserve the invariant keeping generated stores off
the program image (see V4 in [BUGS.md](BUGS.md)).

**Stimulate the jump and upper-immediate opcodes.** *Done.* `gen_stream.py`
now emits JAL, JALR, LUI and AUIPC, and the three immediate shifts. Only
SYSTEM remains out of scope. Two known bugs lived in exactly that gap -- D3's
spurious-stall case and the JAL/JALR half of D6, which was never covered by
any test in any version of the file; both paths are now exercised by the
random stream and check clean against Spike.

Jumps are forward-only and bounded, the same invariant branches already had.
JALR is emitted as an AUIPC+JALR pair so its base register is produced two
instructions earlier by construction rather than being whatever a random
register happens to hold -- which also makes every JALR a distance-1 RAW
hazard on its own target. The generator refuses to emit a pair whose JALR
word is already some earlier transfer's target, since a JALR entered without
its AUIPC would jump through a stale register;
`test_gen_stream.py` re-derives that property independently across 50 seeds.

**Corner-case ALU operands.** D1 was a sign error at the signed-overflow
boundary. The generator uses uniform-random operands, which essentially never
straddle it. Biasing operands toward `INT_MIN`/`INT_MAX`/`0`/`-1` would aim at
the corner instead of hoping for it.

**Write the missing converse assertions.** *Done for the redirect sources:*
`hazard_sva.sv` now asserts cause->effect for JumpD, mret, EnterDebug and
ExitDebug (the D5 property), each with a cover property. `a_jump_flushes` is
now non-vacuous under the generated stream; the mret and debug properties
still are, since that stimulus has no SYSTEM or debug traffic.
Related gaps remain: no properties yet for
retirement validity, wrong-path retirement, PC alignment/progression, or
"no memory write from a flushed instruction". And note the honest scope: these
are simulation assertions -- nothing here is formally proven. The hazard unit
and controller are small enough that a real formal pass (SymbiYosys) over the
bound properties is feasible and would upgrade "checked on the stimulus we ran"
to "proven for all inputs".

**Gate assertion-cover reachability.** The 10 cover properties exist so the
assertions cannot pass vacuously, but nothing yet *requires* them to hit --
a run where `c_fwd_both_stages` never fires still passes. The regression
should extract cover counts from the log and fail on a zero, the same way it
now fails on assertion errors.

**Widen `retire_if` toward RVFI.** The retirement lockstep comparison is the
strongest checker in the project, and the features that most need it -- CSRs,
traps, interrupts, `mret`, debug -- bypass it entirely, relying on directed
end-state tests that a transient wrong value can slip past. The structural fix
is RVFI-style retirement information (trap/interrupt flags, rs1/rs2 addresses
and read data, memory masks, CSR address/read/write data) and generated
streams that include SYSTEM instructions, checked through the same Spike
comparator.

**CI and pinned tooling.** No CI runs any of this on push; Spike and the
cross-toolchain versions are whatever the development machine has. A workflow
that runs the directed tests, the generator unit tests, and lint on every push
-- with the Spike revision pinned -- is table stakes before anyone else can
trust a green checkmark.

**Run the covergroups.** The coverage model exists twice: a plain-SystemVerilog
bin tally that runs everywhere, and `covergroup` blocks behind
`` `ifdef RV32I_COVERAGE ``. Questa Starter Edition's licence withholds
`covergroup`, so only the tally has ever executed. The two are also not
bin-for-bin identical -- the tally has hazard-kind bins the covergroups lack,
and the covergroups have a branch kind-by-outcome cross the tally lacks -- so
first execution includes reconciling them, not just compiling them.

**Verilator on the current tree.** Verilator is not installed on the development
machine, so recent commits are Icarus-only. The two-simulator claim needs a
re-run before it is safe to repeat.

## RTL quality

Tiers below refer to the review pass recorded in this file's history.

**Tier 1 -- self-inconsistencies.** `debug_fsm.sv` is the only block in the core
with a synchronous reset; everything else, and `reset_sync.sv`'s entire stated
rationale, assumes asynchronous assert. `controller.sv:67` is the only
positional instantiation in the RTL, connecting 13 ports by position -- the same
bug class the build journal records for the forwarding muxes. `alu.sv` decodes
ALU control with raw literals instead of importing `rv32i_pkg`, which is exactly
how the SLT overflow-gate bug happened.

**Tier 3 -- unnamed encodings.** `ImmSrc` is spelled as raw 3-bit literals in
both `controller.sv` and `extend.sv` with no shared constant. SYSTEM `funct12`
values are raw binary. `mstatus` bit positions are hand-placed twice in
`csr_file.sv`. Load/store width `funct3` appears in four places.

**Tier 4 -- structure.** `datapath.sv` still carries five jobs. Extracting the
EX-stage trap block into a combinational `trap_unit.sv` is a behaviour-preserving
refactor worth roughly 70 lines. `PCW <= PCPlus4M - 32'd4` derives the retiring
PC with a subtractor instead of pipelining it.

**Tier 5 -- consistency.** Two naming conventions coexist (`PCSrcE` beside
`trap_en`). Either rename wholesale or write the rule down in the design guide
so it reads as a decision.

**Tooling.** There is no lint step. `verilator --lint-only -Wall` in `run_sim.sh`
would mechanically catch unused ports, width mismatches and implicit
truncations, and would keep the items above from coming back.

## Physical design

Deliberately out of scope, but name the gaps honestly if asked:

- No SDC, so no fmax, area, or critical-path numbers.
- `imem` is an inferred array with an `initial $readmemh`, not an SRAM macro
  with a boot path.
- No DFT, no power intent, no STA.

This is an RTL and verification project. Taking it further would mean a
different project, not a longer version of this one.

## Known model differences

`docs/DESIGN_GUIDE.md` section 8 holds the full table. The two that constrain
future test programs:

- **CLINT tick rate.** `clint.sv` increments `mtime` per clock cycle; the Spike
  plugin increments per retired instruction. Tests must check final
  architectural state, not "it fired on cycle N".
- **Unified vs Harvard memory.** Spike has one address space; the core has
  separate `imem` and `dmem` both based at 0. A program that stores into its own
  code diverges. `gen_stream.py` respects this by construction.
