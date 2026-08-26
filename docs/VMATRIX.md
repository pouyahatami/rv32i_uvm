# Verification matrix

One row per design feature: what stimulates it, what checks it, which bound
assertions guard it, where coverage measures it, and an honest status. The
point of this table is that the gaps are *in* it, not around it: a feature
with "none" in a column is a recorded decision, not an oversight.

How to read the columns:

- **Stimulus**: `random` is the hazard-biased generated stream
  (`verif/spike/gen_stream.py`, run by the UVM environment);
  `hazard`/`debug`/`csr` are the three directed testbenches in
  `rtl/tb_pipe.sv`.
- **Checker**: `lockstep` is the UVM scoreboard comparing every retirement
  against Spike (PC, instruction, writeback, store addr/data);
  `end-state` is a directed test diffing all 32 registers (plus dmem words
  for `hazard`) against Spike-generated golden values; `uart-mon` is
  `tb_pipe_csr`'s independent byte-stream monitor.
- **Assertions**: properties in `verif/sva/hazard_sva.sv`, bound into
  `riscv_pipe` in every simulating flow, failure-gated.
- **Coverage**: bins in the plain-SystemVerilog tally
  (`verif/uvm/src/rv32i_coverage.svh`). SVA `cover` properties are listed
  where they exist but are **not currently collected by any flow**, a known
  hole, see the notes below the table.

