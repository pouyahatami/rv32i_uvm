// =============================================================================
// verif/uvm/imem_backdoor_bind.sv
//
// Attaches imem_backdoor_if to every imem instance without modifying the
// synthesizable module. `bind` gives the verification-only interface full
// hierarchical visibility of imem's internal array and size parameter. This
// file appears only in simulation file lists, never in a synthesis one.
// =============================================================================

bind imem imem_backdoor_if #(.IMEM_WORDS(MemWords))
    imem_backdoor(.imem(RAM));
