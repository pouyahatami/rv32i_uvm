import asm as A

# Hazard-focused directed program for the pipelined core. Every category
# of hazard the pipeline needs to get right, each isolated so a failure
# points at a specific piece of logic:
#
#   1. Back-to-back RAW (EX/MEM -> EX forwarding)
#   2. Two-apart RAW (MEM/WB -> EX forwarding)
#   3. Load-use hazard (must stall -- forwarding alone can't fix it)
#   4. Store-data forwarding (the value being stored, not just addresses)
#   5. Taken branch immediately followed by dependent instructions (flush
#      must not leave stale operands behind)
#   6. JAL immediately followed by an instruction that would have been
#      wrong-path (1-bubble flush)
#   7. x0 as a forwarding source -- forwarding logic must never treat an
#      x0 destination as satisfying a real dependency (regfile already
#      reads x0 as 0, but the *forwarding* path is separate hardware and
#      needs its own check)

entries = []
def emit(word): entries.append(('word', word))
def mark(name): entries.append(('label', name))
def emit_lazy(fn): entries.append(('lazy', fn))
def emit_branch(fn, rs1, rs2, lbl): emit_lazy(lambda addr_of, my: fn(rs1, rs2, addr_of[lbl] - my))

# 1. back-to-back RAW
emit(A.ADDI(1, 0, 10))         # x1 = 10
emit(A.ADD(2, 1, 1))           # x2 = x1+x1 = 20      (needs EX/MEM forward of x1)
emit(A.ADD(3, 2, 1))           # x3 = x2+x1 = 30      (needs EX/MEM forward of x2, MEM/WB forward of x1 -- both same cycle)

# 2. two-apart RAW
emit(A.ADDI(4, 0, 5))          # x4 = 5
emit(A.ADDI(0, 0, 0))          # NOP spacer (real NOP, not a hazard)
emit(A.ADD(5, 4, 4))           # x5 = x4+x4 = 10      (needs MEM/WB forward of x4)

# 3. load-use hazard: must stall, not silently use stale data
emit(A.ADDI(6, 0, 0))          # base addr = 0
emit(A.ADDI(7, 0, 0x55))       # value to store
emit(A.SW(6, 7, 0))            # mem[0..3] = 0x55
emit(A.LW(8, 6, 0))            # x8 = mem[0] = 0x55
emit(A.ADDI(9, 8, 1))          # x9 = x8+1 = 0x56     (load-use -- must stall one cycle)

# 4. store-data forwarding: the stored VALUE depends on the immediately
#    preceding instruction's result, not just the address
emit(A.ADDI(10, 0, 4))         # addr = 4
emit(A.ADDI(11, 0, 0x77))      # x11 = 0x77
emit(A.SW(10, 11, 0))          # mem[4..7] = 0x77     (store-data forward of x11)
emit(A.LW(12, 10, 0))          # x12 = mem[4] = 0x77  (readback proves the store actually got 0x77, not stale)

# 5. taken branch immediately followed by dependent instructions
emit(A.ADDI(13, 0, 1))
emit(A.ADDI(14, 0, 1))
emit_branch(A.BEQ, 13, 14, 'br_t')   # taken
emit(A.ADDI(15, 0, 999))              # must be flushed
mark('br_t')
emit(A.ADDI(15, 0, 1))
emit(A.ADD(16, 15, 15))               # x16 = 2, immediately dependent on the branch-target instruction

# 6. JAL 1-bubble flush
mark('jal_here')
emit_lazy(lambda addr_of, my: A.JAL_(17, addr_of['jal_target'] - my))  # x17 = link
emit(A.ADDI(18, 0, 999))              # must be flushed (1 bubble)
mark('jal_target')
emit(A.ADDI(19, 0, 1))
emit(A.ADD(20, 19, 19))               # x20 = 2, immediately dependent

# 7. x0 as a forwarding source must never poison a real dependency
emit(A.ADDI(0, 5, 0))          # attempted write to x0 -- must be a no-op
emit(A.ADDI(21, 0, 1))         # if forwarding incorrectly treated the x0 "write" as live, this would be corrupted
emit(A.ADD(22, 21, 0))         # x22 = x21 + x0 = 1  (x0 read must be 0, not a forwarded stale value)

emit(A.EBREAK())

addr_of = {}
addr = 0
for kind, *rest in entries:
    if kind == 'label': addr_of[rest[0]] = addr
    else: addr += 4

words = []
addr = 0
for kind, *rest in entries:
    if kind == 'word':
        words.append(rest[0]); addr += 4
    elif kind == 'lazy':
        words.append(rest[0](addr_of, addr)); addr += 4

with open('riscvtest_pipe.hex', 'w') as f:
    for w in words:
        f.write(f'{w & 0xFFFFFFFF:08x}\n')
print(f'{len(words)} instructions, {len(words)*4} bytes')
