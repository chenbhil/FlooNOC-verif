// -----------------------------------------------------------------------------
// One observed router-to-router hop: a valid && ready handshake on router
// `router`'s output toward `dir` (North/East/South/West), with the header
// fields decoded from the wire. Published by floonoc_mesh_link_monitor and
// checked by the scoreboard against the XY model one hop at a time.
//
// Carries no flit identity on purpose: flits have no ID field, and the
// per-hop check is stateless — "a flit for dst leaving (x,y) must go the way
// exp_out_port_at says" needs only the header and the location.
// -----------------------------------------------------------------------------
class floonoc_mesh_hop_item extends uvm_sequence_item;

  int unsigned      router;   // router the flit is LEAVING
  floo_pkg::route_direction_e dir;      // output direction it left on (N/E/S/W)
  xy_id_t           dst_id;   // hdr.dst_id as seen on the link
  xy_id_t           src_id;   // hdr.src_id, for diagnostics only
  payload_t         payload;

  `uvm_object_utils(floonoc_mesh_hop_item)

  function new(string name = "floonoc_mesh_hop_item");
    super.new(name);
  endfunction

  // Hand-written, not field macros — same Verilator width-warning reason as
  // floonoc_mesh_flit_item.
  virtual function void do_copy(uvm_object rhs);
    floonoc_mesh_hop_item rhs_;
    if (!$cast(rhs_, rhs)) begin
      `uvm_fatal("DO_COPY", "floonoc_mesh_hop_item::do_copy: $cast of rhs failed")
    end
    super.do_copy(rhs);
    router  = rhs_.router;
    dir     = rhs_.dir;
    dst_id  = rhs_.dst_id;
    src_id  = rhs_.src_id;
    payload = rhs_.payload;
  endfunction

  virtual function string convert2string();
    return $sformatf("R%0d(%0d,%0d) -> %s: src=(%0d,%0d) dst=(%0d,%0d) payload=0x%016h",
                     router, router_x(router), router_y(router), dir_name(32'(dir)),
                     32'(src_id.x), 32'(src_id.y), 32'(dst_id.x), 32'(dst_id.y), payload);
  endfunction

endclass : floonoc_mesh_hop_item
