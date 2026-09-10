// -----------------------------------------------------------------------------
// Shared (non-UVM) types for the FlooNoC 2x2 mesh smoke test.
// Parallel to floo_tb_types_pkg.sv (the single-router bench's package), not
// a modification of it: the mesh bench is a new, independent top-level, so
// nothing here is shared with or can regress `main`'s single-router bench.
//
// Builds the concrete flit/header/ID types from FlooNoC's own typedef
// macros so the TB and the DUT agree on the wire format by construction —
// same construction as floo_tb_types_pkg.sv, but parameterized by mesh
// dimensions instead of a single fixed router position.
// -----------------------------------------------------------------------------
`include "floo_noc/typedef.svh"
`include "dut_config_mesh.svh"

package floo_tb_mesh_types_pkg;

  import floo_pkg::*;

  localparam int unsigned MeshX        = `FLOO_VERIF_MESH_X;
  localparam int unsigned MeshY        = `FLOO_VERIF_MESH_Y;
  localparam int unsigned NumRouters   = MeshX * MeshY;
  localparam int unsigned NumPorts     = `FLOO_VERIF_MESH_NUM_PORTS;
  localparam int unsigned FlitDataW    = `FLOO_VERIF_MESH_FLIT_DATA_W;
  localparam int unsigned InFifoDepth  = `FLOO_VERIF_MESH_IN_FIFO_DEPTH;
  localparam int unsigned OutFifoDepth = `FLOO_VERIF_MESH_OUT_FIFO_DEPTH;

  // Longest possible route in a mesh under dimension-order XY routing:
  // (MeshX-1) X hops plus (MeshY-1) Y hops. Used by later tasks for the
  // drain budget and the hop-count coverage bins, so neither has to
  // hardcode "2x2".
  localparam int unsigned MeshDiameter = MeshX + MeshY - 2;

  // Elaboration-time guard: the mesh UVM layer claims to be generic over
  // mesh shape, and that only holds if the coordinate widths can actually
  // represent the mesh. Nothing else enforces this — config/dut_config_mesh.svh
  // sets `FLOO_VERIF_MESH_X_BITS`/`_Y_BITS` BY HAND, independently of
  // `_MESH_X`/`_MESH_Y`, so editing one without the other silently truncates
  // every `x_bits_t'(...)`/`y_bits_t'(...)` cast below — measured case:
  // MeshX=3 with X_BITS=1 sends router 2 and router 5 to the wrong
  // destination, with no build error.
  //
  // `$error` inside a constant function, called from a localparam
  // initializer, fails Verilator during "function constification" —
  // elaboration, before any simulation event — under both --lint-only and a
  // full --binary build; verified empirically both ways (a too-small
  // X_BITS aborts `make lint-mesh-uvm` and `make build-mesh` with this
  // function's message, restoring the correct value passes again).
  // Considered and rejected: a plain `initial`/`$fatal` guard — packages
  // cannot contain `initial` blocks at all (LRM package_item), and even
  // hoisted into a module it would only fire at simulation time, after
  // `lint-mesh`/`lint-mesh-uvm` had already reported PASS.
  function automatic bit mesh_coord_width_guard();
    if (!((2 ** `FLOO_VERIF_MESH_X_BITS) >= MeshX)) begin
      $error("floo_tb_mesh_types_pkg: FLOO_VERIF_MESH_X_BITS=%0d cannot represent MeshX=%0d (2**X_BITS=%0d < MeshX)",
             `FLOO_VERIF_MESH_X_BITS, MeshX, 2 ** `FLOO_VERIF_MESH_X_BITS);
    end
    if (!((2 ** `FLOO_VERIF_MESH_Y_BITS) >= MeshY)) begin
      $error("floo_tb_mesh_types_pkg: FLOO_VERIF_MESH_Y_BITS=%0d cannot represent MeshY=%0d (2**Y_BITS=%0d < MeshY)",
             `FLOO_VERIF_MESH_Y_BITS, MeshY, 2 ** `FLOO_VERIF_MESH_Y_BITS);
    end
    return 1'b0;
  endfunction

  localparam bit MeshCoordWidthGuard = mesh_coord_width_guard();

  typedef logic [`FLOO_VERIF_MESH_X_BITS-1:0]       x_bits_t;
  typedef logic [`FLOO_VERIF_MESH_Y_BITS-1:0]       y_bits_t;
  typedef logic [`FLOO_VERIF_MESH_PORT_ID_BITS-1:0] port_id_t;
  typedef logic [FlitDataW-1:0]                     payload_t;

  // Concrete DUT types from FlooNoC's own macros (hw/include/floo_noc/typedef.svh)
  `FLOO_TYPEDEF_XY_NODE_ID_T(xy_id_t, x_bits_t, y_bits_t, port_id_t)
  `FLOO_TYPEDEF_HDR_T(hdr_t, xy_id_t, xy_id_t, logic, logic)
  `FLOO_TYPEDEF_GENERIC_FLIT_T(req, hdr_t, payload_t)

  typedef floo_req_generic_flit_t flit_t;

  // Router index <-> (x,y) coordinate. Row-major: router r sits at
  // (r % MeshX, r / MeshX). Matches the instantiation order in tb_top_mesh.
  function automatic int unsigned router_x(int unsigned r);
    return r % MeshX;
  endfunction

  function automatic int unsigned router_y(int unsigned r);
    return r / MeshX;
  endfunction

  function automatic int unsigned router_idx(int unsigned x, int unsigned y);
    return y * MeshX + x;
  endfunction

  // Mesh-wiring helpers for tb_top_mesh's inter-router generate block.
  // North/South and East/West are always opposite ends of the same
  // physical link (see floo_pkg.sv: North=0, East=1, South=2, West=3).
  function automatic route_direction_e opposite_dir(route_direction_e d);
    case (d)
      North: return South;
      South: return North;
      East:  return West;
      West:  return East;
      default: return Eject; // unreachable for N/E/S/W callers
    endcase
  endfunction

  function automatic bit has_neighbor(int unsigned r, route_direction_e dir);
    int unsigned x, y;
    x = router_x(r);
    y = router_y(r);
    case (dir)
      North: return y + 1 < MeshY;
      South: return y > 0;
      East:  return x + 1 < MeshX;
      West:  return x > 0;
      default: return 1'b0; // Eject has no mesh neighbor
    endcase
  endfunction

  // Caller must check has_neighbor(r, dir) first — a boundary port has no
  // valid neighbor index.
  function automatic int unsigned neighbor_idx(int unsigned r, route_direction_e dir);
    int unsigned x, y;
    x = router_x(r);
    y = router_y(r);
    case (dir)
      North: return router_idx(x, y + 1);
      South: return router_idx(x, y - 1);
      East:  return router_idx(x + 1, y);
      West:  return router_idx(x - 1, y);
      default: return r; // unreachable for N/E/S/W callers
    endcase
  endfunction

  // Reference model of the DUT's dimension-order (X-then-Y) XY routing rule,
  // ONE HOP at a time — mirrors floo_tb_types_pkg.exp_out_port, generalized
  // off a per-call current position instead of a single fixed RouterX/RouterY.
  // Source: hw/floo_route_select.sv (gen_xy_routing) and the direction enum
  // in hw/floo_pkg.sv (North=0, East=1, South=2, West=3, Eject=4).
  function automatic route_direction_e exp_out_port_at(
      int unsigned cur_x, int unsigned cur_y, xy_id_t dst);
    if (32'(dst.x) == cur_x && 32'(dst.y) == cur_y) begin
      return Eject;
    end else if (32'(dst.x) != cur_x) begin
      return (32'(dst.x) < cur_x) ? West : East;
    end else begin
      return (32'(dst.y) < cur_y) ? South : North;
    end
  endfunction

  // Full expected path for a flit entering the mesh at router (src_x,src_y)
  // and destined for `dst`: the ordered list of router indices it must
  // traverse, ending at the router that ejects it. Used by the scoreboard
  // to predict which Eject port a flit will surface on and how many hops
  // it should take — a real multi-hop model, unlike the single-router
  // bench's one-shot exp_out_port.
  function automatic void exp_path(
      input  int unsigned src_x, input int unsigned src_y, input xy_id_t dst,
      output int unsigned path[$]);
    int unsigned cx, cy;
    route_direction_e dir;
    cx = src_x;
    cy = src_y;
    path.delete();
    path.push_back(router_idx(cx, cy));
    forever begin
      dir = exp_out_port_at(cx, cy, dst);
      if (dir == Eject) return;
      case (dir)
        North: cy++;
        South: cy--;
        East:  cx++;
        West:  cx--;
        default: ; // unreachable
      endcase
      path.push_back(router_idx(cx, cy));
    end
  endfunction

  function automatic string dir_name(int unsigned p);
    case (p)
      32'(North): return "North";
      32'(East):  return "East";
      32'(South): return "South";
      32'(West):  return "West";
      32'(Eject): return "Eject";
      default:    return $sformatf("port%0d", p);
    endcase
  endfunction

endpackage : floo_tb_mesh_types_pkg
