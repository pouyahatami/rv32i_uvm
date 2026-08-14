#!/usr/bin/env python3
"""
gen_stream.py -- generate the UVM environment's randomized instruction stream
and its expected retirement trace, using Spike as the reference model.

    ./gen_stream.py --seed 1 --num-instr 40 \
        --out-hex ../uvm/stream.hex --out-trace ../uvm/stream_trace.txt

Writes two files that must always be regenerated as a pair: the program the
DUT runs, and the retirement trace the scoreboard checks it against. A trace
computed from a different program is a scoreboard that checks nothing.

## Why the stimulus is generated here rather than in the sequence

The reference model has to be Spike, and Spike cannot be called from inside
the simulator. The environment's documented free run target is EDA Playground,
which compiles DPI C by uploading source files next to the SystemVerilog;
Spike is a library with boost and libfdt dependencies and cannot be uploaded,
so a live Spike-over-DPI bridge would leave the environment with no way to run
at all. Precomputing keeps Spike as the authority and removes the DPI-C
dependency entirely: the testbench needs no C compiler and no plugins, just
two text files.

Generating the program in the same place as the reference is then forced. Two
generators seeded independently, one in Python and one in SystemVerilog, would
drift apart and the comparison would be meaningless.

The tradeoff is real and worth stating: stimulus is fixed per seed rather than
randomized per simulation run, so new stimulus means re-running this script
with a new --seed. For a regression that is arguably better, since a failing
seed is reproducible by name. It also means the environment performs no
randomization at simulation time at all, which is what lets it run under
licences that withhold SystemVerilog randomization -- see verif/uvm/RUNNING.md.

## Generation policy

The safety-by-construction rules below are the reason the stream is legal
without needing post-hoc constraints:

  - x1 is a reserved "safe base pointer", set by the first instruction and
    never used as any other instruction's destination, so every load/store
    offset is known at generation time to be small, aligned, and far from the
    MMIO window at 0x00020000. It points *past the program image*, not at 0 --
    see data_base_for() for why that distinction is load-bearing.
  - branches are forward-only by a small bounded amount.
  - the last instruction is a sentinel (rd=x31) the scoreboard watches for as
    the "program fully retired" marker.
  - ~40% of instructions force rs1 to the previous instruction's destination,
    so RAW hazards appear far more often than uniform-random choice gives.

Padding NOPs are emitted between the body and the sentinel so that a forward
branch among the last few instructions cannot jump past the end of the program
into unwritten memory. Every branch target lands inside the program regardless
of where the branch occurs.

## Trace format

One row per retirement, in retirement order:

    pc instr rd wdata regwrite store_valid store_addr store_data

All hex except rd, regwrite and store_valid, which are decimal. When
store_valid is 0 the two store columns are 0 and carry no meaning.

Older traces have only the first five columns; the scoreboard accepts those
and disables store checking, so a stale trace degrades loudly rather than
silently passing stores that were never compared.
"""

import argparse
import os
import random
import re
import subprocess
import sys
import tempfile

OP_RTYPE, OP_ITYPE, OP_LOAD, OP_STORE, OP_BRANCH = 0x33, 0x13, 0x03, 0x23, 0x63
SAFE_BASE_REG = 1
SENTINEL_REG = 31
SENTINEL_VAL = 0x7FF
NOP = 0x00000013
MAX_BRANCH_OFF = 48                       # matches the generator below
PAD_WORDS = MAX_BRANCH_OFF // 4           # enough padding for the longest branch
DATA_WINDOW = 256                         # bytes reachable from x1 by any
                                          # generated load/store (max offset 255)
MAX_ADDI_IMM = 2047                       # x1 is set with a single ADDI
REG_INIT_REGS = range(2, 31)              # x2..x30 -- see the prologue in
REG_INIT_WORDS = len(REG_INIT_REGS)       # generate() for why these are zeroed
ENTRY_PC = 0x0                            # the core's reset vector


