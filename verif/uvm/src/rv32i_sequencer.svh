// =============================================================================
// rv32i_sequencer: typed sequencer for instruction-load transactions.
//
// The type parameter restricts
// this sequencer's request/response item type to rv32i_instr_txn.
// =============================================================================
typedef uvm_sequencer #(rv32i_instr_txn) rv32i_sequencer;
