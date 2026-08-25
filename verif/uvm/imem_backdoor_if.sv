// =============================================================================
// verif/uvm/imem_backdoor_if.sv
//
// Verification-only backdoor access to the inferred instruction memory. The
// UVM driver uses this while reset is asserted to load the instruction stream.
// The interface is connected with a `bind` statement, so it adds no port to
// the synthesizable memory (see imem_backdoor_bind.sv).
// =============================================================================

// `ref` aliases the caller's actual unpacked array in place, rather than
// copying it in/out like input/output would -- so imem here IS imem.sv's
// RAM (see imem_backdoor_bind.sv), and load_word/read_word interface with it
// directly.
interface imem_backdoor_if #(parameter IMEM_WORDS = 4096)
                             (ref logic [31:0] imem [IMEM_WORDS-1:0]);

  function automatic int word_count();
    return IMEM_WORDS;
  endfunction

  task automatic load_word(input int idx, input logic [31:0] val);
    imem[idx] = val;
  endtask

  function automatic logic [31:0] read_word(input int idx);
    return imem[idx];
  endfunction
endinterface
