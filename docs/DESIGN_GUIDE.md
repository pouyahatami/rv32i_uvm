# Project guide: RV32I ISS, DUT extension, pipeline, and where UVM fits

This is a teaching document, not a status report — it explains *how* each piece
works and *why* it's built the way it is, so you can defend every design
decision in an interview or a code review. Read it alongside the actual files;
line numbers aren't given because the files are short enough to read in full.

Four things got built today, in this order:

1. A C++ instruction-set simulator (ISS) for RV32I — the golden reference model.
2. An extension of a 13-instruction textbook single-cycle RISC-V core to full RV32I.
3. A 5-stage pipelined version of that same core, with hazard handling.
4. Reintegration of the existing debug (halt/resume) support into the pipeline.

Most of this document was written with no Verilog tooling available, and
says so where it matters. **That is no longer true — see Section 10:
`rtl/` now passes all three testbenches under both Icarus Verilog and
Verilator, and getting there turned up two real RTL bugs.** Sections 1–9
are left as originally written, with pointers forward where simulation
later contradicted or confirmed them; that history is the point, not an
oversight. Section 6 has the run commands.

---

## 1. The ISS (`iss/`)

**What it is.** A from-scratch C++ model of an RV32I CPU: `RV32ISim` holds
32 registers (`regs_[32]`), a `pc_`, and a `Memory` object. `step()` does
fetch → `decode()` → dispatch to one `execXxx()` handler per instruction
*format* (R-type, I-type, load, store, branch, JAL, JALR, LUI, AUIPC,
SYSTEM), not one handler per instruction — `execRType` internally switches
on `funct3`/`funct7` to pick ADD vs SUB vs AND, etc. This is the "dispatch
to handler functions, don't write one giant if-chain" advice from the
original project brief, applied literally.

**Why it matters for everything downstream.** Every subsequent piece of RTL
work in this project got its *expected values* from running the same
instruction stream through this ISS, rather than hand-computing them. That's
not a convenience — it means a human arithmetic mistake in "what should this
register equal after this program runs" can't sneak into the checker itself.
You'll see this pattern (`golden_gen.cpp`) reused three times: once for the
RV32I DUT extension, twice for the pipeline (hazard test + a from-scratch
reasoning-only design for the debug test, which the ISS can't help with
since debug isn't part of RV32I's architectural semantics).

**Key correctness details already handled:**
- `x0` is hardwired to zero in the *write* path (`setReg`), not the read
  path — matches the brief's explicit guidance and how real register files
  do it (the read side would need a mux on every read otherwise; gating the
  write is one line).
- Loads sign/zero-extend correctly: `LB`/`LH` sign-extend via `signExtend()`
  cast through `int16_t`/`int8_t`; `LBU`/`LHU` zero-extend by construction
  (unsigned reads, no extension needed beyond the top bits already being 0
  after masking).
- `JALR` masks bit 0 of the target (`& ~1u`), per spec.

**What's NOT modeled:** CSRs, traps/exceptions (ECALL/EBREAK just set
`halted_`), and — important for cross-checking DUT memory contents — this
is a *unified* (Von Neumann) memory: instructions and data share one address
space. The DUT is Harvard (separate `imem`/`dmem`). This bit us once (see
§2's "memory model mismatch" note) and is worth remembering if you build a
DPI-C bridge later: don't compare raw memory dumps between ISS and DUT at
addresses the test program didn't explicitly touch.

---

## 2. Extending the DUT to full RV32I (`rtl_extension/`)

**Starting point.** `UBC-ORCA/riscv-debug-tutorial/rtl` is Harris & Harris's
*Digital Design and Computer Architecture* single-cycle RV32I core
(`riscvsingle.v`, split into per-module files), with a debug FSM bolted on
top for halt/resume support. Reading `controller.sv`'s `maindec` directly
showed it only ever decodes 13 instructions: `LW SW ADD SUB SLT OR AND BEQ
ADDI SLTI ORI ANDI JAL`. No other branches, no JALR/LUI/AUIPC, no byte/half
loads-stores, no shifts, no XOR, no SLTU. That's the gap this phase closed.

**The single-cycle datapath, briefly** (you need this mental model before
the pipeline section makes sense): one clock cycle = one instruction,
fully combinational path from `PC` → `imem` → decode → regfile read → ALU
→ `dmem` → regfile writeback, all in the same cycle. `controller.sv` has
two sub-modules: `maindec` (opcode → control signals: `RegWrite`,
`ALUSrc`, `MemWrite`, `ResultSrc`, `Branch`, `ALUOp`, `Jump`) and `aludec`
(`ALUOp` + `funct3` + `funct7b5` → the 4-bit `ALUControl` the ALU actually
uses). `datapath.sv` wires the register file, immediate extender, ALU, and
muxes together; `PCSrc` picks the next PC from a 4-way mux (sequential /
branch-or-jump target / debug-halt address / debug-resume address — the
last two already existed from the debug integration).

**What had to change, file by file:**

| File | Change |
|---|---|
| `alu.sv` | `alucontrol` widened 3→4 bits. Added SRA, SLTU. XOR/SLL/SRL already existed as ALU opcodes but were dead code — `aludec` never emitted them. |
| `extend.sv` | `immsrc` widened 2→3 bits, added U-type immediate decode (LUI/AUIPC: just take `instr[31:12]`, zero-fill the bottom 12 bits — no sign extension needed since the immediate already occupies the top bits). |
| `controller.sv` | New opcodes (`jalr`, `lui`, `auipc`) in `maindec`. **The one genuinely new piece of hardware**: `aludec`'s "branch family" case. The original design only ever computed `Zero` via subtraction — enough for BEQ, not enough for BLT/BGE/BLTU/BGEU. Added a `Lt` output from the ALU (`result[0]`, valid when `ALUControl` is SLT/SLTU) and a `take_branch` case statement keyed on `funct3` that picks which comparator result to use and whether to invert it. |
| `datapath.sv` | JALR's target is `rs1+imm`, not `PC+imm` like branch/jal — solved by muxing the *base operand* of the existing branch/jal adder between `PC` and `rs1` (controlled by a new `Jalr` signal) rather than adding a second adder, then masking bit 0 on the result. AUIPC needs `PC` as the ALU's first operand instead of `rs1` (`AUIPCSel` mux). LUI bypasses the ALU (`resultmux` widened 3-way → 4-way to add "just pass the immediate through"). |
| `dmem.sv` | Rewritten from a flat 64-word array to a byte-addressable 256-byte store with real byte-lane read/write logic, selected by a new `funct3` input. Highest-risk file in this phase — sign-extension and byte-lane alignment bugs live here. |
| `imem.sv` | Added a `TESTFILE` parameter (default unchanged) so new testbenches can point at a different program without touching this file. |
| `riscvsingle.sv` / `top.sv` | Pure wiring: new `MemFunct3` port threaded from `Instr[14:12]` down to `dmem`, new `Jalr`/`AUIPCSel`/`Lt` wires between controller and datapath. |
| `cells.sv`, `regfile.sv`, `debug_fsm.sv` | Untouched, copied verbatim. |

**A bug I caught by hand-reasoning, worth understanding.** The ALU's SLT
result uses a "compute `a-b`, then correct the sign bit for overflow" trick
(`sum[31] ^ v`, where `v` is an overflow flag). That overflow correction
must be enabled for exactly three operations: add, sub, and SLT itself
(SLT reuses the same subtract-and-check-sign hardware). When I widened the
ALU control encoding from 3 to 4 bits, I initially wrote the "is this an
add/sub-style operation" gate to only cover add and sub — which would have
silently produced wrong SLT results at the signed boundary (e.g. comparing
`INT_MIN` against `1`), with everything else correct. This is *exactly* the
"immediate edge value" bug class the original project brief calls out. I
fixed it, but flag it here because it's a good illustration of why directed
tests at `0`, `INT_MAX`, `INT_MIN` matter — a bug like this passes almost
every random test and fails only at the boundary.

**Test program & validation approach.** `testgen/asm.py` is a minimal
hand-rolled RV32I encoder (R/I/S/B/U/J format functions). `testgen/
program.py` builds a 60-instruction directed program exercising every new
instruction — including deliberately adversarial cases: JALR with an odd
target address (must mask bit 0), a store to the upper half of a word that
must not disturb the lower half already written, SLTU/SLTIU against
`0xFFFFFFFF`. Labels and branch/jump offsets are resolved by the assembler
itself (two-pass, like a real assembler) instead of hand-counted, because
hand-counting instruction offsets is a classic way to inject exactly the
kind of bug this test program exists to catch.

`testgen/iss_check/golden_gen.cpp` loads that same hex into the ISS,
free-runs it to `EBREAK`, and prints every register plus the two memory
words the program actually stores to, formatted as SystemVerilog assignment
statements — literally the golden values `tb_ext.sv` asserts against
(`golden_vals.svh`, auto-generated, do not hand-edit).

**Memory model mismatch (read this before extending the test program).**
The ISS shares one address space for code and data; the DUT has separate
`imem`/`dmem` arrays. My first pass at `golden_gen.cpp` dumped *every*
memory word 0–15 and got nonsense for addresses the program never stored
to — because the ISS's "memory" at those addresses still held leftover
*instruction* bytes (since instructions and data live in the same array),
while the DUT's `dmem` would correctly show 0 (reset value, separate
array). Fixed by only dumping addresses the program explicitly stores to.
If you extend this test program, remember: only compare DUT/ISS memory at
addresses your program actually writes.

---

## 3. Pipelining the core (`rtl_pipeline/`)

**Why this phase exists at all.** A single-cycle core has no data hazards,
no control hazards, no forwarding, no stalling — every instruction sees a
completely consistent, already-finished machine state. That means an ISS +
scoreboard co-simulation architecture (the whole point of the original
project) is somewhat redundant against it: the class of bug it's designed
to catch (wrong behavior under hazards) doesn't exist in the DUT. Pipelining
introduces real hazards, which is what makes "did my golden model and my
DUT agree after every retiring instruction" a genuinely interesting
question instead of a formality.

