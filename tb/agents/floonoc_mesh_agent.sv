// -----------------------------------------------------------------------------
// Active agent bundling sequencer, driver and monitor for the mesh's
// per-router Eject ports.
// -----------------------------------------------------------------------------
typedef uvm_sequencer #(floonoc_mesh_flit_item) floonoc_mesh_sequencer;

class floonoc_mesh_agent extends uvm_agent;

  `uvm_component_utils(floonoc_mesh_agent)

  floonoc_mesh_sequencer sqr;
  floonoc_mesh_driver    drv;
  floonoc_mesh_monitor   mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = floonoc_mesh_sequencer::type_id::create("sqr", this);
    drv = floonoc_mesh_driver::type_id::create("drv", this);
    mon = floonoc_mesh_monitor::type_id::create("mon", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction

endclass : floonoc_mesh_agent
