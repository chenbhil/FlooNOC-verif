// -----------------------------------------------------------------------------
// Read-only observation interface over every router's North/East/South/West
// OUTPUT handshake in the mesh — the inter-router links, which
// floonoc_mesh_if (Eject endpoints only) does not expose.
//
// Driven in tb_top_mesh by hierarchical reference into OUR wrapper
// (floonoc_mesh_dut's dut_valid_out / dut_ready_out / dut_data_out), never
// into vendor RTL, and never written back: the DUT wrapper's ports are
// unchanged. Consumed by floonoc_mesh_link_monitor for the per-hop XY path
// check (verification plan RM8).
//
// Indexing is [router][direction] with direction = floo_pkg North=0, East=1,
// South=2, West=3. `ready` is router r's ready_i for that output: the
// neighbor's input ready on a connected link, tied 0 at a mesh boundary.
// -----------------------------------------------------------------------------
interface floonoc_mesh_link_if
  import floo_tb_mesh_types_pkg::*;
(
  input logic clk,
  input logic rst_n
);

  logic  [NumRouters-1:0][3:0] valid;
  logic  [NumRouters-1:0][3:0] ready;
  flit_t [NumRouters-1:0][3:0] data;

endinterface : floonoc_mesh_link_if