def data_base_for(num_instr):
    """Where x1 points -- and it must NOT be 0.

    The DUT is Harvard: separate imem and dmem, both based at 0, so a store to
    a low address cannot touch the program. Spike is von Neumann: one address
    space. With x1 = 0 the generated stores land on top of the program image,
    Spike executes the corrupted words, traps to an uninitialised mtvec = 0,
    jumps back to the top and loops forever -- the sentinel never retires.

    That is not merely a termination problem. Even if it had terminated, the
    two models would have disagreed about the whole run, so the trace would be
    worthless as a reference for the DUT. DESIGN_GUIDE.md section 8 lists this
    as one of the eight legitimate model differences. Every directed test in
    this project respects the invariant by construction, because a human wrote
    each one and never thought to store over the code; it took a random
    generator scattering stores across low memory to make it bite.

    So x1 points past the end of the program image, with a 256-byte gap. Both
    models then agree, because neither one's data region overlaps its code.
    """
    n_words = (REG_INIT_WORDS + 1 + DATA_WINDOW // 4
               + num_instr + PAD_WORDS + 1)
    prog_bytes = n_words * 4
    base = ((prog_bytes + 255) // 256 + 1) * 256      # round up, then one gap
    if base + DATA_WINDOW - 1 > MAX_ADDI_IMM:
        sys.exit(f"--num-instr {num_instr} makes the program too long: x1 would "
                 f"need to be 0x{base:x}, past what a single ADDI can encode "
                 f"({MAX_ADDI_IMM}). Use a smaller --num-instr, or teach the "
                 f"generator to emit LUI+ADDI for the base pointer.")
    return base


def enc_i(opcode, rd, funct3, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def enc_r(opcode, rd, funct3, rs1, rs2, funct7):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def enc_s(opcode, funct3, rs1, rs2, imm12):
    imm12 &= 0xFFF
    return (((imm12 >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (funct3 << 12) | ((imm12 & 0x1F) << 7) | opcode


def enc_b(opcode, funct3, rs1, rs2, imm13):
    imm13 &= 0x1FFF
    return (((imm13 >> 12) & 1) << 31) | (((imm13 >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | \
           (((imm13 >> 1) & 0xF) << 8) | (((imm13 >> 11) & 1) << 7) | opcode


def generate(rng, num_instr):
    base = data_base_for(num_instr)

    # Register-zeroing prologue.
    #
    # Spike does not start with a clean register file. Its boot ROM runs five
    # instructions before jumping to the ELF entry, and they leave state
    # behind -- most importantly x11 = <dtb pointer>, a large non-zero value.
    # The DUT resets straight to PC 0 and never executes any of that, so any
    # generated instruction reading x11 (or x5, or x10) before writing it
    # would diverge for a reason that has nothing to do with the DUT. It would
    # look exactly like a forwarding bug, which is the worst kind of false
    # positive to hand a verification engineer.
    #
    # Zeroing x2..x30 makes both models provably start from the same
    # architectural state. x1 is set to the data base immediately below; x31
    # is the sentinel register and is never read by the generated body
    # (rs1/rs2 are drawn from x0..x30), so neither needs zeroing here.
    words = [enc_i(OP_ITYPE, r, 0b000, 0, 0) for r in REG_INIT_REGS]

    # x1 = the data base pointer (see data_base_for -- deliberately not 0).
    words.append(enc_i(OP_ITYPE, SAFE_BASE_REG, 0b000, 0, base))

    # Zeroing prologue: store 0 to every word the generated loads can reach.
    #
    # Without this, a load from a location the program has not yet written
    # reads whatever the memory powers up as -- and the models disagree about
    # that. Spike reads 0. A 4-state simulator (Icarus, and Riviera-PRO, which
    # is what the UVM environment actually runs on) reads X from an
    # uninitialised dmem array. Every such load would mismatch the trace, for
    # no reason connected to the DUT being wrong.
    #
    # This is the same class of problem as tb_pipe.sv's register-file
    # initialisation (docs/JOURNAL.md, "Two testbench bugs"): the reference model and
    # the DUT must start from the same architectural state, and it is the
    # testbench's job to establish that rather than the RTL's. Doing it with
    # real stores rather than a backdoor keeps it inside the checked
    # instruction trace, so the prologue verifies itself.
    for off in range(0, DATA_WINDOW, 4):
        words.append(enc_s(OP_STORE, 0b010, SAFE_BASE_REG, 0, off))

    last_rd = SAFE_BASE_REG

    for _ in range(num_instr):
        cls = rng.randrange(100)
        rs1 = last_rd if rng.randrange(100) < 40 else rng.randrange(31)
        rs2 = rng.randrange(31)
        rd = rng.randrange(31)
        while rd in (SAFE_BASE_REG, SENTINEL_REG):
            rd = rng.randrange(31)

        if cls < 30:                                        # R-type
            funct3 = rng.randrange(8)
            if funct3 in (0b000, 0b101):
                funct7 = 0b0100000 if rng.randrange(2) else 0b0000000
            else:
                funct7 = 0
            words.append(enc_r(OP_RTYPE, rd, funct3, rs1, rs2, funct7))
        elif cls < 55:                                      # I-type ALU
            funct3 = [0b000, 0b010, 0b011, 0b100, 0b110, 0b111][rng.randrange(6)]
            words.append(enc_i(OP_ITYPE, rd, funct3, rs1, rng.randrange(4096)))
        elif cls < 75:                                      # LOAD off x1
            funct3, off = [
                (0b010, rng.randrange(64) * 4),
                (0b001, rng.randrange(128) * 2),
                (0b101, rng.randrange(128) * 2),
                (0b000, rng.randrange(256)),
                (0b100, rng.randrange(256)),
            ][rng.randrange(5)]
            words.append(enc_i(OP_LOAD, rd, funct3, SAFE_BASE_REG, off))
        elif cls < 90:                                      # STORE off x1
            funct3, off = [
                (0b010, rng.randrange(64) * 4),
                (0b001, rng.randrange(128) * 2),
                (0b000, rng.randrange(256)),
            ][rng.randrange(3)]
            words.append(enc_s(OP_STORE, funct3, SAFE_BASE_REG, rs2, off))
        else:                                               # BRANCH, forward only
            funct3 = 0b001 if rng.randrange(2) else 0b000
            words.append(enc_b(OP_BRANCH, funct3, rs1, rs2,
                               rng.randint(1, 3) * 16))
        last_rd = rd

    words += [NOP] * PAD_WORDS
    words.append(enc_i(OP_ITYPE, SENTINEL_REG, 0b000, 0, SENTINEL_VAL))
    return words


def build_elf(words, workdir, cross):
    asm = os.path.join(workdir, "stream.S")
    with open(asm, "w") as f:
        f.write(".section .text\n.globl _start\n_start:\n")
        for w in words:
            f.write(f"  .word 0x{w:08x}\n")
    obj, elf = os.path.join(workdir, "s.o"), os.path.join(workdir, "s.elf")
    for cmd in ([f"{cross}as", "-march=rv32i_zicsr", "-mabi=ilp32", asm, "-o", obj],
                [f"{cross}ld", "-m", "elf32lriscv", "-Ttext=0x0", "-e", "0x0",
                 "--no-warn-rwx-segments", obj, "-o", elf]):
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit(f"{' '.join(cmd)}\n{p.stderr}")
    return elf


# --log-commits lines look like:
#   core   0: 3 0x00000000 (0x00000093) x 1 0x00000000            ALU op
#   core   0: 3 0x00000004 (0x00b52023) mem 0x00000010 0x0000002a store
#   core   0: 3 0x00000008 (0x00052083) x 1 0x2a mem 0x00000010    load
COMMIT = re.compile(
    r"core\s+\d+:\s+\d+\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)(.*)")
REGWRITE = re.compile(r"\bx\s*(\d+)\s+0x([0-9a-f]+)")

# A store is the only case where `mem` carries two operands: address then
# value. A load prints `mem <addr>` with the loaded value in the register
# field instead, so the second 0x... is absent and this does not match.
# `\bx` in REGWRITE does not fire on the `x` inside `0x...` because there is
# no word boundary between a digit and x, which is what keeps these two
# patterns from stealing each other's operands.
MEMWRITE = re.compile(r"\bmem\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)")


def spike_trace(spike, elf, sentinel_word, memmap, max_instr):
    with tempfile.NamedTemporaryFile("w+", suffix=".log", delete=False) as log:
        logname = log.name
    cmd = [spike, "-l", "--log-commits", f"--log={logname}",
           "--isa=rv32i_zicsr", "--priv=m", f"-m{memmap}",
           f"--instructions={max_instr}", elf]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"spike failed:\n{' '.join(cmd)}\n{p.stdout}\n{p.stderr}")

    trace = []
    for line in open(logname):
        m = COMMIT.match(line.strip())
        if not m:
            continue
        pc, instr, rest = int(m.group(1), 16), int(m.group(2), 16), m.group(3)
        rw = REGWRITE.search(rest)
        if rw:
            rd, wdata, regwrite = int(rw.group(1)), int(rw.group(2), 16), 1
        else:
            rd, wdata, regwrite = 0, 0, 0
        mw = MEMWRITE.search(rest)
        if mw:
            st_valid, st_addr, st_data = 1, int(mw.group(1), 16), int(mw.group(2), 16)
        else:
            st_valid, st_addr, st_data = 0, 0, 0
        trace.append((pc, instr, rd, wdata, regwrite, st_valid, st_addr, st_data))
        if instr == sentinel_word:
            break
    os.unlink(logname)

    if not trace or trace[-1][1] != sentinel_word:
        sys.exit("spike never retired the sentinel -- the generated program "
                 "did not terminate as expected. The usual cause is the "
                 "program corrupting itself: Spike has one address space, the "
                 "DUT is Harvard, so a store into the code image loops Spike "
                 "forever. See data_base_for().")

    # Drop Spike's boot ROM. Spike starts at its reset vector and runs a short
    # setup sequence (auipc/addi/csrrs mhartid/lw/jalr) before jumping to the
    # ELF entry. The DUT has no boot ROM -- it resets directly to PC 0 -- so
    # those retirements have no counterpart and would put every subsequent
    # comparison out of step by five.
    #
    # Cutting at the first retirement at the entry PC is safe here because the
    # generated program only ever branches forward and so never returns to 0.
    start = next((i for i, row in enumerate(trace) if row[0] == ENTRY_PC), None)
    if start is None:
        sys.exit(f"spike never reached the program entry at 0x{ENTRY_PC:x}")
    if start:
        print(f"  (dropped {start} boot-ROM retirements before the entry point)")
    return trace[start:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--num-instr", type=int, default=40)
    ap.add_argument("--out-hex", default="../uvm/stream.hex")
    ap.add_argument("--out-trace", default="../uvm/stream_trace.txt")
    ap.add_argument("--memmap", default="0x0:0x1000,0x2000:0x1e000")
    ap.add_argument("--max-instr", type=int, default=100000)
    ap.add_argument("--spike", default=os.environ.get("SPIKE", "spike"))
    ap.add_argument("--toolchain", default=os.environ.get("CROSS", "riscv64-unknown-elf-"))
    args = ap.parse_args()

    rng = random.Random(args.seed)
    words = generate(rng, args.num_instr)
    sentinel = words[-1]

    with tempfile.TemporaryDirectory() as wd:
        elf = build_elf(words, wd, args.toolchain)
        trace = spike_trace(args.spike, elf, sentinel, args.memmap, args.max_instr)

    with open(args.out_hex, "w") as f:
        for w in words:
            f.write(f"{w:08x}\n")

    with open(args.out_trace, "w") as f:
        f.write(f"// AUTO-GENERATED by verif/spike/gen_stream.py "
                f"--seed {args.seed} --num-instr {args.num_instr}\n")
        f.write("// Reference model: Spike. Columns: "
                "pc instr rd wdata regwrite store_valid store_addr store_data\n")
        for pc, instr, rd, wdata, regwrite, sv, sa, sd in trace:
            f.write(f"{pc:08x} {instr:08x} {rd:2d} {wdata:08x} {regwrite} "
                    f"{sv} {sa:08x} {sd:08x}\n")

    n_stores = sum(row[5] for row in trace)
    print(f"{args.out_hex}: {len(words)} words (seed {args.seed})")
    print(f"{args.out_trace}: {len(trace)} retirements ({n_stores} stores), "
          f"sentinel 0x{sentinel:08x}")


if __name__ == "__main__":
    main()
