// -----------------------------------------------------------------------------
// Top-level testbench: clock/reset generation, DUT (floo_router) instance,
// purpose-built interface, SVA checker, config_db publication of the virtual
// interface, run_test(), waveform hook and a global watchdog.
// -----------------------------------------------------------------------------
`include "dut_config.svh"

module tb_top;

  import uvm_pkg::*;
  import floo_pkg::*;
  import floo_tb_types_pkg::*;
  import floonoc_uvm_pkg::*;

  // ---------------------------------------------------------------------------
  // Clock / reset
  // ---------------------------------------------------------------------------
  logic clk = 1'b0;
  // rst_n starts as X, not with a declaration initializer: an initializer is
  // applied before time 0 and raises no event (IEEE 1800 6.8), so the DUT's
  // async resets would never see a negedge and its flops would stay X until
  // the first clock edge. The X->0 transition at #1 is a negedge (9.4.2),
  // after time-0 process start-up and before the first posedge clk.
  logic rst_n;

  always #5ns clk = ~clk;   // 100 MHz

  initial begin
    #1ns rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Interface + DUT
  // ---------------------------------------------------------------------------
  floonoc_router_if rif (.clk(clk), .rst_n(rst_n));

  // Map flat per-port interface signals onto the DUT's [port][virt_channel]
  // arrays (NumVirtChannels == 1).
  logic  [NumPorts-1:0][0:0] dut_valid_in, dut_ready_in;
  logic  [NumPorts-1:0][0:0] dut_valid_out, dut_ready_out;
  flit_t [NumPorts-1:0][0:0] dut_data_in, dut_data_out;

  for (genvar p = 0; p < NumPorts; p++) begin : gen_if_map
    assign dut_valid_in[p][0]  = rif.valid_in[p];
    assign rif.ready_in[p]     = dut_ready_in[p][0];
    assign dut_data_in[p][0]   = rif.data_in[p];
    assign rif.valid_out[p]    = dut_valid_out[p][0];
    assign dut_ready_out[p][0] = rif.ready_out[p];
    assign rif.data_out[p]     = dut_data_out[p][0];
  end

  localparam xy_id_t RouterId = '{
    x:       x_bits_t'(RouterX),
    y:       y_bits_t'(RouterY),
    port_id: '0
  };

  floo_router #(
    .NumRoutes       ( NumPorts     ),
    .NumVirtChannels ( 1            ),
    .NumPhysChannels ( 1            ),
    .flit_t          ( flit_t       ),
    .hdr_t           ( hdr_t        ),
    .InFifoDepth     ( InFifoDepth  ),
    .OutFifoDepth    ( OutFifoDepth ),
    .RouteAlgo       ( XYRouting    ),
    .IdWidth         ( $bits(xy_id_t) ),
    .id_t            ( xy_id_t      )
  ) i_dut (
    .clk_i          ( clk           ),
    .rst_ni         ( rst_n         ),
    .test_enable_i  ( 1'b0          ),
    .xy_id_i        ( RouterId      ),
    .id_route_map_i ( '0            ),  // unused for XYRouting
    .valid_i        ( dut_valid_in  ),
    .ready_o        ( dut_ready_in  ),
    .data_i         ( dut_data_in   ),
    .credit_o       (               ),  // VcNaive: constant, unused
    .valid_o        ( dut_valid_out ),
    .ready_i        ( dut_ready_out ),
    .data_o         ( dut_data_out  ),
    .credit_i       ( '0            ),
    .offload_req_o  (               ),  // collectives disabled
    .offload_rsp_i  ( '0            )
  );

  // ---------------------------------------------------------------------------
  // Protocol assertions
  // ---------------------------------------------------------------------------
  floonoc_router_sva i_sva (
    .clk       ( clk           ),
    .rst_n     ( rst_n         ),
    .valid_in  ( rif.valid_in  ),
    .ready_in  ( rif.ready_in  ),
    .valid_out ( rif.valid_out ),
    .ready_out ( rif.ready_out )
  );

  // ---------------------------------------------------------------------------
  // UVM entry
  // ---------------------------------------------------------------------------
  initial begin
    uvm_config_db#(virtual floonoc_router_if)::set(null, "*", "vif", rif);
    run_test();
  end

  // ---------------------------------------------------------------------------
  // Waves: enable at runtime with +trace. The container format (FST or VCD)
  // is fixed at compile time (--trace-fst / --trace-vcd, see run_verilator.sh);
  // +tracefile=<path> selects the output file (default waves/tb_top.fst).
  // ---------------------------------------------------------------------------
  initial begin
    string tracefile;
    if ($test$plusargs("trace")) begin
      if (!$value$plusargs("tracefile=%s", tracefile)) begin
        tracefile = "waves/tb_top.fst";
      end
      $dumpfile(tracefile);
      $dumpvars(0, tb_top);
    end
  end

  // ---------------------------------------------------------------------------
  // Last-resort watchdog (UVM-level drain watchdog reports first)
  // ---------------------------------------------------------------------------
  initial begin
    #1ms;
    $display("[tb_top] FATAL: global watchdog expired");
    $fatal(1);
  end

endmodule : tb_top
