// -----------------------------------------------------------------------------
// Negative self-tests: each injects one controlled fault into the checking
// path (never into the DUT or upstream RTL) and MUST end in *** TEST FAILED ***
// with a specific diagnostic. They prove the scoreboard and watchdogs are not
// vacuous. Executed by `make run-negative`, which inverts the pass criteria.
// See docs/verification_plan.md rows N1-N3.
// -----------------------------------------------------------------------------

// N1: corrupt one expected payload -> R2 integrity check must fire
class floonoc_neg_payload_test extends floonoc_smoke_test;

  `uvm_component_utils(floonoc_neg_payload_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(int)::set(this, "env.sb", "corrupt_payload_idx", 3);
  endfunction

endclass : floonoc_neg_payload_test


// N2: model one flit at the wrong output port -> R1/R5 checks must fire
// (unexpected flit at the real output and/or a stuck expectation)
class floonoc_neg_route_test extends floonoc_smoke_test;

  `uvm_component_utils(floonoc_neg_route_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(int)::set(this, "env.sb", "corrupt_route_idx", 5);
    // The mis-modeled expectation can never drain; keep the budget short.
    drain_cycle_budget = 300;
  endfunction

endclass : floonoc_neg_route_test


// N3: hold permanent output backpressure -> forward-progress watchdogs must
// fire with a diagnostic dump of every stuck in-flight flit
class floonoc_neg_stall_test extends floonoc_smoke_test;

  `uvm_component_utils(floonoc_neg_stall_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(int)::set(this, "env.agent.drv", "ready_pct", 0);
    seq_cycle_budget   = 300;
    drain_cycle_budget = 100;
  endfunction

endclass : floonoc_neg_stall_test
