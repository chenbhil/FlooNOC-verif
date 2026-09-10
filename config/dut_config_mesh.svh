// -----------------------------------------------------------------------------
// DUT configuration for the FlooNoC 2x2 mesh smoke test.
// Separate from dut_config.svh (the single-router bench's config) by design:
// this bench is a new, independent top-level (tb_top_mesh) — `main`'s
// single-router bench is never touched by mesh work. See CLAUDE.md's
// "full mesh" plan for the rationale.
// -----------------------------------------------------------------------------
`ifndef FLOO_VERIF_DUT_CONFIG_MESH_SVH_
`define FLOO_VERIF_DUT_CONFIG_MESH_SVH_

// Mesh dimensions. 2x2 is the smallest topology that is actually a mesh
// (multi-hop routing exists) — deliberately smaller than FlooNoC's own
// floogen examples (which default to 4x4) so the hand-wired TB architecture
// can be proven out before scaling.
`define FLOO_VERIF_MESH_X         2
`define FLOO_VERIF_MESH_Y         2

// Number of router ports (N, E, S, W, Eject) — same canonical router as the
// single-router bench; every router in the mesh uses all 5, with boundary
// ports tied off per floogen's own convention (floo_axi_router.sv.mako):
// unconnected inputs tie valid/data to '0, unconnected outputs tie
// ready/credit to '0.
`define FLOO_VERIF_NUM_PORTS      5

// Payload width of the generic flit (bits). Same as the single-router bench.
`define FLOO_VERIF_FLIT_DATA_W    64

// Coordinate bit widths: 1 bit each covers a 2x2 mesh (id range 0..1).
`define FLOO_VERIF_X_BITS         1
`define FLOO_VERIF_Y_BITS         1
`define FLOO_VERIF_PORT_ID_BITS   1

// FIFO depths (InFifoDepth > 0 required for wormhole input buffering) —
// same as the single-router bench.
`define FLOO_VERIF_IN_FIFO_DEPTH  2
`define FLOO_VERIF_OUT_FIFO_DEPTH 2

`endif // FLOO_VERIF_DUT_CONFIG_MESH_SVH_
