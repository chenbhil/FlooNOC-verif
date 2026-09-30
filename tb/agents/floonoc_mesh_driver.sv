// -----------------------------------------------------------------------------
// Driver for ONE router: converts mesh flit items into valid/ready handshakes
// on router `router_idx`'s Eject INPUT port, honoring the DUT contract that
// valid stays asserted (with stable data) until ready (mirrors the DUT's
// StableValidIn assertion).
//
// There is one driver (and one sequencer) per router, so several routers can
// inject in the same cycle. Driver r owns ONLY valid_in[r], data_in[r] and
// ready_out[r]; it never writes another router's bits. Its router index comes
// from config_db ("router_idx"), set by floonoc_mesh_agent.
//
// ready_out[r] is re-randomized every cycle (~80% high) to exercise
// backpressure while remaining a legal sink, unless the shared
// floonoc_mesh_ready_ctrl holds it low or overrides the percentage.
//
// Timing discipline: all pins are driven with non-blocking assignments at
// posedge and all DUT outputs are read at posedge (pre-edge values), which
// matches SVA sampling semantics under Verilator --timing.
// -----------------------------------------------------------------------------
class floonoc_mesh_driver extends uvm_driver #(floonoc_mesh_flit_item);

  `uvm_component_utils(floonoc_mesh_driver)

  virtual floonoc_mesh_if vif;

  int unsigned            router_idx;
  floonoc_mesh_ready_ctrl ready_ctrl;

  // Probability (percent) that a router's Eject ready is high in a given cycle
  int unsigned ready_pct = 80;

  // Publishes the ORIGINAL sequence item once it has been accepted on the
  // wire (see drive_flit). This exists so the scoreboard (Task 7) can key
  // its expectations on the item the sequence actually intended to send,
  // rather than on the wire-level flit decoded by an input monitor.
  //
  // Without this port, the only source of "what did we expect?" would be
  // from_flit() decoding the header the driver itself just encoded via
  // as_flit(). A bug in that encode/decode pair (x/y transposed, say) would
  // then be invisible end-to-end: the driver would drive the wrong header,
  // an input monitor would decode that same wrong header into the same
  // wrong expectation, the DUT would faithfully route to the wrong place,
  // and the scoreboard would report a match — the bench would be
  // self-certifying instead of actually checking anything. Publishing the
  // pre-as_flit() sequence item breaks that loop: the expectation comes
  // from what was asked for, independent of how it was encoded onto the
  // wire.
  uvm_analysis_port #(floonoc_mesh_flit_item) sent_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    sent_ap = new("sent_ap", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    int rp;
    super.build_phase(phase);
    if (!uvm_config_db#(virtual floonoc_mesh_if)::get(this, "", "vif", vif)) begin
      `uvm_fatal("DRV", "virtual interface not found in config_db")
    end
    if (!uvm_config_db#(int unsigned)::get(this, "", "router_idx", router_idx)) begin
      `uvm_fatal("DRV", "router_idx not found in config_db")
    end
    if (router_idx >= NumRouters) begin
      `uvm_fatal("DRV", $sformatf("router_idx %0d outside a %0d-router mesh", router_idx, NumRouters))
    end
    if (!uvm_config_db#(floonoc_mesh_ready_ctrl)::get(this, "", "ready_ctrl", ready_ctrl)) begin
      `uvm_fatal("DRV", "ready_ctrl not found in config_db")
    end
    // Overridable for backpressure scenarios (0 = outputs never ready,
    // used by the floonoc_mesh_neg_stall self-test)
    if (uvm_config_db#(int)::get(this, "", "ready_pct", rp)) begin
      if (rp < 0) rp = 0;
      ready_pct = unsigned'(rp);
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    floonoc_mesh_flit_item item;

    vif.valid_in[router_idx]  <= 1'b0;
    vif.data_in[router_idx]   <= '0;
    vif.ready_out[router_idx] <= 1'b1;

    fork
      drive_output_ready();
    join_none

    wait (vif.rst_n === 1'b1);
    @(posedge vif.clk);

    forever begin
      seq_item_port.get_next_item(item);
      drive_flit(item);
      seq_item_port.item_done();
    end
  endtask

  // Assert valid/data after the current edge; they participate in the
  // handshake from the next posedge on. Hold until ready seen at an edge.
  task drive_flit(floonoc_mesh_flit_item item);
    floonoc_mesh_flit_item sent_item;
    int unsigned r = router_idx;
    if (item.src_router != router_idx) begin
      `uvm_fatal("DRV", $sformatf(
        "driver for router %0d was handed an item for source router %0d (sequence started on the wrong sequencer): %s",
        router_idx, item.src_router, item.convert2string()))
    end
    vif.valid_in[r] <= 1'b1;
    vif.data_in[r]  <= item.as_flit();
    do begin
      @(posedge vif.clk);
    end while (!(vif.valid_in[r] === 1'b1 && vif.ready_in[r] === 1'b1));
    vif.valid_in[r] <= 1'b0;
    item.accept_time = $realtime;  // the handshake edge; carried by the clone
    `uvm_info("DRV", {"sent: ", item.convert2string()}, UVM_HIGH)
    // Publish AFTER the handshake completes, so the write is equivalent to
    // an "accepted" event, not merely "requested" — a flit the DUT never
    // took (e.g. reset mid-handshake) is never reported as sent. Publish a
    // CLONE, not `item` itself: `item` is owned by the sequencer/sequence
    // and later sequence activity could still mutate the same object the
    // scoreboard is holding onto. do_copy is hand-written (see
    // floonoc_mesh_flit_item), so clone() round-trips src_router,
    // dst_router and payload faithfully.
    if (!$cast(sent_item, item.clone())) begin
      `uvm_fatal("DRV", "floonoc_mesh_driver::drive_flit: $cast of item.clone() failed")
    end
    sent_ap.write(sent_item);
  endtask

  // Legal random sink: ready may toggle freely; the DUT does not require
  // ready stability (ready/valid dependency rules only constrain valid).
  // Only this driver's own router; see floonoc_mesh_ready_ctrl for the
  // hold / override precedence.
  task drive_output_ready();
    int unsigned pct;
    forever begin
      @(posedge vif.clk);
      if (ready_ctrl.hold[router_idx]) begin
        vif.ready_out[router_idx] <= 1'b0;
      end else begin
        pct = (ready_ctrl.pct_override[router_idx] >= 0)
              ? unsigned'(ready_ctrl.pct_override[router_idx]) : ready_pct;
        vif.ready_out[router_idx] <= bit'($urandom_range(99) < pct);
      end
    end
  endtask

endclass : floonoc_mesh_driver
