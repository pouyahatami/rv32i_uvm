// ===========================================================================
// rv32i_instr_txn: one instruction word to be written into imem.
//
//   instr   - the 32-bit instruction word.
//   last_word - set on the final word of a program. Signals the driver to
//               stop pulling items and release reset.
// ===========================================================================
// Deliberately not `rand`. The instruction word is read from stream.hex,
// never randomized here, and a `rand` qualifier on a field nothing
// randomizes is both misleading and a needless dependency on a
// randomization licence feature. See this file's header.
class rv32i_instr_txn extends uvm_sequence_item;
  bit [31:0] instr;
  bit        last_word;

  `uvm_object_utils_begin(rv32i_instr_txn)
    `uvm_field_int(instr, UVM_ALL_ON)
    `uvm_field_int(last_word, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "rv32i_instr_txn");
    super.new(name);
  endfunction
endclass
