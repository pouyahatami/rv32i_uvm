// =============================================================================
// verif/uvm/mem_backdoor_if.sv
//
// Backdoor load/read access to imem.sv's instruction array, for the UVM
// driver to inject a randomized instruction stream without needing a
// bootloader or a real fetch-time load path. Connected to imem.sv's
// internal `RAM` signal via a `bind` statement (see mem_backdoor_bind.sv)
// -- NOT by adding a port to imem.sv itself. imem.sv is synthesizable RTL
// and stays completely untouched by this verification environment; this
// is the standard SystemVerilog pattern for backdoor memory access, using
// a `ref` port so reads/writes go straight to the caller's array with no
// copy, bound into the target module at elaboration time only for
// simulation builds that include the bind file.
// =============================================================================

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
