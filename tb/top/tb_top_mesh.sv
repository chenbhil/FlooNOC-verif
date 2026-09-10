// -----------------------------------------------------------------------------
// Top-level testbench: clock/reset generation, DUT (2x2 mesh of floo_router)
// instance, purpose-built interface, config_db publication of the virtual
// interface, run_test() and a global watchdog.
//
// New, independent top-level — does not touch tb_top.sv (the single-router
// bench) or anything it depends on (floo_tb_types_pkg, dut_config.svh,
// floonoc_router_if, floonoc_router_sva all stay single-router-only; this
// file uses their mesh-scoped counterparts exclusively). The two benches
// are never compiled into the same Verilator invocation either — see
// TB_SOURCES vs TB_MESH_SOURCES in scripts/run_verilator.sh.
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
// The mesh RTL itself lives in tb/top/floonoc_mesh_dut.sv; this file is the
// TB shell: clock/reset, the interface, config_db publication, run_test(),
// waves hook and the last-resort watchdog. It is a new, independent
// top-level — nothing here touches tb_top.sv or anything it depends on.
// -----------------------------------------------------------------------------

module tb_top_mesh;

  import uvm_pkg::*;
  import floo_pkg::*;
  import floo_tb_mesh_types_pkg::*;
  import floonoc_mesh_uvm_pkg::*;
  // Deliberately no `import floonoc_uvm_pkg::*` (or floo_tb_types_pkg) here.
  // The macro-collision mechanism that used to be the reason is gone — the
  // mesh config macros are FLOO_VERIF_MESH_*-namespaced since Task 2 and
  // collide with nothing — but the caution still holds for a different
  // reason: floo_tb_types_pkg and floo_tb_mesh_types_pkg export the same
  // symbol names (NumPorts, flit_t, hdr_t, dir_name, ...), so wildcard-
  // importing both into one scope is a compile-time ambiguity error on the
  // first unqualified use. Loud and immediate rather than silent, but still
  // not something to do.

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
  // UVM entry
  //
  // (The Phase-1 hand-rolled directed smoke check that used to live here was
  // temporary scaffolding for the RTL wiring checkpoint, never a regression
  // test. Its job is fully subsumed by the directed phase of
  // floonoc_mesh_smoke_seq, which exercises every link in both directions and
  // both mesh diagonals, with a scoreboard behind it.)
  // ---------------------------------------------------------------------------
  initial begin
    uvm_config_db#(virtual floonoc_mesh_if)::set(null, "*", "vif", rif);
    run_test();
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
