#!/usr/bin/env python3
"""Generate the UVM environment's instruction stream and its expected retirement trace.

    ./gen_stream.py --seed 1 --num-instr 40 \
        --out-hex ../uvm/stream.hex --out-trace ../uvm/stream_trace.txt

Writes the program the DUT runs and the trace the scoreboard checks it against.
The two must always be regenerated together: a trace computed from a different
program is a scoreboard that checks nothing.

Spike runs here, ahead of simulation, rather than being called live from the
testbench. verif/uvm/RUNNING.md explains why and what that costs.

Trace format, one row per retirement in retirement order:

    pc instr rd wdata regwrite store_valid store_addr store_data

Hex except rd, regwrite and store_valid. When store_valid is 0 the two store
columns are 0. Traces carrying only the first five columns are still accepted;
the scoreboard then disables store checking rather than silently passing stores
it never compared.
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
    """Where x1 points. Must not be 0.

    The DUT is Harvard (separate imem and dmem, both based at 0); Spike is von
    Neumann. With x1 = 0 the generated stores land on the program image, which
    only Spike then executes -- it traps to an uninitialised mtvec and loops, so
    the sentinel never retires and the two models disagree about the whole run.

    Pointing x1 past the program image with a 256-byte gap keeps each model's
    data region clear of its code. DESIGN_GUIDE.md section 8 has the full list
    of legitimate model differences.
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
    """Build a stream that is legal by construction, so it needs no post-hoc constraints.

    x1 is a reserved base pointer -- never any instruction's destination -- so
    every load/store offset is known here to be small, aligned, and clear of the
    MMIO window. Branches only ever go forward, by a bounded amount. The last
    instruction is a sentinel the scoreboard watches for.
    """
    base = data_base_for(num_instr)

    # Register-zeroing prologue. Spike's boot ROM leaves state behind before
    # jumping to the ELF entry (notably x11 = dtb pointer); the DUT resets
    # straight to PC 0 and runs none of it. Reading such a register before
    # writing it would diverge for reasons unrelated to the DUT, and would look
    # exactly like a forwarding bug. x1 is set below; x31 is the sentinel and is
    # never read by the body, so neither needs zeroing here.
    words = [enc_i(OP_ITYPE, r, 0b000, 0, 0) for r in REG_INIT_REGS]

    # x1 = the data base pointer (see data_base_for -- deliberately not 0).
    words.append(enc_i(OP_ITYPE, SAFE_BASE_REG, 0b000, 0, base))

    # Memory-zeroing prologue: store 0 to every word the generated loads reach.
    # A load from a never-written location reads 0 on Spike but X in a 4-state
    # simulator, so every such load would mismatch for no reason connected to
    # the DUT. Using real stores rather than a backdoor keeps the prologue
    # inside the checked trace, so it verifies itself.
    for off in range(0, DATA_WINDOW, 4):
        words.append(enc_s(OP_STORE, 0b010, SAFE_BASE_REG, 0, off))

    last_rd = SAFE_BASE_REG

    for _ in range(num_instr):
        cls = rng.randrange(100)
        # 40% of instructions read the previous destination, so RAW hazards show up
        # far more often than uniform-random choice would give.
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

    # Pad so a forward branch among the last few instructions lands inside the
    # program rather than in unwritten memory.
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

# Only a store prints `mem` with two operands (address then value); a load
# prints `mem <addr>` and puts the value in the register field. REGWRITE's `\bx`
# cannot fire on the x inside `0x...` -- no word boundary between a digit and x
# -- which is what stops these two patterns stealing each other's operands.
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

    # Drop Spike's boot ROM: it runs a short setup sequence before jumping to
    # the ELF entry, and those retirements have no counterpart in the DUT, which
    # resets directly to PC 0. Cutting at the first retirement at the entry PC
    # is safe because the generated program only ever branches forward.
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
