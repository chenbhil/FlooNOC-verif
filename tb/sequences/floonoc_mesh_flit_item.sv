// -----------------------------------------------------------------------------
// Smallest meaningful mesh transaction: one single-flit packet (hdr.last == 1,
// so the wormhole route lock opens and closes per flit — see
// docs/assumptions.md A2) injected at one router's Eject port and ejected at
// another router's Eject port.
//
// Endpoints are ROUTER INDICES, not port directions. The TB only ever touches
// Eject ports; North/East/South/West are inter-router links inside
// floonoc_mesh_dut. That is why the single-router bench's per-source-direction
// constraint table does not appear here: src_router != dst_router is the only
// illegal combination.
//
// Intermediate hops stay legal automatically. floo_router ties off the
// N/S-input -> E/W-output crossbar cells under XYRouteOpt
// (hw/floo_router.sv:349-353) and asserts XYDirectionNotAllowed on them
// (:515). Dimension-order XY routing resolves X completely before it ever
// turns in Y, so a flit that arrived from North or South always has
// dst.x == cur.x and can only leave North, South or Eject — never East or
// West. NoLoopback holds for the same reason: XY routing never sends a flit
// back out the port it arrived on.
// -----------------------------------------------------------------------------
class floonoc_mesh_flit_item extends uvm_sequence_item;

  // Stimulus fields
  rand int unsigned src_router;   // injection router (its Eject input)
  rand int unsigned dst_router;   // destination router (its Eject output)
  rand payload_t    payload;

  // Observation fields (filled by the monitor)
  int unsigned out_router;        // which router's Eject port delivered it
  bit          backpressured;

  `uvm_object_utils(floonoc_mesh_flit_item)

  // Both endpoints are plain router indices, so the whole legality rule is
  // two range bounds and one inequality — deliberately solver-trivial.
  // Modeling the destination as an index rather than as (dst_x, dst_y) also
  // keeps router_idx()'s modulo/divide out of the constraint block.
  constraint c_legal_route {
    src_router < NumRouters;
    dst_router < NumRouters;
    dst_router != src_router;
  }

  function new(string name = "floonoc_mesh_flit_item");
    super.new(name);
  endfunction

  function int unsigned src_x(); return router_x(src_router); endfunction
  function int unsigned src_y(); return router_y(src_router); endfunction
  function int unsigned dst_x(); return router_x(dst_router); endfunction
  function int unsigned dst_y(); return router_y(dst_router); endfunction

  function xy_id_t dst_id();
    xy_id_t id;
    id.x       = x_bits_t'(router_x(dst_router));
    id.y       = y_bits_t'(router_y(dst_router));
    id.port_id = '0;
    return id;
  endfunction

  // The source router travels with the flit so the OUTPUT-side monitor can
  // recover it: it only sees rif.data_out[r], and the scoreboard keys its
  // expectation FIFOs on (src_router, dst_router). This is safe because
  // floo_route_select.sv rewrites hdr.dst_id ONLY under SourceRouting
  // (line 96); under XYRouting the header passes through every hop
  // unmodified (line 190, channel_o = channel_i), and hdr.src_id is read
  // only on the multicast path (floo_route_xymask.sv), which is inert here
  // (collective_op == Unicast, EnCollective off).
  function xy_id_t src_id();
    xy_id_t id;
    id.x       = x_bits_t'(router_x(src_router));
    id.y       = y_bits_t'(router_y(src_router));
    id.port_id = '0;
    return id;
  endfunction

  // Expected exit router. Under XY routing a flit ejects exactly at its
  // destination router, so this is dst_router by definition — the real
  // content of check R1 is that the DUT agrees.
  function int unsigned exp_out_router();
    return dst_router;
  endfunction

  // Hop count, from the package's multi-hop routing model. Coverage signal
  // only: floonoc_mesh_if exposes Eject endpoints, not the path taken, so
  // the scoreboard cannot and does not check intermediate routers.
  function int unsigned exp_hops();
    int unsigned path[$];
    exp_path(router_x(src_router), router_y(src_router), dst_id(), path);
    return path.size() - 1;
  endfunction

  // Build the wire-level flit.
  function flit_t as_flit();
    flit_t f;
    f            = '0;
    f.hdr.dst_id = dst_id();
    f.hdr.src_id = src_id();
    f.hdr.last   = 1'b1;
    f.payload    = payload;
    return f;
  endfunction

  // Decode an observed flit. `router` is the physical router whose Eject
  // port this was seen on.
  function void from_flit(flit_t f, int unsigned router, bit is_output, bit bp);
    dst_router    = router_idx(32'(f.hdr.dst_id.x), 32'(f.hdr.dst_id.y));
    payload       = f.payload;
    backpressured = bp;
    if (is_output) begin
      out_router = router;
      src_router = router_idx(32'(f.hdr.src_id.x), 32'(f.hdr.src_id.y));
    end else begin
      src_router = router;  // trust the physical port on the input side
    end
  endfunction

  virtual function string convert2string();
    return $sformatf("src=R%0d(%0d,%0d) dst=R%0d(%0d,%0d) hops=%0d payload=0x%016h%s",
                     src_router, router_x(src_router), router_y(src_router),
                     dst_router, router_x(dst_router), router_y(dst_router),
                     exp_hops(), payload,
                     backpressured ? " [bp]" : "");
  endfunction

endclass : floonoc_mesh_flit_item
