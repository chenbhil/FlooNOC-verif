// -----------------------------------------------------------------------------
// Purpose-built SV interface around floo_router's per-port valid/ready/flit
// channels (single virtual channel configuration, so one bit per port).
// The UVM driver/monitor access this through a virtual interface handle
// distributed via uvm_config_db.
// -----------------------------------------------------------------------------
interface floonoc_router_if
  import floo_tb_types_pkg::*;
(
  input logic clk,
  input logic rst_n
);

  // Input side (TB drives, DUT accepts)
  logic  [NumPorts-1:0] valid_in;
  logic  [NumPorts-1:0] ready_in;   // driven by DUT
  flit_t [NumPorts-1:0] data_in;

  // Output side (DUT drives, TB accepts)
  logic  [NumPorts-1:0] valid_out;
  logic  [NumPorts-1:0] ready_out;  // driven by TB
  flit_t [NumPorts-1:0] data_out;

endinterface : floonoc_router_if