**Architecture: classic 5-stage, Harris & Harris naming convention.**
IF → ID → EX → MEM → WB, with a pipeline register between each stage. Every
signal is suffixed with the stage it belongs to (`PCF`, `InstrD`, `ALUResultE`,
`ReadDataM`, `ResultW`, ...) — this isn't cosmetic, it's how you avoid
confusing "the instruction I'm currently talking about" across five
simultaneously-in-flight instructions.

```
   IF          ID          EX          MEM         WB
 ┌─────┐    ┌─────┐    ┌─────┐    ┌─────┐    ┌─────┐
 │ PCF │ -> │InstrD│ -> │ ALU │ -> │dmem │ -> │Result│ -> regfile
 │imem │    │regs  │    │fwd  │    │     │    │ mux  │
 └─────┘    │extend│    │mux  │    └─────┘    └─────┘
            └─────┘    └─────┘
```

**File responsibilities (deliberately separated, mirroring the single-cycle
split):**
- `controller.sv` — pure combinational decode, instantiated *once*, for
  whatever instruction is currently in D. No sequencing logic at all now
  (that moved out — see below).
- `hazard_unit.sv` — all hazard detection: forwarding-source selection,
  the load-use stall, and every flush condition. This is the file to read
  first if you want to understand the pipeline's actual complexity; every
  other file is comparatively mechanical.
- `datapath.sv` — owns every pipeline register, the regfile, the ALU, and
  every stage-local adder/mux. Takes control signals and hazard signals as
  *inputs* rather than computing them itself.
- `riscv_pipe.sv` — top-level wiring (the pipelined analog of
  `riscvsingle.sv`), plus the debug FSM instantiation.

### 3.1 Where each instruction class resolves

This is the design decision with the most downstream consequences, so it's
worth being explicit:

- **Branches and JALR resolve in EX.** They need forwarded operands (a
  branch might compare against a value produced by the immediately
  preceding instruction) or, for JALR, an actual register value — neither
  is available combinationally in ID. Consequence: when taken, **two**
  already-fetched instructions (the one in D, and the one that was in F and
  is about to enter D) are wrong-path and must be flushed.
- **JAL resolves in ID.** Its target (`PC + imm`) has no register
  dependency at all, so there's no reason to wait for EX. Consequence: only
  **one** bubble (the instruction currently in F) instead of two.
- **LUI passes the immediate straight through the ALU** as a new `PASSB`
  op (`result = b`) instead of needing a dedicated 4th writeback-mux source
  threaded through three extra pipeline registers. Small simplification,
  but it's why `alu.sv` has an 11th opcode that didn't exist in the
  single-cycle version.

### 3.2 Forwarding

`ForwardAE`/`ForwardBE` (2 bits each) steer the EX-stage ALU operands away
from a stale register-file read toward a more recent in-flight result:

| Value | Source | Meaning |
|---|---|---|
| `00` | `RD1E`/`RD2E` | No hazard — regular regfile read is fine |
| `10` | `ALUResultM` | Forward from the instruction currently in MEM |
| `01` | `ResultW` | Forward from the instruction currently in WB |

M is checked before W in `hazard_unit.sv`'s priority `if`/`else if` chain
because if both match (three dependent instructions in a row), M is the
*more recent* producer.

**Store-data forwarding** is the same mechanism, easy to forget: the value
a `SW`/`SH`/`SB` writes to memory is just another consumer of `rs2`, so it
needs identical forwarding treatment. `WriteDataE` (the forwarded rs2
value) feeds *both* the ALU's B input (when `ALUSrc=0`) *and* is latched
into `EX/MEM` as the store's data, regardless of `ALUSrc`. There's a
directed test for this specifically (§3.5) because it's a classic thing to
silently omit.

**A wiring bug I caught by manually cross-checking port order against
`hazard_unit.sv`'s encoding**, worth understanding because it's the kind of
mistake that produces a wrong *answer*, never a compile error: `mux3`
selects its first data input on select-value `00`, second on `01`, third
on `10`. I initially wired `forwardamux`'s inputs as
`(RD1E, ALUResultM, ResultW)` — but `hazard_unit.sv`'s encoding is
`01`=forward-from-**W**, `10`=forward-from-**M**, so the M and W sources
were swapped. Fixed to `(RD1E, ResultW, ALUResultM)`. This is exactly why
§6's directed test specifically forces both an M-forward and a W-forward
in the same short instruction sequence — a bug like this only shows up
under a hazard, never in a hazard-free run.

### 3.3 The load-use stall

Forwarding can't produce data that doesn't exist yet. A load's result
isn't available until it reaches MEM — one cycle later than EX/MEM
forwarding can supply. If the instruction currently in D needs the value a
load *currently in EX* is about to produce, the pipeline must stall one
cycle: freeze `PCF` and the `IF/ID` register (`StallF`/`StallD`), and
insert a bubble into `ID/EX` (`FlushE`) so the dependent instruction
re-enters EX one cycle later, by which time the load has reached MEM/WB
and forwarding covers it normally.

**A second bug this surfaced, also fixed**: the raw hazard check (`does
the EX-stage load's destination register number match the D-stage
instruction's rs1/rs2 bit positions`) doesn't know instruction *types*.
JAL, LUI, and AUIPC reuse those exact same bit positions (`InstrD[19:15]`,
`InstrD[24:20]`) as *immediate* bits, not register indices. Without
gating, a JAL whose immediate happens to numerically collide with a
preceding load's destination register would spuriously stall — and worse,
`StallF` freezing `PCF` the same cycle the JAL needs to redirect it would
silently *drop the jump*. Fixed by adding `Rs1UsedD`/`Rs2UsedD` outputs to
`controller.sv`'s `maindec` (1 for every opcode that genuinely reads those
fields, 0 for JAL/LUI/AUIPC) and gating the stall check with them.

### 3.4 Flushes — three different ones, three different reasons

| Flush | Squashes | Trigger | Why |
|---|---|---|---|
| `FlushD` | `IF/ID` → NOP | `PCSrcE` (taken branch/jalr) OR `JumpD` (jal) OR `EnterDebug` | The F-stage content was fetched sequentially and is wrong-path (or debug is halting) |
| `FlushE` | `ID/EX` → bubble | `PCSrcE` OR load-use stall OR `EnterDebug` | The D-stage content is either wrong-path, or needs to wait one more cycle |
| `FlushM` | `EX/MEM` → bubble | `EnterDebug` **only** | See §4 — this one has no branch-misprediction analog |

The injected bubble is the *real* RISC-V NOP encoding, `32'h00000013`
(`ADDI x0, x0, 0`) — not all-zeros, which would decode as a `LOAD` opcode
and do something wrong.

### 3.5 Directed hazard test (`tb_pipe_hazard`, in `tb_pipe.sv`)

`testgen/program.py` builds a short program isolating each hazard category
so a failure points at specific logic:

1. Back-to-back RAW (needs EX/MEM forwarding twice in a row, including a
   case where the *same* cycle needs both an EX/MEM forward and a MEM/WB
   forward for different operands).
