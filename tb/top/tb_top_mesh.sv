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
  // Interface (Eject ports only) + mesh DUT
  //
  // The mesh RTL itself lives in tb/top/floonoc_mesh_dut.sv so it can be
  // linted with no TB attached (make lint-mesh). Local nets sit between the
  // DUT's outputs and the interface variables, matching tb_top.sv's
  // gen_if_map pattern.
  // ---------------------------------------------------------------------------
  floonoc_mesh_if rif (.clk(clk), .rst_n(rst_n));

  logic  [NumRouters-1:0] mesh_ready_in;
  logic  [NumRouters-1:0] mesh_valid_out;
  flit_t [NumRouters-1:0] mesh_data_out;

  floonoc_mesh_dut i_mesh (
    .clk_i   ( clk              ),
    .rst_ni  ( rst_n            ),
    .valid_i ( rif.valid_in     ),
    .ready_o ( mesh_ready_in    ),
    .data_i  ( rif.data_in      ),
    .valid_o ( mesh_valid_out   ),
    .ready_i ( rif.ready_out    ),
    .data_o  ( mesh_data_out    )
  );

  assign rif.ready_in  = mesh_ready_in;
  assign rif.valid_out = mesh_valid_out;
  assign rif.data_out  = mesh_data_out;

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
  //
  // MUST BE REMOVED when the mesh UVM env lands (Task 8): the `initial`
  // block below procedurally drives `rif.ready_out`, `rif.valid_in` and
  // `rif.data_in` directly. A UVM driver will drive those same interface
  // variables — leaving this block in alongside it is a silent last-write-
  // wins multiple-driver race, with no compile or runtime diagnostic. The
  // same removal applies to the rest of this Phase-1 scaffolding below —
  // the `valid_out_seen`/`smoke_ok` sticky-flag state, the `gen_misroute_watch`
  // generate loop that drives it, and the smoke-check `initial` block that
  // reads it — all of which exist only to check this hand-driven flit and
  // become dead code once a UVM scoreboard takes over that job.
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
