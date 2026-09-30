// -----------------------------------------------------------------------------
// Mesh smoke test: run the smoke sequence, drain the scoreboard, end via
// objections, report explicit PASS/FAIL. A drain watchdog dumps all stuck
// in-flight flits before failing if forward progress stops.
//
// The drain budget is derived from the mesh diameter rather than being a flat
// literal, so it cannot silently under-budget if dut_config_mesh.svh grows.
// -----------------------------------------------------------------------------
class floonoc_mesh_smoke_test extends uvm_test;

  `uvm_component_utils(floonoc_mesh_smoke_test)

  floonoc_mesh_env env;

  // Budgets in cycles of the 10ns clock. The sequence budget catches stalled
  // stimulus (e.g. permanent backpressure); the drain budget catches accepted
  // flits that never reach an output.
  int unsigned seq_cycle_budget    = 5000;

  // Per-hop allowance: a flit crosses at most MeshDiameter routers, each
  // costing an input FIFO, an arbitration round and an output FIFO, and the
  // driver stalls ~20% of Eject-out cycles. 500 cycles per hop is roughly
  // 100x that worst case — deliberately loose, because this budget only has
  // to distinguish "draining" from "wedged".
  int unsigned drain_base_cycles   = 1000;
  int unsigned drain_per_hop_cycles = 500;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function int unsigned drain_cycle_budget();
    return drain_base_cycles + MeshDiameter * drain_per_hop_cycles;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = floonoc_mesh_env::type_id::create("env", this);
  endfunction

  virtual task run_phase(uvm_phase phase);
    floonoc_mesh_smoke_seq seq;
    bit seq_done = 1'b0;
    int unsigned waited = 0;
    int unsigned drain_budget = drain_cycle_budget();

    phase.raise_objection(this, "mesh smoke sequence running");

    seq = floonoc_mesh_smoke_seq::type_id::create("seq");
    // +mesh_num_random=N resizes the random phase (default 15): 15 draws
    // cover little of a large mesh's src x dst cross.
    void'($value$plusargs("mesh_num_random=%d", seq.num_random));

    // Run the sequence under a forward-progress watchdog: if stimulus can
    // no longer be accepted (e.g. permanent backpressure), fail with a
    // diagnostic dump instead of hanging until the global watchdog.
    fork
      begin
        seq.start(env.agent.sqr);
        seq_done = 1'b1;
      end
    join_none
    while (!seq_done && waited < seq_cycle_budget) begin
      #10ns;
      waited++;
    end
    if (!seq_done) begin
      env.sb.dump_pending();
      `uvm_error("TEST", $sformatf(
        "forward progress stopped: sequence still stalled after %0d cycles (%0d flit(s) in flight)",
        seq_cycle_budget, env.sb.pending_count()))
    end

    // Drain: all accepted flits must eventually be delivered
    waited = 0;
    while (env.sb.pending_count() > 0 && waited < drain_budget) begin
      #10ns;
      waited++;
    end
    if (env.sb.pending_count() > 0) begin
      env.sb.dump_pending();
      `uvm_error("TEST", $sformatf(
        "forward progress stopped: %0d flit(s) still in flight after %0d cycles",
        env.sb.pending_count(), drain_budget))
    end

    // A few idle cycles so any spurious late output would be caught
    #200ns;

    phase.drop_objection(this, "mesh smoke sequence drained");
  endtask

  virtual function void report_phase(uvm_phase phase);
    uvm_report_server svr = uvm_report_server::get_server();
    bit fail = (svr.get_severity_count(UVM_ERROR) > 0) ||
               (svr.get_severity_count(UVM_FATAL) > 0) ||
               (env.sb.n_matched == 0) || (env.sb.n_mismatched > 0);
    super.report_phase(phase);
    if (fail) begin
      `uvm_info("RESULT", "*** TEST FAILED ***", UVM_NONE)
    end else begin
      `uvm_info("RESULT", $sformatf(
        "*** TEST PASSED *** (%0d flits accepted, %0d delivered, %0d matched, 0 mismatches)",
        env.sb.n_accepted, env.sb.n_delivered, env.sb.n_matched), UVM_NONE)
    end
  endfunction

endclass : floonoc_mesh_smoke_test
