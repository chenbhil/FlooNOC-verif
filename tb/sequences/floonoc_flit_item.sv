// -----------------------------------------------------------------------------
// Smallest meaningful router transaction: one single-flit packet
// (hdr.last == 1, so the wormhole route lock opens and closes per flit;
// see docs/assumptions.md A2).
//
// The legality constraints are derived from documented DUT behavior
// (docs/dut_scope.md "Legal traffic"): with NoLoopback=1 and XYRouteOpt=1
// (both floo_router defaults) certain input-port/destination pairs have
// their crossbar connection tied off, so driving them would deadlock and
// violate the DUT's own XYDirectionNotAllowed/NoLoopback assertions.
// -----------------------------------------------------------------------------
class floonoc_flit_item extends uvm_sequence_item;

  // Stimulus fields
  rand int unsigned            src_port;
  rand bit [`FLOO_VERIF_X_BITS-1:0] dst_x;
  rand bit [`FLOO_VERIF_Y_BITS-1:0] dst_y;
  rand payload_t               payload;

  // Observation fields (filled by the monitor)
  int unsigned out_port;
  bit          backpressured;

  `uvm_object_utils(floonoc_flit_item)

  // Legal-traffic constraints. RouterX/RouterY = (1,1); direction indices
  // from floo_pkg: North=0, East=1, South=2, West=3, Eject=4.
  //  - src North(0): X must already be resolved (XYRouteOpt forbids N->E/W)
  //    and dst may not route back North (NoLoopback) => x==1 && y<=1
  //  - src East(1):  must not route back East => dst_x <= 1
  //  - src South(2): x resolved, not back South => x==1 && y>=1
  //  - src West(3):  must not route back West => dst_x >= 1
  //  - src Eject(4): must not eject at this router => dst != (1,1)
  constraint c_legal_route {
    src_port < NumPorts;
    (src_port == 0) -> (32'(dst_x) == RouterX && 32'(dst_y) <= RouterY);
    (src_port == 1) -> (32'(dst_x) <= RouterX);
    (src_port == 2) -> (32'(dst_x) == RouterX && 32'(dst_y) >= RouterY);
    (src_port == 3) -> (32'(dst_x) >= RouterX);
    (src_port == 4) -> !(32'(dst_x) == RouterX && 32'(dst_y) == RouterY);
  }

  function new(string name = "floonoc_flit_item");
    super.new(name);
  endfunction

  // Hand-written field automation, not `uvm_object_utils_begin/`uvm_field_int
  // (same reasoning as floonoc_mesh_flit_item: on this Verilator 5.052 /
  // UVM 1800.2-2017-1.0 combination the macro form trips WIDTHEXPAND/
  // WIDTHTRUNC on every narrow field). Without these, clone() would copy
  // NOTHING: the class has only `uvm_object_utils, so a clone would arrive
  // with src_port=0, dst=(0,0), payload=0 — and the driver's sent_ap
  // publishes clones, so every expectation would silently be wrong.
  //
  // do_compare checks only the flit's IDENTITY (src_port, dst_x, dst_y,
  // payload). out_port and backpressured are OBSERVATION fields the monitor
  // fills in; an expected item never has them set the way an observed one
  // does. do_copy still copies everything — clone() is a full snapshot.
  virtual function void do_copy(uvm_object rhs);
    floonoc_flit_item rhs_;
    if (!$cast(rhs_, rhs)) begin
      `uvm_fatal("DO_COPY", "floonoc_flit_item::do_copy: $cast of rhs failed")
    end
    super.do_copy(rhs);
    src_port      = rhs_.src_port;
    dst_x         = rhs_.dst_x;
    dst_y         = rhs_.dst_y;
    payload       = rhs_.payload;
    out_port      = rhs_.out_port;
    backpressured = rhs_.backpressured;
  endfunction

  virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
    floonoc_flit_item rhs_;
    bit result;
    if (!$cast(rhs_, rhs)) return 0;
    result = super.do_compare(rhs, comparer);
    result &= (src_port == rhs_.src_port);
    result &= (dst_x    == rhs_.dst_x);
    result &= (dst_y    == rhs_.dst_y);
    result &= (payload  == rhs_.payload);
    return result;
  endfunction

  function xy_id_t dst_id();
    xy_id_t id;
    id.x       = dst_x;
    id.y       = dst_y;
    id.port_id = '0;
    return id;
  endfunction

  // Expected output port per the documented XY routing rule
  function int unsigned exp_out();
    return 32'(exp_out_port(dst_id()));
  endfunction

  // Build the wire-level flit. The source port index is encoded in
  // hdr.src_id (opaque to the router's routing logic at this scope).
  function flit_t as_flit();
    flit_t f;
    f              = '0;
    f.hdr.dst_id   = dst_id();
    f.hdr.src_id   = xy_id_t'($bits(xy_id_t)'(src_port));
    f.hdr.last     = 1'b1;
    f.payload      = payload;
    return f;
  endfunction

  function void from_flit(flit_t f, int unsigned port, bit is_output, bit bp);
    dst_x         = f.hdr.dst_id.x;
    dst_y         = f.hdr.dst_id.y;
    payload       = f.payload;
    src_port      = 32'($bits(xy_id_t)'(f.hdr.src_id));
    backpressured = bp;
    if (is_output) out_port = port;
    else           src_port = port; // trust the physical port on the input side
  endfunction

  virtual function string convert2string();
    return $sformatf("src=%0d(%s) dst=(%0d,%0d) exp_out=%0d(%s) payload=0x%016h%s",
                     src_port, dir_name(src_port), dst_x, dst_y,
                     exp_out(), dir_name(exp_out()), payload,
                     backpressured ? " [bp]" : "");
  endfunction

endclass : floonoc_flit_item
