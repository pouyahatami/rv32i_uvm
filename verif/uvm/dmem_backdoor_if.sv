// =============================================================================
// verif/uvm/dmem_backdoor_if.sv
//
// Verification-only backdoor access to the inferred data memory. The UVM
// driver uses this while reset is asserted to establish a known-zero dmem
// start state. The interface is connected with a `bind` statement, so it adds
// no reset network or port to the synthesizable memory.
// =============================================================================

// dmem.sv is byte-addressable, so its backdoor has the same element width as
// the underlying array. clear() is intentionally a zero-time testbench task:
// modelling this as reset logic in dmem.sv would turn a RAM initialization
// precondition into 16 KB of hardware reset behaviour and can prevent RAM
// inference in synthesis.
interface dmem_backdoor_if #(parameter DMEM_BYTES = 16384)
                             (ref logic [7:0] dmem [DMEM_BYTES-1:0]);

  task automatic clear();
    for (int i = 0; i < DMEM_BYTES; i++) dmem[i] = 8'h00;
  endtask
endinterface
