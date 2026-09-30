// -----------------------------------------------------------------------------
// Mesh scoreboard. Checks (traceability in docs/verification_plan.md):
//  R1 routing      — every flit is ejected at the router its own header
//                    names as the destination. Note what this is and is not:
//                    it compares two INDEPENDENT sources — the wire-decoded
//                    hdr.dst_id and the physical Eject port the monitor saw
//                    it on — so it catches a real DUT misroute. It is not a
//                    check of the XY routing MODEL: per D6 the eject router
//                    is the destination by definition, so exp_out_router()
//                    makes no prediction. The XY routing MODEL is checked
//                    separately, hop by hop, by RM8 below.
//  R2 payload      — payload and destination header arrive unmodified
//  R5 no loss/dup  — every accepted flit is delivered exactly once; any
//                    output flit without a pending expectation is an error
//  R6 ordering     — flits of the same (src router -> dst router) pair are
//                    delivered in acceptance order (per-pair FIFO)
//  RM8 XY path     — every router-to-router hop (valid && ready on a
//                    North/East/South/West output, observed by
//                    floonoc_mesh_link_monitor) leaves in the direction
//                    exp_out_port_at(router x, router y, hdr.dst_id) predicts.
//                    Stateless: no flit identity is needed. If every hop
//                    decision matches the model, the path equals exp_path()
//                    by induction; the final Eject decision is R1. Plus a
//                    completeness invariant at check_phase: total observed
//                    hops == sum of exp_hops() over accepted flits, which
//                    catches a hop the link monitor missed. TB-owned and
//                    independent of the DUT's own XYDirectionNotAllowed /
//                    NoLoopback assertions, so it still runs under
//                    -D ASSERTS_OFF (the xezim configuration).
//
// R6 on a mesh: two flits sharing (src, dst) take the SAME route, because
// dimension-order XY routing is deterministic and stateless. They therefore
// enter each intermediate router on the same input port and leave on the
// same output port, and every stage between them is a FIFO (input
// stream_fifo, output fifo). Nothing can reorder them relative to each
// other. Cross-pair order is deliberately NOT assumed — see
// docs/assumptions.md A4-M.
//
// The expectation side is fed by the DRIVER's analysis port (the original
// sequence item, pre-as_flit()), not by the input-side wire monitor. Keying
// the expectation off the wire would make a driver-side encoding bug
// self-certifying: a wrong header would be decoded back into the same wrong
// expectation, faithfully routed there, and scored as a match. See the
// plan's amendment A8.
//
// Path correctness is checked via a SEPARATE read-only link interface
// (floonoc_mesh_link_if), not floonoc_mesh_if, which exposes only Eject
// endpoints. See RM8 above.
// -----------------------------------------------------------------------------

