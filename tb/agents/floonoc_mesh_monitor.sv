// -----------------------------------------------------------------------------
// Monitor: observes every router's Eject-input and Eject-output handshake and
// publishes the transactions through two analysis ports. Backpressure
// (valid && !ready) seen while a flit waits is recorded on the transaction
// for coverage.
//
// `in_ap`/`out_ap` are protocol/backpressure observations, not the source of
// scoreboard expectations — the driver's `sent_ap` (floonoc_mesh_driver)
// covers that so the scoreboard keys on the sequence's intent rather than on
// the wire. See that port's comment for the full reasoning.
//
// On the input side the source router is the physical port index. On the
// output side it is decoded from hdr.src_id, which the DUT carries through
// every hop untouched under XYRouting.
// -----------------------------------------------------------------------------
class floonoc_mesh_monitor extends uvm_monitor;

  `uvm_component_utils(floonoc_mesh_monitor)

  virtual floonoc_mesh_if vif;

  uvm_analysis_port #(floonoc_mesh_flit_item) in_ap;   // accepted input flits
  uvm_analysis_port #(floonoc_mesh_flit_item) out_ap;  // delivered output flits

  // Sticky per-router backpressure trackers (cleared on handshake)
  protected bit in_bp  [NumRouters];
  protected bit out_bp [NumRouters];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    in_ap  = new("in_ap", this);
    out_ap = new("out_ap", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual floonoc_mesh_if)::get(this, "", "vif", vif)) begin
      `uvm_fatal("MON", "virtual interface not found in config_db")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    floonoc_mesh_flit_item item;
    wait (vif.rst_n === 1'b1);
    forever begin
      @(posedge vif.clk);
      for (int unsigned r = 0; r < NumRouters; r++) begin
        // Input side (TB -> router r's Eject input)
        if (vif.valid_in[r] === 1'b1 && vif.ready_in[r] !== 1'b1) begin
          in_bp[r] = 1'b1;
        end
        if (vif.valid_in[r] === 1'b1 && vif.ready_in[r] === 1'b1) begin
          // Free cross-check on the encoder: from_flit() trusts the
          // physical port for src_router on the input side (it does not
          // read hdr.src_id there at all — see its comment), so nothing
          // else in the chain verifies that the driver's src_id() actually
          // encoded the router it is physically injecting on. A bug in
          // src_id() (x/y swapped, wrong router_idx() arithmetic, ...)
          // would otherwise never surface here: it would only show up
          // indirectly, and misleadingly, as an output-side src_router
          // mismatch far downstream. Check it directly, right where the
          // flit enters.
          automatic int unsigned encoded_src =
              router_idx(32'(vif.data_in[r].hdr.src_id.x), 32'(vif.data_in[r].hdr.src_id.y));
          if (encoded_src != r) begin
            `uvm_error("MON", $sformatf(
                "input flit at router %0d carries hdr.src_id decoding to router %0d (x=%0d,y=%0d) — floonoc_mesh_flit_item::src_id() encoded the wrong router for the port it was driven on",
                r, encoded_src, 32'(vif.data_in[r].hdr.src_id.x), 32'(vif.data_in[r].hdr.src_id.y)))
          end
          item = floonoc_mesh_flit_item::type_id::create($sformatf("mon_in_r%0d", r));
          item.from_flit(vif.data_in[r], r, /*is_output*/ 1'b0, in_bp[r]);
          // The scoreboard only ever sees the flag on OUTPUT-side items (its
          // expectation side is fed by the driver, per A8), and in_ap has no
          // subscriber today, so an input-side malformed decode would be
          // reported by nobody unless it is reported here.
          if (item.hdr_malformed) begin
            `uvm_error("MON", $sformatf("malformed input flit at router %0d: %s: %s",
                                        r, item.hdr_malformed_why, item.convert2string()))
          end
          in_bp[r] = 1'b0;
          `uvm_info("MON", {"in : ", item.convert2string()}, UVM_HIGH)
          in_ap.write(item);
        end
        // Output side (router r's Eject output -> TB)
        if (vif.valid_out[r] === 1'b1 && vif.ready_out[r] !== 1'b1) begin
          out_bp[r] = 1'b1;
        end
        if (vif.valid_out[r] === 1'b1 && vif.ready_out[r] === 1'b1) begin
          item = floonoc_mesh_flit_item::type_id::create($sformatf("mon_out_r%0d", r));
          item.from_flit(vif.data_out[r], r, /*is_output*/ 1'b1, out_bp[r]);
          item.obs_time = $realtime;  // output handshake edge, for latency
          out_bp[r] = 1'b0;
          `uvm_info("MON", {"out: ", item.convert2string()}, UVM_HIGH)
          out_ap.write(item);
        end
      end
    end
  endtask

endclass : floonoc_mesh_monitor
