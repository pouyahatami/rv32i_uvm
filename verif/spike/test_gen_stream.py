#!/usr/bin/env python3
"""Unit tests for gen_stream.py's generator invariants.

    cd verif/spike && python3 -m unittest test_gen_stream -v

These test generate() itself, which is pure Python -- no Spike, no toolchain.
Every invariant here is one the memory model or the checker depends on, and
each was either violated once or is the kind of thing that would fail silently:
a generator bug does not crash a simulation, it quietly changes what the
regression is testing (docs/BUGS.md, V4/V5 -- and the phantom-producer bias
bug that motivated this file).
"""

import random
import unittest

import gen_stream as g


def fld(w, lo, hi):
    return (w >> lo) & ((1 << (hi - lo + 1)) - 1)


def opcode(w):
    return fld(w, 0, 6)


def rd(w):
    return fld(w, 7, 11)


def rs1(w):
    return fld(w, 15, 19)


def rs2(w):
    return fld(w, 20, 24)


def i_imm(w):
    return fld(w, 20, 31)


def s_imm(w):
    return (fld(w, 25, 31) << 5) | fld(w, 7, 11)


def b_imm(w):
    imm = (fld(w, 31, 31) << 12) | (fld(w, 7, 7) << 11) | \
          (fld(w, 25, 30) << 5) | (fld(w, 8, 11) << 1)
    return imm - 0x2000 if imm & 0x1000 else imm


def j_imm(w):
    imm = (fld(w, 31, 31) << 20) | (fld(w, 12, 19) << 12) | \
          (fld(w, 20, 20) << 11) | (fld(w, 21, 30) << 1)
    return imm - 0x200000 if imm & 0x100000 else imm


WRITING_OPCODES = {g.OP_RTYPE, g.OP_ITYPE, g.OP_LOAD,
                   g.OP_LUI, g.OP_AUIPC, g.OP_JAL, g.OP_JALR}


def body_of(words, random_instr_count):
    """The randomly generated slice: after the prologue, before pad+sentinel.

    A JALR pair emits two words, so the body can be longer than
    random_instr_count -- slice by position, not by count.
    """
    prologue = len(g.USABLE_GPRS) + 1
    return words[prologue:len(words) - g.PAD_WORDS - 1]


def streams(n_seeds=50, random_instr_count=40):
    for seed in range(n_seeds):
        rng = random.Random(seed)
        yield (seed, g.generate(rng, random_instr_count),
               random_instr_count)


class TestReservedRegisters(unittest.TestCase):
    def test_body_never_writes_base_pointer_or_sentinel(self):
        # x1 is what keeps stores off the program image (BUGS.md V4); x31 is
        # what tells the scoreboard the run is over. Writing either mid-stream
        # breaks the memory model or ends checking early.
        for seed, words, n in streams():
            for w in body_of(words, n):
                if opcode(w) in WRITING_OPCODES:
                    self.assertNotIn(rd(w), (g.DATA_BASE_GPR, g.COMPLETION_GPR),
                                     f"seed {seed}: body writes reserved reg")

    def test_every_memory_access_is_based_on_x1(self):
        for seed, words, n in streams():
            for w in body_of(words, n):
                if opcode(w) in (g.OP_LOAD, g.OP_STORE):
                    self.assertEqual(rs1(w), g.DATA_BASE_GPR,
                                     f"seed {seed}: memory access off x{rs1(w)}")


class TestMemoryWindow(unittest.TestCase):
    def test_offsets_stay_inside_the_initialized_window_and_are_aligned(self):
        # The UVM reset-time backdoor establishes the known-zero dmem state.
        # Keeping accesses in MEM_GAP_BYTES also keeps them below
        # MMIO. A misaligned access would trap on the DUT and not on Spike.
        width_align = {0b000: 1, 0b100: 1, 0b001: 2, 0b101: 2, 0b010: 4}
        for seed, words, n in streams():
            for w in body_of(words, n):
                if opcode(w) == g.OP_LOAD:
                    off = i_imm(w)
                elif opcode(w) == g.OP_STORE:
                    off = s_imm(w)
                else:
                    continue
                f3 = fld(w, 12, 14)
                self.assertLess(off, g.MEM_GAP_BYTES, f"seed {seed}")
                self.assertEqual(off % width_align[f3], 0,
                                 f"seed {seed}: misaligned funct3={f3:03b} off={off}")


