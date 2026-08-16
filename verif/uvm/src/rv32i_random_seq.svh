// ===========================================================================
// Sequence: replays the instruction stream from stream.hex, which
// verif/spike/gen_stream.py generates together with its reference trace.
//
//
// The generation policy lives in gen_stream.py. Summarised, because it is
// what makes the stream legal without post-hoc constraints:
//  - ~40% of instructions take rs1 from the previous instruction's rd, so
//    RAW hazards appear far more often than uniform-random choice gives.
//  - x1 is reserved as a safe base pointer for every load and store, and is
//    never another instruction's destination, so every offset is known at
//    generation time to be small, aligned, and clear of the MMIO window at
//    0x00020000. This is the same "reserve a pointer register" technique
//    riscv-dv uses. x1 points PAST the end of the program image, never at 0:
//    the DUT is Harvard and Spike is von Neumann, so stores into low memory
//    would corrupt Spike's copy of the program and not the DUT's. See
//    data_base_for() in gen_stream.py, which exists for that reason.
//  - branches only ever jump forward by a small bounded amount, and padding
//    NOPs before the sentinel keep every branch target inside the program.
//  - the last instruction is a fixed sentinel (rd=x31, a recognisable
//    immediate) that the scoreboard watches for as the "program fully
//    retired" signal, rather than inferring completion from pipeline timing.
//
// Stimulus is therefore fixed per seed rather than per simulation run: new
// stimulus means re-running gen_stream.py with a new --seed. For a
// regression that is arguably an improvement, since a failing seed is
// reproducible by name.
// ===========================================================================
class rv32i_random_seq extends uvm_sequence #(rv32i_instr_txn);
  `uvm_object_utils(rv32i_random_seq)

  // Program length is a gen_stream.py argument (--num-instr) rather than a
  // runtime plusarg, because the reference trace is computed from the same
  // program and the two have to agree. +STREAM/+TRACE select which
  // generated pair to run.

  function new(string name = "rv32i_random_seq");
    super.new(name);
  endfunction

  task send_instruction(bit [31:0] instruction, bit last_word = 1'b0);
    rv32i_instr_txn req;
    // The item must already exist before calling start_item:
    req = rv32i_instr_txn::type_id::create("req");
    start_item(req);
    // Copy the task arguments into the transaction
    req.instr     = instruction;
    req.last_word = last_word;
    finish_item(req);
  endtask

  task body();
    int        fd, code;
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
      code = $fscanf(fd, "%h\n", word);
      if (code == 1) words.push_back(word);
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
