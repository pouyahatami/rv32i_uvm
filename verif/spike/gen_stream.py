"""Generate the UVM environment's instruction stream and its expected
retirement trace.

    ./gen_stream.py --seed 1 --num-instr 40 \
        --out-hex ../uvm/stream.hex --out-trace ../uvm/stream_trace.txt

Writes the program the DUT runs and the trace the scoreboard checks it against.
The two must always be regenerated together.
Spike runs here, ahead of simulation, rather than being called live from the
testbench. verif/uvm/RUNNING.md explains why and what that costs.

Trace format, one row per retirement in retirement order:

    pc instr rd wdata regwrite store_valid store_addr store_data

Hex except rd, regwrite and store_valid. When store_valid is 0 the two store
columns are 0. Traces carrying only the first five columns are still accepted;
the scoreboard then disables store checking.
"""

import argparse
import os
import random
import re
import subprocess
import sys
import tempfile

OP_RTYPE, OP_ITYPE, OP_LOAD, OP_STORE, OP_BRANCH = 0x33, 0x13, 0x03, 0x23, 0x63
DATA_BASE_GPR = 1
COMPLETION_GPR = 31
COMPLETION_VALUE = 0x7FF
NOP = 0x00000013
MEMAX_BRANCH_OFFSET = 48                       # Chosen by the generator.
PAD_WORDS = MEMAX_BRANCH_OFFSET // 4           # Enough padding for the longest
                                               # branch offset from the last
                                               # random instruction to land
                                               # within the defined imem region
                                               # (NOP instructions).

MEM_GAP_BYTES = 256                            # Gap between the imem and dmem
                                               # regions.

MAX_ADDI_IMMEDIATE = 2047                      # x1 is set with a single ADDI by
                                               # the generator; the program
                                               # length must not cause its base
                                               # to exceed this value.
RECENT_RESULT_BIAS_PERCENT = 60                # Chance a source register is a
                                               # recent destination; see
                                               # biased_src().
REG_INIT_REGS = range(2, 31)                   # x2..x30.
REG_INIT_WORDS = len(REG_INIT_REGS)
ENTRY_PC = 0x0                                 # The core's reset vector.


