// ===========================================================================
// Sequence: replays the instruction stream from stream.hex, which
// verif/spike/gen_stream.py generates together with its reference trace.
//
// The program is generated in Python rather than here because the reference
// model is. A precomputed Spike trace only means something if the program it
// was computed from is the program the DUT runs, so both come out of one
// generator and one seed. Two generators, seeded independently, would be a
// scoreboard that checks nothing.
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

  task send(bit [31:0] w, bit last = 1'b0);
    rv32i_instr_txn req;
    req = rv32i_instr_txn::type_id::create("req");
    start_item(req);
    req.instr   = w;
    req.last_word = last;
    finish_item(req);
  endtask

  task body();
    int        fd, code;
    int        word;
    bit [31:0] words[$];
    string     hex_file;

    if (!$value$plusargs("STREAM=%s", hex_file))
      hex_file = "stream.hex";

    fd = $fopen(hex_file, "r");
    if (fd == 0)
      `uvm_fatal("NOSTREAM",
        $sformatf("cannot open instruction stream '%s' -- generate it with verif/spike/gen_stream.py",
                  hex_file))

    while (!$feof(fd)) begin
      code = $fscanf(fd, "%h\n", word);
      if (code == 1) words.push_back(word);
    end
    $fclose(fd);

    if (words.size() == 0)
      `uvm_fatal("NOSTREAM", $sformatf("instruction stream '%s' was empty", hex_file))

    `uvm_info("SEQ", $sformatf("loaded %0d instruction words from %s",
                               words.size(), hex_file), UVM_LOW)

    foreach (words[i])
      send(words[i], (i == words.size() - 1));
  endtask
endclass