// Distinct suffixes from the single-router bench's _in/_out: these macros
// define GLOBAL class names (uvm_analysis_imp_mesh_in, ...), so unique names
// keep the two packages independent even if they ever met in one compile.
`uvm_analysis_imp_decl(_mesh_in)
`uvm_analysis_imp_decl(_mesh_out)
`uvm_analysis_imp_decl(_mesh_hop)

class floonoc_mesh_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(floonoc_mesh_scoreboard)

  uvm_analysis_imp_mesh_in  #(floonoc_mesh_flit_item, floonoc_mesh_scoreboard) in_imp;
  uvm_analysis_imp_mesh_out #(floonoc_mesh_flit_item, floonoc_mesh_scoreboard) out_imp;
  uvm_analysis_imp_mesh_hop #(floonoc_mesh_hop_item,  floonoc_mesh_scoreboard) hop_imp;

  // Per (source router, destination router) FIFO of expected flits
  protected floonoc_mesh_flit_item expected [NumRouters][NumRouters][$];

  int unsigned n_accepted;
  int unsigned n_delivered;
  int unsigned n_matched;
  int unsigned n_mismatched;
  int unsigned n_hops;             // RM8: link hops observed
  int unsigned n_path_violations;  // RM8: hops that disagreed with the XY model
  int unsigned exp_hop_sum;        // RM8: sum of exp_hops() over accepted flits

  // Fault-injection knobs for negative self-tests ONLY (prove the checkers
  // are not vacuous — see docs/verification_plan.md N1/N2). Default -1: off.
  // Indices are 0-based over ACCEPTED flits (compared before n_accepted++).
  int corrupt_payload_idx = -1;  // corrupt this accepted flit's expected payload
  int corrupt_route_idx   = -1;  // model this accepted flit at the wrong router
  // NM4: perturb the XY model's expected direction for this OBSERVED hop
  // (0-based over hops, compared before n_hops++). The DUT is untouched.
  int corrupt_hop_idx     = -1;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    in_imp  = new("in_imp", this);
    out_imp = new("out_imp", this);
    hop_imp = new("hop_imp", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(int)::get(this, "", "corrupt_payload_idx", corrupt_payload_idx));
    void'(uvm_config_db#(int)::get(this, "", "corrupt_route_idx", corrupt_route_idx));
    void'(uvm_config_db#(int)::get(this, "", "corrupt_hop_idx", corrupt_hop_idx));
  endfunction

  // N2 helper: pick a router that is neither the true destination nor the
  // source, so the corrupted expectation stays legal-shaped AND is
  // guaranteed to differ from the truth. A silent no-op here would make the
  // negative test vacuously "pass", which is precisely what it exists to
  // disprove — so failing to find one is fatal, not a warning.
  protected function int unsigned wrong_router(int unsigned src, int unsigned truth);
    for (int unsigned k = 1; k < NumRouters; k++) begin
      int unsigned cand = (truth + k) % NumRouters;
      if (cand != src && cand != truth) return cand;
    end
    `uvm_fatal("SB_NEG", $sformatf(
      "cannot build a wrong-router expectation on a %0d-router mesh: N2 would be vacuous",
      NumRouters))
    return truth;
  endfunction

  // Input handshake accepted by the DUT -> predict the ejecting router.
  //
  // `t` is cloned before anything is stored or mutated. The driver already
  // publishes a clone, so today `t` is ours alone — but uvm_analysis_port
  // hands the SAME handle to every subscriber in connection order, so the
  // moment a second subscriber is attached to sent_ap, whether it sees the
  // true or the N1-corrupted payload would depend on connection order.
  // One clone here removes that ordering dependency permanently.
  virtual function void write_mesh_in(floonoc_mesh_flit_item orig);
    floonoc_mesh_flit_item t;
    int unsigned eo;
    if (!$cast(t, orig.clone())) begin
      `uvm_fatal("SB", "floonoc_mesh_scoreboard::write_mesh_in: $cast of clone() failed")
    end
    eo = t.exp_out_router();
    // Guard the fixed-array indices. An out-of-range index is SILENTLY
    // DISCARDED in SystemVerilog, so without this an impossible item would
    // make its expectation vanish and resurface later as a misleading
    // "unexpected flit" at delivery time, pointing at the DUT.
    if (t.src_router >= NumRouters || eo >= NumRouters) begin
      n_mismatched++;
      `uvm_error("SB", $sformatf(
        "accepted flit with out-of-range endpoint on a %0d-router mesh: %s",
        NumRouters, t.convert2string()))
      return;
    end
    if (int'(n_accepted) == corrupt_payload_idx) begin
      t.payload = t.payload ^ payload_t'(1);
      `uvm_info("SB_NEG", $sformatf("injected payload corruption on accepted flit #%0d",
                                    n_accepted), UVM_LOW)
    end
    if (int'(n_accepted) == corrupt_route_idx) begin
      eo = wrong_router(t.src_router, eo);
      `uvm_info("SB_NEG", $sformatf("injected wrong-router expectation (R%0d) on accepted flit #%0d",
                                    eo, n_accepted), UVM_LOW)
    end
    n_accepted++;
    // RM8 completeness: every router-to-router link this flit must cross.
    // Taken from the TRUE item, before any N2 corruption of `eo` — the flit
    // on the wire still follows its real path.
    exp_hop_sum += t.exp_hops();
    expected[t.src_router][eo].push_back(t);
  endfunction

  // RM8: one router-to-router hop observed on a link -> compare the direction
  // it left on with the XY model's one-hop decision at that router.
  virtual function void write_mesh_hop(floonoc_mesh_hop_item h);
    floo_pkg::route_direction_e exp_dir;
    exp_dir = exp_out_port_at(router_x(h.router), router_y(h.router), h.dst_id);
    if (int'(n_hops) == corrupt_hop_idx) begin
      exp_dir = floo_pkg::route_direction_e'((32'(exp_dir) + 1) % 4);
      `uvm_info("SB_NEG", $sformatf("injected wrong XY-model direction (%s) on observed hop #%0d",
                                    dir_name(32'(exp_dir)), n_hops), UVM_LOW)
    end
    n_hops++;
    if (h.dir != exp_dir) begin
      n_mismatched++;
      n_path_violations++;
      `uvm_error("SB", $sformatf(
        "path violation: flit for R%0d(%0d,%0d) at R%0d(%0d,%0d) left %s, XY model says %s: %s",
        router_idx(32'(h.dst_id.x), 32'(h.dst_id.y)), 32'(h.dst_id.x), 32'(h.dst_id.y),
        h.router, router_x(h.router), router_y(h.router),
        dir_name(32'(h.dir)), dir_name(32'(exp_dir)), h.convert2string()))
    end
  endfunction

  // Output handshake delivered by the DUT -> match oldest expectation
  virtual function void write_mesh_out(floonoc_mesh_flit_item t);
    floonoc_mesh_flit_item exp;
    n_delivered++;

    // R5: the wire decoded to a router index outside the mesh. Reported
    // here rather than inside from_flit() so it lands in the same
    // n_mismatched accounting as every other output-side failure, and so
    // the item is never used as a FIFO index below.
    if (t.hdr_malformed) begin
      n_mismatched++;
      `uvm_error("SB", $sformatf("malformed output flit at router %0d: %s: %s",
                                 t.out_router, t.hdr_malformed_why, t.convert2string()))
      return;
    end
    // R1: routing — the flit must eject at the router its own header names.
    //
    // Checked FIRST, ahead of the expectation lookup, because it needs only
    // the observed flit. A misrouted flit normally lands where nothing is
    // pending, so the spurious-flit branch below would claim it and report
    // "unexpected flit" — the right count, the wrong story. Worse, in the
    // window where the wrong router DOES have something pending, testing R1
    // after the pop would consume an innocent expectation, turning one fault
    // into two errors (a routing violation reported against someone else's
    // flit, then "unexpected flit" when that flit legitimately arrives).
    // Checking first gives the precise diagnosis and leaves the real
    // expectation pending, where check_phase reports it as never delivered.
    if (t.exp_out_router() != t.out_router) begin
      n_mismatched++;
      `uvm_error("SB", $sformatf(
        "routing violation: flit for router %0d(%0d,%0d) ejected at router %0d(%0d,%0d)",
        t.dst_router, t.dst_x(), t.dst_y(),
        t.out_router, router_x(t.out_router), router_y(t.out_router)))
      return;
    end

    // R5: spurious flit — nothing pending for this (src, exit) pair
    if (expected[t.src_router][t.out_router].size() == 0) begin
      n_mismatched++;
      `uvm_error("SB", $sformatf(
        "unexpected flit at router %0d (nothing pending from input router %0d): %s",
        t.out_router, t.src_router, t.convert2string()))
      return;
    end

    // R6: per-pair ordering — the oldest pending flit must be this one
    exp = expected[t.src_router][t.out_router].pop_front();

    // R2: payload integrity.
    //
    // Only the payload is compared. A `t.dst_router != exp.dst_router` test
    // used to sit here and was DEAD: expectations are filed under the key
    // exp.dst_router, this pop used t.out_router as the key, and R1 above
    // has already established t.dst_router == t.out_router — so the two
    // destinations are equal by construction on every path except the TB's
    // own N2 injection. Destination integrity is real, but it is enforced by
    // the FIFO KEY, not by a comparison: a flit whose destination header was
    // corrupted in flight is delivered somewhere no expectation is filed and
    // is caught above as an unexpected flit, with its true expectation left
    // pending. Keeping a comparison that cannot fail would read as coverage
    // that does not exist.
    if (t.payload !== exp.payload) begin
      n_mismatched++;
      `uvm_error("SB", $sformatf("integrity/order mismatch:\n  expected: %s\n  observed: %s",
                                 exp.convert2string(), t.convert2string()))
      return;
    end

    n_matched++;
  endfunction

  function int unsigned pending_count();
    int unsigned n = 0;
    foreach (expected[i, o]) n += expected[i][o].size();
    return n;
  endfunction

  function void dump_pending(string ctx = "TIMEOUT");
    foreach (expected[i, o]) begin
      foreach (expected[i][o][k]) begin
        `uvm_info(ctx, $sformatf("stuck in-flight [R%0d->R%0d]: %s",
                  i, o, expected[i][o][k].convert2string()), UVM_NONE)
      end
    end
  endfunction

  // R5: nothing may remain in flight at the end of test
  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (pending_count() != 0) begin
      dump_pending("SB");
      `uvm_error("SB", $sformatf("%0d accepted flit(s) never delivered", pending_count()))
    end
    if (n_delivered != n_accepted) begin
      `uvm_error("SB", $sformatf("accepted %0d != delivered %0d", n_accepted, n_delivered))
    end
    // RM8 completeness. Only meaningful once the mesh has drained: a flit
    // still stuck in flight (NM3, or a real stall already reported above)
    // has legitimately not crossed all its links yet, and flagging that too
    // would be a second report of the same fault.
    if (pending_count() == 0 && n_delivered == n_accepted) begin
      if (n_hops != exp_hop_sum) begin
        `uvm_error("SB", $sformatf(
          "link hop count mismatch: observed %0d router-to-router hops, XY model predicts %0d for the %0d accepted flits",
          n_hops, exp_hop_sum, n_accepted))
      end
    end
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("SB", $sformatf(
      "accepted=%0d delivered=%0d matched=%0d mismatched=%0d pending=%0d",
      n_accepted, n_delivered, n_matched, n_mismatched, pending_count()), UVM_LOW)
    `uvm_info("SB", $sformatf(
      "hops checked=%0d (XY model predicts %0d) path_violations=%0d",
      n_hops, exp_hop_sum, n_path_violations), UVM_LOW)
  endfunction

endclass : floonoc_mesh_scoreboard
