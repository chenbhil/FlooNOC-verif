// -----------------------------------------------------------------------------
// Top-level testbench: clock/reset generation, DUT (2x2 mesh of floo_router)
// instance, purpose-built interface, config_db publication of the virtual
// interface, run_test() and a global watchdog.
//
// New, independent top-level — does not touch tb_top.sv (the single-router
// bench) or anything it depends on (floo_tb_types_pkg, dut_config.svh,
// floonoc_router_if, floonoc_router_sva all stay single-router-only; this
// file uses their mesh-scoped counterparts exclusively, to avoid a
// `define macro collision between dut_config.svh and dut_config_mesh.svh
// if both ever ended up in the same compile unit).
//
// Wiring: every router uses the same 5-port floo_router as the single-router
// bench (NumRoutes=NumInput=NumOutput=5, ports [North,East,South,West,Eject]
// per floo_pkg.sv). Only the Eject port is TB-facing; North/East/South/West
// are either wired to the adjacent router's opposite port, or tied off at a
// mesh boundary. The tie-off convention (unconnected input: valid/data='0;
// unconnected output: ready/credit='0) matches floogen's own generated
// mesh router template (floo_axi_router.sv.mako) so hand-wired and
// floogen-generated meshes agree on boundary behavior.
//
// Deliberately NOT included in this first checkpoint: floonoc_router_sva
// per-router instances (it hard-imports floo_tb_types_pkg, which would
// reintroduce the exact macro-collision risk this file exists to avoid —
// a mesh-scoped equivalent is a follow-up, not required to validate wiring).
// -----------------------------------------------------------------------------

