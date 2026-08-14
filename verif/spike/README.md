# Spike as the reference model

Golden values for the self-checking RTL testbenches come from
[Spike](https://github.com/riscv-software-src/riscv-isa-sim), RISC-V
International's reference simulator, and so does the UVM environment's
instruction stream and expected retirement trace.

## Why

A golden model written by the same person as the RTL, from the same reading of
the specification, cannot catch a misreading of the specification. Both sides
express the same misunderstanding, the comparison passes, and the green result
carries no information.

That limitation was not hypothetical here. The old ISS was structurally
different from the DUT in one dimension — it had no pipeline — so it was a
genuinely independent check on *microarchitecture*, and it earned its keep:
both real RTL bugs in `docs/JOURNAL.md` were found that way. But it was
written by the same author as the RTL for *ISA semantics*, and
`docs/JOURNAL.md` says so outright: the ISS was extended to have "the
same CSR addresses, same mcause encoding, same trap priority" as the RTL. For
that milestone the golden model was a restatement of the design under test.

Spike is not. It is maintained by RISC-V International and is the model the
official compliance suite uses to generate its reference signatures, so a
disagreement between Spike and this core is evidence about the core.

**What the swap actually changed: nothing, and that is the useful part.**
Spike reproduces the old ISS's golden values *exactly* — all 32 registers and
both memory words for `tb_pipe_hazard`, and all 32 registers for
`tb_pipe_csr` including the trap counters, the `mcause` value `0x80000007`,
and the `x25 = 0x555` interrupt-preemption marker. The old ISS was right. What
changed is that this is now checkable rather than assumed.

## Layout

| File | Purpose |
|---|---|
| `gen_golden.py` | hex program → ELF → Spike → `golden_vals_*.svh` |
| `rvproj_devices.cc` | Spike MMIO plugin: the project's CLINT and UART |
| `Makefile` | builds the plugin |
| `regen.sh` | regenerates every testbench's golden values |

The generated `.svh` files are checked in, so running the RTL regression
(`rtl/run_sim.sh`) needs no Spike — only regenerating them does.

## Where the trust boundary sits

Everything with a specification comes from Spike: every instruction, every CSR
read/write side effect, trap cause encoding, trap priority, `mstatus` stacking
on trap entry, `mret`.

Two things do not, and cannot: `clint.sv` and `uart_tx.sv` are project-specific
peripherals — a deliberately simplified 32-bit CLINT at a project-chosen
address, and a transmit-only UART with no baud model. There is no standard for
them to conform to, so `rvproj_devices.cc` models them for Spike. That is a
restatement of a *design decision*, not an independent claim about correctness,
and it is about 60 lines with no branching semantics. See the header comment in
that file.

`tb_pipe_debug` has no golden values at all: debug halt/resume is not
architectural state, so no ISS models it.

## Building Spike

```bash
sudo apt-get install device-tree-compiler libboost-regex-dev libboost-system-dev
git clone https://github.com/riscv-software-src/riscv-isa-sim.git ~/src/riscv-isa-sim
cd ~/src/riscv-isa-sim
```

### The one patch Spike needs, and why

Spike reserves the bottom of the address space for itself, and this core resets
to PC 0. Two constants in `riscv/platform.h` have to move:

```c
#define DEFAULT_RSTVEC     0x40001000   /* was 0x00001000 -- boot ROM      */
#define DEBUG_START        0x40000000   /* was 0x0        -- debug module  */
```

Without this, Spike refuses to start with `devices at [0, 1000) and [0, 40000)
overlap`: its debug module occupies `[0x0, 0x1000)` unconditionally and its
boot ROM sits at `0x1000`, both inside the core's RAM.

This is a **platform placement constant, not instruction semantics**. Nothing
about how Spike executes an instruction, takes a trap, or updates a CSR is
affected, and the change is two lines that can be diffed against upstream. The
alternative — relocating the test programs — is not viable: `JAL`'s link value
and `AUIPC` are PC-dependent, so the code base address is part of the expected
result, and the core's reset vector is 0.

```bash
mkdir build && cd build
../configure --prefix=$HOME/.local/spike
make -j$(nproc) && make install
```

## Regenerating

```bash
cd verif/spike
SPIKE=$HOME/.local/spike/bin/spike ./regen.sh
```

Then re-run the RTL regression to confirm the core still matches:

```bash
cd ../../rtl && ./run_sim.sh
```

## Known model differences

**CLINT tick rate.** `clint.sv` increments `mtime` once per clock cycle; Spike
has no clock, so the plugin increments once per retired instruction. The two
therefore reach any given `mtime` after different amounts of program progress.
This does not affect the current test, which sets `mtimecmp = 0` so the
interrupt is pending immediately on both models and the handler then defers it
to `0xFFFFFFFF`. It is the same step-count-versus-clock-count mismatch
`docs/DESIGN_GUIDE.md` section 8 documents, and the reason
`tb_pipe_csr` checks final architectural state rather than "it fired on cycle
N".

**Unified versus Harvard memory.** Spike has one address space; the core has
separate `imem` and `dmem` both based at 0. A program that stores to a low
address overwrites its own instructions in Spike but not in the core. The
current programs never re-execute an address they have written, so the final
state agrees — but this is a real constraint on future test programs, and the
same one `docs/DESIGN_GUIDE.md` section 8 records.
