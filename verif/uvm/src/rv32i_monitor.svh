// ===========================================================================
// Monitor: samples retire_if.sv's MON modport every cycle, publishes one
// rv32i_retire_txn per cycle where retire_valid is set
// ===========================================================================
class rv32i_monitor extends uvm_monitor;
  `uvm_component_utils(rv32i_monitor)

  virtual retire_if.MON            vif;
  uvm_analysis_port #(rv32i_retire_txn) analysis_port;

  // Set at the sentinel. Past it the core executes unwritten memory and X
  // instructions "retire" every cycle, so RETIRE_X would fire on every clean
  // run. Publishing continues so the downstream guards stay exercised.
  bit finished;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    analysis_port = new("analysis_port", this); // parented to the monitor, so it joins the UVM hierarchy
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual retire_if.MON)::get(this, "", "retire_vif", vif))
      `uvm_fatal("NOVIF", "rv32i_monitor: no retire_if.MON found in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    rv32i_retire_txn txn;
    bit x_always;    // fields meaningful on every retirement
    bit x_regwrite;  // fields qualified by regwrite
    bit x_store;     // fields qualified by store_valid
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.retire_valid) begin
        txn = rv32i_retire_txn::type_id::create("txn");
        txn.pc           = vif.mon_cb.pc;
        txn.instr        = vif.mon_cb.instr;
        txn.rd           = vif.mon_cb.rd;
        txn.wdata        = vif.mon_cb.wdata;
        txn.regwrite     = vif.mon_cb.regwrite_valid;
        txn.store_valid  = vif.mon_cb.store_valid;
        txn.store_addr   = vif.mon_cb.store_addr;
        txn.store_data   = vif.mon_cb.store_data;
        txn.store_funct3 = vif.mon_cb.store_funct3;

        x_always   = $isunknown({txn.pc, txn.instr, txn.regwrite, txn.store_valid});
        x_regwrite = (txn.regwrite    === 1'b1) &&
                     $isunknown({txn.rd, txn.wdata});
        x_store    = (txn.store_valid === 1'b1) &&
                     $isunknown({txn.store_addr, txn.store_data, txn.store_funct3});

        if (!finished && (x_always || x_regwrite || x_store))
          `uvm_error("RETIRE_X", $sformatf(
              "unknown value on retirement interface: pc=%h instr=%h rd=%0d wdata=%h regwrite=%b store_valid=%b",
              txn.pc, txn.instr, txn.rd, txn.wdata, txn.regwrite, txn.store_valid))

        if (txn.regwrite === 1'b1 && txn.rd === COMPLETION_GPR &&
            txn.wdata === COMPLETION_VALUE)
          finished = 1'b1;

        analysis_port.write(txn); // coverage collector and scoreboard get a copy of the retire_txn
      end
    end
  endtask
endclass
