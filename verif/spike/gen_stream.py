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
OP_LUI, OP_AUIPC, OP_JAL, OP_JALR = 0x37, 0x17, 0x6F, 0x67
DATA_BASE_GPR = 1
COMPLETION_GPR = 31
COMPLETION_VALUE = 0x7FF
NOP = 0x00000013
BASE_PTR_WORD = 1                              # The ADDI that loads x1, the
                                               # data base pointer.
SENTINEL_WORD = 1                              # The ADDI that writes x31, the
                                               # completion sentinel.
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
USABLE_GPRS = range(2, 31)                     # x2..x30: the registers the
                                               # random body may freely read
                                               # and clobber -- everything but
                                               # x0, the x1 base pointer, and
                                               # the x31 sentinel.
DEST_GPRS = [0, *USABLE_GPRS]                  # rd pool: x0 plus x2..x30 --
                                               # never x1 or x31.
ENTRY_PC = 0x0                                 # The core's reset vector.


def compute_data_window_base(program_word_count):
    """Compute the safe data-window address placed in x1. Must not be 0.

    The DUT is Harvard (separate imem and dmem, both based at 0); Spike is von
    Neumann. With x1 = 0, the generated stores land on the program image, which
    only Spike then executes (overwriting the imem).

    Pointing x1 past the program image with a 256-byte gap keeps each model's
    data region clear of its code.
    """
    program_size_bytes = program_word_count * 4
    data_window_base = ((program_size_bytes + 255) // 256 + 1) * 256
    if data_window_base + MEM_GAP_BYTES - 1 > MAX_ADDI_IMMEDIATE:
        sys.exit(
            f"a {program_word_count}-word program is too long: x1 would need "
            f"to be 0x{data_window_base:x}, past what a single ADDI can "
            f"encode ({MAX_ADDI_IMMEDIATE}). Use a smaller --num-instr, or "
            "teach the generator to emit LUI+ADDI for the base pointer.")
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

# U-type (LUI/AUIPC): imm[31:12] sits directly above rd.
def enc_u(opcode, rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | opcode

# J-type (JAL): 21-bit even offset, bit 0 implicit; imm[20] -> bit 31,
# imm[10:1] -> 30:21, imm[11] -> bit 20, imm[19:12] -> 19:12.
def enc_j(opcode, rd, imm21):
    imm21 &= 0x1FFFFF
    return (((imm21 >> 20) & 1) << 31) | (((imm21 >> 1) & 0x3FF) << 21) | \
           (((imm21 >> 11) & 1) << 20) | (((imm21 >> 12) & 0xFF) << 12) | \
           (rd << 7) | opcode

def generate(rng, random_instr_count):
    """Build a program that is safe by construction: loads/stores only go
    through the reserved x1 base, control transfers only jump forward a
    bounded amount, and the last instruction is the sentinel the scoreboard
    watches for."""

    # Zero x2..x30 so Spike and the DUT start the body with identical registers
    # One "addi rN, x0, 0" per register
    zero_regs = [enc_i(OP_ITYPE, register, 0b000, 0, 0) for register in USABLE_GPRS]

    # dmem needs no init: the UVM driver backdoor-clears it

    # rd of the last three instructions, newest first (0 = wrote no register);
    # biased_src() reuses these to hit both forwarding paths and the regfile bypass
    recent_rd = [DATA_BASE_GPR, 0, 0]

    def biased_src():
        """A source register, biased toward a recent real producer.

        RECENT_RESULT_BIAS_PERCENT of the time this picks one of the last three
        slots uniformly, so the stimulus asks for all three hazard distances
        rather than piling onto the easiest one. A slot holding 0 means that
        instruction wrote no register. 

        x1 is the base pointer, x2..x30 are zeroed up front, and
        x0 is hardwired. x31 is the sentinel and is deliberately unreachable.
        """
        if rng.randrange(100) < RECENT_RESULT_BIAS_PERCENT:
            r = recent_rd[rng.randrange(3)]
            if r != 0:
                return r
        return rng.randrange(31)

    def push_producer(reg, writes):
        recent_rd.insert(0, reg if (writes and reg != 0) else 0)
        del recent_rd[3:] # delete from index 3 onwards

    body = []
    # Layout: zero_regs | base-pointer ADDI | body | NOP padding | sentinel
    body_base = len(zero_regs) + BASE_PTR_WORD

    # Every word index an already-emitted branch or jump can land on
    # AUIPC+JALR below only works as a unit: a jump straight onto the JALR
    # skips the AUIPC, leaving a random address in rt
    jump_targets = set()

    for _ in range(random_instr_count):
        idx = body_base + len(body)      # word index of the next instruction
        # cls 0..99 picks the instruction class by weight: 25% R-type,
        # 20% I-type ALU, 17% load, 13% store, 10% branch, 5% JAL,
        # 4% AUIPC+JALR pair, 6% LUI/AUIPC
        cls = rng.randrange(100)
        rs1 = biased_src()
        rs2 = biased_src()
        rd = rng.choice(DEST_GPRS)

        if cls < 25:                                        # R-type
            funct3 = rng.randrange(8)
            # funct7 bit 30 turns ADD into SUB and SRL into SRA; it must be
            # 0 for every other funct3.
            if funct3 in (0b000, 0b101):
                funct7 = 0b0100000 if rng.randrange(2) else 0b0000000
            else:
                funct7 = 0
            body.append(enc_r(OP_RTYPE, rd, funct3, rs1, rs2, funct7))
            push_producer(rd, True)
        elif cls < 45:                                      # I-type ALU
            funct3 = [0b000, 0b010, 0b011, 0b100, 0b110, 0b111,
                      0b001, 0b101][rng.randrange(8)]
            if funct3 == 0b001:                             # SLLI: imm = shamt
                imm = rng.randrange(32)
            elif funct3 == 0b101:                           # SRLI/SRAI: bit 30
                imm = rng.randrange(32) | (0x400 if rng.randrange(2) else 0)
            else:                                           # plain 12-bit imm
                imm = rng.randrange(4096)
            body.append(enc_i(OP_ITYPE, rd, funct3, rs1, imm))
            push_producer(rd, True)
        elif cls < 62:                                      # LOAD off x1
            # (funct3, offset) per width -- LW LH LHU LB LBU -- with the
            # offset aligned to that width and inside the 256-byte window.
            funct3, off = [
                (0b010, rng.randrange(64) * 4),
                (0b001, rng.randrange(128) * 2),
                (0b101, rng.randrange(128) * 2),
                (0b000, rng.randrange(256)),
                (0b100, rng.randrange(256)),
            ][rng.randrange(5)]
            body.append(enc_i(OP_LOAD, rd, funct3, DATA_BASE_GPR, off))
            push_producer(rd, True)
        elif cls < 75:                                      # STORE off x1
            # Same scheme for SW SH SB.
            funct3, off = [
                (0b010, rng.randrange(64) * 4),
                (0b001, rng.randrange(128) * 2),
                (0b000, rng.randrange(256)),
            ][rng.randrange(3)]
            body.append(enc_s(OP_STORE, funct3, DATA_BASE_GPR, rs2, off))
            push_producer(0, False)
        elif cls < 85:                                      # BRANCH, forward only
            # BEQ or BNE, jumping forward 16, 32 or 48 bytes
            # (PAD_WORDS guarantees the target is inside the program)
            funct3 = 0b001 if rng.randrange(2) else 0b000
            off = rng.randint(1, 3) * 16
            jump_targets.add(idx + off // 4)
            body.append(enc_b(OP_BRANCH, funct3, rs1, rs2, off))
            push_producer(0, False)
        elif cls < 90:                                      # JAL, forward only
            off = rng.randint(1, 3) * 16
            jump_targets.add(idx + off // 4)
            body.append(enc_j(OP_JAL, rd, off))
            push_producer(rd, True)
        elif cls < 94 and (idx + 1) not in jump_targets:    # AUIPC+JALR pair
            rt = rng.choice(list(USABLE_GPRS))
            off = rng.randint(1, 3) * 16
            jump_targets.add(idx + off // 4)
            body.append(enc_u(OP_AUIPC, rt, 0))
            body.append(enc_i(OP_JALR, rd, 0b000, rt, off))
            push_producer(rt, True)
            push_producer(rd, True)
        else:                             # LUI/AUIPC (and the pair's fallback)
            opc = OP_LUI if rng.randrange(2) else OP_AUIPC
            body.append(enc_u(opc, rd, rng.randrange(1 << 20)))
            push_producer(rd, True)

    # A JALR pair emits two words, so we cant guess how many instr in the program
    program_words = body_base + len(body) + PAD_WORDS + SENTINEL_WORD
    data_window_base = compute_data_window_base(program_words)

    words = zero_regs
    words.append(enc_i(OP_ITYPE, DATA_BASE_GPR, 0b000, 0, data_window_base))
    words += body
    # Pad so a forward transfer among the last few instructions lands inside
    # the program rather than in unwritten memory
    words += [NOP] * PAD_WORDS
    words.append(enc_i(OP_ITYPE, COMPLETION_GPR, 0b000, 0, COMPLETION_VALUE))
    return words

# Spike loads ELF excecutables
# This loop writes a tiny assembly file that contains no instructions at all 
# just .word directives
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
REGWRITE = re.compile(r"\bx\s*(\d+)\s+0x([0-9a-f]+)")   # \b: never inside 0x...

# A store prints two operands after `mem`. a load prints only the address and
# puts its value in the `x` field. Requiring two is what selects stores.
MEMWRITE = re.compile(r"\bmem\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)")


def spike_trace(spike, elf, sentinel_word, memmap, max_instr):
    # Make a log for spike to write into 
    with tempfile.NamedTemporaryFile("w+", suffix=".log", delete=False) as log:
        logname = log.name

    # Need to set these flags to make spike behave like the DUT core 
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
