// ===========================================================================
// Sequence: replays the instruction stream from stream.hex, which
// verif/spike/gen_stream.py generates together with its reference trace.
//
// The generation policy -- the hazard bias, the reserved x1 data window,
// forward-only control transfers, the padding and the sentinel -- lives in
// gen_stream.py's generate(), and docs/GAPS.md records what it does not do.
//
// Stimulus is fixed per seed rather than per run, so new stimulus means a new
// --seed. A failing seed is then reproducible by name.
// ===========================================================================
class rv32i_random_seq extends uvm_sequence #(rv32i_instr_txn);
  `uvm_object_utils(rv32i_random_seq)

  // Program length is a gen_stream.py argument, not a runtime plusarg: the
  // reference trace is computed from the same program and the two must agree.
  // +STREAM/+TRACE select which generated pair to run.

  function new(string name = "rv32i_random_seq");
    super.new(name);
  endfunction

  task send_instruction(bit [31:0] instruction, bit last_word = 1'b0);
    rv32i_instr_txn req;
    req = rv32i_instr_txn::type_id::create("req");
    start_item(req);
    req.instr     = instruction;
    req.last_word = last_word;
    finish_item(req);
  endtask

  task body();
    int        fd, fields_read;
    int        word;
    // SV queue
    bit [31:0] words[$];
    string     hex_file;

    // Use +STREAM=<file> when provided on the simulator command line;
    // otherwise, read the default stream.hex file.
    if (!$value$plusargs("STREAM=%s", hex_file)) begin
      hex_file = "stream.hex";
    end

    fd = $fopen(hex_file, "r");
    if (fd == 0) begin 
      `uvm_fatal("NOSTREAM",
        $sformatf("cannot open instruction stream '%s' -- generate it with verif/spike/gen_stream.py",
                  hex_file))
    end 

    while (!$feof(fd)) begin
      fields_read = $fscanf(fd, "%h\n", word);
      if (fields_read == 1) words.push_back(word);
    end
    $fclose(fd);

    if (words.size() == 0) begin 
      `uvm_fatal("NOSTREAM", $sformatf("instruction stream '%s' was empty", hex_file))
    end 

    `uvm_info("SEQ", $sformatf("loaded %0d instruction words from %s",
                               words.size(), hex_file), UVM_LOW)

    foreach (words[i]) begin 
      send_instruction(words[i], (i == words.size() - 1));
    end 
  endtask
endclass
