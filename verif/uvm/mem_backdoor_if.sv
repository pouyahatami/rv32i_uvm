// =============================================================================
// verif/uvm/mem_backdoor_if.sv
//
// Backdoor load/read access to imem.sv, for the UVM driver to inject
// a randomized instruction stream without needing a
// bootloader or a real fetch-time load path. Connected to imem.sv's
// internal `RAM` signal via a `bind` statement (see mem_backdoor_bind.sv)
// =============================================================================

// `ref` aliases the caller's actual unpacked array in place, rather than
// copying it in/out like input/output would -- so mem here IS imem.sv's
// RAM (see mem_backdoor_bind.sv), and load_word/read_word interface with it
// directly.
interface mem_backdoor_if #(parameter MEM_WORDS = 4096)
                            (ref logic [31:0] mem [MEM_WORDS-1:0]);

  function automatic int word_count();
    return MEM_WORDS;
  endfunction

  task automatic load_word(input int idx, input logic [31:0] val);
    mem[idx] = val;
  endtask

  function automatic logic [31:0] read_word(input int idx);
    return mem[idx];
  endfunction
endinterface
