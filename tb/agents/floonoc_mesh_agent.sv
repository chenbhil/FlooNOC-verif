// -----------------------------------------------------------------------------
// Active agent for the mesh's per-router Eject ports: ONE sequencer + driver
// PER ROUTER (sqr_<r> / drv_<r>), and a single monitor, which already loops
// over every router.
//
// One driver per router is what makes simultaneous injection possible: a
// single driver blocks on each flit's handshake, so the whole mesh could only
// ever inject one flit at a time. Driver r learns its router index from
// config_db ("router_idx") and owns only valid_in[r], data_in[r],
// ready_out[r]. Knobs aimed at "the driver" use the glob env.agent.drv_*.
// -----------------------------------------------------------------------------
typedef uvm_sequencer #(floonoc_mesh_flit_item) floonoc_mesh_sequencer;

class floonoc_mesh_agent extends uvm_agent;

  `uvm_component_utils(floonoc_mesh_agent)

  floonoc_mesh_sequencer sqr [NumRouters];
  floonoc_mesh_driver    drv [NumRouters];
  floonoc_mesh_monitor   mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    for (int unsigned r = 0; r < NumRouters; r++) begin
      uvm_config_db#(int unsigned)::set(this, $sformatf("drv_%0d", r), "router_idx", r);
      sqr[r] = floonoc_mesh_sequencer::type_id::create($sformatf("sqr_%0d", r), this);
      drv[r] = floonoc_mesh_driver::type_id::create($sformatf("drv_%0d", r), this);
    end
    mon = floonoc_mesh_monitor::type_id::create("mon", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    for (int unsigned r = 0; r < NumRouters; r++) begin
      drv[r].seq_item_port.connect(sqr[r].seq_item_export);
    end
  endfunction

endclass : floonoc_mesh_agent
