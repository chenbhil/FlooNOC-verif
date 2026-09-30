// -----------------------------------------------------------------------------
// Hotspot virtual sequence: S source routers at the same Manhattan distance d
// from a target router T each send K flits to T, all starting in the SAME
// clock cycle, while T's Eject output is held stalled for `hold_cycles` and
// then released to 100% ready.
//
// Modes:
//  axis — the (up to) four routers T±d along x and y. Under XY routing each
//         arrives on a DIFFERENT input port of T (west source on W, east on
//         E, south on S, north on N).
//  ring — every router at Manhattan distance d. Off-axis sources travel X
//         first, then Y, so they merge onto T's N and S inputs; round-robin is
//         fair per input PORT, not per flow, so unequal shares are expected.
// Sources outside the mesh are dropped, not fatal (2x2 degrades to 2
// sources); the run logs how many of T's input ports the sources reach.
// The four-way case needs at least a 3x3 mesh.
//
// Payload signature: {16'h4853 ("HS"), 16'(src), 16'(T), 16'(k)} — every flit
// is traceable in the log to its source and sequence number.
//
// Stimulus self-check (a pass/fail check, NM5 proves it live): after the
// run, every source's FIRST flit must have hand-shaken at its Eject input in
// the same cycle. `late_src_idx` (NM5 only) delays one source by
// `late_cycles` clock edges to prove the check fires.
// -----------------------------------------------------------------------------
class floonoc_mesh_hotspot_seq extends uvm_sequence;

  `uvm_object_utils(floonoc_mesh_hotspot_seq)
  `uvm_declare_p_sequencer(floonoc_mesh_vsequencer)

  // Knobs (set by floonoc_mesh_hotspot_test; -1 / 0 = derive a default)
  int          target      = -1;
  int          d           = -1;
  bit          ring_mode   = 1'b0;
  int          k           = -1;
  bit          fill        = 1'b0;
  bit          hold        = 1'b1;
  int          hold_cycles = -1;
  int          late_src_idx = -1;   // NM5 only: index into sources[]
  int unsigned late_cycles  = 1;

  // Resolved values (read back by the test/report)
  int unsigned sources[$];
  realtime     first_accept[$];
  realtime     release_time;

  function new(string name = "floonoc_mesh_hotspot_seq");
    super.new(name);
  endfunction

  static function int unsigned abs_diff(int unsigned a, int unsigned b);
    return (a > b) ? a - b : b - a;
  endfunction

  // Which of T's input ports a flit from `src` arrives on under XY routing.
  static function floo_pkg::route_direction_e arrival_port(int unsigned src, int unsigned t);
    if (router_x(src) < router_x(t)) return floo_pkg::West;
    if (router_x(src) > router_x(t)) return floo_pkg::East;
    if (router_y(src) < router_y(t)) return floo_pkg::South;
    return floo_pkg::North;
  endfunction

  function void resolve();
    int unsigned tx, ty, dmax;
    if (target < 0) target = int'(router_idx(MeshX / 2, MeshY / 2));
    if (target >= int'(NumRouters)) begin
      `uvm_fatal("HOTSPOT", $sformatf("target R%0d outside a %0d-router mesh", target, NumRouters))
    end
    tx = router_x(target);
    ty = router_y(target);
    if (d < 0) begin
      dmax = tx;
      if (MeshX - 1 - tx < dmax) dmax = MeshX - 1 - tx;
      if (ty < dmax)             dmax = ty;
      if (MeshY - 1 - ty < dmax) dmax = MeshY - 1 - ty;
      d = (dmax > 2) ? 2 : ((dmax < 1) ? 1 : int'(dmax));
    end
    sources.delete();
    for (int unsigned r = 0; r < NumRouters; r++) begin
      int unsigned mdist = abs_diff(router_x(r), tx) + abs_diff(router_y(r), ty);
      if (mdist != unsigned'(d)) continue;
      if (!ring_mode && router_x(r) != tx && router_y(r) != ty) continue;
      sources.push_back(r);
    end
    if (sources.size() == 0) begin
      `uvm_fatal("HOTSPOT", $sformatf("no source router at distance %0d from R%0d on a %0dx%0d mesh",
                                      d, target, MeshX, MeshY))
    end
    if (k < 0) begin
      if (fill) k = d * int'(InFifoDepth + OutFifoDepth) + int'(InFifoDepth + OutFifoDepth) + 1;
      else      k = int'(InFifoDepth + OutFifoDepth) + 1;
    end
    if (hold_cycles < 0) hold_cycles = 4 * (d + 1) + 2 * k + 16;
  endfunction

  virtual task body();
    floonoc_mesh_send_seq     s[$];
    floonoc_mesh_flit_item    item;
    bit                       ports[4];
    int unsigned              n_ports = 0;
    string                    src_list = "";
    realtime                  tmin;
    bit                       all_same;

    resolve();
    foreach (sources[i]) begin
      ports[int'(arrival_port(sources[i], unsigned'(target)))] = 1'b1;
      src_list = {src_list, $sformatf(" R%0d(%0d,%0d)", sources[i],
                  router_x(sources[i]), router_y(sources[i]))};
    end
    foreach (ports[p]) if (ports[p]) n_ports++;
    `uvm_info("HOTSPOT", $sformatf(
      "target=R%0d(%0d,%0d) mode=%s d=%0d K=%0d fill=%0d hold=%0d H=%0d cycles; %0d sources:%s; reaching %0d of T's input ports%s",
      target, router_x(target), router_y(target), ring_mode ? "ring" : "axis", d, k, fill,
      hold, hold_cycles, sources.size(), src_list, n_ports,
      (n_ports < 4) ? string'(" (four-way contention needs >= 3x3 and an interior T)") : string'("")), UVM_LOW)

    foreach (sources[i]) begin
      s.push_back(floonoc_mesh_send_seq::type_id::create($sformatf("hs_src_%0d", sources[i])));
      for (int j = 0; j < k; j++) begin
        item = floonoc_mesh_flit_item::type_id::create($sformatf("hs_%0d_%0d", sources[i], j));
        item.src_router = sources[i];
        item.dst_router = unsigned'(target);
        item.payload    = {16'h4853, 16'(sources[i]), 16'(target), 16'(j)};
        s[i].items.push_back(item);
      end
    end

    // Wait out reset first. Every driver sits in `wait (rst_n)` and then one
    // clock edge before it takes its first item, so a fork issued during
    // reset would be aligned BY RESET, not by this sequence — found by NM5,
    // whose one-cycle delay was silently absorbed by the drivers' reset
    // wait. Two edges after reset every driver is idle in get_next_item.
    wait (p_sequencer.vif.rst_n === 1'b1);
    repeat (2) @(posedge p_sequencer.vif.clk);
    // Align to a clock edge, then start everything in this one timestep.
    @(posedge p_sequencer.vif.clk);
    if (hold) p_sequencer.ready_ctrl.hold[target] = 1'b1;
    foreach (s[i]) begin
      fork
        automatic int ii = i;
        begin
          if (ii == late_src_idx) begin
            `uvm_info("HOTSPOT_NEG", $sformatf("delaying source R%0d by %0d cycle(s)",
                      sources[ii], late_cycles), UVM_LOW)
            repeat (late_cycles) @(posedge p_sequencer.vif.clk);
          end
          s[ii].start(p_sequencer.sqr[sources[ii]], this);
        end
      join_none
    end
    if (hold) begin
      fork
        begin
          repeat (hold_cycles) @(posedge p_sequencer.vif.clk);
          p_sequencer.ready_ctrl.hold[target]         = 1'b0;
          p_sequencer.ready_ctrl.pct_override[target] = 100;
          release_time = $realtime;
          `uvm_info("HOTSPOT", $sformatf("released T=R%0d Eject after %0d cycles (now 100%% ready)",
                    target, hold_cycles), UVM_LOW)
        end
      join_none
    end
    wait fork;

    // Simultaneity self-check: every source's first handshake in one cycle.
    first_accept.delete();
    foreach (s[i]) first_accept.push_back(s[i].items[0].accept_time);
    tmin = first_accept[0];
    foreach (first_accept[i]) if (first_accept[i] < tmin) tmin = first_accept[i];
    all_same = 1'b1;
    foreach (first_accept[i]) begin
      if (first_accept[i] != tmin) begin
        all_same = 1'b0;
        `uvm_error("HOTSPOT", $sformatf(
          "simultaneity violated: source R%0d's first flit hand-shook at t=%0t, %0d cycle(s) after the earliest source (t=%0t)",
          sources[i], first_accept[i], int'((first_accept[i] - tmin) / 10ns), tmin))
      end
    end
    `uvm_info("HOTSPOT", $sformatf("first-flit handshake times: %p (all %s)", first_accept,
              all_same ? string'("SAME cycle") : string'("NOT the same cycle")), UVM_LOW)
  endtask

endclass : floonoc_mesh_hotspot_seq
