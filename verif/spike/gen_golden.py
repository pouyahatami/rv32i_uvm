#!/usr/bin/env python3
"""
gen_golden.py -- generate a testbench's golden register/memory values by
running its program on Spike (riscv-isa-sim), the reference RISC-V ISS.

This replaces the project's former hand-written C++ ISS (iss/, deleted). The
point of the change is trust, not convenience: a golden model written by the
same person as the RTL, from the same reading of the spec, cannot catch a
misreading of the spec -- both sides agree and the test passes. Spike is
maintained by RISC-V International and is the model the official compliance
suite uses as its reference, so a disagreement between it and this core is
evidence about the core rather than about whether two of our own files match.

Flow:
    <prog>.txt (hex words)
      -> .S with .word directives
      -> riscv64-unknown-elf-as / -ld           ELF, .text at 0x0, entry 0x0
      -> spike -d --debug-cmd                   run to the program's EBREAK
      -> parse `reg 0` / `mem <addr>` output
      -> golden_vals_*.svh                      consumed unchanged by tb_pipe.sv

Note the assembler is doing real work here beyond file format: it is an
independent check on testgen/asm.py's hand-rolled encodings, since the ELF is
built from the same words the RTL's imem is loaded with.

See README.md in this directory for the Spike build (including the two
platform.h constants that must be moved, and why).
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

EBREAK = 0x00100073

# `reg 0` prints ABI names; map them back to architectural indices.
ABI = [
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
]
ABI_INDEX = {name: i for i, name in enumerate(ABI)}


def read_hex(path):
    words = []
    for line in open(path):
        line = line.strip()
        if line:
            words.append(int(line, 16))
    if not words:
        sys.exit(f"{path}: no instruction words found")
    return words


def find_ebreak(words, path):
    for i, w in enumerate(words):
        if w == EBREAK:
            return i * 4
    sys.exit(f"{path}: no EBREAK (0x{EBREAK:08x}) found -- "
             "gen_golden.py needs one to know where the program ends")


def build_elf(words, workdir, toolchain):
    asm = os.path.join(workdir, "prog.S")
    with open(asm, "w") as f:
        f.write(".section .text\n.globl _start\n_start:\n")
        for w in words:
            f.write(f"  .word 0x{w:08x}\n")

    obj = os.path.join(workdir, "prog.o")
    elf = os.path.join(workdir, "prog.elf")
    run([f"{toolchain}as", "-march=rv32i_zicsr", "-mabi=ilp32", asm, "-o", obj])
    # .text at 0x0 and entry 0x0 to match the core's reset vector exactly --
    # JAL/AUIPC results are PC-dependent, so the link address is not cosmetic.
    run([f"{toolchain}ld", "-m", "elf32lriscv", "-Ttext=0x0", "-e", "0x0",
         "--no-warn-rwx-segments", obj, "-o", elf])
    return elf


def spike_version(spike):
    """Recorded in the generated header so a .svh names the model that made it."""
    p = subprocess.run([spike, "--help"], capture_output=True, text=True)
    for line in (p.stderr + p.stdout).splitlines():
        if line.strip():
            return line.strip()
    return "unknown spike version"


def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        sys.exit(f"command failed: {' '.join(cmd)}\n{p.stdout}\n{p.stderr}")
    return p.stdout


def run_spike(spike, elf, stop_pc, mem_addrs, workdir, isa, memmap, devices, extlib):
    cmds = os.path.join(workdir, "cmds.txt")
    with open(cmds, "w") as f:
        f.write(f"until pc 0 0x{stop_pc:x}\n")
        f.write("reg 0\n")
        for a in mem_addrs:
            f.write(f"mem 0x{a:x}\n")
        f.write("quit\n")

    cmd = [spike, "-d", f"--debug-cmd={cmds}", f"--isa={isa}", "--priv=m",
           f"-m{memmap}"]
    for lib in extlib:
        cmd.append(f"--extlib={lib}")
    for dev in devices:
        cmd.append(f"--device={dev}")
    cmd.append(elf)

    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"spike failed:\n{' '.join(cmd)}\n{p.stdout}\n{p.stderr}")
    # Spike's interactive-debug replies go to stderr, its warnings too; take both.
    return p.stdout + p.stderr


def parse(out, n_mem):
    regs = {}
    mems = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("warning:"):
            continue
        # a bare "0x...." line is the answer to one of our `mem` commands
        if re.fullmatch(r"0x[0-9a-f]+", line):
            mems.append(int(line, 16))
            continue
        for name, val in re.findall(r"(\w+):\s*(0x[0-9a-f]+)", line):
            if name in ABI_INDEX:
                regs[ABI_INDEX[name]] = int(val, 16)

    missing = [i for i in range(32) if i not in regs]
    if missing:
        sys.exit(f"spike output did not contain registers {missing}\n{out}")
    if len(mems) != n_mem:
        sys.exit(f"expected {n_mem} memory words from spike, got {len(mems)}\n{out}")
    return regs, mems


def emit(path, regs, mems, hexname, spike_version):
    with open(path, "w") as f:
        f.write(f"// AUTO-GENERATED by verif/spike/gen_golden.py from {hexname}.\n")
        f.write(f"// Reference model: {spike_version}\n")
        f.write("// Do not hand-edit -- regenerate with verif/spike/regen.sh.\n")
        for i in range(32):
            f.write(f"    expect_reg[{i}] = 32'h{regs[i]:08x};\n")
        for n, val in enumerate(mems):
            f.write(f"    expect_mem_w{n} = 32'h{val:08x};\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hex", required=True, help="program hex file (one word per line)")
    ap.add_argument("--out", required=True, help="output .svh")
    ap.add_argument("--mem", action="append", default=[],
                    help="memory word address to dump, e.g. 0x0 (repeatable)")
    ap.add_argument("--isa", default="rv32i_zicsr")
    ap.add_argument("--memmap", default="0x0:0x1000,0x2000:0x3e000",
                    help="spike -m argument; the hole is where the boot ROM sits")
    ap.add_argument("--device", action="append", default=[])
    ap.add_argument("--extlib", action="append", default=[])
    ap.add_argument("--spike", default=os.environ.get("SPIKE", "spike"))
    ap.add_argument("--toolchain", default=os.environ.get("CROSS", "riscv64-unknown-elf-"))
    args = ap.parse_args()

    words = read_hex(args.hex)
    stop_pc = find_ebreak(words, args.hex)
    mem_addrs = [int(a, 0) for a in args.mem]

    version = spike_version(args.spike)

    with tempfile.TemporaryDirectory() as workdir:
        elf = build_elf(words, workdir, args.toolchain)
        out = run_spike(args.spike, elf, stop_pc, mem_addrs, workdir,
                        args.isa, args.memmap, args.device, args.extlib)
        regs, mems = parse(out, len(mem_addrs))

    emit(args.out, regs, mems, os.path.basename(args.hex), version)
    print(f"{args.out}: {len(words)} instructions, stopped at PC 0x{stop_pc:x}, "
          f"{len(mems)} memory word(s), reference = {version}")


if __name__ == "__main__":
    main()
