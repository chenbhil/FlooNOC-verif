// -----------------------------------------------------------------------------
// Active agent bundling sequencer, driver and monitor for the router's
// flit ports.
// -----------------------------------------------------------------------------
typedef uvm_sequencer #(floonoc_flit_item) floonoc_sequencer;

class floonoc_agent extends uvm_agent;

  `uvm_component_utils(floonoc_agent)

  floonoc_sequencer sqr;
  floonoc_driver    drv;
  floonoc_monitor   mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = floonoc_sequencer::type_id::create("sqr", this);
    drv = floonoc_driver::type_id::create("drv", this);
    mon = floonoc_monitor::type_id::create("mon", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction

endclass : floonoc_agent
