// ===========================================================================
// rv32i_retire_txn: one retired instruction, as observed at writeback.
// Emitted exactly once per instruction, gated on retire_if.sv's retire_valid.
//
//   pc           - PC of the retiring instruction
//   instr        - the retiring instruction
//   rd           - destination register, if any
//   wdata        - value written to rd
//   regwrite     - set if this instruction wrote a register
//   store_valid  - set if this instruction was a store
//   store_addr   - the address it wrote
//   store_data   - the full 32-bit register value;
//   store_funct3 - store width: 000 = SB, 001 = SH, 010 = SW
// ===========================================================================
class rv32i_retire_txn extends uvm_object;
  // Four-state on purpose. These fields carry DUT observations, and the DUT
  // interface is 4-state: declaring them `bit` would silently convert an X
  // on the wires to 0 at the assignment, BEFORE the scoreboard's !==
  // comparison could see it -- so an unknown writeback would compare equal
  // to a legitimate zero and pass. `logic` preserves the X so it both fails
  // the comparison and trips the monitor's explicit $isunknown check.
  logic [31:0] pc;
  logic [31:0] instr;
  logic [4:0]  rd;
  logic [31:0] wdata;
  logic        regwrite;
  logic        store_valid;
  logic [31:0] store_addr;
  logic [31:0] store_data;
  logic [2:0]  store_funct3;

  `uvm_object_utils_begin(rv32i_retire_txn)
    `uvm_field_int(pc, UVM_ALL_ON)
    `uvm_field_int(instr, UVM_ALL_ON)
    `uvm_field_int(rd, UVM_ALL_ON)
    `uvm_field_int(wdata, UVM_ALL_ON)
    `uvm_field_int(regwrite, UVM_ALL_ON)
    `uvm_field_int(store_valid, UVM_ALL_ON)
    `uvm_field_int(store_addr, UVM_ALL_ON)
    `uvm_field_int(store_data, UVM_ALL_ON)
    `uvm_field_int(store_funct3, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "rv32i_retire_txn");
    super.new(name);
  endfunction
endclass
