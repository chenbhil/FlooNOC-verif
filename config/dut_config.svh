// -----------------------------------------------------------------------------
// DUT configuration for the FlooNoC router UVM smoke test.
// Single source of truth for the selected floo_router parameterization.
// See docs/dut_scope.md for the rationale behind every value.
// -----------------------------------------------------------------------------
`ifndef FLOO_VERIF_DUT_CONFIG_SVH_
`define FLOO_VERIF_DUT_CONFIG_SVH_

// Number of router ports (N, E, S, W, Eject) — canonical 2D-mesh router
`define FLOO_VERIF_NUM_PORTS      5

// Payload width of the generic flit (bits). Arbitrary at router scope;
// the router treats the payload as opaque.
`define FLOO_VERIF_FLIT_DATA_W    64

// Coordinate bit widths: 2 bits each => 4x4 coordinate space, router at (1,1)
`define FLOO_VERIF_X_BITS         2
`define FLOO_VERIF_Y_BITS         2
`define FLOO_VERIF_PORT_ID_BITS   1

// Router position (must be interior-capable so all 4 directions are exercised)
`define FLOO_VERIF_ROUTER_X       1
`define FLOO_VERIF_ROUTER_Y       1

// FIFO depths (InFifoDepth > 0 required for wormhole input buffering;
// upstream tb_floo_router uses 4, we use 2 as the minimum useful depth)
`define FLOO_VERIF_IN_FIFO_DEPTH  2
`define FLOO_VERIF_OUT_FIFO_DEPTH 2

`endif // FLOO_VERIF_DUT_CONFIG_SVH_
