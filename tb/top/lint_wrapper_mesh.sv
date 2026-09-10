// -----------------------------------------------------------------------------
// Minimal mesh wrapper for `make lint-mesh`: elaborates floonoc_mesh_dut with
// the exact bench parameterization, with no UVM and no testbench involvement,
// so lint findings are attributable to DUT RTL / required dependencies only.
// Parallel to lint_wrapper.sv (the single-router bench's lint shell).
// -----------------------------------------------------------------------------
module lint_wrapper_mesh
  import floo_pkg::*;
  import floo_tb_mesh_types_pkg::*;
(
  input  logic                   clk_i,
  input  logic                   rst_ni,
  input  logic  [NumRouters-1:0] valid_i,
  output logic  [NumRouters-1:0] ready_o,
  input  flit_t [NumRouters-1:0] data_i,
  output logic  [NumRouters-1:0] valid_o,
  input  logic  [NumRouters-1:0] ready_i,
  output flit_t [NumRouters-1:0] data_o
);

  floonoc_mesh_dut i_mesh (
    .clk_i   ( clk_i   ),
    .rst_ni  ( rst_ni  ),
    .valid_i ( valid_i ),
    .ready_o ( ready_o ),
    .data_i  ( data_i  ),
    .valid_o ( valid_o ),
    .ready_i ( ready_i ),
    .data_o  ( data_o  )
  );

endmodule : lint_wrapper_mesh
