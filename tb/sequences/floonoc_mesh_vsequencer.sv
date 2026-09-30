// -----------------------------------------------------------------------------
// Virtual sequencer: handles to every per-router sequencer, the shared
// Eject-ready control, and the interface (for clock-aligned waits inside
// virtual sequences). Filled in by floonoc_mesh_env::connect_phase.
// -----------------------------------------------------------------------------
class floonoc_mesh_vsequencer extends uvm_sequencer;

  `uvm_component_utils(floonoc_mesh_vsequencer)

  floonoc_mesh_sequencer  sqr [NumRouters];
  floonoc_mesh_ready_ctrl ready_ctrl;
  virtual floonoc_mesh_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

endclass : floonoc_mesh_vsequencer