module tb_top_mesh;

  import floo_pkg::*;
  import floo_tb_mesh_types_pkg::*;
  // Deliberately no `import floonoc_uvm_pkg::*` here: that package
  // `` `include``s dut_config.svh directly and imports floo_tb_types_pkg —
  // both single-router-only. Pulling it into this compile unit would
  // redefine dut_config_mesh.svh's macros (X_BITS, Y_BITS, ...) with the
  // single-router bench's values via plain `define collision, silently
  // corrupting one or the other depending on include order. A mesh UVM
  // env (its own package, driving floonoc_mesh_if) is a follow-up; this
  // checkpoint has no UVM layer yet — see the module header.

  // ---------------------------------------------------------------------------
  // Clock / reset
  // ---------------------------------------------------------------------------
  logic clk = 1'b0;
  logic rst_n = 1'b0;

  always #5ns clk = ~clk;   // 100 MHz

  initial begin
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Interface (Eject ports only) + per-router DUT port arrays
  // ---------------------------------------------------------------------------
  floonoc_mesh_if rif (.clk(clk), .rst_n(rst_n));

  // Per-router [port][virt_channel] arrays (NumVirtChannels == 1), same
  // shape as the single-router bench, one set per router.
  logic  [NumRouters-1:0][NumPorts-1:0][0:0] dut_valid_in, dut_ready_in;
  logic  [NumRouters-1:0][NumPorts-1:0][0:0] dut_valid_out, dut_ready_out;
  flit_t [NumRouters-1:0][NumPorts-1:0][0:0] dut_data_in, dut_data_out;

  // Eject port (index 4) <-> the mesh interface, one per router.
  for (genvar r = 0; r < NumRouters; r++) begin : gen_eject_map
    assign dut_valid_in[r][Eject][0]  = rif.valid_in[r];
    assign rif.ready_in[r]            = dut_ready_in[r][Eject][0];
    assign dut_data_in[r][Eject][0]   = rif.data_in[r];
    assign rif.valid_out[r]           = dut_valid_out[r][Eject][0];
    assign dut_ready_out[r][Eject][0] = rif.ready_out[r];
    assign rif.data_out[r]            = dut_data_out[r][Eject][0];
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
  // of every edge exactly once each (when r=A,dir=North assigns A's inputs
  // and B's ready_i; the symmetric r=B,dir=South assigns B's inputs and A's
  // ready_i) — no signal is ever assigned twice.
  //
  // A boundary port (no neighbor) ties its input side to '0 (nothing ever
  // arrives) and its ready_i to '0 (nothing ever drains it) — see the file
  // header for why this matches floogen's own convention.
  // ---------------------------------------------------------------------------
  for (genvar r = 0; r < NumRouters; r++) begin : gen_router_links
    for (genvar dp = 0; dp < 4; dp++) begin : gen_dir
      localparam route_direction_e Dir = route_direction_e'(dp);
      if (has_neighbor(r, Dir)) begin : gen_connected
        localparam int unsigned Nbr = neighbor_idx(r, Dir);
        localparam route_direction_e Opp = opposite_dir(Dir);
        // dut_ready_in[r] is router r's OWN ready_o output (see the
        // gen_eject_map / gen_routers port maps below) — it is driven by
        // r's own floo_router instance and must never be assigned here.
        // Only dut_ready_out (the router's ready_i INPUT) needs external
        // drive, fed by the neighbor's ready_o — the mirror-image
        // iteration (r'=Nbr, dir'=Opp) is what assigns dut_ready_out[r][Dir]
        // (from dut_ready_in[Nbr][Opp]), by the same symmetry that makes
        // this loop cover every edge exactly once from each side.
        assign dut_valid_in[r][Dir][0]   = dut_valid_out[Nbr][Opp][0];
        assign dut_data_in[r][Dir][0]    = dut_data_out[Nbr][Opp][0];
        assign dut_ready_out[Nbr][Opp][0] = dut_ready_in[r][Dir][0];
      end else begin : gen_boundary
        // No neighbor: nothing ever arrives (valid/data='0) and nothing
        // ever drains this output (ready_i='0) — matches floogen's own
        // mesh-router tie-off convention (floo_axi_router.sv.mako).
        // dut_ready_out (not dut_ready_in, which is r's own output) is the
        // signal that needs tying here.
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
      .NumRoutes       ( NumPorts     ),
      .NumVirtChannels ( 1            ),
      .NumPhysChannels ( 1            ),
      .flit_t          ( flit_t       ),
      .hdr_t           ( hdr_t        ),
      .InFifoDepth     ( InFifoDepth  ),
      .OutFifoDepth    ( OutFifoDepth ),
      .RouteAlgo       ( XYRouting    ),
      .IdWidth         ( $bits(xy_id_t) ),
      .id_t            ( xy_id_t      )
    ) i_dut (
      .clk_i          ( clk               ),
      .rst_ni         ( rst_n             ),
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

  // ---------------------------------------------------------------------------
  // No UVM entry yet — this checkpoint validates the RTL wiring only: a
  // single directed 2-hop flit driven by hand at router 0, checked for
  // (a) arriving at the CORRECT router's Eject port with the correct
  // payload and (b) never surfacing at either wrong router along the way.
  // This is temporary scaffolding for the wiring checkpoint, not a
  // regression test — a mesh UVM env (driver/monitor/scoreboard over
  // floonoc_mesh_if, its own package) is the next step, mirroring
  // floonoc_uvm_pkg but built against floo_tb_mesh_types_pkg's multi-hop
  // exp_path instead of the single-router exp_out_port.
  // ---------------------------------------------------------------------------
  // Sticky per-router "did this Eject port ever assert valid_out" flags —
  // simpler and safer than a fork/join_none per non-destination router.
  // The smoke check below reads these once at the end instead of racing
  // dynamic processes.
  // Sticky "did this Eject port ever assert valid_out" per router, for
  // EVERY router — the initial block below decides at runtime (plusargs)
  // which one was the intended destination, so the watch can't exclude one
  // at elaboration time like a single fixed-destination check could.
  bit valid_out_seen[NumRouters];
  bit smoke_ok; // module-scope, not a fork-local automatic: the fork below
                // writes it from a child process that must outlive nothing
  for (genvar r = 0; r < NumRouters; r++) begin : gen_misroute_watch
    always @(posedge clk) if (rif.valid_out[r]) valid_out_seen[r] <= 1'b1;
  end

  initial begin
    automatic flit_t f;
    automatic int unsigned src_router, dst_x, dst_y, dst_router;
    rif.ready_out = '1; // sink every Eject port immediately
    rif.valid_in  = '0;
    rif.data_in   = '0;
    foreach (valid_out_seen[r]) valid_out_seen[r] = 1'b0;

    // +src_router=<0..3> +dst_x=<0|1> +dst_y=<0|1>, default: router 0 (0,0)
    // to (1,1) = router 3, the longest path in a 2x2 mesh (2 hops: East
    // then North, or North then East depending on X-first ordering —
    // exp_path settles which). Overridable so the same binary can exercise
    // the reverse-direction links (South/West) without recompiling.
    src_router = 0;
    dst_x      = 1;
    dst_y      = 1;
    void'($value$plusargs("src_router=%0d", src_router));
    void'($value$plusargs("dst_x=%0d", dst_x));
    void'($value$plusargs("dst_y=%0d", dst_y));
    dst_router = router_idx(dst_x, dst_y);

    @(posedge rst_n);
    repeat (3) @(posedge clk);

    f            = '0;
    f.hdr.dst_id = '{x: x_bits_t'(dst_x), y: y_bits_t'(dst_y), port_id: '0};
    f.hdr.last   = 1'b1;
    f.payload    = payload_t'(64'hCAFE_D00D_0000_2A2A);

    @(negedge clk);
    rif.valid_in[src_router] = 1'b1;
    rif.data_in[src_router]  = f;
    wait (rif.ready_in[src_router] === 1'b1);
    @(negedge clk);
    rif.valid_in[src_router] = 1'b0;
    $display("[MESH-SMOKE] flit accepted at router %0d, expecting delivery at router %0d",
              src_router, dst_router);

    smoke_ok = 1'b0;
    fork
      begin
        wait (rif.valid_out[dst_router] === 1'b1);
        if (rif.data_out[dst_router].payload === f.payload) begin
          $display("[MESH-SMOKE] payload 0x%016h delivered at router %0d",
                    rif.data_out[dst_router].payload, dst_router);
          smoke_ok = 1'b1;
        end else begin
          $display("[MESH-SMOKE] FAIL: router %0d asserted valid_out with wrong payload 0x%016h",
                    dst_router, rif.data_out[dst_router].payload);
        end
      end
      #200ns;
    join_any
    disable fork;
    #20ns; // let a same-cycle misroute latch before the final check

    if (!smoke_ok) $display("[MESH-SMOKE] FAIL: flit never delivered within 200ns");
    foreach (valid_out_seen[r]) begin
      if (r != dst_router && valid_out_seen[r]) begin
        $display("[MESH-SMOKE] FAIL: unexpected valid_out at router %0d (expected only %0d)",
                  r, dst_router);
        smoke_ok = 1'b0;
      end
    end

    if (smoke_ok) $display("*** MESH-SMOKE PASSED ***");
    else           $display("*** MESH-SMOKE FAILED ***");
    $finish;
  end

  // ---------------------------------------------------------------------------
  // Waves: enable at runtime with +trace. The container format (FST or VCD)
  // is fixed at compile time (--trace-fst / --trace-vcd); +tracefile=<path>
  // selects the output file (default waves/tb_top_mesh.fst).
  // ---------------------------------------------------------------------------
  initial begin
    string tracefile;
    if ($test$plusargs("trace")) begin
      if (!$value$plusargs("tracefile=%s", tracefile)) begin
        tracefile = "waves/tb_top_mesh.fst";
      end
      $dumpfile(tracefile);
      $dumpvars(0, tb_top_mesh);
    end
  end

  // ---------------------------------------------------------------------------
  // Last-resort watchdog (UVM-level drain watchdog reports first)
  // ---------------------------------------------------------------------------
  initial begin
    #1ms;
    $display("[tb_top_mesh] FATAL: global watchdog expired");
    $fatal(1);
  end

endmodule : tb_top_mesh
