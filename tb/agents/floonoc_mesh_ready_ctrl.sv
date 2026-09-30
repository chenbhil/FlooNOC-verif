// -----------------------------------------------------------------------------
// Shared, deterministic control of each router's Eject-output ready line.
//
// One instance is created by the env and published through config_db
// ("ready_ctrl"); every per-router driver reads its own entry every cycle and
// the virtual sequencer hands the same object to sequences. Precedence per
// router r, re-evaluated at every posedge:
//   hold[r]            -> ready_out[r] = 0
//   pct_override[r]>=0 -> ready_out[r] random at that percentage (100 = always)
//   otherwise          -> ready_out[r] random at the driver's ready_pct
//
// This is how a sequence stalls one router's Eject output for a window and
// then releases it (the hotspot test) without guessing at timing.
// -----------------------------------------------------------------------------
class floonoc_mesh_ready_ctrl extends uvm_object;

  `uvm_object_utils(floonoc_mesh_ready_ctrl)

  bit hold         [NumRouters];
  int pct_override [NumRouters];

  function new(string name = "floonoc_mesh_ready_ctrl");
    super.new(name);
    foreach (pct_override[r]) pct_override[r] = -1;
  endfunction

endclass : floonoc_mesh_ready_ctrl
