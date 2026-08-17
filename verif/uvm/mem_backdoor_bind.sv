// =============================================================================
// verif/uvm/mem_backdoor_bind.sv
//
// Attaches mem_backdoor_if to every instance of imem without modifying
// imem.sv. `bind` is the SystemVerilog feature built for exactly this: a
// verification-only instance that is textually invisible to imem.sv but has
// full hierarchical visibility of its internals, here the RAM array and the
// MemWords parameter, because the tool elaborates it as if it were declared
// inside imem.sv. This file appears only in simulation file lists, never in
// a synthesis one, so imem.sv's synthesizable view stays clean.
// =============================================================================

bind imem mem_backdoor_if #(.MEM_WORDS(MemWords)) backdoor(.mem(RAM));
