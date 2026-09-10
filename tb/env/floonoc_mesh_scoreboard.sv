// -----------------------------------------------------------------------------
// Mesh scoreboard. Checks (traceability in docs/verification_plan.md):
//  R1 routing      — every accepted flit is ejected at exactly the router
//                    predicted by the XY routing rule (i.e. its destination)
//  R2 payload      — payload and destination header arrive unmodified
//  R5 no loss/dup  — every accepted flit is delivered exactly once; any
//                    output flit without a pending expectation is an error
//  R6 ordering     — flits of the same (src router -> dst router) pair are
//                    delivered in acceptance order (per-pair FIFO)
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
// Path correctness is deliberately NOT checked: floonoc_mesh_if exposes only
// Eject endpoints, not the hops in between. Intermediate-router behavior is
// the RTL wiring layer's job (Phase 1) and the DUT's own per-router
// XYDirectionNotAllowed / NoLoopback assertions.
// -----------------------------------------------------------------------------

// Distinct suffixes from the single-router bench's _in/_out: these macros
// define GLOBAL class names (uvm_analysis_imp_mesh_in, ...), so unique names
// keep the two packages independent even if they ever met in one compile.
`uvm_analysis_imp_decl(_mesh_in)
`uvm_analysis_imp_decl(_mesh_out)

class floonoc_mesh_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(floonoc_mesh_scoreboard)

  uvm_analysis_imp_mesh_in  #(floonoc_mesh_flit_item, floonoc_mesh_scoreboard) in_imp;
  uvm_analysis_imp_mesh_out #(floonoc_mesh_flit_item, floonoc_mesh_scoreboard) out_imp;

  // Per (source router, destination router) FIFO of expected flits
  protected floonoc_mesh_flit_item expected [NumRouters][NumRouters][$];

  int unsigned n_accepted;
  int unsigned n_delivered;
  int unsigned n_matched;
  int unsigned n_mismatched;

  // Fault-injection knobs for negative self-tests ONLY (prove the checkers
  // are not vacuous — see docs/verification_plan.md N1/N2). Default -1: off.
  int corrupt_payload_idx = -1;  // corrupt the Nth accepted flit's expected payload
  int corrupt_route_idx   = -1;  // model the Nth accepted flit at the wrong router

  function new(string name, uvm_component parent);
    super.new(name, parent);
    in_imp  = new("in_imp", this);
    out_imp = new("out_imp", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(int)::get(this, "", "corrupt_payload_idx", corrupt_payload_idx));
    void'(uvm_config_db#(int)::get(this, "", "corrupt_route_idx", corrupt_route_idx));
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

  // Input handshake accepted by the DUT -> predict the ejecting router
  virtual function void write_mesh_in(floonoc_mesh_flit_item t);
    int unsigned eo = t.exp_out_router();
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
    expected[t.src_router][eo].push_back(t);
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

    // R1: routing — the flit must eject at the router its own header names
    if (t.exp_out_router() != t.out_router) begin
      n_mismatched++;
      `uvm_error("SB", $sformatf(
        "routing violation: flit for router %0d(%0d,%0d) ejected at router %0d(%0d,%0d)",
        t.dst_router, t.dst_x(), t.dst_y(),
        t.out_router, router_x(t.out_router), router_y(t.out_router)))
      return;
    end

    // R2: payload + destination header integrity
    if (t.payload !== exp.payload || t.dst_router != exp.dst_router) begin
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
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("SB", $sformatf(
      "accepted=%0d delivered=%0d matched=%0d mismatched=%0d pending=%0d",
      n_accepted, n_delivered, n_matched, n_mismatched, pending_count()), UVM_LOW)
  endfunction

endclass : floonoc_mesh_scoreboard
