// ===========================================================================
// Driver: holds reset, establishes a known-zero dmem state, backdoor-loads the
// sequence's instruction stream, then releases reset and lets the DUT run.
// Both memory operations use verification-only interfaces attached by bind;
// the synthesizable memories remain unchanged.
// ===========================================================================
class rv32i_driver extends uvm_driver #(rv32i_instr_txn);
  `uvm_component_utils(rv32i_driver)

  // Handles pointing to interface instances in the top level module 
  virtual rv32i_if         clk_rst_vif;
  virtual imem_backdoor_if imem_bd_vif;
  virtual dmem_backdoor_if dmem_bd_vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual rv32i_if)::get(this, "", "clk_rst_vif", clk_rst_vif))
      `uvm_fatal("NOVIF", "Could not get handle to virtual interface clk_rst_vif")
    if (!uvm_config_db#(virtual imem_backdoor_if)::get(
            this, "", "imem_bd_vif", imem_bd_vif))
      `uvm_fatal("NOVIF",
                 "Could not get handle to virtual interface imem_bd_vif")
    if (!uvm_config_db#(virtual dmem_backdoor_if)::get(this, "", "dmem_bd_vif", dmem_bd_vif))
      `uvm_fatal("NOVIF", "Could not get handle to virtual interface dmem_bd_vif")
  endfunction

  virtual task run_phase(uvm_phase phase);
    rv32i_instr_txn req;
    int             idx;
    bit             done;

    // hold the DUT in reset while the program is being loaded into imem
    clk_rst_vif.reset = 1'b1;
    repeat (2) @(posedge clk_rst_vif.clk);

    // Zero data memory before running the program (Spike expects this)
    dmem_bd_vif.clear();
    `uvm_info("DRIVER", "zeroed data memory while reset was asserted", UVM_LOW)

    idx  = 0;
    done = 1'b0;
    // Loop until every word is loaded into imem
    while (!done) begin
      seq_item_port.get_next_item(req);
      imem_bd_vif.load_word(idx, req.instr);
      idx++;
      done = req.last_word;
      seq_item_port.item_done();
    end
    `uvm_info("DRIVER", $sformatf("backdoor-loaded %0d instruction words", idx), UVM_LOW)

    // release reset
    repeat (2) @(posedge clk_rst_vif.clk);
    clk_rst_vif.reset = 1'b0;
  endtask
endclass
