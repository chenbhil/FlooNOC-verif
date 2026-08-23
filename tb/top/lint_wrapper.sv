// -----------------------------------------------------------------------------
// Minimal DUT wrapper for `make lint`: elaborates floo_router with the exact
// smoke-test parameterization, with no UVM involvement, so lint findings are
// attributable to DUT RTL / required dependencies only.
// -----------------------------------------------------------------------------
`include "dut_config.svh"

module lint_wrapper
  import floo_pkg::*;
  import floo_tb_types_pkg::*;
(
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic  [NumPorts-1:0] valid_i,
  output logic  [NumPorts-1:0] ready_o,
  input  flit_t [NumPorts-1:0] data_i,
  output logic  [NumPorts-1:0] valid_o,
  input  logic  [NumPorts-1:0] ready_i,
  output flit_t [NumPorts-1:0] data_o
);

  logic  [NumPorts-1:0][0:0] dut_valid_in, dut_ready_in;
  logic  [NumPorts-1:0][0:0] dut_valid_out, dut_ready_out;
  flit_t [NumPorts-1:0][0:0] dut_data_in, dut_data_out;

  for (genvar p = 0; p < NumPorts; p++) begin : gen_map
    assign dut_valid_in[p][0]  = valid_i[p];
    assign ready_o[p]          = dut_ready_in[p][0];
    assign dut_data_in[p][0]   = data_i[p];
    assign valid_o[p]          = dut_valid_out[p][0];
    assign dut_ready_out[p][0] = ready_i[p];
    assign data_o[p]           = dut_data_out[p][0];
  end

  localparam xy_id_t RouterId = '{
    x:       x_bits_t'(RouterX),
    y:       y_bits_t'(RouterY),
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
    .clk_i          ( clk_i         ),
    .rst_ni         ( rst_ni        ),
    .test_enable_i  ( 1'b0          ),
    .xy_id_i        ( RouterId      ),
    .id_route_map_i ( '0            ),
    .valid_i        ( dut_valid_in  ),
    .ready_o        ( dut_ready_in  ),
    .data_i         ( dut_data_in   ),
    .credit_o       (               ),
    .valid_o        ( dut_valid_out ),
    .ready_i        ( dut_ready_out ),
    .data_o         ( dut_data_out  ),
    .credit_i       ( '0            ),
    .offload_req_o  (               ),
    .offload_rsp_i  ( '0            )
  );

endmodule : lint_wrapper
