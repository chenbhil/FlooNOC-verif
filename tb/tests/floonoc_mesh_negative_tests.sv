// -----------------------------------------------------------------------------
// Mesh negative self-tests: each injects one controlled fault into the
// checking path (never into the DUT or upstream RTL) and MUST end in
// *** TEST FAILED *** with a specific diagnostic. They prove the mesh
// scoreboard and watchdogs are not vacuous. Executed by
// `make run-negative-mesh`, which inverts the pass criteria.
// See docs/verification_plan.md rows NM1-NM4.
//
// Injection indices count ACCEPTED flits (floonoc_mesh_scoreboard::n_accepted).
// RULE: NM1/NM2's indices (3 and 5) must land inside directed phase A (one
// flit per directed link, 2*[(X-1)*Y + X*(Y-1)] of them) at EVERY mesh size,
// so the injection point is topology-derived and seed-independent rather than
// a function of the random draw. Phase A has 8 flits at 2x2 (the smallest 2-D
// mesh), 24 at 3x3, 48 at 4x4 and 80 at 5x5, so 3 and 5 always qualify. (At
// 2x2 the full run is 8 + 4 diagonal + 3 burst + 15 random = 30 flits.)
// -----------------------------------------------------------------------------

// NM1: corrupt one expected payload -> R2 integrity check must fire
class floonoc_mesh_neg_payload_test extends floonoc_mesh_smoke_test;

  `uvm_component_utils(floonoc_mesh_neg_payload_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(int)::set(this, "env.sb", "corrupt_payload_idx", 3);
  endfunction

endclass : floonoc_mesh_neg_payload_test


// NM2: model one flit as ejecting at the wrong router -> R1/R5/R6 checks must
// fire (unexpected flit at the real exit router and/or a stuck expectation).
// The scoreboard's wrong_router() helper guarantees the injected router is
// neither the true destination nor the source, so the injection can never
// degrade into a silent no-op.
class floonoc_mesh_neg_route_test extends floonoc_mesh_smoke_test;

  `uvm_component_utils(floonoc_mesh_neg_route_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(int)::set(this, "env.sb", "corrupt_route_idx", 5);
    // The mis-modeled expectation can never drain; keep the budget short.
    drain_base_cycles    = 300;
    drain_per_hop_cycles = 0;
  endfunction

endclass : floonoc_mesh_neg_route_test


// NM3: hold permanent Eject backpressure on every router -> forward-progress
// watchdogs must fire with a diagnostic dump of every stuck in-flight flit
class floonoc_mesh_neg_stall_test extends floonoc_mesh_smoke_test;

  `uvm_component_utils(floonoc_mesh_neg_stall_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(int)::set(this, "env.agent.drv_*", "ready_pct", 0);
    seq_cycle_budget     = 300;
    drain_base_cycles    = 100;
    drain_per_hop_cycles = 0;
  endfunction

endclass : floonoc_mesh_neg_stall_test


// NM4: perturb the scoreboard's XY-model direction for one OBSERVED link hop
// -> the RM8 per-hop path check must fire. The fault is in the model side of
// the comparison, never the DUT; it stands in for a DUT that sends a flit
// the wrong way. Hop #0 is the first link handshake of the directed phase,
// so the injection point is seed-independent.
class floonoc_mesh_neg_path_test extends floonoc_mesh_smoke_test;

  `uvm_component_utils(floonoc_mesh_neg_path_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(int)::set(this, "env.sb", "corrupt_hop_idx", 0);
  endfunction

endclass : floonoc_mesh_neg_path_test
