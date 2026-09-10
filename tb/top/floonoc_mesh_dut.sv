// -----------------------------------------------------------------------------
// The mesh DUT proper: an MeshX x MeshY array of floo_router instances with
// their North/East/South/West ports wired to each other (or tied off at a
// boundary), exposing only the per-router Eject port as a flat, TB-facing
// bus indexed by router number (row-major, see floo_tb_mesh_types_pkg).
//
// Extracted out of tb_top_mesh so the mesh can be elaborated and linted with
// no testbench and no UVM attached (tb/top/lint_wrapper_mesh.sv), and so
// tb_top_mesh is a pure TB shell. No behavioral change: the generate bodies
// below are the Phase-1 wiring verbatim.
//
// Wiring: every router uses the same 5-port floo_router as the single-router
// bench (NumRoutes=NumInput=NumOutput=5, ports [North,East,South,West,Eject]
// per floo_pkg.sv). The tie-off convention (unconnected input: valid/data='0;
// unconnected output: ready/credit='0) matches floogen's own generated mesh
// router template (floo_axi_router.sv.mako) so hand-wired and floogen-
// generated meshes agree on boundary behavior.
// -----------------------------------------------------------------------------
module floonoc_mesh_dut
  import floo_pkg::*;
  import floo_tb_mesh_types_pkg::*;
(
  input  logic                   clk_i,
  input  logic                   rst_ni,
  // TB -> router Eject input, one per router
  input  logic  [NumRouters-1:0] valid_i,
  output logic  [NumRouters-1:0] ready_o,
  input  flit_t [NumRouters-1:0] data_i,
  // router Eject output -> TB, one per router
  output logic  [NumRouters-1:0] valid_o,
  input  logic  [NumRouters-1:0] ready_i,
  output flit_t [NumRouters-1:0] data_o
);

  // Per-router [port][virt_channel] arrays (NumVirtChannels == 1), same
  // shape as the single-router bench, one set per router.
  logic  [NumRouters-1:0][NumPorts-1:0][0:0] dut_valid_in, dut_ready_in;
  logic  [NumRouters-1:0][NumPorts-1:0][0:0] dut_valid_out, dut_ready_out;
  flit_t [NumRouters-1:0][NumPorts-1:0][0:0] dut_data_in, dut_data_out;

  // Eject port (index 4) <-> the flat TB-facing bus, one per router.
  for (genvar r = 0; r < NumRouters; r++) begin : gen_eject_map
    assign dut_valid_in[r][Eject][0]  = valid_i[r];
    assign ready_o[r]                 = dut_ready_in[r][Eject][0];
    assign dut_data_in[r][Eject][0]   = data_i[r];
    assign valid_o[r]                 = dut_valid_out[r][Eject][0];
    assign dut_ready_out[r][Eject][0] = ready_i[r];
    assign data_o[r]                  = dut_data_out[r][Eject][0];
  end

  // ---------------------------------------------------------------------------
  // Inter-router mesh wiring (North/East/South/West).
  //
  // For router r, direction dir, with neighbor n = neighbor_idx(r, dir) and
  // opp = opposite_dir(dir): the link between r and n is two independent
  // channels sharing the same port pair —
  //   r.valid_o[dir]/data_o[dir]  -> n.valid_i[opp]/data_i[opp], gated by
  //   n.ready_o[opp]              -> r.ready_i[dir]
  // Looping this over EVERY (r, dir) with a neighbor covers both directions
  // of every edge exactly once each — no signal is ever assigned twice.
  // ---------------------------------------------------------------------------
  for (genvar r = 0; r < NumRouters; r++) begin : gen_router_links
    for (genvar dp = 0; dp < 4; dp++) begin : gen_dir
      localparam route_direction_e Dir = route_direction_e'(dp);
      if (has_neighbor(r, Dir)) begin : gen_connected
        localparam int unsigned Nbr = neighbor_idx(r, Dir);
        localparam route_direction_e Opp = opposite_dir(Dir);
        // dut_ready_in[r] is router r's OWN ready_o output and must never be
        // assigned here. Only dut_ready_out (the router's ready_i INPUT)
        // needs external drive, fed by the neighbor's ready_o — the mirror
        // iteration (r'=Nbr, dir'=Opp) assigns dut_ready_out[r][Dir].
        assign dut_valid_in[r][Dir][0]    = dut_valid_out[Nbr][Opp][0];
        assign dut_data_in[r][Dir][0]     = dut_data_out[Nbr][Opp][0];
        assign dut_ready_out[Nbr][Opp][0] = dut_ready_in[r][Dir][0];
      end else begin : gen_boundary
        // No neighbor: nothing ever arrives (valid/data='0) and nothing
        // ever drains this output (ready_i='0).
        assign dut_valid_in[r][Dir][0]  = 1'b0;
        assign dut_data_in[r][Dir][0]   = '0;
        assign dut_ready_out[r][Dir][0] = 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Router array
  // ---------------------------------------------------------------------------
  for (genvar r = 0; r < NumRouters; r++) begin : gen_routers
    localparam xy_id_t RouterId = '{
      x:       x_bits_t'(router_x(r)),
      y:       y_bits_t'(router_y(r)),
      port_id: '0
    };

    floo_router #(
      .NumRoutes       ( NumPorts       ),
      .NumVirtChannels ( 1              ),
      .NumPhysChannels ( 1              ),
      .flit_t          ( flit_t         ),
      .hdr_t           ( hdr_t          ),
      .InFifoDepth     ( InFifoDepth    ),
      .OutFifoDepth    ( OutFifoDepth   ),
      .RouteAlgo       ( XYRouting      ),
      .IdWidth         ( $bits(xy_id_t) ),
      .id_t            ( xy_id_t        )
    ) i_dut (
      .clk_i          ( clk_i             ),
      .rst_ni         ( rst_ni            ),
      .test_enable_i  ( 1'b0              ),
      .xy_id_i        ( RouterId          ),
      .id_route_map_i ( '0                ),  // unused for XYRouting
      .valid_i        ( dut_valid_in[r]   ),
      .ready_o        ( dut_ready_in[r]   ),
      .data_i         ( dut_data_in[r]    ),
      .credit_o       (                   ),  // VcNaive: constant, unused
      .valid_o        ( dut_valid_out[r]  ),
      .ready_i        ( dut_ready_out[r]  ),
      .data_o         ( dut_data_out[r]   ),
      .credit_i       ( '0                ),
      .offload_req_o  (                   ),  // collectives disabled
      .offload_rsp_i  ( '0                )
    );
  end

endmodule : floonoc_mesh_dut
