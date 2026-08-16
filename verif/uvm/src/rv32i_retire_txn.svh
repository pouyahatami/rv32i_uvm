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
  bit [31:0] pc;
  bit [31:0] instr;
  bit [4:0]  rd;
  bit [31:0] wdata;
  bit        regwrite;
  bit        store_valid;
  bit [31:0] store_addr;
  bit [31:0] store_data;
  bit [2:0]  store_funct3;

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