def compute_data_window_base(random_instr_count):
    """Compute the safe data-window address placed in x1. Must not be 0.

    The DUT is Harvard (separate imem and dmem, both based at 0); Spike is von
    Neumann. With x1 = 0, the generated stores land on the program image, which
    only Spike then executes (overwriting the imem).

    Pointing x1 past the program image with a 256-byte gap keeps each model's
    data region clear of its code.
    """
    # The two +1 terms below account for the x1 data-base initialization and
    # the x31 completion instruction, indicating program start and completion.
    program_word_count = (REG_INIT_WORDS + 1 + random_instr_count
                          + PAD_WORDS + 1)
    program_size_bytes = program_word_count * 4
    data_window_base = ((program_size_bytes + 255) // 256 + 1) * 256
    if data_window_base + MEM_GAP_BYTES - 1 > MAX_ADDI_IMMEDIATE:
        sys.exit(
            f"--num-instr {random_instr_count} makes the program too long: "
            f"x1 would need to be 0x{data_window_base:x}, past what a single "
            f"ADDI can encode ({MAX_ADDI_IMMEDIATE}). Use a smaller "
            "--num-instr, or teach the generator to emit LUI+ADDI for the "
            "base pointer.")
    return data_window_base



# Field skeleton shared by all formats (R-type shown; the others repurpose
# the funct7/rd slots for immediate bits):
#
# bit: 31      25 24   20 19   15 14  12 11    7 6      0
#      ┌─────────┬───────┬───────┬──────┬───────┬────────┐
#      │ funct7  │  rs2  │  rs1  │funct3│  rd   │ opcode │
#      │ 7 bits  │ 5 bits│ 5 bits│3 bits│ 5 bits│ 7 bits │
#      └─────────┴───────┴───────┴──────┴───────┴────────┘

# I-type (ALU-immediate, loads): imm[11:0] replaces funct7+rs2 at bits
# 31:20.
def enc_i(opcode, rd, funct3, rs1, imm12):
    return (((imm12 & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode)

# R-type (register-register ALU): no immediate; funct7 disambiguates ADD/SUB
# and SRL/SRA.
def enc_r(opcode, rd, funct3, rs1, rs2, funct7):
    return ((funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode)

# S-type (stores): no rd, so imm[11:5] takes the funct7 slot and imm[4:0]
# takes the rd slot.
def enc_s(opcode, funct3, rs1, rs2, imm12):
    imm12 &= 0xFFF
    return (((imm12 >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (funct3 << 12) | ((imm12 & 0x1F) << 7) | opcode

# B-type (branches): 13-bit even offset, bit 0 implicit; imm[12] -> bit 31,
# imm[10:5] -> 30:25, imm[4:1] -> 11:8, imm[11] -> bit 7.
def enc_b(opcode, funct3, rs1, rs2, imm13):
    imm13 &= 0x1FFF
    return (((imm13 >> 12) & 1) << 31) | (((imm13 >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | \
           (((imm13 >> 1) & 0xF) << 8) | (((imm13 >> 11) & 1) << 7) | opcode

def generate(rng, random_instr_count):
    """Build a stream that is legal by construction.

    This means it needs no post-hoc constraints.

    x1 is a reserved base pointer -- never any instruction's destination -- so
    every load/store offset is known here to be small, aligned, and clear of the
    MMIO window. Branches only ever go forward, by a bounded amount. The last
    instruction is a sentinel the scoreboard watches for.
    """
    data_window_base = compute_data_window_base(random_instr_count)

    # Register-zeroing prologue. Spike's boot ROM leaves state behind before
    # jumping to the ELF entry (notably x11 = dtb pointer); the DUT resets
    # straight to PC 0 and runs none of it. Reading such a register before
    # writing it would diverge for reasons unrelated to the DUT, and would look
    # exactly like a forwarding bug. x1 is set below; x31 is the sentinel and is
    # never read by the body, so neither needs zeroing here.
    words = [enc_i(OP_ITYPE, r, 0b000, 0, 0) for r in REG_INIT_REGS]

    # x1 = the data base pointer. It is deliberately not 0; see
    # compute_data_window_base().
    words.append(enc_i(OP_ITYPE, DATA_BASE_GPR, 0b000, 0,
                       data_window_base))

    # The UVM driver clears dmem through a verification-only backdoor while
    # reset is asserted. Spike also starts RAM at zero, so loads from the data
    # window now agree without spending 64 retired stores on initialization.

    # The architectural producers among the last three instructions, most
    # recent first. A slot holds the destination register if that instruction
    # actually wrote one, else 0: stores and branches write no register, and a
    # write to x0 writes nothing, so none of those is a producer a later
    # instruction could depend on.
    #
    # Tracking that distinction matters, not just the raw rd fields. An
    # earlier version pushed rd unconditionally, so after a store or branch
    # the bias pointed at a register the instruction never wrote -- a phantom
    # producer. The bias percentage the comments claimed was then not the bias
    # the generator delivered, and the coverage distances were diluted by
    # dependencies on registers whose "producer" produced nothing.
    #
    # Dependency DISTANCE is what selects the mechanism under test: distance 1
    # and 2 are the two forwarding paths, and distance 3 is the register-file
    # read-during-write bypass -- the gap between those two mechanisms, and a
    # real bug once (docs/BUGS.md, D4).
    recent_rd = [DATA_BASE_GPR, 0, 0]

    def biased_src():
        """A source register, biased toward a recent real producer.

        RECENT_RESULT_BIAS_PERCENT of the time this picks one of the last three
        slots uniformly, so the stimulus asks for all three hazard distances
        rather than piling onto the easiest one. A slot holding 0 means that
        instruction produced nothing -- fall through to a uniform pick rather
        than fabricating a dependency on x0, which is never a hazard.

        Every register this can return is architecturally defined at this
        point: x1 is the base pointer, x2..x30 are zeroed by the prologue, and
        x0 is hardwired. x31 is the sentinel and is deliberately unreachable.
        """
        if rng.randrange(100) < RECENT_RESULT_BIAS_PERCENT:
            r = recent_rd[rng.randrange(3)]
            if r != 0:
                return r
        return rng.randrange(31)

    for _ in range(random_instr_count):
        cls = rng.randrange(100)
        rs1 = biased_src()
        rs2 = biased_src()
        rd = rng.randrange(31)
        while rd in (DATA_BASE_GPR, COMPLETION_GPR):
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
            words.append(enc_i(OP_LOAD, rd, funct3, DATA_BASE_GPR, off))
        elif cls < 90:                                      # STORE off x1
            funct3, off = [
                (0b010, rng.randrange(64) * 4),
                (0b001, rng.randrange(128) * 2),
                (0b000, rng.randrange(256)),
            ][rng.randrange(3)]
            words.append(enc_s(OP_STORE, funct3, DATA_BASE_GPR, rs2, off))
        else:                                               # BRANCH, forward only
            funct3 = 0b001 if rng.randrange(2) else 0b000
            words.append(enc_b(OP_BRANCH, funct3, rs1, rs2,
                               rng.randint(1, 3) * 16))

        # cls < 75 covers exactly the classes that write a register (R-type,
        # I-type ALU, LOAD); stores and branches, and any write to x0, push 0.
        writes_rd = cls < 75 and rd != 0
        recent_rd = [rd if writes_rd else 0] + recent_rd[:2]

    # Pad so a forward branch among the last few instructions lands inside the
    # program rather than in unwritten memory.
    words += [NOP] * PAD_WORDS
    words.append(enc_i(OP_ITYPE, COMPLETION_GPR, 0b000, 0, COMPLETION_VALUE))
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
                 "forever. See compute_data_window_base().")

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
    ap.add_argument("--num-instr", dest="random_instr_count", type=int, default=40)
    ap.add_argument("--out-hex", default="../uvm/stream.hex")
    ap.add_argument("--out-trace", default="../uvm/stream_trace.txt")
    ap.add_argument("--memmap", default="0x0:0x1000,0x2000:0x1e000")
    ap.add_argument("--max-instr", type=int, default=100000)
    ap.add_argument("--spike", default=os.environ.get("SPIKE", "spike"))
    ap.add_argument("--toolchain", default=os.environ.get("CROSS", "riscv64-unknown-elf-"))
    args = ap.parse_args()

    rng = random.Random(args.seed)
    words = generate(rng, args.random_instr_count)
    sentinel = words[-1]

    with tempfile.TemporaryDirectory() as wd:
        elf = build_elf(words, wd, args.toolchain)
        trace = spike_trace(args.spike, elf, sentinel, args.memmap, args.max_instr)

    with open(args.out_hex, "w") as f:
        for w in words:
            f.write(f"{w:08x}\n")

    with open(args.out_trace, "w") as f:
        f.write(f"// AUTO-GENERATED by verif/spike/gen_stream.py "
                f"--seed {args.seed} --num-instr {args.random_instr_count}\n")
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
