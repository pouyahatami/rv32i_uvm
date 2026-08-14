# =============================================================================
# program_csr.py
#
# Directed test program for the CSR, trap, interrupt and UART paths.
# Exercises, in order:
#   1. mtvec setup (must happen before anything that can trap)
#   2. CSR read/write semantics (CSRRW/S/C + the *I variants, via mscratch)
#   3. ecall trap -> handler -> mret (with mepc+=4 skip, since a synchronous
#      exception's faulting instruction must not be blindly re-executed)
#   4. illegal-instruction trap -> handler -> mret
#   5. misaligned-load trap -> handler -> mret
#   6. misaligned-store trap -> handler -> mret
#   7. UART TX writes + readback
#   8. timer interrupt -> handler -> mret (WITHOUT mepc+=4 -- an interrupt's
#      mepc points at an instruction that has NOT executed yet and must be
#      re-executed after resume, unlike a synchronous exception)
#
# The handler dispatches on mcause: bit 31 distinguishes interrupt from
# exception; among exceptions, x28/x29/x30 count ecall/illegal/misaligned
# occurrences (test-bench visible via the register file, same "trust the
# ISS as ground truth, diff the final architectural state" pattern as
# every other testbench in this project -- see tb_pipe.sv).
# =============================================================================

import asm as A

entries = []
def emit(word): entries.append(('word', word))
def mark(name): entries.append(('label', name))
def emit_lazy(fn): entries.append(('lazy', fn))
def emit_branch(fn, rs1, rs2, lbl): emit_lazy(lambda addr_of, my: fn(rs1, rs2, addr_of[lbl] - my))
def emit_jal(rd, lbl): emit_lazy(lambda addr_of, my: A.JAL_(rd, addr_of[lbl] - my))

# ---- main program (PC starts here at reset -- address 0x0 IS 'main').
# Emitted BEFORE the handler code so 'main' lands at address 0 -- reset
# fetches from PC=0, and it must be main's first instruction, not the
# handler's. Straight-line execution ends at EBREAK, below, well before
# the handler's code region begins; the handler is only ever reached via
# a trap redirect through mtvec, never via fall-through.
mark('main')
emit(A.ADDI(1, 0, 0))                   # placeholder resolved below (mtvec)
entries[-1] = ('lazy', lambda addr_of, my: A.ADDI(1, 0, addr_of['handler']))
emit(A.CSRRW(0, A.CSR_MTVEC, 1))        # mtvec = &handler

# ---- CSR read/write semantics (no trap) ----
emit(A.ADDI(9, 0, 0x55))
emit(A.CSRRW(10, A.CSR_MSCRATCH, 9))    # mscratch = 0x55; x10 = old (0)
emit(A.CSRRS(11, A.CSR_MSCRATCH, 0))    # x11 = mscratch = 0x55 (pure read)
emit(A.ADDI(12, 0, 0x30))
emit(A.CSRRS(13, A.CSR_MSCRATCH, 12))   # mscratch |= 0x30 -> 0x75; x13 = old (0x55)
emit(A.CSRRC(14, A.CSR_MSCRATCH, 12))   # mscratch &= ~0x30 -> 0x45; x14 = old (0x75)
emit(A.CSRRWI(15, A.CSR_MSCRATCH, 7))   # mscratch = 7; x15 = old (0x45)
emit(A.CSRRS(27, A.CSR_MSCRATCH, 0))    # x27 = final mscratch = 7 -- checked by testbench

# ---- ecall ----
emit(A.ECALL())
emit(A.ADDI(2, 0, 0x111))               # forward-progress marker

# ---- illegal instruction (opcode 0b1111111, not any recognized RV32I opcode) ----
emit(0x0000007F)
emit(A.ADDI(3, 0, 0x222))               # forward-progress marker

# ---- misaligned load ----
emit(A.ADDI(4, 0, 1))                   # address 1 -- misaligned for LW
emit(A.LW(5, 4, 0))
emit(A.ADDI(6, 0, 0x333))               # forward-progress marker

