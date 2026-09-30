// -----------------------------------------------------------------------------
// Passive hotspot observer around one target router T. Created by the env
// ONLY when a test sets config_db "hotspot_target", so the smoke run's
// components and coverage are unchanged.
//
// T's input from direction `dir` is read through the existing read-only
// floonoc_mesh_link_if: it is neighbor n = neighbor_idx(T, dir)'s output
// toward opposite_dir(dir), i.e. lif.valid[n][opp] IS dut_valid_in[T][dir]
// and lif.ready[n][opp] IS dut_ready_in[T][dir] (floonoc_mesh_dut wiring).
// No vendor-internal net is referenced.
//
// Measures (none of this is pass/fail — the spec promises no fairness):
//  - contention coverage: each of T's inputs stalled (valid && !ready); all
//    live inputs stalled in the same cycle; number of T's inputs presenting a
//    flit FOR T when T's Eject handshakes. That last one is input-PORT
//    pressure; the arbiter's FIFO-head requests are vendor-internal and are
//    deliberately not read.
//  - per-router Eject-input backpressure: stalled cycles (valid && !ready,
//    from the vif) and backpressured handshakes (from the monitor's in_ap,
//    which had no subscriber before).
//  - arbitration after release: the source order at T's Eject, per-source
//    deliveries per window of S consecutive T-ejections, and the largest
//    number of other-source flits that left T while a given source had a
//    flit inside T (entered T over a link, not yet ejected).
//
// Coverage bins are over T's four N/E/S/W input directions — fixed by the
// 5-port router, not by the mesh size. Verilator 5.052 rejects covergroup
// constructor arguments in bin ranges ("Non-constant expression in array
// bins range"), so bins cannot be sized to T's live-neighbor count; a T with
// fewer than four neighbors (only on a 2x2 mesh, or a boundary T) leaves the
// bins of its missing directions structurally unreachable, like the
// x_src_dst diagonal. The "all live inputs stalled" cover is a single bit and
// IS derived from has_neighbor().
// -----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_mesh_hs_in)

