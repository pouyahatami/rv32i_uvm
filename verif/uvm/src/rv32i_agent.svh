// ===========================================================================
// Agent, env, test -- standard UVM wiring, nothing project-specific here.
// ===========================================================================
class rv32i_agent extends uvm_agent;
  `uvm_component_utils(rv32i_agent)

  rv32i_sequencer sqr;
  rv32i_driver    drv;
  rv32i_monitor   mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = rv32i_sequencer::type_id::create("sqr", this);
    drv = rv32i_driver::type_id::create("drv", this);
    mon = rv32i_monitor::type_id::create("mon", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
