// -----------------------------------------------------------------------------
// DUT configuration for the FlooNoC mesh bench (2x2 by default).
// Separate from dut_config.svh (the single-router bench's config) by design:
// this bench is a new, independent top-level (tb_top_mesh) — `main`'s
// single-router bench is never touched by mesh work. See CLAUDE.md's
// "full mesh" plan for the rationale.
// -----------------------------------------------------------------------------
`ifndef FLOO_VERIF_DUT_CONFIG_MESH_SVH_
`define FLOO_VERIF_DUT_CONFIG_MESH_SVH_

// Every macro below is deliberately in the FLOO_VERIF_MESH_* namespace.
// dut_config.svh (the single-router bench) defines FLOO_VERIF_NUM_PORTS,
// FLOO_VERIF_X_BITS etc. with DIFFERENT values, under a different include
// guard, and config/verilator.f puts +incdir+config on every build — so
// identical names here would silently redefine each other in include order
// if the two benches ever met in one compile unit. Distinct names make that
// impossible instead of merely unlikely.

// Every value below is a DEFAULT: each macro is wrapped in `ifndef, so a
// +define+FLOO_VERIF_MESH_<NAME>=<value> on the Verilator command line
// overrides it. scripts/run_verilator.sh does that from the MESH_X, MESH_Y,
// MESH_IN_FIFO_DEPTH and MESH_OUT_FIFO_DEPTH environment variables
// (e.g. `make build-mesh MESH_X=5 MESH_Y=5`); with none set, the build is the
// 2x2 bench exactly as before.

// Mesh dimensions. 2x2 is the smallest topology that is actually a mesh
// (multi-hop routing exists) — deliberately smaller than FlooNoC's own
// floogen examples (which default to 4x4) so the hand-wired TB architecture
// can be proven out before scaling.
`ifndef FLOO_VERIF_MESH_X
`define FLOO_VERIF_MESH_X              2
`endif
`ifndef FLOO_VERIF_MESH_Y
`define FLOO_VERIF_MESH_Y              2
`endif

// Number of router ports (N, E, S, W, Eject) — same canonical router as the
// single-router bench; every router in the mesh uses all 5, with boundary
// ports tied off per floogen's own convention (floo_axi_router.sv.mako):
// unconnected inputs tie valid/data to '0, unconnected outputs tie
// ready/credit to '0.
`ifndef FLOO_VERIF_MESH_NUM_PORTS
`define FLOO_VERIF_MESH_NUM_PORTS      5
`endif

// Payload width of the generic flit (bits). Same as the single-router bench.
`ifndef FLOO_VERIF_MESH_FLIT_DATA_W
`define FLOO_VERIF_MESH_FLIT_DATA_W    64
`endif

// Coordinate bit widths, DERIVED from the dimensions by default:
// $clog2(dim), at least 1 bit (1 at 2x2, as before; 2 at 3x3/4x4; 3 at 5x5).
// Still overridable by hand; floo_tb_mesh_types_pkg's elaboration-time
// MeshCoordWidthGuard rejects a width that cannot represent the mesh.
`ifndef FLOO_VERIF_MESH_X_BITS
`define FLOO_VERIF_MESH_X_BITS ((`FLOO_VERIF_MESH_X > 1) ? $clog2(`FLOO_VERIF_MESH_X) : 1)
`endif
`ifndef FLOO_VERIF_MESH_Y_BITS
`define FLOO_VERIF_MESH_Y_BITS ((`FLOO_VERIF_MESH_Y > 1) ? $clog2(`FLOO_VERIF_MESH_Y) : 1)
`endif
`ifndef FLOO_VERIF_MESH_PORT_ID_BITS
`define FLOO_VERIF_MESH_PORT_ID_BITS   1
`endif

// FIFO depths (InFifoDepth > 0 required for wormhole input buffering) —
// same as the single-router bench.
`ifndef FLOO_VERIF_MESH_IN_FIFO_DEPTH
`define FLOO_VERIF_MESH_IN_FIFO_DEPTH  2
`endif
`ifndef FLOO_VERIF_MESH_OUT_FIFO_DEPTH
`define FLOO_VERIF_MESH_OUT_FIFO_DEPTH 2
`endif

`endif // FLOO_VERIF_DUT_CONFIG_MESH_SVH_
