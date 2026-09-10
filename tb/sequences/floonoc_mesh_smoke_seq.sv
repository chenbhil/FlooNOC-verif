// -----------------------------------------------------------------------------
// Mesh smoke sequence.
//
// Directed phase A: every physical inter-router link, in both directions,
//   as a 1-hop case (inject at r's Eject, destination is r's neighbor).
// Directed phase B: both mesh diagonals, both directions each — guarantees
//   at least one full-diameter (MeshDiameter-hop) case, and on a 2-D mesh
//   exercises both X-then-Y turn senses (on a 1-D mesh there are no turns,
//   and the two diagonals coincide).
// Random phase: constrained-random legal flits (src != dst).
//
// Generated from floo_tb_mesh_types_pkg's topology helpers rather than from
// a literal table, so a larger mesh needs no change here. The illegal
// src == dst case is deliberately NOT tested: c_legal_route makes it
// unconstructible, and Phase 1's RTL-level smoke check already confirmed the
// DUT's own NoLoopback assertion fires for it.
// -----------------------------------------------------------------------------
class floonoc_mesh_smoke_seq extends uvm_sequence #(floonoc_mesh_flit_item);

  `uvm_object_utils(floonoc_mesh_smoke_seq)

  // Enough draws that the (src, dst) cross sees repeated pairs, which is
  // what actually exercises the per-pair ordering check R6.
  int unsigned num_random = 15;

  // Running index, used for the directed payload signature.
  protected int unsigned n_sent = 0;

  function new(string name = "floonoc_mesh_smoke_seq");
    super.new(name);
  endfunction

  // One directed flit with a recognizable payload (0xFACE_....).
  task send_directed(int unsigned src, int unsigned dst, string why);
    floonoc_mesh_flit_item item;
    item = floonoc_mesh_flit_item::type_id::create($sformatf("directed_%0d", n_sent));
    start_item(item);
    item.src_router = src;
    item.dst_router = dst;
    item.payload    = payload_t'(64'hFACE_0000_0000_0000 + 64'(n_sent));
    finish_item(item);
    `uvm_info("SEQ", $sformatf("directed[%0s]: %s", why, item.convert2string()), UVM_MEDIUM)
    n_sent++;
  endtask

  // Both directions of one pair, skipped if the pair degenerates. That only
  // happens on a 1x1 mesh: on a 1xN or Nx1 mesh the two diagonals are
  // distinct pairs that happen to be THE SAME pair as each other, so the
  // anti-diagonal re-sends the main one rather than degenerating (harmless,
  // and it is the only thing that gives R6 a depth-2 FIFO on a 1-D mesh).
  task send_pair(int unsigned a, int unsigned b, string why);
    if (a == b) begin
      `uvm_info("SEQ", $sformatf("skipping degenerate %0s pair R%0d", why, a), UVM_MEDIUM)
      return;
    end
    send_directed(a, b, why);
    send_directed(b, a, why);
  endtask

  virtual task body();
    floonoc_mesh_flit_item item;

    // --- Directed phase A: every physical link, both directions ------------
    // Injecting at r for destination neighbor_idx(r, dir) routes out of r's
    // `dir` port and ejects at the neighbor, so the r -> neighbor half of
    // that link is exercised. The (neighbor, opposite_dir) iteration covers
    // the other half.
    for (int unsigned r = 0; r < NumRouters; r++) begin
      for (int unsigned d = 0; d < 4; d++) begin
        // Explicitly qualified: the direction enum lives in floo_pkg, and
        // floo_tb_mesh_types_pkg imports it without re-exporting, so the
        // type name is not visible here through that package alone.
        floo_pkg::route_direction_e dir = floo_pkg::route_direction_e'(d);
        if (!has_neighbor(r, dir)) continue;
        send_directed(r, neighbor_idx(r, dir),
                      $sformatf("link R%0d.%0s", r, dir_name(d)));
      end
    end

    // --- Directed phase B: both diagonals, both directions -----------------
    send_pair(router_idx(0, 0), router_idx(MeshX-1, MeshY-1), "diag-main");
    send_pair(router_idx(MeshX-1, 0), router_idx(0, MeshY-1), "diag-anti");

    // --- Random phase: constrained-random legal traffic --------------------
    repeat (num_random) begin
      item = floonoc_mesh_flit_item::type_id::create("rand_item");
      // Randomized BEFORE start_item, and fatal on failure. A failed solve
      // leaves the item at its defaults, src_router == dst_router == 0 —
      // the one combination c_legal_route exists to forbid. Driving it
      // trips the DUT's own NoLoopback assertion and the flit is never
      // ejected, so a one-line solver failure would surface as a watchdog
      // timeout behind a cascade of "never delivered". c_legal_route is two
      // range bounds and one inequality; the only way it becomes
      // unsatisfiable is a degenerate (1x1) mesh, which is a config error,
      // not something to limp past.
      if (item.randomize() == 0) begin
        `uvm_fatal("SEQ", $sformatf(
          "randomize() failed on a %0d-router mesh — c_legal_route is unsatisfiable (1x1 mesh?)",
          NumRouters))
      end
      start_item(item);
      finish_item(item);
      `uvm_info("SEQ", {"random:   ", item.convert2string()}, UVM_MEDIUM)
      n_sent++;
    end
  endtask

endclass : floonoc_mesh_smoke_seq