| Feature | Stimulus | Checker | Assertions | Coverage | Status |
|---|---|---|---|---|---|
| EX forwarding from MEM | random (d1 bias), hazard | lockstep, end-state | `a_fwd_mem_legal_*`, `a_no_spurious_fwd_*` | `hazard.alu_raw_d1`, `rs1/rs2_dist.d1`; SVA `c_fwd_mem_*` | verified |
| EX forwarding from WB | random (d2 bias), hazard | lockstep, end-state | `a_fwd_wb_legal_*` | `hazard.alu_raw_d2`, `rs*_dist.d2`; SVA `c_fwd_wb_*` | verified |
| MEM-over-WB forward priority | random (d1+d2 same reg) | lockstep | `a_fwd_mem_priority_*` | SVA `c_fwd_both_stages` only | verified (the shipped distance-3 bug's property) |
| No forward for x0 | random (`rd.x0` writes) | lockstep | `a_no_fwd_x0_*` | `rd.x0` | verified |
| Load-use interlock | random (load-use bias), hazard | lockstep, end-state | `a_lwstall_effect`, `a_stall_has_cause` | `hazard.load_use_d1`; SVA `c_lwstall` | verified |
| Flush-beats-stall priority | random (branch × load-use coincidence) | lockstep | `a_flush_beats_stall` | SVA `c_stall_and_flush` | verified |
| Conditional branches (BEQ/BNE), flush of wrong path | random (forward-only), hazard | lockstep (PC check), end-state | `a_branch_flushes_both`, `a_flushd/e_has_cause` | `branch.{taken,not_taken,beq,bne}`, `x_op_rs1/2.branch_*` | verified; BLT/BGE/BLTU/BGEU not generated |
| JAL (resolved in ID) | random, hazard | lockstep, end-state | `a_jump_flushes` | `opcode.jal` | random stimulus added; link-register writeback checked by lockstep |
| JALR (resolved in EX) | random (AUIPC-paired), hazard | lockstep | `a_branch_flushes_both` (fires on PCSrcE) | `opcode.jalr` | random stimulus added; target register is a forced d1 dependency by construction |
| LUI / AUIPC | random, hazard | lockstep, end-state | none (datapath only) | `opcode.lui`, `opcode.auipc` | random stimulus added |
| R-type ALU ops (ADD SUB SLL SLT SLTU XOR SRL SRA OR AND) | random (uniform over funct3, funct7 bit split) | lockstep (wdata), end-state | none | `alu.add` to `alu.and` | verified |
| I-type ALU ops incl. immediate shifts (SLLI/SRLI/SRAI) | random (uniform over funct3; shamt drawn separately) | lockstep (wdata), end-state | none | `alu.addi` to `alu.andi` | verified; `alu.srai` needs ~20 seeds to hit, see note 6 |
| Loads LB/LH/LW/LBU/LHU (sign/zero extension) | random (width-weighted, aligned) | lockstep (wdata) | none | `mem.lb/lh/lw/lbu/lhu` | verified for aligned; misaligned never generated, see note |
| Stores SB/SH/SW (byte enables) | random (width-weighted, aligned) | lockstep (addr + width-masked data) | none | `mem.sb/sh/sw` | verified for aligned; misaligned never generated, see note |
| Writeback value integrity | random, all directed | lockstep (wdata), end-state | none | `wb.{zero,neg,pos}` operand-corner bins | verified |
| Retirement interface known-values | random | monitor `RETIRE_X` 4-state check | none | n/a | verified (fires on any X at retirement) |
| CSR read/write (mstatus/mie/mtvec/mepc/mcause/mtval/mscratch) | csr only | end-state | none | none | directed only, random CSR is out of scope by design (RUNNING.md) |
| ECALL trap | csr only | end-state | `a_trap_flushes` (vacuous under random) | SVA `c_trap` | directed only |
| Illegal-instruction trap | csr only | end-state | `a_trap_flushes` | none | directed only |
| Misaligned load/store traps | csr only | end-state | `a_trap_flushes` | none | directed only |
| Machine timer interrupt (CLINT, MTIE/MTIP gating, precise preemption) | csr only | end-state + Spike MMIO plugin | `a_trap_flushes` | none | directed only; plugin is trusted (~60 lines, no branching semantics) |
| MRET | csr only | end-state | `a_mret_flushes` | SVA `c_mret` | directed only |
| Debug halt/resume (debug_req → dpc, dret) | debug only | scripted self-check (halt seen, PC at halt addr, resumes) | `a_enterdebug_flushes`, `a_exitdebug_flushes` | SVA `c_enterdebug/exitdebug` | directed only; no ISS reference exists for debug state (not architectural) |
| UART TX | csr only | uart-mon + plugin end-state | none | none | directed only |
| dmem read/write paths | random + hazard | lockstep stores, end-state dmem diff | none | `mem.*` width bins | verified for aligned accesses |
| Reset behaviour | every test (reset held, then released) | implicit (first retirement at PC 0) | none | none | exercised, not independently checked |

## Known holes this table makes visible

1. **SVA cover properties are written but never collected.** Fourteen
   `cover property` directives exist to prove the assertions above them pass
   non-vacuously, and no run script reports their hit counts. Until a flow
   prints them, "SVA `c_*`" cells describe intent, not measurement.
2. **The trap/CSR/interrupt column is directed-only, deliberately.** Random
   CSR/trap stimulus requires trap handlers in generated programs and ends
   the lockstep-vs-Spike simplicity. The cost is that those features get one
   program's worth of stimulus each.
3. **Misalignment is untested everywhere.** The generator aligns every
   access by construction; `tb_pipe_csr` covers the misaligned *trap* path
   only. What a misaligned access does when it does not trap is unverified.
4. **BLT/BGE/BLTU/BGEU are not generated**: branch stimulus is BEQ/BNE
   only. The decode and compare logic for the other four is exercised by
   nothing random and only incidentally by directed programs.
5. **No riscv-arch-test run.** "Verified against Spike on generated
   streams" is the accurate claim; "compliant" is not.
6. **`alu.srai` is the generator's thinnest bin.** The I-type arm draws
   `funct3` uniformly from eight values and SRAI is half of one of them, so a
   40-instruction program emits it about once every two programs, and a
   forward jump often skips it. Ten seeds left it as the single union hole;
   thirty close it. It is reachable, not unreachable, but the margin is thin
   enough that weighting the I-type pool would be a fair change.
