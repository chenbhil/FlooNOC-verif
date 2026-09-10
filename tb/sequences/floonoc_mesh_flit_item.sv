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
  // 1 iff from_flit() was called with is_output=1. out_router alone cannot
  // tell an input-side item (where it is never set) from a real observation
  // of router 0 — router 0 is a legal index at any mesh size — so this is
  // the explicit "was this filled in" flag convert2string() guards on
  // (FIX 3/FIX 2). Defaults to 0, which is correct: a freshly-built item is
  // not an output observation until from_flit() says otherwise.
  bit          is_output_obs;
  // Set by from_flit() when a decoded wire field lands outside the mesh.
  // from_flit() is the single boundary where untrusted wire data becomes a
  // TB router index, so it is the only place that can tell a malformed
  // header from a real one; every consumer downstream has already lost that
  // information. The coordinate widths are not required to be exact
  // (FLOO_VERIF_MESH_X_BITS is independent of FLOO_VERIF_MESH_X), so at a
  // non-power-of-two mesh some wire patterns legitimately decode out of
  // range. Flagged, never silently used: the scoreboard indexes its
  // expectation FIFOs with these values.
  bit          hdr_malformed;
  string       hdr_malformed_why;

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

  // Hand-written field automation, not `uvm_object_utils_begin/`uvm_field_int:
  // probed separately against this Verilator 5.052 / UVM 1800.2-2017-1.0
  // combination and the macro form produced 107 WIDTHEXPAND/WIDTHTRUNC
  // warnings (the generic field-automation storage is 4096 bits wide;
  // narrow fields like `backpressured` trip a width check on every
  // compare/copy/print/record call the macro expands to). Rather than force
  // it, or waive a warning class wholesale project-wide, do_copy/do_compare
  // are written out by hand — more verbose, but portable.
  //
  // do_compare deliberately checks only src_router, dst_router and payload —
  // a flit's IDENTITY. out_router, backpressured and is_output_obs are
  // OBSERVATION fields the monitor fills in after the fact; an expected item
  // built by the sequence never has them set the way an observed item does,
  // so folding them into compare() would fail every legitimate
  // expected-vs-observed match for reasons that are not integrity errors.
  // do_copy still copies everything, including the observation fields —
  // clone() is a full snapshot, not an identity-only one.
  virtual function void do_copy(uvm_object rhs);
    floonoc_mesh_flit_item rhs_;
    if (!$cast(rhs_, rhs)) begin
      `uvm_fatal("DO_COPY", "floonoc_mesh_flit_item::do_copy: $cast of rhs failed")
    end
    super.do_copy(rhs);
    src_router    = rhs_.src_router;
    dst_router    = rhs_.dst_router;
    payload       = rhs_.payload;
    out_router    = rhs_.out_router;
    backpressured = rhs_.backpressured;
    is_output_obs = rhs_.is_output_obs;
    hdr_malformed     = rhs_.hdr_malformed;
    hdr_malformed_why = rhs_.hdr_malformed_why;
  endfunction

  virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
    floonoc_mesh_flit_item rhs_;
    bit result;
    if (!$cast(rhs_, rhs)) return 0;
    result = super.do_compare(rhs, comparer);
    result &= (src_router == rhs_.src_router);
    result &= (dst_router == rhs_.dst_router);
    result &= (payload    == rhs_.payload);
    return result;
  endfunction

  function int unsigned src_x(); return router_x(src_router); endfunction
  function int unsigned src_y(); return router_y(src_router); endfunction
  function int unsigned dst_x(); return router_x(dst_router); endfunction
  function int unsigned dst_y(); return router_y(dst_router); endfunction

  function xy_id_t dst_id();
    xy_id_t id;
    id.x       = x_bits_t'(dst_x());
    id.y       = y_bits_t'(dst_y());
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
    id.x       = x_bits_t'(src_x());
    id.y       = y_bits_t'(src_y());
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
    is_output_obs = is_output;
    if (is_output) begin
      out_router = router;
      src_router = router_idx(32'(f.hdr.src_id.x), 32'(f.hdr.src_id.y));
    end else begin
      src_router = router;  // trust the physical port on the input side
    end
    // Range-check the decode at the boundary, before anyone indexes with it.
    hdr_malformed     = 1'b0;
    hdr_malformed_why = "";
    if (dst_router >= NumRouters) begin
      hdr_malformed     = 1'b1;
      hdr_malformed_why = $sformatf(
          "hdr.dst_id(x=%0d,y=%0d) decodes to router %0d, outside a %0d-router mesh",
          32'(f.hdr.dst_id.x), 32'(f.hdr.dst_id.y), dst_router, NumRouters);
    end else if (is_output && src_router >= NumRouters) begin
      hdr_malformed     = 1'b1;
      hdr_malformed_why = $sformatf(
          "hdr.src_id(x=%0d,y=%0d) decodes to router %0d, outside a %0d-router mesh",
          32'(f.hdr.src_id.x), 32'(f.hdr.src_id.y), src_router, NumRouters);
    end
  endfunction

  virtual function string convert2string();
    // out_router is only meaningful on an output-side observation (FIX 3);
    // on an input-side item, or on an item nobody has run through
    // from_flit() yet, print "out=-" rather than a router index that would
    // read as a real (and misleading, since 0 is a legal router) observation.
    string out_field;
    string bad_field;
    if (is_output_obs) out_field = $sformatf(" out=R%0d", out_router);
    else                out_field = " out=-";
    // A malformed decode is worth saying out loud wherever the item is
    // printed, not only where the scoreboard happens to check the flag.
    if (hdr_malformed) bad_field = $sformatf(" MALFORMED(%s)", hdr_malformed_why);
    else               bad_field = "";
    // §11.4.11: padding a conditional's false arm only bites when BOTH arms
    // are bare string literals; casting each arm to `string` sidesteps it
    // (confirmed by hexdump: unfixed, the false arm was 5x 0x20).
    return $sformatf("src=R%0d(%0d,%0d) dst=R%0d(%0d,%0d) hops=%0d payload=0x%016h%s%s%s",
                     src_router, src_x(), src_y(),
                     dst_router, dst_x(), dst_y(),
                     exp_hops(), payload, out_field,
                     backpressured ? string'(" [bp]") : string'(""),
                     bad_field);
  endfunction

endclass : floonoc_mesh_flit_item
