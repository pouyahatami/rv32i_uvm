// =============================================================================
// verif/uvm/dmem_backdoor_bind.sv
//
// Attaches dmem_backdoor_if to every dmem instance without modifying the
// synthesizable module. `bind` gives the verification-only interface full
// hierarchical visibility of dmem's internal array and size parameter. This
// file appears only in simulation file lists, never in a synthesis one.
// =============================================================================

bind dmem dmem_backdoor_if #(.DMEM_BYTES(MemBytes))
    dmem_backdoor(.dmem(mem));
