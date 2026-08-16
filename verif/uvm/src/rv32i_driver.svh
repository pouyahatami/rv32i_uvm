// ===========================================================================
// Driver: holds reset, backdoor-loads the sequence's instruction stream
// into imem's RAM via mem_backdoor_if (see mem_backdoor_if.sv/
// mem_backdoor_bind.sv), then releases reset and lets the DUT run.
// ===========================================================================
class rv32i_driver extends uvm_driver #(rv32i_instr_txn);
  `uvm_component_utils(rv32i_driver)

  virtual rv32i_if        vif;
  virtual mem_backdoor_if bd_vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual rv32i_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "rv32i_driver: no rv32i_if found in config_db")
    if (!uvm_config_db#(virtual mem_backdoor_if)::get(this, "", "bd_vif", bd_vif))
      `uvm_fatal("NOVIF", "rv32i_driver: no mem_backdoor_if found in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    rv32i_instr_txn req;
    int             idx;
    bit             done;

    // hold the DUT in reset while the program is backdoor-loaded
    vif.reset = 1'b1;
    repeat (2) @(posedge vif.clk);

    idx  = 0;
    done = 1'b0;
    while (!done) begin
      seq_item_port.get_next_item(req);
      bd_vif.load_word(idx, req.instr);
      idx++;
      done = req.last_word;
      seq_item_port.item_done();
    end
    `uvm_info("DRIVER", $sformatf("backdoor-loaded %0d instruction words", idx), UVM_LOW)

    // release reset -- the loaded program starts fetching from word 0
    repeat (2) @(posedge vif.clk);
    vif.reset = 1'b0;
  endtask
endclass
