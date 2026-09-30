// -----------------------------------------------------------------------------
// Passive monitor over every inter-router link (floonoc_mesh_link_if).
//
// At each posedge after reset, for every router r and direction d in
// North/East/South/West:
//  - valid && ready        -> publish one floonoc_mesh_hop_item on hop_ap;
//                             the scoreboard checks it against the XY model.
//  - valid on a BOUNDARY   -> immediate error. A boundary output's ready is
//    port (no neighbor)       tied 0 in floonoc_mesh_dut, so such a flit can
//                             never handshake: without this check an
//                             off-mesh route would only ever surface as a
//                             forward-progress watchdog timeout, with no
//                             hint of where the flit went.
//
// Sampling is pre-edge at posedge, same discipline as floonoc_mesh_monitor.
// -----------------------------------------------------------------------------
class floonoc_mesh_link_monitor extends uvm_monitor;

  `uvm_component_utils(floonoc_mesh_link_monitor)

  virtual floonoc_mesh_link_if vif;

  uvm_analysis_port #(floonoc_mesh_hop_item) hop_ap;

  int unsigned n_hops;
  int unsigned n_boundary_valid;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    hop_ap = new("hop_ap", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual floonoc_mesh_link_if)::get(this, "", "link_vif", vif)) begin
      `uvm_fatal("LINKMON", "link virtual interface (link_vif) not found in config_db")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    floonoc_mesh_hop_item h;
    flit_t                f;
    floo_pkg::route_direction_e     dir;
    wait (vif.rst_n === 1'b1);
    forever begin
      @(posedge vif.clk);
      for (int unsigned r = 0; r < NumRouters; r++) begin
        for (int unsigned d = 0; d < 4; d++) begin
          dir = floo_pkg::route_direction_e'(d);
          if (vif.valid[r][d] !== 1'b1) continue;
          if (!has_neighbor(r, dir)) begin
            n_boundary_valid++;
            f = vif.data[r][d];
            `uvm_error("LINKMON", $sformatf(
              "router %0d(%0d,%0d) asserts valid toward %s: off-mesh route (no neighbor), dst=(%0d,%0d)",
              r, router_x(r), router_y(r), dir_name(d),
              32'(f.hdr.dst_id.x), 32'(f.hdr.dst_id.y)))
            continue;
          end
          if (vif.ready[r][d] === 1'b1) begin
            f         = vif.data[r][d];
            h         = floonoc_mesh_hop_item::type_id::create($sformatf("hop_r%0d_d%0d", r, d));
            h.router  = r;
            h.dir     = dir;
            h.dst_id  = f.hdr.dst_id;
            h.src_id  = f.hdr.src_id;
            h.payload = f.payload;
            n_hops++;
            `uvm_info("LINKMON", {"hop: ", h.convert2string()}, UVM_HIGH)
            hop_ap.write(h);
          end
        end
      end
    end
  endtask

endclass : floonoc_mesh_link_monitor
