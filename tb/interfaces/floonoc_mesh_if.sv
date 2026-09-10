// -----------------------------------------------------------------------------
// Purpose-built SV interface around a mesh's per-router EJECT port only.
// North/East/South/West are inter-router links wired directly in
// tb_top_mesh (or tied off at a mesh boundary) — they are never TB-facing,
// unlike the single-router bench where all 5 ports face the TB. Only the
// Eject port of each router is an external endpoint.
//
// One instance covers the whole mesh: signals are indexed by router number
// (row-major, see floo_tb_mesh_types_pkg::router_idx), not duplicated per
// router, so the UVM driver/monitor address "which router's Eject port"
// with a single index the same way the single-router bench addresses N
// input/output ports.
// -----------------------------------------------------------------------------
interface floonoc_mesh_if
  import floo_tb_mesh_types_pkg::*;
(
  input logic clk,
  input logic rst_n
);

  // Input side (TB drives, DUT accepts) — one per router's Eject port.
  logic  [NumRouters-1:0] valid_in;
  logic  [NumRouters-1:0] ready_in;   // driven by DUT
  flit_t [NumRouters-1:0] data_in;

  // Output side (DUT drives, TB accepts) — one per router's Eject port.
  logic  [NumRouters-1:0] valid_out;
  logic  [NumRouters-1:0] ready_out;  // driven by TB
  flit_t [NumRouters-1:0] data_out;

endinterface : floonoc_mesh_if