class floonoc_mesh_hotspot_monitor extends uvm_component;

  `uvm_component_utils(floonoc_mesh_hotspot_monitor)

  virtual floonoc_mesh_if      vif;
  virtual floonoc_mesh_link_if lif;
  floonoc_mesh_ready_ctrl      ready_ctrl;

  uvm_analysis_imp_mesh_hs_in #(floonoc_mesh_flit_item, floonoc_mesh_hotspot_monitor) in_imp;

  int unsigned target;
  int unsigned n_live;                 // T's inputs that have a neighbor
  bit          live [4];

  // Counters
  int unsigned stall_cycles    [4];    // per T input direction
  int unsigned all_stall_cycles;
  int unsigned in_stall_cycles [NumRouters];  // per router Eject input
  int unsigned in_bp_handshakes[NumRouters];
  int unsigned t_ejects;

  // Arbitration state
  bit          released;
  int unsigned order[$];               // src router per T-ejection, after release
  int unsigned in_t    [NumRouters];   // flits of each source inside T
  int unsigned wait_now[NumRouters];   // other-source ejections while waiting
  int unsigned wait_max[NumRouters];

  covergroup cg_stall with function sample(int unsigned dir);
    option.per_instance = 1;
    cp_dir : coverpoint dir { bins d[] = {[0:3]}; }
  endgroup

  covergroup cg_all_stalled with function sample(bit all);
    option.per_instance = 1;
    cp_all : coverpoint all { bins all_live_stalled = {1}; }
  endgroup

  covergroup cg_requesting with function sample(int unsigned n);
    option.per_instance = 1;
    cp_n : coverpoint n { bins n[] = {[1:4]}; }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    in_imp         = new("in_imp", this);
    cg_stall       = new();
    cg_all_stalled = new();
    cg_requesting  = new();
  endfunction

  virtual function void build_phase(uvm_phase phase);
    int t;
    super.build_phase(phase);
    if (!uvm_config_db#(int)::get(this, "", "hotspot_target", t))
      `uvm_fatal("HSMON", "hotspot_target not found in config_db")
    if (t < 0 || t >= int'(NumRouters))
      `uvm_fatal("HSMON", $sformatf("hotspot_target %0d outside a %0d-router mesh", t, NumRouters))
    target = unsigned'(t);
    if (!uvm_config_db#(virtual floonoc_mesh_if)::get(this, "", "vif", vif))
      `uvm_fatal("HSMON", "vif not found in config_db")
    if (!uvm_config_db#(virtual floonoc_mesh_link_if)::get(this, "", "link_vif", lif))
      `uvm_fatal("HSMON", "link_vif not found in config_db")
    if (!uvm_config_db#(floonoc_mesh_ready_ctrl)::get(this, "", "ready_ctrl", ready_ctrl))
      `uvm_fatal("HSMON", "ready_ctrl not found in config_db")
    n_live = 0;
    for (int unsigned d = 0; d < 4; d++) begin
      live[d] = has_neighbor(target, floo_pkg::route_direction_e'(d));
      if (live[d]) n_live++;
    end
  endfunction

  virtual function void write_mesh_hs_in(floonoc_mesh_flit_item t);
    if (t.backpressured && t.src_router < NumRouters) in_bp_handshakes[t.src_router]++;
  endfunction

  virtual task run_phase(uvm_phase phase);
    int unsigned n, n_stalled, n_req, src;
    logic [1:0] opp;   // N/E/S/W index into the link arrays
    flit_t f;
    bit was_held = 1'b0;
    wait (vif.rst_n === 1'b1);
    forever begin
      @(posedge vif.clk);
      if (ready_ctrl.hold[target]) was_held = 1'b1;
      else if (was_held)           released = 1'b1;

      for (int unsigned r = 0; r < NumRouters; r++) begin
        if (vif.valid_in[r] === 1'b1 && vif.ready_in[r] !== 1'b1) in_stall_cycles[r]++;
      end

      n_stalled = 0;
      n_req     = 0;
      for (int unsigned d = 0; d < 4; d++) begin
        if (!live[d]) continue;
        n   = neighbor_idx(target, floo_pkg::route_direction_e'(d));
        opp = 2'(opposite_dir(floo_pkg::route_direction_e'(d)));
        if (lif.valid[n][opp] !== 1'b1) continue;
        f = lif.data[n][opp];
        if (router_idx(32'(f.hdr.dst_id.x), 32'(f.hdr.dst_id.y)) == target) n_req++;
        if (lif.ready[n][opp] !== 1'b1) begin
          n_stalled++;
          stall_cycles[d]++;
          cg_stall.sample(d);
        end else begin
          // a flit entered T over this link
          src = router_idx(32'(f.hdr.src_id.x), 32'(f.hdr.src_id.y));
          if (src < NumRouters) in_t[src]++;
        end
      end
      if (n_live > 0 && n_stalled == n_live) begin
        all_stall_cycles++;
        cg_all_stalled.sample(1'b1);
      end

      if (vif.valid_out[target] === 1'b1 && vif.ready_out[target] === 1'b1) begin
        f   = vif.data_out[target];
        src = router_idx(32'(f.hdr.src_id.x), 32'(f.hdr.src_id.y));
        t_ejects++;
        if (n_req > 0) cg_requesting.sample(n_req);
        if (src < NumRouters) begin
          if (in_t[src] > 0) in_t[src]--;
          for (int unsigned s = 0; s < NumRouters; s++) begin
            if (s == src || in_t[s] == 0) continue;
            wait_now[s]++;
            if (wait_now[s] > wait_max[s]) wait_max[s] = wait_now[s];
          end
          wait_now[src] = 0;
          if (released) order.push_back(src);
        end
      end
    end
  endtask

  virtual function void report_phase(uvm_phase phase);
    string line;
    int unsigned srcs[$];
    int unsigned cnt[int unsigned];
    super.report_phase(phase);
    `uvm_info("HSMON", $sformatf(
      "T=R%0d(%0d,%0d): %0d live inputs; stalled cycles N=%0d E=%0d S=%0d W=%0d; all-live-stalled cycles=%0d; T ejections=%0d",
      target, router_x(target), router_y(target), n_live,
      stall_cycles[0], stall_cycles[1], stall_cycles[2], stall_cycles[3],
      all_stall_cycles, t_ejects), UVM_LOW)
    `uvm_info("HSMON", $sformatf("contention coverage: per-input stall %0.1f%%, all-stalled %0.1f%%, requesting-at-eject %0.1f%%",
              cg_stall.get_inst_coverage(), cg_all_stalled.get_inst_coverage(),
              cg_requesting.get_inst_coverage()), UVM_LOW)
    line = "";
    for (int unsigned r = 0; r < NumRouters; r++) begin
      if (in_stall_cycles[r] != 0 || in_bp_handshakes[r] != 0)
        line = {line, $sformatf(" R%0d:%0dcyc/%0dhs", r, in_stall_cycles[r], in_bp_handshakes[r])};
    end
    `uvm_info("HSMON", {"Eject-input backpressure (stalled cycles / backpressured handshakes):",
                        (line == "") ? string'(" none") : line}, UVM_LOW)

    // Arbitration after release
    foreach (order[i]) begin
      bit seen = 1'b0;
      foreach (srcs[j]) if (srcs[j] == order[i]) seen = 1'b1;
      if (!seen) srcs.push_back(order[i]);
    end
    line = "";
    foreach (order[i]) line = {line, $sformatf(" %0d", order[i])};
    `uvm_info("HSMON", $sformatf("arbitration order at T's Eject after release (%0d flits, src router):%s",
              order.size(), line), UVM_LOW)
    if (srcs.size() > 0) begin
      for (int unsigned w = 0; w * srcs.size() < order.size(); w++) begin
        cnt.delete();
        for (int unsigned i = w * srcs.size(); i < (w + 1) * srcs.size() && i < order.size(); i++)
          cnt[order[i]] = cnt.exists(order[i]) ? cnt[order[i]] + 1 : 1;
        line = "";
        foreach (srcs[j]) line = {line, $sformatf(" R%0d=%0d", srcs[j], cnt.exists(srcs[j]) ? cnt[srcs[j]] : 0)};
        `uvm_info("HSMON", $sformatf("  window %0d (%0d ejections):%s", w, srcs.size(), line), UVM_LOW)
      end
    end
    line = "";
    for (int unsigned r = 0; r < NumRouters; r++)
      if (wait_max[r] > 0) line = {line, $sformatf(" R%0d=%0d", r, wait_max[r])};
    `uvm_info("HSMON", {"max other-source ejections while a source waited inside T:",
                        (line == "") ? string'(" none") : line}, UVM_LOW)
  endfunction

endclass : floonoc_mesh_hotspot_monitor
