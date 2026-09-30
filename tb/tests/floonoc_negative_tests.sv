// -----------------------------------------------------------------------------
// Negative self-tests: each injects one controlled fault into the checking
// path (never into the DUT or upstream RTL) and MUST end in *** TEST FAILED ***
// with a specific diagnostic. They prove the scoreboard and watchdogs are not
// vacuous. Executed by `make run-negative`, which inverts the pass criteria.
// See docs/verification_plan.md rows N1-N4.
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


// N4: drive one flit with its destination x/y SWAPPED on the wire, while the
// driver's sent_ap still publishes the true intent -> the scoreboard (keyed
// on driver intent, not on the wire decode) must see the flit at the wrong
// output. Flit #0 is directed row 0, Eject->(2,1)=East; swapped it becomes
// (1,2)=North, still legal from Eject, so the DUT delivers it rather than
// stalling. If the scoreboard were fed from mon.in_ap instead, the wrong
// header would decode into a matching wrong expectation and this would PASS.
class floonoc_neg_encode_test extends floonoc_smoke_test;

  `uvm_component_utils(floonoc_neg_encode_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(int)::set(this, "env.agent.drv", "corrupt_encode_idx", 0);
    // The true expectation can never drain; keep the budget short.
    drain_cycle_budget = 300;
  endfunction

endclass : floonoc_neg_encode_test
