// -----------------------------------------------------------------------------
// Mesh negative self-tests: each injects one controlled fault into the
// checking path (never into the DUT or upstream RTL) and MUST end in
// *** TEST FAILED *** with a specific diagnostic. They prove the mesh
// scoreboard and watchdogs are not vacuous. Executed by
// `make run-negative-mesh`, which inverts the pass criteria.
// See docs/verification_plan.md rows NM1-NM4.
//
// Injection indices count ACCEPTED flits (floonoc_mesh_scoreboard::n_accepted),
// and floonoc_mesh_smoke_seq sends 12 directed + 15 random = 27 of them on a
// 2x2 mesh. Indices 3 and 5 therefore land inside the DIRECTED phase, whose
// (src, dst) pairs are topology-derived and identical on every run — so the
// injection point is deterministic rather than a function of the random seed.
// Keep them below the directed-phase count if the sequence ever changes.
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
    uvm_config_db#(int)::set(this, "env.agent.drv", "ready_pct", 0);
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