# ---- misaligned store ----
emit(A.ADDI(7, 0, 2))                   # address 2 -- misaligned for SW
emit(A.SW(7, 7, 0))
emit(A.ADDI(8, 0, 0x444))               # forward-progress marker

# ---- UART TX ----
emit(A.LUI_(16, A.UART_BASE >> 12))     # x16 = UART_BASE
emit(A.ADDI(17, 0, 0x41))               # 'A'
emit(A.SW(16, 17, 0))
emit(A.ADDI(18, 0, 0x42))               # 'B'
emit(A.SW(16, 18, 0))
emit(A.LW(26, 16, 0))                   # x26 = readback = last byte written = 'B'

# ---- timer interrupt ----
emit(A.LUI_(20, A.CLINT_BASE >> 12))    # x20 = CLINT_BASE
emit(A.ADDI(21, 0, 0))                  # x21 = 0
emit(A.SW(20, 21, 4))                   # mtimecmp = 0 -- already <= mtime, pending as soon as enabled
emit(A.ADDI(19, 0, 0x80))               # x19 = MTIE bit (bit 7 -- doesn't fit CSRRSI's 5b uimm)
emit(A.CSRRS(0, A.CSR_MIE, 19))         # mie.MTIE = 1
emit(A.CSRRSI(0, A.CSR_MSTATUS, 8))     # mstatus.MIE = 1 -- interrupt becomes visible starting next instruction
emit(A.ADDI(25, 0, 0x555))              # <-- this instruction is preempted, then re-executed cleanly after resume

emit(A.EBREAK())

# ---- handler (placed after main -- only reached via a trap redirect) ----
mark('handler')
emit(A.CSRRS(20, A.CSR_MCAUSE, 0))      # x20 = mcause
emit(A.SRLI(22, 20, 31))                # x22 = interrupt bit
emit_branch(A.BEQ, 22, 0, 'sync_case')  # if not interrupt -> sync_case

# ---- interrupt path: bump x31, defer mtimecmp, mret WITHOUT mepc+=4 ----
emit(A.ADDI(31, 31, 1))                 # x31 = timer-interrupt count
emit(A.ADDI(23, 0, -1))                 # x23 = 0xFFFFFFFF
emit(A.LUI_(24, A.CLINT_BASE >> 12))    # x24 = CLINT_BASE
emit(A.SW(24, 23, 4))                   # mtimecmp = 0xFFFFFFFF -- clear the pending condition
emit_jal(0, 'handler_ret')

# ---- synchronous-exception path: bucket by mcause, then mepc += 4 ----
mark('sync_case')
emit(A.ADDI(21, 0, 11))                 # ECALL_M
emit_branch(A.BNE, 20, 21, 'not_ecall')
emit(A.ADDI(28, 28, 1))
emit_jal(0, 'sync_done')
mark('not_ecall')
emit(A.ADDI(21, 0, 2))                  # ILLEGAL_INSTR
emit_branch(A.BNE, 20, 21, 'not_illegal')
emit(A.ADDI(29, 29, 1))
emit_jal(0, 'sync_done')
mark('not_illegal')
# anything else reaching here is LOAD_MISALIGN (4) or STORE_MISALIGN (6) --
# both bucket into x30, so no further branch is needed
emit(A.ADDI(30, 30, 1))
mark('sync_done')
emit(A.CSRRS(24, A.CSR_MEPC, 0))        # x24 = mepc
emit(A.ADDI(24, 24, 4))                 # skip the deliberately-faulting instruction
emit(A.CSRRW(0, A.CSR_MEPC, 24))        # mepc += 4

mark('handler_ret')
emit(A.MRET())

# ---- two-pass address resolution (identical pattern to program.py) ----
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

with open('riscvtest_pipe_csr.hex', 'w') as f:
    for w in words:
        f.write(f'{w & 0xFFFFFFFF:08x}\n')
print(f'{len(words)} instructions, {len(words)*4} bytes')
print('labels:', {k: hex(v) for k, v in addr_of.items()})
