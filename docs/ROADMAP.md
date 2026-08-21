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

**Close functional coverage.** Currently 61-71% of 53 bins across ten seeds.
Seven bins are unreachable by the current generator, including every `rs2`
dependency distance: `gen_stream.py` biases `rs1` to the previous destination
and never biases `rs2`, so the `ForwardBE` path is barely stimulated. Fix is in
the generator, not the RTL -- bias `rs2` on some fraction of instructions.

**Run the covergroups.** The coverage model exists twice: a plain-SystemVerilog
bin tally that runs everywhere, and the equivalent `covergroup` blocks behind
`` `ifdef RV32I_COVERAGE ``. Questa Starter Edition's licence withholds
`covergroup`, so only the tally has ever executed. The covergroups are written
but unexercised -- they need a licensed simulator before they can be trusted.

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
