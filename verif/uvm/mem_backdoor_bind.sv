// =============================================================================
// verif/uvm/mem_backdoor_bind.sv
//
// Attaches mem_backdoor_if to every instance of imem, WITHOUT modifying
// imem.sv. `bind` is exactly the SystemVerilog feature built for this: a
// verification-only instance that's textually invisible to imem.sv but
// has full hierarchical visibility of its internals (here, the `RAM`
// array and `MEM_WORDS` parameter), because the tool elaborates it as if
// it were declared inside imem.sv itself. This file is only ever included
// in a simulation build -- never in a synthesis file list, so imem.sv's
// synthesizable view is exactly as clean as it was before this milestone.
//
// imem.sv's own size parameter is MemWords (renamed from MEM_WORDS by the
// lowRISC style-guide retrofit -- UpperCamelCase for tunable parameters);
// mem_backdoor_if's own formal parameter, declared in mem_backdoor_if.sv,
// is left as MEM_WORDS for now since verif/uvm/ as a whole hasn't been
// through that pass yet (it has never been elaborated or run -- see
// docs/DESIGN_GUIDE.md Section 11.5/11.6). Only the VALUE passed here had
// to change, to track imem.sv's actual parameter name.
// =============================================================================

bind imem mem_backdoor_if #(.MEM_WORDS(MemWords)) backdoor(.mem(RAM));
