// -----------------------------------------------------------------------------
// Scoreboard. Checks (traceability in docs/verification_plan.md):
//  R1 routing      — every accepted flit appears at exactly the output port
//                    predicted by the documented XY routing rule
//  R2 payload      — payload and header fields arrive unmodified
//  R5 no loss/dup  — every accepted flit is delivered exactly once; any
//                    output flit without a pending expectation is an error
//  R6 ordering     — flits of the same (input port -> output port) pair are
//                    delivered in acceptance order (per-pair FIFO expectation;
//                    see docs/assumptions.md A4 — no cross-pair order assumed)
// -----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_in)
`uvm_analysis_imp_decl(_out)

class floonoc_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(floonoc_scoreboard)

  uvm_analysis_imp_in  #(floonoc_flit_item, floonoc_scoreboard) in_imp;
  uvm_analysis_imp_out #(floonoc_flit_item, floonoc_scoreboard) out_imp;

  // Per (input port, output port) FIFO of expected flits
  protected floonoc_flit_item expected [NumPorts][NumPorts][$];

  int unsigned n_accepted;
  int unsigned n_delivered;
  int unsigned n_matched;
  int unsigned n_mismatched;

  // Fault-injection knobs for negative self-tests ONLY (prove the checkers
  // are not vacuous — see docs/verification_plan.md N1/N2). Default -1: off.
  // Set via uvm_config_db by the floonoc_neg_* tests.
  int corrupt_payload_idx = -1;  // corrupt the Nth accepted flit's expected payload
  int corrupt_route_idx   = -1;  // model the Nth accepted flit at the wrong output

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

  // Input handshake accepted by the DUT -> predict destination port
  //
  // `t` is cloned before anything is stored or mutated: uvm_analysis_port
  // hands the SAME handle to every subscriber, so if a second subscriber is
  // ever attached to the driver's sent_ap, whether it sees the true or the
  // N1-corrupted payload would otherwise depend on connection order.
  virtual function void write_in(floonoc_flit_item orig);
    floonoc_flit_item t;
    int unsigned eo;
    if (!$cast(t, orig.clone())) begin
      `uvm_fatal("SB", "floonoc_scoreboard::write_in: $cast of clone() failed")
    end
    eo = t.exp_out();
    if (int'(n_accepted) == corrupt_payload_idx) begin
      t.payload = t.payload ^ payload_t'(1);
      `uvm_info("SB_NEG", $sformatf("injected payload corruption on accepted flit #%0d", n_accepted), UVM_LOW)
    end
    if (int'(n_accepted) == corrupt_route_idx) begin
      eo = (eo + 1) % NumPorts;
      `uvm_info("SB_NEG", $sformatf("injected wrong-output expectation on accepted flit #%0d", n_accepted), UVM_LOW)
    end
    n_accepted++;
    expected[t.src_port][eo].push_back(t);
  endfunction

  // Output handshake delivered by the DUT -> match oldest expectation
  virtual function void write_out(floonoc_flit_item t);
    floonoc_flit_item exp;
    n_delivered++;

    // R5: unexpected source or spurious flit
    if (t.src_port >= NumPorts) begin
      n_mismatched++;
      `uvm_error("SB", $sformatf("output flit with unknown src encoding: %s",
                                 t.convert2string()))
      return;
    end
    if (expected[t.src_port][t.out_port].size() == 0) begin
      n_mismatched++;
      `uvm_error("SB", $sformatf(
        "unexpected flit at output %0d(%s) (nothing pending from input %0d): %s",
        t.out_port, dir_name(t.out_port), t.src_port, t.convert2string()))
      return;
    end

    // R6: per-pair ordering — the oldest pending flit must be this one
    exp = expected[t.src_port][t.out_port].pop_front();

    // R1: routing — by construction exp landed in this queue via exp_out();
    // double-check against the observed flit's own destination header.
    if (t.exp_out() != t.out_port) begin
      n_mismatched++;
      `uvm_error("SB", $sformatf(
        "routing violation: flit for (%0d,%0d) seen at port %0d(%s), expected %0d(%s)",
        t.dst_x, t.dst_y, t.out_port, dir_name(t.out_port),
        t.exp_out(), dir_name(t.exp_out())))
      return;
    end

    // R2: payload + header integrity
    if (t.payload !== exp.payload || t.dst_x !== exp.dst_x || t.dst_y !== exp.dst_y) begin
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
        `uvm_info(ctx, $sformatf("stuck in-flight [%0d->%0d]: %s",
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

endclass : floonoc_scoreboard