class TestControlTransfers(unittest.TestCase):
    def test_branches_and_jal_only_jump_forward_within_the_padding(self):
        # A backward transfer can loop forever; a forward one past the pad
        # lands in unwritten memory. Both desynchronise the two models.
        for seed, words, n in streams():
            for w in body_of(words, n):
                if opcode(w) == g.OP_BRANCH:
                    self.assertGreater(b_imm(w), 0, f"seed {seed}")
                    self.assertLessEqual(b_imm(w), g.MEMAX_BRANCH_OFFSET,
                                         f"seed {seed}")
                elif opcode(w) == g.OP_JAL:
                    self.assertGreater(j_imm(w), 0, f"seed {seed}")
                    self.assertLessEqual(j_imm(w), g.MEMAX_BRANCH_OFFSET,
                                         f"seed {seed}")

    def test_jalr_is_paired_and_never_a_jump_target(self):
        # Each JALR must directly follow the AUIPC that pins its base, and no
        # other transfer may land on the JALR word -- entered alone it would
        # jump through a stale register.
        for seed, words, n in streams():
            body = body_of(words, n)
            base = len(g.USABLE_GPRS) + 1
            targets = set()
            for i, w in enumerate(body):
                if opcode(w) in (g.OP_BRANCH, g.OP_JAL):
                    off = b_imm(w) if opcode(w) == g.OP_BRANCH else j_imm(w)
                    targets.add(base + i + off // 4)
                elif opcode(w) == g.OP_JALR:
                    prev = body[i - 1] if i > 0 else 0
                    self.assertEqual(opcode(prev), g.OP_AUIPC,
                                     f"seed {seed}: unpaired JALR")
                    self.assertEqual(rd(prev), rs1(w),
                                     f"seed {seed}: JALR base != AUIPC rd")
                    self.assertGreater(i_imm(w), 0, f"seed {seed}")
                    self.assertLessEqual(i_imm(w), g.MEMAX_BRANCH_OFFSET,
                                         f"seed {seed}")
                    targets.add(base + (i - 1) + i_imm(w) // 4)
            for i, w in enumerate(body):
                if opcode(w) == g.OP_JALR:
                    self.assertNotIn(base + i, targets,
                                     f"seed {seed}: a transfer targets a JALR")


class TestSentinel(unittest.TestCase):
    def test_stream_ends_with_the_sentinel_write(self):
        for seed, words, n in streams(n_seeds=10):
            w = words[-1]
            self.assertEqual(opcode(w), g.OP_ITYPE)
            self.assertEqual(rd(w), g.COMPLETION_GPR)
            self.assertEqual(i_imm(w), g.COMPLETION_VALUE)


class TestHazardBias(unittest.TestCase):
    def test_dependencies_target_real_producers_at_a_real_rate(self):
        # The regression's whole value rests on the stimulus being
        # hazard-rich. This measures, with an independent reimplementation of
        # producer tracking, how often a source register reads something one
        # of the previous three instructions ACTUALLY wrote -- stores,
        # branches and x0-writes produce nothing and must not count. The
        # phantom-producer bug this file exists to prevent inflated the
        # apparent bias while diluting the real one.
        dep = 0
        uses = 0
        for seed, words, n in streams():
            producers = [0, 0, 0]
            for w in body_of(words, n):
                op = opcode(w)
                srcs = []
                if op in (g.OP_RTYPE, g.OP_ITYPE, g.OP_LOAD, g.OP_STORE,
                          g.OP_BRANCH, g.OP_JALR):
                    srcs.append(rs1(w))
                if op in (g.OP_RTYPE, g.OP_STORE, g.OP_BRANCH):
                    srcs.append(rs2(w))
                for s in srcs:
                    uses += 1
                    if s != 0 and s in producers:
                        dep += 1
                wrote = rd(w) if (op in WRITING_OPCODES and rd(w) != 0) else 0
                producers = [wrote] + producers[:2]
        rate = dep / uses
        # Uniform-random sources would land near 10%; the bias should put it
        # far above that. The bound is loose on purpose -- this is a tripwire
        # for the bias silently breaking, not a distribution test.
        self.assertGreater(rate, 0.30,
                           f"only {rate:.0%} of source reads depend on a real "
                           f"producer in the last 3 instructions -- bias broken?")


if __name__ == "__main__":
    unittest.main()