2. Two-apart RAW (needs MEM/WB forwarding specifically).
3. Load-use hazard (must stall — proves forwarding alone isn't enough).
4. Store-data forwarding (store a forwarded value, then read it back to
   prove the *stored* value was correct, not stale).
5. Taken branch immediately followed by dependent instructions (proves
   flush doesn't leave stale operands sitting in a "squashed" pipeline
   register that later gets misread).
6. JAL immediately followed by a dependent instruction (1-bubble flush).
7. An attempted write to `x0` immediately followed by real use of `x0` as
   an operand — proves the *forwarding* path (not just the regfile's read
   mux) correctly refuses to forward a value toward a "write" that's
   architecturally a no-op.

Checked the same way as the RV32I extension: run through the ISS first
(architectural end-state is timing-independent — a pipeline and a
single-cycle core must produce *identical* final register/memory contents
for the same program, only the cycle count differs), bake those values into
`golden_vals_pipe.svh`, assert against them in simulation.

---

## 4. Debug reintegration in the pipeline

The single-cycle debug FSM (`debug_fsm.sv` — completely unchanged in
*behavior* through every milestone up to the lowRISC style-guide retrofit
in §12, which converted its state encoding from two `parameter` constants
to a typedef enum; see that file's own header for exactly what did and
didn't change) has a simple contract: given a `pc` snapshot and an
`enter_debug`/`exit_debug` pulse, it tracks halted/running state, latches
`dpc = pc` on entry, and tells the datapath where to redirect fetch. The
single-cycle version fed it the (only) PC there was; the pipeline needs to
decide *which* in-flight instruction's PC to snapshot, since there are four
candidates at any moment.

**Design decision:** feed it `PCE` — the EX-stage PC — and treat entering
debug mode as squashing the two youngest in-flight instructions (currently
in D and E) while letting whatever's in M and W complete normally (they're
already committed). Concretely:

- `is_ebreak`/`is_dret` are decoded once in D (same as the single-cycle
  version) and pipelined through `ID/EX`, becoming `is_ebreakE`/`is_dretE`
  — which has a nice side effect for free: if an `ebreak` gets flushed by
  an *earlier* branch misprediction before it would have retired, its
  control bits (including `is_ebreak`) get zeroed by that same flush, so a
  never-really-executed `ebreak` correctly never triggers a halt.
- On `enter_debug`: `FlushD` and `FlushE` fire (same mechanism as a branch
  misprediction — squash D and what's entering E), **and** a new `FlushM`
  fires, squashing whatever's currently in E from ever reaching `EX/MEM`
  for real. `FlushM` has no branch-misprediction equivalent — by the time
  a branch resolves in E nothing wrong has reached E yet — but a debug
  halt request is asynchronous and can arrive while a perfectly correct,
  in-order instruction is sitting in EX. The design choice is to squash it
  rather than let it retire; since `dpc = PCE` (its own PC), it cleanly
  re-executes for real once the core resumes. This directly generalizes
  the single-cycle design's "gate this instruction's `RegWrite`/
  `MemWrite`, save its PC" behavior to four pipeline stages.
- The PC mux gains a priority level above everything else:
  `EnterDebug > ExitDebug > PCSrcE > JumpD > sequential`. A halt request
  wins over a simultaneously-resolving branch.

**What I could not verify without a simulator, and you should check
first.** This is meaningfully higher-risk than §2 or §3.1–3.4 — pipeline +
async-halt interaction has more moving parts than pure hazard logic, and I
don't have the same "run it through the ISS" cross-check available (debug
behavior isn't part of RV32I architectural semantics, so there's no golden
model for it). `tb_pipe_debug` (in `tb_pipe.sv`) checks the robust
properties (halt eventually happens, PC lands at `dm_halt_addr_i`, the
core eventually resumes and makes forward progress again) but explicitly
does **not** assert "the interrupted instruction's register stays frozen
while parked" — the debug ROM here is a bare `dret` at address `0x0C` (same
convention as the *original* tutorial's own minimal test program), not a
real parking loop a debugger explicitly breaks out of, so the halted window
is only a few cycles wide and racy to assert against without knowing exact
simulator timing. See the comment in `tb_pipe.sv` for the full reasoning.

**Recommended verification order** (don't debug both at once):
1. Run `tb_pipe_hazard` first, get it passing. This isolates pure pipeline/
   hazard correctness from debug entirely.
2. Only then run `tb_pipe_debug`. If it fails, you know the base pipeline
   is solid and the bug is specifically in the halt/flush/resume logic.

---

## 4.5 Code-quality pass, informed by real open-source implementations

Looked at several real GitHub repos for structural inspiration before
this pass: `HafizMutahirAhmed/RV32I-5-Stage-Processor` (RV32I 5-stage
with forwarding + hazard detection, RISCOF-compliance-tested — good
validation that this project's scope and architecture matches what real
implementers consider "complete"), and two UVM-for-RISC-V references —
`gopro-uvm-rtl-verification/RISC-V-CPU-Core-UVM-Based-ISA-Compliance-Verification`
and OpenHW's `core-v-verif` — both of which sample a **commit/retire
interface** and check it against a **DPI golden model** at the commit
boundary, exactly the architecture this project's UVM section already
described. That's a useful confirmation the plan was already pointed the
right direction; the concrete thing worth borrowing was *how* they
structure that boundary.

**Changes made, both mechanical/low-risk and re-verified with the same
manual port-cross-check discipline used throughout this project:**

- **`rv32i_pkg.sv`** — a SystemVerilog package holding named opcode and
  ALU-control constants (`OPC_JALR`, `ALU_SLTU`, etc.) instead of the
  magic hex/binary literals previously scattered through `controller.sv`
  and referenced ad hoc in `alu.sv`'s case statement. This isn't purely
  cosmetic: every real bug caught during this project's construction
  (the swapped forwarding-mux order, the missing `Rs1UsedD` gate) was a
  *wiring* bug, and magic literals are exactly where the next one hides.
  A typo'd package constant either fails to compile or is wrong in
  exactly one place, instead of being silently wrong inside a literal
  that looks plausible on a quick read.
- **`id_ex_ctrl_t`** — the ID/EX pipeline register's control bundle
  (`RegWrite`, `MemWrite`, `Branch`, `ALUSrc`, `Jalr`, `AUIPCSel`,
  `ResultSrc`, `ALUControl`, `is_ebreak`, `is_dret`) is now one packed
  struct instead of 10 separate ports threaded through `controller.sv`,
  `datapath.sv`, and `riscv_pipe.sv`. `controller.sv`'s internal
  `maindec`/`aludec` decode logic is untouched — only the *interface*
  boundary changed, deliberately, since re-deriving proven decode logic
  from scratch would have been strictly more risk for no benefit. A
  future new control signal (say, branch prediction's "predicted taken"
  bit) is now one struct field instead of a new port in three files.
- **`retire_if.sv`** — a proper SystemVerilog `interface` for the
  WB-stage retirement boundary (`pc`, `instr`, `rd`, `wdata`,
  `regwrite_valid`), with a `clocking` block and a read-only `MON`
  modport. This is modeled directly on the `commit_if.sv` pattern from
  the UVM reference repos above. Instantiated in `riscv_pipe.sv` and
  driven from `datapath.sv`'s new retirement outputs — including
  `InstrW`, which didn't exist before this pass and was specifically
  called out as a gap in §7's "Step 2" (a monitor needs the retiring
  instruction word, not just that something retired). Not yet threaded
  up through `top.sv`'s port list, since nothing outside `riscv_pipe.sv`
  consumes it yet; a UVM monitor will bind to it directly
  (`dut.rvpipe.retire`) or `top.sv` gets a port added when that monitor
  is actually written.

**Automated cross-check, not just manual this time.** Given how much
surface area changed at once, every named-port module instantiation in
the pipeline was diffed programmatically against its module declaration
(port set equality, not just eyeballing), and every positional
instantiation (the `cells.sv` primitives, `alu`, `regfile`, `extend`)
had its argument count checked against the target module's port count.
All passed. This catches "did I connect the right number/names of
signals," which is necessary but *not* sufficient — it would not have
caught the earlier forwarding-mux-argument-order bug, because that bug
had the right count and right names, just the wrong two arguments
swapped in a positional call. That class of bug still needs either
simulation or the kind of semantic manual review this project has been
doing throughout (see the comment directly above `forwardamux` in
`datapath.sv`, which exists specifically to make that check easy to redo
by eye next time).

**What this refactor deliberately did NOT touch:** `alu.sv`'s own case
statement still uses raw 4-bit literals rather than referencing
`ALU_ADD`/`ALU_SUB`/etc from inside itself (it's the file that *defines*
the encoding via its header comment table, so the constants would be
somewhat circular there); `dmem.sv`, `imem.sv`, `cells.sv`, `regfile.sv`,
`debug_fsm.sv` are unchanged. Widening the struct/package treatment to
those, or to the RV32I-extension (`rtl_extension/`) single-cycle files,
is a reasonable next increment but wasn't done here to keep this pass's
blast radius bounded and fully re-checkable in one sitting.

**RISCOF / riscv-arch-test — attempted, blocked by sandbox limits, not
skipped by choice.** `pip install riscof` succeeded, but there's no
RISC-V cross-compiler in this sandbox and no root to install one, and a
direct download of a prebuilt toolchain release was blocked by the
sandbox's network allowlist. Running the actual official RISC-V
compliance suite against the ISS — the single strongest credibility line
available for the write-up, and the star feature of essentially every
serious RV32I implementation found during this search — needs to happen
on your machine, not here. Concretely: install a `riscv32-unknown-elf-gcc`
toolchain (or the `riscv-none-elf-gcc` xPack prebuilt release), clone
`riscv-non-isa/riscv-arch-test`, and write a `riscof` Python plugin whose
`runTests()` shells out to a small wrapper around the already-built
`RV32ISim` (load the compiled ELF's `.text`/`.data`, run to the test's
`tohost` completion signal, dump the `begin_signature`/`end_signature`
memory region to the file format `riscof` expects for comparison against
the reference signatures). The ISS doesn't currently parse ELF files
(the test programs so far were hand-assembled to raw hex) — that's the
one piece of new ISS code this would actually require; everything else
in `RV32ISim` is already exactly what's needed.

---

## 5. Deliberately not done (and why)

- **Branch prediction.** You asked about this mid-session. A simple static
  predictor (backward-taken/forward-not-taken, misprediction = flush +
  redirect, same mechanism already built) is realistic and not a large
  lift once the base pipeline is verified — but stacking a third unverified
  mechanism on top of two others I also couldn't simulate would make any
  bug much harder to isolate. Natural next step, not done here.
- **CSRs / real trap handling.** `SYSTEM` still decodes as a NOP except for
  the `ebreak`/`dret` special-casing debug already needed. No `mtvec`/
  `mepc`/`mcause`, no illegal-instruction or misaligned-access traps.
- **Compressed instructions (RV32IC).** Different fetch/decode shape
  entirely (16-bit instructions, PC+2), not attempted.

---

## 6. How to actually run all of this

> **Superseded in part by §10.** This has since been run, on both Icarus
> Verilog and Verilator, and all three testbenches pass. The short version
> is now just:
>
> ```bash
> cd rtl && ./run_sim.sh          # both simulators, all three testbenches
> ./run_sim.sh verilator hazard   # or narrow it down
> ```
>
> `run_sim.sh` passes `-DRTL_ONLY_NO_CLOCKING`, which both free simulators
> need in order to skip `retire_if.sv`'s UVM-only clocking block (§10.5).
> The hand-written command lines below still work and are kept because they
> spell out the file order and what each testbench checks -- but add that
> define if you run them directly.

The rest of this section was written when there was no simulator available
at all, which is no longer the case (§10).

Note on repo structure: the standalone single-cycle-only regression test
described when this section was first written (`rtl_extension/`'s
`riscvsingle.sv` + `tb_ext.sv`) is no longer present in this repo — that
milestone's source was retired once the pipeline superseded it, in favor
of one current `rtl/` rather than several redundant snapshots (see the
top-level README). Its role — confirm the ISA extension itself, isolated
from pipeline/hazard logic — is still worth understanding conceptually
(§2), it's just not separately runnable here anymore. What follows is the
current, complete command set for `rtl/`, superseding the two-milestone
version of this section:

```bash
cd rtl
# rv32i_pkg.sv must come first -- every other file imports it. csr_file.sv/
# clint.sv/uart_tx.sv/mem_bus.sv are required even for the hazard/debug
# testbenches now, since mem_bus.sv unconditionally sits under top.sv --
# see tb_pipe.sv's header comment.
FILES="rv32i_pkg.sv cells.sv regfile.sv alu.sv extend.sv retire_if.sv \
    controller.sv hazard_unit.sv csr_file.sv clint.sv uart_tx.sv mem_bus.sv \
    datapath.sv debug_fsm.sv riscv_pipe.sv dmem.sv imem.sv top.sv tb_pipe.sv"

# 1. Pipeline, hazards only (no debug, no CSR/trap)
iverilog -g2012 -o sim_hazard -s tb_pipe_hazard $FILES
vvp sim_hazard
# expect: PASS: all 32 registers + 2 dmem words match ISS golden values

# 2. Pipeline + debug halt/resume
iverilog -g2012 -o sim_debug -s tb_pipe_debug $FILES
vvp sim_debug
# expect: PASS: debug halt/resume works on the pipelined core

# 3. CSR/trap/interrupt/UART (see §8.4 for the golden-value regen command)
iverilog -g2012 -o sim_csr -s tb_pipe_csr $FILES
vvp sim_csr
# expect: PASS: all 32 registers match ISS golden values (CSR/trap/
# interrupt/UART), UART TX stream correct
```

If any of these fail, the `$display` names the exact register or memory
word (tests 1/3) or the exact check (test 2) that mismatched — that
localizes the bug immediately rather than requiring a waveform dive.
**Waveforms are still your friend if a `PASS`/`FAIL` alone doesn't explain
*why*** — dump with `$dumpfile`/`$dumpvars` and open in GTKWave.

---

## 7. Starting the UVM phase

Your original plan's Phase 2–3 (DPI-C bridge, then UVM) targeted whatever
DUT existed at the time. Two things changed since that plan was written:
the DUT is now full RV32I (so the ISS you validate against should stay
full RV32I, no scope mismatch), and — if you pipeline-verify before
starting UVM, as recommended — the DUT has real hazards, which is what
makes the co-sim architecture actually worth building instead of
optional.

**Step 1 — DPI-C bridge, non-UVM throwaway harness first (your Phase 2,
unchanged in spirit).** The one thing that's different for a pipelined DUT
vs. what the plan assumed: **"retirement" is not a single clean
same-cycle event anymore.** In the single-cycle core, every cycle *is* a
retiring instruction. In the pipeline, an instruction retires when it
exits WB — meaning your monitor needs to watch the `MEM/WB` → regfile
write boundary specifically (`RegWriteW` asserted, or `dut.rvpipe.dp.RdW`
with a valid write that cycle), not just "the DUT executed something this
cycle." Also watch for: a cycle where `RegWriteW` is asserted but the
instruction currently retiring was a *bubble* injected by a flush (its
`RegWriteW` will correctly read 0, so this should already be handled for
free by the flush-to-NOP design — but verify it in the monitor rather than
assuming).

Minimal DPI-C surface, same three functions as your original plan:
```systemverilog
import "DPI-C" function void iss_step(input logic [31:0] instr);
import "DPI-C" function int  iss_get_reg(input int idx);
import "DPI-C" function int  iss_get_pc();
```
`iss_step` should call into `RV32ISim::step()` (already built, already
validated) — you're not writing new ISS code here, just a thin C wrapper
Verilog can call.

**Step 2 — scoreboard design, adapted for retirement timing.** On each WB-
stage retirement (not each cycle), pull the retiring instruction's *word*
(you'll need the monitor to carry `InstrW` through the pipeline
alongside the other MEM/WB signals — currently not plumbed, since nothing
needed it yet; add a pass-through field), call `iss_step()` with that same
word, then compare: `ResultW`/regfile-write-value against `iss_get_reg
(rd)`, and `PCPlus4W`/whatever this instruction's *next-PC-should-have-
been* against `iss_get_pc()`. Log mismatches with the instruction word,
expected vs. actual, and — since you'll have it — which pipeline hazard
(if any) was active for that instruction, which massively shortens debug
time versus a bare "register 7 mismatched" message.

**Step 3 — sequences.** Constrained-random: randomize opcode class first,
then legal operand fields (exactly as your plan specifies), so you get
valid-but-unpredictable streams. For a *pipelined* DUT specifically, bias
the sequence generator toward back-to-back register dependencies more
often than uniform-random would — hazard logic is the highest-density bug
surface here, and uniform-random opcode/register selection will hit true
hazards far less often than a generator that deliberately makes `rd` of
instruction N equal `rs1`/`rs2` of instruction N+1 some fraction of the
time.

**Step 4 — directed corner cases**, updating your original list for what's
now actually implemented:
- `x0` writes are no-ops — already directly tested at the RTL level
  (§3.5, case 7); re-verify through the full UVM env too, since the
  forwarding-to-x0 bug class is specifically a pipeline-only risk.
- Forward and backward branches — done at RTL level (§2's test program);
  extend to randomized offsets through UVM.
- Load-use hazard — **now directly relevant**, unlike your original plan's
  note that it's "less relevant on single-cycle." This DUT has one. Make
  it a first-class directed sequence, not a footnote.
- Sign-extension boundaries on LB/LH, immediate edge values (0, max
  positive, max negative) — done at RTL level for both the ALU (§2's SLT
  bug) and `dmem` (§2's byte-lane tests); still worth dedicated UVM
  coverage bins so gaps get caught systematically rather than by luck.

**Step 5 — coverage**, per your original Phase 4 plan, now with new bins
that matter specifically because of the pipeline: forwarding-path taken
(EX/MEM vs. MEM/WB vs. none) crossed with instruction type, load-use stall
taken/not-taken, flush-due-to-branch vs. flush-due-to-JAL vs.
flush-due-to-debug (three different `Flush*` trigger reasons — see §3.4's
table — make sure your coverage model distinguishes them, not just "a
flush happened").

**Step 6 — bug seeding (your Phase 5, unchanged and still the best idea in
the whole plan).** Good candidate seeded bugs specifically informed by
today's work, since they're bugs *of the same shape* as ones actually
caught during construction:
- Swap the forward-mux source order for `ForwardAE`/`ForwardBE` back to
  the wrong one (§3.2's real bug, reintroduced on purpose) — confirms your
  scoreboard catches a hazard-only bug that a hazard-free random run would
  never expose.
- Remove the `Rs1UsedD`/`Rs2UsedD` gating from the load-use check (§3.3's
  real bug) — confirms coverage-driven random testing (or a specifically
  targeted directed sequence) actually generates the JAL-with-colliding-
  immediate-bits case needed to catch it, since it's a narrow corner case.
- Flip `SRA`/`SRL` selection in `aludec` (drop the `funct7b5` check) —
  classic sign-extension-adjacent bug, cheap to seed, easy to verify the
  scoreboard flags it via the shift-with-negative-operand test case
  already in §2/§3.5's programs.

This gives you three seeded bugs with a documented reason each one is
representative of a real bug class this project actually produced, rather
than three arbitrary bit-flips — which is a stronger answer to "how do you
know your verification environment is any good" than the generic version

## 8. CPU-design milestone: CSR, traps, timer interrupt, and a memory-mapped UART (`rtl/`)

This is the answer to "how much more CPU design does the project need
before it stops looking like DDCA." §5 flagged memory size, CSRs/traps,
and a UART as the highest-leverage remaining gaps; this milestone does
all three at once, plus a real machine-timer interrupt (a genuine async
event, not just a synchronous fault), built on top of `rtl_pipeline/`.
Reference points actually looked at before writing any of this: VenomCPU
(`JohnH2448/Anvil-Demo`, a 5-stage RV32I+Zicsr M-mode core — closest
analog for the CSR/trap shape), `AleksandarLilic/ama-riscv` (5-stage
RV32IM with a memory-mapped UART, verified in lockstep against an ISA
sim over DPI — structurally close to this whole project), and
`ultraembedded/riscv_soc` / NEORV32 for peripheral memory-map
conventions (a flat address-range decoder in front of a few MMIO
registers, not an AXI/Wishbone bus — deliberately simple).

### 8.1 What changed, file by file

- **`rv32i_pkg.sv`** — CSR addresses (`CSR_MSTATUS`/`MIE`/`MTVEC`/
  `MSCRATCH`/`MEPC`/`MCAUSE`/`MTVAL`/`MIP`/`MHARTID`), trap cause codes
  matching the RISC-V standard numbering, `CLINT_BASE`/`UART_BASE`, a new
  `RESULT_CSR` writeback-mux source (the 4th, previously-unused
  `ResultSrc` encoding), and six new `id_ex_ctrl_t` fields (`is_ecall`,
  `is_mret`, `is_csr`, `csr_op`, `csr_use_imm`, `is_illegal`).
- **`controller.sv`** — decodes ECALL/MRET/CSRRW/S/C (+ the `*I`
  immediate variants) the same way EBREAK/DRET already were: matched
  against `Instr[31:20]`/`funct3` in the top-level module, not inside
  `maindec`. A coarse illegal-instruction check (unrecognized opcode, or
  unrecognized `funct3`/`funct12` under SYSTEM) rides along the same
  path. `Rs1UsedD` gets one more case: `CSRRWI`/`SI`/`CI` reuse
  `InstrD[19:15]` as a 5-bit immediate, not a register index — same
  class of fix as JAL/LUI/AUIPC already needed.
- **`csr_file.sv`** (new) — the M-mode CSR bank itself: `mstatus`
  (MIE/MPIE only), `mie`/`mip` (MTIE/MTIP only), `mtvec` (direct mode
  only), `mepc`, `mcause`, `mtval`, `mscratch`. Commits writes at
  **EX-stage timing** — one stage earlier than `dmem`, which commits from
  registered MEM-stage signals — because only one instruction occupies EX
  per cycle in this in-order pipeline, so there's no WAW risk, and it
  avoids needing to pipeline write-enable/data through another register
  stage. The one thing this timing choice requires: the caller must
  suppress `csr_we`/`trap_en`/`mret_en` on any cycle where `EnterDebug`
  also fires, so a CSR write can't sneak in the instant before debug
  halts an instruction the rest of the pipeline is treating as squashed.
  That gating lives in `datapath.sv`, not inside `csr_file.sv` itself —
  see its header comment for the full reasoning.
- **`clint.sv`** / **`uart_tx.sv`** (new) — deliberately simplified
  peripherals: a 32-bit free-running `mtime` + `mtimecmp` (real CLINTs
  are 64-bit; not needed here), and a TX-only UART with an instant-
  transmit model (no baud-rate timing — `UART_STATUS.TX_READY` is always
  1). Both are memory-mapped, not CSR-mapped, matching real hardware.
- **`mem_bus.sv`** (new) — the address decoder sitting between the core's
  one load/store port and RAM/CLINT/UART. `top.sv` now instantiates this
  instead of `dmem.sv` directly; nothing in `riscv_pipe.sv` or
  `datapath.sv` changed to accommodate it, since it presents the exact
  same we/addr/wdata/funct3/rdata shape `dmem.sv` always did.
- **`dmem.sv`** / **`imem.sv`** — the memory-widening fix: both are now
  parameterized (`MEM_BYTES`/`MEM_WORDS`, defaulting to 16KB each) instead
  of hardcoded to 256 bytes / 64 words. The byte-lane logic itself didn't
  change.
- **`datapath.sv`** — the real integration work. New EX-stage logic:
  CSR write-data computation (a small dedicated RW/RS/RC mux, not a reuse
  of the main ALU — CSRRC needs an AND-with-inverted-operand the ALU
  doesn't have a control code for); exception detection (illegal
  instruction, ecall, misaligned load/store address, checked in that
  priority order); a `validE` register that's 0 only on a flush-inserted
  bubble, gating the timer-interrupt check specifically so a bubble can
  never be mistaken for an interruptible instruction and corrupt `mepc`
  with PC=0; and the trap/mret PC redirect, slotted into the fetch mux
  above `PCSrcE`/`JumpD`, below `EnterDebug`/`ExitDebug`.
- **`hazard_unit.sv`** — `FlushD`/`FlushE` now also fire on `trap_en` or
  `mret_enE` (same reasoning as a mispredicted branch: whatever's
  sequentially in D/about-to-enter-E is wrong-path). `FlushM` gets
  `trap_en` added but deliberately **not** `mret_enE` — a trap means the
  EX-stage instruction itself is the one faulting, so its own
  RegWrite/MemWrite must be squashed as it moves into MEM (same mechanism
  debug-halt already used); mret has no such self-effect to suppress.
- **`rv32isim.cpp`/`.hpp`** (the ISS, `iss/`) — extended to stay
  in lockstep with all of the above: the same CSR addresses, same
  mcause encoding, same trap priority, same MMIO address windows, so it
  remains a valid scoreboard reference for the new RTL behavior. One
  structural difference is unavoidable and documented in the file header:
  this is a single-issue, no-pipeline model, so "one `step()`" is the
  natural unit of forward progress the same way "one clock edge" is in
  the RTL, but the two don't correspond 1:1 — which is why the timer-
  interrupt test checks "did the handler run at least once," not "did it
  fire on exactly cycle N."

### 8.2 The two timing decisions worth understanding, not just accepting

**Why CSR writes commit at EX instead of MEM.** Every other piece of
committed state in this pipeline (`dmem`, the register file via `ResultW`)
commits from a *registered*, one-stage-later signal specifically so
`FlushM`/`EnterDebug` can squash it before it lands. CSR writes don't
follow that pattern — they commit directly from EX-stage combinational
logic, gated by an explicit `~EnterDebug` term instead. This was a
deliberate simplification, not an oversight: threading `csr_we`/
`csr_wdata` through the EX/MEM register just to reuse the exact same
squash mechanism would have been more code for no behavioral difference,
since gating at the source is equally correct as long as it's not
forgotten anywhere. If you extend this CSR file later (S-mode, PMP,
performance counters), keep that gate in mind — it's the one place a new
CSR-writing code path could silently reintroduce the debug-preemption bug
this section exists to explain.

**Why the interrupt handler must NOT `mepc += 4`, but the exception
handlers must.** This is the single easiest mistake to make writing the
test program's trap handler (and it's exactly the kind of thing worth
asking about in an interview to see if a candidate actually understands
precise interrupts vs. synchronous exceptions, not just the mechanics of
CSR encoding). A synchronous exception's faulting instruction — illegal
opcode, ecall, misaligned access — genuinely cannot complete; `mepc`
points at it, and if the handler `mret`s without advancing past it, the
core just re-faults on the same instruction forever. An interrupt is
different: it *preempts* an instruction that would otherwise have
executed correctly. `mepc` points at that not-yet-executed instruction,
and the handler must leave `mepc` alone so `mret` re-enters normal
execution exactly where it left off. `testgen/program_csr.py`'s handler
branches on `mcause[31]` (the interrupt bit) specifically to give the two
paths different epilogues — bump a counter and defer `mtimecmp` (so the
condition doesn't refire the instant `mret` restores `mstatus.MIE`) for
the interrupt path; bump a counter and `mepc += 4` for the exception
path.

### 8.3 Verification: this milestone got a real compiler, not just review

Every earlier milestone in this project was written under the same hard
constraint: no RISC-V toolchain, no SystemVerilog simulator, in this
sandbox — verification meant careful manual/static review and an
ISS-vs-RTL golden-value comparison that could never actually be *run*.
That changed partway through this milestone: `pip install pyslang`
(Python bindings for **slang**, a real SystemVerilog compiler/elaborator)
worked, which meant the RTL could finally be checked by a tool instead of
just by eye.

What that actually caught, concretely:
- **Two genuine pre-existing forward-reference bugs**, present since the
  original pipeline was written, invisible because Icarus Verilog (the
  simulator all the run-commands in this guide target) tolerates
  module-scope forward references that stricter tools don't: `ResultW`
  used in `datapath.sv`'s `regfile`/`forwardamux`/`forwardbmux` before its
  own declaration, and `enter_debug` used in `riscv_pipe.sv`'s
  `hazard_unit` instantiation before its declaration. Both fixed by
  moving the declaration earlier — no logic changed, just ordering.
- **One bug this milestone itself introduced**: `tb_pipe_hazard`'s
  backdoor memory-word check used the hierarchical path
  `dut.dmem.mem[...]`, which broke the moment `mem_bus.sv` started
  sitting between `top.sv` and `dmem.sv` (the instance is now
  `dut.bus.dmem_inst.mem[...]`). This is exactly the kind of regression a
  real simulator run would catch in seconds and pure code review can
  easily miss — found here because elaboration actually resolves
  hierarchical paths.

With those three fixes, all three testbench targets (`tb_pipe_hazard`,
`tb_pipe_debug`, `tb_pipe_csr`) elaborate cleanly under slang with every
warning class enabled (`-Weverything`), including width/type/port
checks — real evidence of structural correctness (ports connect, types
and widths agree, hierarchical paths resolve) that no earlier milestone
in this project had. It does **not** mean the testbenches were actually
simulated — slang elaborates, it doesn't execute `initial` blocks or
`$display` — so "does the logic behave correctly at runtime" still rests
on the manual EX/MEM/WB timing analysis in §8.1/§8.2 plus the ISS-side
validation below, not on this tool.

> **Follow-up (§10).** That last caveat turned out to be the important
> one. The testbenches have since been run for real, and elaboration-clean
> did *not* imply correct: two genuine RTL bugs were sitting behind it, one
> of which (§10.1) would have broken essentially any real program. Static
> checking bought exactly what it claims to buy — structure — and nothing
> about behaviour. Worth remembering the next time a clean elaboration
> feels like a result.

**The ISS half, unlike the RTL, actually ran.** `iss/` is plain
C++ against a host compiler, which *is* available in this sandbox
(`g++`). `testgen/program_csr.py`'s directed test — CSR read/write
semantics, an ecall trap, an illegal-instruction trap, a misaligned-load
trap, a misaligned-store trap, two UART TX bytes, and a timer interrupt,
all in one program — was assembled, executed against the extended ISS,
and produced exactly the expected result on the first fully-wired
attempt: `trap_count=5`, all four trap-type counters (`x28`–`x31`) at
their expected values, both UART bytes captured in order, and — the one
that actually matters most, verifying interrupt semantics specifically
(§8.2) — `x25` showing the preempted instruction's marker value,
confirming it re-executed correctly after `mret` rather than being
skipped or re-executed twice. That's real execution, not review, and
it's the golden-value source `golden_vals_pipe_csr.svh` was generated
from.

### 8.4 Running it

```
# CSR/trap/interrupt/UART directed test (needs pyslang or iverilog to
# actually elaborate/simulate; ISS-side validation already done above)
iverilog -g2012 -o sim_csr -s tb_pipe_csr rv32i_pkg.sv cells.sv \
    regfile.sv alu.sv extend.sv retire_if.sv controller.sv \
    hazard_unit.sv csr_file.sv datapath.sv debug_fsm.sv riscv_pipe.sv \
    dmem.sv clint.sv uart_tx.sv mem_bus.sv imem.sv top.sv tb_pipe.sv
vvp sim_csr
# expect: PASS: all 32 registers match ISS golden values (CSR/trap/
# interrupt/UART), UART TX stream correct

# re-run tb_pipe_hazard/tb_pipe_debug too -- mem_bus.sv now sits under
# top.sv unconditionally, so both need the same expanded file list (see
# tb_pipe.sv's header comment for the exact commands)

# regenerate golden values from the ISS after any RTL-side trap/CSR change.
# golden_gen_csr.cpp builds directly against the shared iss/ source (no
# vendored copy -- see the top-level README's note on this) via a
# relative include path:
cd rtl/testgen/iss_check
g++ -std=c++17 -I../../../iss/include golden_gen_csr.cpp \
    ../../../iss/src/memory.cpp ../../../iss/src/rv32isim.cpp -o golden_gen_csr
./golden_gen_csr ../riscvtest_pipe_csr.hex > ../../golden_vals_pipe_csr.svh
```

### 8.5 What's still deliberately not done

Same spirit as §5: named here so it reads as scoped, not forgotten.
S-mode/U-mode and PMP (this is M-mode only, which is a defensible and
common scope for a project this size — plenty of real embedded RISC-V
cores ship M-mode-only). Vectored `mtvec` mode (`mtvec[1:0]` is stored
but always treated as direct mode). Software/external interrupts (only
the timer is wired up — `mie`/`mip`'s MSIP/MEIP bits don't exist). Full
illegal-instruction coverage (a bogus `funct7` on a known R-type opcode
isn't caught — only unrecognized opcodes/SYSTEM sub-encodings are). A
real RISC-V toolchain to compile actual C and exercise this from real
software instead of hand-assembled directed tests — still the single
biggest lever left, and still squarely the user's machine, not this
sandbox, per §5's original note.
in your original plan.

## 9. A real UVM environment (`verif/uvm/`)

Section 7 scoped this out before any RTL beyond the basic pipeline
existed; this milestone builds it, on top of the CSR/trap/interrupt/UART
core from Section 8. Same DPI-C-bridge-to-the-ISS architecture Section 7
already described (and the same two reference repos it cites --
`gopro-uvm-rtl-verification` and OpenHW's `core-v-verif` -- sample a
commit/retire interface and check it against a DPI golden model, which is
exactly this).

**What it does, concretely.** `rv32i_random_seq` (a `uvm_sequence`)
procedurally generates a randomized-but-legal RV32I instruction stream --
R-type ALU, I-type ALU, LOAD, STORE, forward-only BRANCH -- biased toward
back-to-back register dependencies (per Section 7 Step 3's advice, since
that's the highest-density bug surface in a pipeline). `rv32i_driver`
holds the DUT in reset and backdoor-loads that stream directly into
`imem`'s instruction array via `mem_backdoor_if.sv`, a small interface
attached with `bind` -- not a port, so `imem.sv` itself is untouched.
`rv32i_monitor` samples `retire_if.sv` every cycle a real (non-bubble)
instruction retires. `rv32i_scoreboard` runs that exact same instruction
word through the ISS over DPI-C (`iss_dpi.cc`) and checks both the
retiring PC (a real control-flow check, catches wrong branch targets) and
the register write value (skipped for `x0`, an architectural no-op on
both sides).

**One RTL change this needed, not just testbench code.** `retire_if.sv`
previously exposed `regwrite_valid`, but that can't tell a monitor "a
real instruction retired this cycle" for an instruction that doesn't
write a register (a store, a branch) -- and `InstrW == NOP_INSTR` can't
either, since a real program can legally contain a genuine
`ADDI x0,x0,0`, bit-identical to a flush-inserted bubble. The fix:
`validE` (already existed, gating the timer-interrupt check) is now
carried one stage further at a time through EX/MEM and MEM/WB as
`validM`/`validW`, exactly the same shape `InstrE`/`InstrM`/`InstrW`
already used, and exposed as `retire_if.sv`'s new `retire_valid` signal.
Small, mechanical, and the same "a monitor needs X, so expose X" pattern
that added `InstrW` to `retire_if.sv` in the first place (Section 7's own
note flagged this exact class of future need).

**Verification of the verification environment itself.** Two real checks
happened before this was ever handed over, not just written and hoped:

1. The DPI-C bridge's core trick (backdoor-write the retiring instruction
   word at the ISS's current PC, then call its already-existing `step()`
   -- see `iss_dpi.cc`'s header for why this needs zero new RV32ISim API)
   was validated with a standalone C++ program, compiled and run directly
   with `g++`, covering ADDI/ADD/a taken BEQ (checking the PC-lockstep
   path specifically)/the x0-write-is-a-no-op rule the scoreboard
   depends on. All passed.
2. The entire environment -- every file in `verif/uvm/` plus the full
   `rtl/` file list, with `tb_uvm_top` as top -- was elaborated with
   `slang` (via `pyslang`, `-Weverything`) against the real, open-source
   Accellera `uvm-core` (IEEE 1800.2-2020.3.1), not a stub. Result: 0
   errors. The only warnings attributable to this project's own code (as
   opposed to UVM's own field-automation macro internals) were 3 benign
   `-Wcase-default` warnings on cases that are exhaustive by construction
   over a bounded `$urandom_range()` domain -- the same accepted pattern
   `controller.sv`'s R-type funct3 case already has.

**What this does NOT verify.** Real event-driven simulation in Riviera-
PRO. `slang` elaborates and type-checks; it does not run the clock,
exercise the DPI calling convention Riviera-PRO actually uses, or confirm
the backdoor-load timing works the way this was designed on paper. See
`verif/uvm/EDA_PLAYGROUND_SETUP.md` for how to actually run this, and its
honesty note at the top about what elaboration-clean does and doesn't
guarantee.

**Deliberately out of scope for this pass** (see `rv32i_uvm_pkg.sv`'s
header for the full list): JAL/JALR/LUI/AUIPC/SYSTEM (so this environment
doesn't yet exercise CSR/trap/interrupt/UART -- `tb_pipe_csr` remains the
directed test for that path); true `rand`/`constraint`-based generation
instead of procedural `$urandom_range()` calls (a lower-risk choice for
code that couldn't be iteratively compiled against a real UVM library
before being handed over); functional coverage (Section 7 Step 5).

---

## 10. The core actually ran: two simulators, two real RTL bugs

Every section above this one was written under the same constraint --
no SystemVerilog simulator -- and says so honestly. That constraint is
gone. **`rtl/` has now been simulated, end to end, under two independent
event-driven simulators, and all three testbenches pass on both.**

```
$ cd rtl && ./run_sim.sh
===== Icarus Verilog =====
  hazard  : PASS: all 32 registers + 2 dmem words match ISS golden values
  debug   : PASS: debug halt/resume works on the pipelined core
  csr     : PASS: all 32 registers match ISS golden values (...), UART TX stream correct
===== Verilator =====
  hazard  : PASS: all 32 registers + 2 dmem words match ISS golden values
  debug   : PASS: debug halt/resume works on the pipelined core
  csr     : PASS: all 32 registers match ISS golden values (...), UART TX stream correct
ALL GREEN
```

The first run was not green. It found two real RTL bugs, both of which
had survived every static-review pass in this document, plus two
testbench defects. This section is about those, because *what the bugs
were* is more interesting than the fact that it now passes.

### 10.1 Bug 1 -- distance-3 RAW hazards read stale registers

`tb_pipe_hazard` failed with `x12 = 0x55, expected 0x77`.

The store-data-forwarding case (§3.5 case 4) is:

```
    ADDI x10, x0, 4       <- producer
    ADDI x11, x0, 0x77
    SW   x11, 0(x10)
    LW   x12, 0(x10)      <- consumer, three instructions later
```

`0x55` is the value the *previous* test case stored at address **0**. So
the load had gone to address 0, not 4 -- meaning it read `x10` as 0
rather than 4. The store immediately before it used the same `x10` and
went to the right place, so this was specific to the distance between
producer and consumer.

**Root cause.** Forwarding in `hazard_unit.sv` covers a producer in MEM
(`FWD_MEM`) or in WB (`FWD_WB`) relative to a consumer in **EX** -- that
is, instruction distance 1 and 2. The register file is read in **ID**,
one stage earlier. At distance 3 the producer is in WB while the consumer
is still in ID, and `regfile.sv` wrote on `posedge` with a plain
combinational read, so the read returned the pre-write value. By the time
the consumer reached EX the producer had retired and no forwarding path
saw it either. Distance 3 fell straight through the gap between the two
mechanisms.

This is the classic reason Harris & Harris clock the pipelined register
file's write on the **falling** edge -- the write lands mid-cycle, before
the ID read samples it. This project's `regfile.sv` was inherited
unchanged from the single-cycle design (where the question cannot arise,
because there is no ID stage to be early), and pipelining it never
revisited that assumption. The header comment even still said "UNCHANGED
by the RV32I extension," which in hindsight reads as a warning.

**Fix** (`regfile.sv`): a read-during-write bypass rather than a second
clock edge -- same behaviour, but keeps the file synthesisable as
ordinary single-edge logic.

```systemverilog
assign rd1 = (a1 == 0) ? 32'b0 : (we3 && (a3 == a1)) ? wd3 : rf[a1];
assign rd2 = (a2 == 0) ? 32'b0 : (we3 && (a3 == a2)) ? wd3 : rf[a2];
```

**Why this one matters more than its one-line fix suggests.** A
distance-3 RAW dependency is not a corner case -- it is what ordinary
compiled code looks like. Essentially any real program would have hit
this. It is also precisely the bug class §3's whole architecture was
built to catch, and static review had been over `hazard_unit.sv` several
times without finding it, because the bug is not *in* `hazard_unit.sv`:
it is in the gap between that file's stated coverage and an assumption
buried in a different file that nobody had reason to re-read.

### 10.2 Bug 2 -- `dret` never flushed the instructions behind it

`tb_pipe_debug` failed under Icarus with `x1 not advancing after resume
(00000007 -> 00000007)`: the core halted correctly, resumed correctly,
and then wedged.

**Root cause.** `datapath.sv`'s fetch mux redirects `PCNextF` to `dpc` on
`ExitDebug`, but `hazard_unit.sv`'s flush terms were

```systemverilog
assign FlushD = PCSrcE | JumpD | EnterDebug | trap_en | mret_enE;
assign FlushE = PCSrcE | lwStallD | EnterDebug | trap_en | mret_enE;
```

`ExitDebug` is absent from both. So the two instructions already fetched
sequentially behind the `dret` -- at `dm_halt_addr_i+4` and `+8`, i.e.
whatever happens to sit after the debug ROM stub -- were never squashed,
and executed for real after the resume.

This is structurally identical to `mret_enE`, which *was* handled: `dret`
is just the debug-mode spelling of the same "redirect the PC from EX"
event, and §3.4's own table states the rule it violates ("the F-stage
content was fetched sequentially and is wrong-path"). §4 reasoned
carefully about which stages to squash on debug *entry* and never asked
the same question about *exit*.

**Fix**: add `ExitDebug` to `FlushD`/`FlushE` (not `FlushM` -- same
reasoning as `mret_enE`, there is no self-squash to do), plus the port
and one wire in `riscv_pipe.sv`.

### 10.3 Why two simulators, not one

Bug 2 is the argument, and it is worth being precise about, because it
is the kind of thing that is easy to assert in the abstract and hard to
demonstrate. Re-seeding the bug on purpose gives:

```
########## SEEDED: ExitDebug REMOVED from FlushD/FlushE ##########
  Icarus     debug : FAIL: x1 not advancing after resume (00000007 -> 00000007)
  Verilator  debug : PASS
```

**Verilator does not catch this bug.** The two simulators disagree about
what the stray fetches past the end of the program decode to. Verilator
reads uninitialised `imem` as 0, and `0x00000000` is an illegal opcode,
so the core took an illegal-instruction trap to `mtvec` = 0 -- which is
the top of the test program, so execution fell back into the loop and
`x1` kept incrementing. The testbench passed by luck, off the back of a
trap handler firing for a bug that had nothing to do with traps. Icarus
is 4-state: those fetches read X, the PC went X, and the core visibly
wedged.

Neither tool is "right" here. Real hardware would fetch whatever those
addresses physically contain, and the answer would be neither 0 nor X.
The point is that a single simulator's initialisation policy is a silent
assumption baked into every result it gives you, and the cheapest way to
find out where you are leaning on one is to run a second tool that leans
differently. That is why `run_sim.sh` runs both by default, and why
green-on-one is not treated as green.

For symmetry: the seeded distance-3 regfile bug (§10.1) is caught by
**both** simulators, which is what you would expect for a bug in
architectural data flow rather than in initialisation-sensitive control.

### 10.4 Two testbench bugs, which are not the same thing as RTL bugs

Worth separating out, because a testbench failure that is the
*testbench's* fault is the single easiest way to "fix" a working design
into a broken one.

- **Sampled one delta-cycle too early.** Both `tb_pipe_hazard` and
  `tb_pipe_csr` did `@(posedge clk)` and then read `dut.rvpipe.dp.rf.rf[]`
  immediately. The last instruction before `EBREAK` commits its register
  write on exactly that edge, as a nonblocking assignment -- which had
  not been scheduled yet at the moment the testbench read the array. So
  `x22` (hazard) and `x25` (csr) read as their reset value and reported a
  mismatch against a perfectly correct DUT. `x25` is specifically the
  interrupt-preemption marker §8.2 exists to explain, so this looked
  alarming and was not. Fixed with a `#1` after the edge.
- **Register file has no reset, and the two simulators disagree about
  that too.** `regfile.sv` is a RAM with no reset -- correct hardware, and
  RISC-V does not define reset values for `x1`-`x31`. Under Icarus every
  never-written register therefore reads X, while Verilator reads 0, and
  the golden values expect 0. The DUT is now forced to a known all-zero
  architectural start state from the testbench, matching the ISS. That is
  deliberately a *testbench* fix: adding a reset to `regfile.sv` would be
  inventing hardware to satisfy a simulator.

### 10.5 Portability changes needed to get here

None of these change behaviour; they are recorded so the next person does
not rediscover them.

| File | Change | Why |
|---|---|---|
| `rv32i_pkg.sv` | `ID_EX_CTRL_BUBBLE` written as a concatenation instead of a named assignment pattern (`'{RegWrite: 1'b0, ...}`) | Icarus 12 cannot parse named assignment patterns. Fields must stay in typedef order; a field added to the struct and not here is a width mismatch, which every tool rejects loudly |
| `retire_if.sv` | `clocking` block + `MON` modport guarded by `` `ifndef RTL_ONLY_NO_CLOCKING `` | Verilator rejects "modport clocking"; Icarus cannot parse a clocking block inside an interface at all. Both are UVM-only constructs. Guarded on *what the compile is for*, not on tool name -- an `` `ifndef VERILATOR `` would have left Icarus broken, and per-tool macros grow a branch per simulator. Compiled in by default, so the UVM flow needs no flags |
| `tb_pipe.sv` | `fork`/`join_any` + `disable timeout` replaced by an independent watchdog `initial` block | Verilator does not support disabling a named block from a sibling fork branch |
| `tb_pipe.sv` | `%p` on the UART queue replaced with an element-by-element print | Icarus rejects `%p` on a queue outright, which aborted the run before the check could report |

### 10.6 What this does and does not establish

Does: the RTL elaborates, runs, and produces architecturally correct
final state for the three directed programs, under two independent
simulators, checked against the C++ ISS rather than hand-computed values.
Two real bugs that survived every review pass in this document are fixed,
and both are demonstrated to fail the regression when re-seeded.

Does not: the UVM environment in `verif/uvm/` still has not run --
neither simulator here supports UVM (§9's honesty note stands). Coverage
is still unmeasured, so "these three programs pass" is not "the ISA is
correct"; the directed programs exercise what §2/§3.5/§8 describe and
nothing else. And the three programs are hand-assembled, so this is still
not the official compliance suite -- see §10.7.

### 10.7 The toolchain blocker in §4.5 is also gone

§4.5 records that RISCOF/`riscv-arch-test` could not run because there
was no RISC-V cross-compiler available and a prebuilt toolchain download
was blocked. On this machine that is no longer true:
`riscv64-unknown-elf-gcc` 13.2.0 and `binutils` 2.42 are available from
the distribution's own archive, and compile `-march=rv32i_zicsr
-mabi=ilp32` correctly.

That makes §4.5's plan directly actionable now, and it is the highest-value
next step: clone `riscv-non-isa/riscv-arch-test` and write a `riscof`
plugin for the RTL. The step after that is the one §8.5 calls the biggest
remaining lever: compile actual C and run it on the core, which -- now
that §10.1 is fixed -- it can finally survive.

---

## 11. Replacing the hand-written ISS with Spike

Sections 1--10 all rest on the same golden model: `iss/`, a from-scratch
C++ RV32I simulator written for this project. Section 1 calls it "the
golden reference model" and every self-checking testbench diffs against
it. **It has been deleted and replaced by Spike (`riscv-isa-sim`), the
RISC-V reference simulator.** The generator now lives in `verif/spike/`.

### 11.1 The argument for doing it

A golden model written by the same person as the RTL, from the same
reading of the specification, cannot catch a misreading of the
specification. Both sides express the same misunderstanding, the
comparison passes, and the green result carries no information.

That splits the old ISS's value cleanly in two, and it is worth being
precise because the two halves have opposite answers:

- **Microarchitecture.** The ISS was structurally different from the DUT
  in exactly one dimension that matters -- it had no pipeline -- so it
  genuinely could not share a hazard bug. It earned its keep here: both
  §10 bugs were found this way, and that was not luck. It is the only
  bug class this arrangement can catch.
- **ISA semantics.** Here the ISS was worth close to nothing as a check,
  and §8.1 says so without noticing: the ISS was extended to have "the
  same CSR addresses, same mcause encoding, same trap priority, same MMIO
  address windows" as the RTL. Written that way, the golden model is a
  restatement of the design under test. Any misreading of the privileged
  spec would sit in both files and pass.

Spike is maintained by RISC-V International and is the model the official
compliance suite uses to generate its reference signatures, so a
disagreement between Spike and this core is evidence about the core.

### 11.2 What the swap actually found: nothing, which is the useful part

Spike reproduces the old ISS's golden values **exactly** -- all 32
registers plus both memory words for `tb_pipe_hazard`, and all 32
registers for `tb_pipe_csr` including the four trap counters, the
`mcause` value `0x80000007`, and the `x25 = 0x555` interrupt-preemption
marker that §8.2 exists to explain.

So the old ISS was right about everything these programs exercise. That is
a genuinely reassuring result and worth stating plainly rather than
burying: the previous work was not wrong. What changed is that this is now
*checkable* instead of assumed, and every future test program gets checked
against an authority nobody here wrote.

An independent check of a different layer came for free along the way.
Disassembling all three programs with GNU binutils confirmed every
encoding `testgen/asm.py` produces -- which matters because a hand-rolled
assembler feeding both the RTL and the model is another way for a single
mistake to be invisible. It also showed that the deliberate
"illegal instruction" `0x0000007F` is not an unallocated opcode as its
comment claims, but the RISC-V *instruction-length encoding* for
80-bit-or-longer instructions. The test still does something valid (this
core does not implement variable-length instructions, so trapping is
correct), but it is not quite testing what it says, and the ISS could
never have told us -- both sides agreed by construction.

### 11.3 Where the trust boundary sits now

Everything with a specification comes from Spike: every instruction, every
CSR read/write side effect, trap cause encoding, trap priority, `mstatus`
stacking, `mret`.

Two things do not. `clint.sv` and `uart_tx.sv` are project-specific
peripherals -- a simplified 32-bit CLINT at a project-chosen address and a
transmit-only UART with no baud model -- so `verif/spike/rvproj_devices.cc`
models them as a Spike MMIO plugin. This is deliberately *not* a
reintroduction of the original problem: there is no standard for these two
devices to disagree with, so modelling them restates a design decision
rather than making an independent claim about correctness. It is about 60
lines with no branching semantics, and it is the smallest surface that
keeps `tb_pipe_csr`'s timer-interrupt and UART coverage.

### 11.4 The one patch Spike needs

This core resets to PC 0; Spike reserves `[0x0, 0x1000)` for its debug
module and puts its boot ROM at `0x1000`. Two constants in
`riscv/platform.h` have to move (`DEBUG_START`, `DEFAULT_RSTVEC`), or Spike
refuses to start with `devices at [0, 1000) and [0, 40000) overlap`.

This is platform *placement*, not instruction semantics -- two lines,
diffable against upstream, with no effect on how anything executes.
Relocating the test programs instead is not an option: `JAL`'s link value
and `AUIPC` are PC-dependent, so the code base address is part of the
expected result.

### 11.5 The UVM environment had to change shape

The UVM scoreboard called the old ISS live over DPI-C, one step per
retirement. Spike cannot go in that slot. The environment's only
documented way to run is EDA Playground, which compiles DPI C files by
uploading them next to the SystemVerilog -- fine for four self-contained
files, impossible for a library with boost and libfdt dependencies. A live
Spike-over-DPI bridge would have left the environment with no way to run
at all.

So the reference moved from live to precomputed: `verif/spike/gen_stream.py`
generates the instruction stream *and* runs it through Spike to emit an
expected retirement trace, and the scoreboard reads that trace with
`$fscanf`. The environment now needs no DPI-C, no C compiler and no
plugins, which makes it strictly more portable than before.

The real cost, stated plainly: stimulus is now fixed per seed rather than
randomized inside the simulator. New stimulus means re-running the
generator with a new `--seed`. For a regression that is arguably better --
a failing seed is reproducible by name -- but it is a genuine change in
how the environment is driven, and generation had to move out of
SystemVerilog into Python because the program and its reference trace must
come from the same source to mean anything.

One latent bug turned up during the port: the old in-simulator generator
could emit a forward branch among the last few instructions that jumped
*past* the end of the program into unwritten memory. The Python version
pads with NOPs before the sentinel so every branch target lands inside the
program.

### 11.6 Two more model-mismatch bugs, found by running it

`gen_stream.py` did not work first time, and both failures were the same
underlying mistake in different clothes: **the reference model and the DUT
must start from the same state, and "the same state" is larger than it
looks.** Neither was a bug in Spike or in the RTL. Both were gaps between
two models that are each internally correct.

**Memory.** The generated loads and stores used `x1` as a base seeded to
0, with offsets up to 255. The DUT is Harvard -- separate `imem` and
`dmem` both based at 0 -- so those stores cannot touch the program. Spike
is von Neumann. The program overwrote its own instructions, executed the
corrupted words, trapped to an uninitialised `mtvec` = 0, jumped back to
the top and looped forever; the sentinel never retired. This is exactly
the mismatch §2 recorded for the previous ISS, and it took a *random*
generator scattering stores across low memory to expose it -- every
directed test in this project respects the invariant by construction,
because a human wrote each one and never thought to store over the code.
Fixed by placing the data window past the end of the program image
(`data_base_for()`).

Worth noting the failure was loud rather than quiet. Had the corrupted
program happened to terminate, the generator would have emitted a
plausible-looking trace encoding a completely different execution, and the
scoreboard would have reported mismatches pointing at innocent RTL. The
`sys.exit` on a missing sentinel is doing real work.

**Registers.** With that fixed the script exited 0 -- and the trace was
still wrong. Its first five rows were at PC `0x40001000`: Spike's boot ROM,
which runs `auipc/addi/csrrs mhartid/lw/jalr` before jumping to the ELF
entry. The DUT has no boot ROM and resets straight to PC 0, so every
comparison would have been five out of step. Worse, that sequence leaves
`x11` holding a device-tree pointer, so any generated instruction reading
`x11` before writing it would diverge -- and would look exactly like a
forwarding bug, the most expensive kind of false positive to hand a
verification engineer. Fixed by zeroing `x2`--`x30` in the prologue and
trimming the boot-ROM retirements from the trace.

This one is worth dwelling on because the script *reported success*. It was
caught only by reading the actual output instead of the exit code.

### 11.7 The full list of legitimate model differences

The naive picture of co-simulation is "run both, diff the answers." The
actual work is enumerating every way the two models can legitimately
differ, and either eliminating it or excluding it from the comparison.
For this project that list is:

| Difference | How it is handled |
|---|---|
| Harvard vs von Neumann memory | data window placed past the code image |
| Uninitialised data memory (0 vs X) | prologue stores zeros before any load |
| Spike's boot ROM leaves registers set | prologue zeros `x2`--`x30` |
| Spike's boot ROM retirements | trimmed from the trace |
| Debug module / boot ROM at address 0 | two `platform.h` constants relocated |
| CLINT and UART do not exist in Spike | MMIO plugin (`rvproj_devices.cc`) |
| `mtime` counts cycles vs instructions | tests assert final state, not timing |
| Debug halt/resume is not architectural | no reference model; separate test |

Eight entries, every one a place where a passing test could have meant
nothing. **That table is the co-simulation environment.** The diff is
trivial by comparison.

### 11.8 Verified, and not

Verified by running: Spike built; both `golden_vals_*.svh` regenerated by
it and checked against the old ISS's values; the MMIO plugin compiles and
produced the CSR golden values; **the full RTL regression re-run against
the regenerated values -- three testbenches, two simulators, all green**;
and `gen_stream.py` producing a clean 147-word stream and 133-retirement
trace.

Not verified: the rewritten UVM sequence and scoreboard have **not been
elaborated or run by anything**, because neither available simulator
supports UVM. The previous version at least had a clean `slang`
elaboration against the real Accellera UVM library; this one does not even
have that. Section 10 exists because this project has repeatedly been
burned by assuming code that looks right is right -- six real bugs so far,
none of them found by reading.

---

## 12. Retrofitting the lowRISC Verilog Coding Style Guide

This milestone applied [lowRISC's Verilog Coding Style
Guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md)
to every file in `rtl/`. It's worth recording as its own section rather
than folding into the file-by-file history above, because the interesting
part isn't the mechanical edits -- it's the handful of places the guide's
rules genuinely conflict with a decision this project already made and
defended, and the honest call on each.

### 12.1 What the audit found, and what changed

A rule-by-rule pass against the guide's concrete, checkable items:

| Rule | Before | After |
|---|---|---|
| `unique case` | plain `case`, mostly with `default:` already | `unique case` everywhere; the one missing `default:` (`aludecoder`'s R-type inner case) added |
| Named-port instantiation | already fully compliant | unchanged |
| Instance names lower_snake_case | already fully compliant | unchanged |
| Module declaration format (paren placement) | first port on the `module` line, closing paren inline | reformatted to the guide's Verilog-2001 layout across every file |
| Tunable parameters `UpperCamelCase` | `TESTFILE`, `MEM_WORDS`, `MEM_BYTES`, `RAM_BYTES`, `WIDTH` | `TestFile`, `MemWords`, `MemBytes`, `RamBytes`, `Width` -- every call site updated |
| Enumerated constants `ALL_CAPS` | already compliant (opcodes, ALU codes, CSR addresses, cause codes) | unchanged -- the guide explicitly prefers ALL_CAPS for this category |
| FSM state as `typedef enum ..._e`, `UpperCamelCase` values | `debug_fsm.sv` used two bare `parameter` constants | `state_e { StRunning, StParked }`, same encoding values, same behavior |
| `X` as a "don't care" default | `alu.sv`/`extend.sv` defaulted unreachable cases to `32'bx` | defaults to `32'b0` -- a defined value, not an unknown, on paths that are provably unreachable from decode |
| Explicit port/signal typing | `cells.sv`'s `adder` used implicit `wire` ports | explicit `logic` |
| 1-bit literal sizing | `maindec` assigned bare `1`/`0` to 1-bit control signals | `1'b1`/`1'b0` |
| Line length / trailing whitespace / tabs | one stray trailing-whitespace line, two comment lines over 100 cols | fixed |
| `interface` used for `retire_if.sv` | undocumented as an exception | one-paragraph justification added, per the guide's own "exceptions need a comment" rule |

### 12.2 What was deliberately NOT done, and why

Two of the guide's rules were audited, flagged, and put to the project
owner as an explicit choice rather than executed blind. Both were kept
as-is, confirmed:

**Full `lower_snake_case` signal renaming.** The guide's primary naming
rule wants every signal and port in `lower_snake_case`. This project uses
Harris & Harris's convention instead -- `PascalCase` signal names suffixed
with the pipeline stage they belong to (`PCF`, `InstrD`, `ALUResultE`,
`ResultW`). §1 of this document explains why that convention was kept
deliberately: with five instructions in flight simultaneously, the stage
suffix is *how you avoid confusing which instruction a signal refers to*
-- it is not cosmetic. Replacing it with lowRISC's `_d`/`_q` register-pair
convention (designed for a single register, not a 5-deep pipeline) would
be swapping one deliberate, already-justified naming scheme for another,
not fixing an oversight. This needed a decision from the project owner
before touching several hundred signal references across every file, every
testbench hierarchical path, the wave-capture script's signal list, and
this document -- see the conversation this milestone came from for that
discussion.

**Active-low asynchronous reset (`reset` -> `rst_ni`).** The guide wants
resets active-low, named `rst_n` (or `rst_<domain>_n`), asynchronous. This
core's reset is active-high, named `reset`, inherited from the original
Harris & Harris tutorial and used consistently (`posedge reset` in every
`always_ff`, `if (reset)` throughout, `reset = 1`/`reset = 0` in every
testbench). This is not a naming change -- inverting reset polarity means
flipping the sense of every reset condition in every sequential block in
every file, plus every testbench's reset sequence, plus `mem_backdoor_if`/
`mem_backdoor_bind`. A single missed inversion is a bug that silently
holds the core permanently in or out of reset. Same reasoning as above:
flagged for an explicit decision rather than executed blind.

### 12.3 What still needs to happen before this is trusted

Every change in this section was made **without a working shell in this
session** -- edited by hand against the RTL as read, not compiled. The one
place that could not be avoided is `debug_fsm.sv`, which every earlier
section of this document holds up specifically *because* it was untouched
since the original tutorial; that specific claim is now false (see this
file's own header for the honest version), and the fix (parameter constants
-> typedef enum, same encoding) is small and mechanical, but "small and
mechanical" is exactly the category of change this project has repeatedly
found real bugs in by actually running it (§10, §11.6). The full RTL
regression (`cd rtl && ./run_sim.sh`, both simulators, all three
testbenches) needs to pass again before this section's changes are
considered verified rather than merely reasoned-through.
