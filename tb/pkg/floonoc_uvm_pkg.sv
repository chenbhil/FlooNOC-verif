// -----------------------------------------------------------------------------
// UVM package for the FlooNoC router smoke bench. Compilation-order-safe:
// everything is included here in dependency order.
// -----------------------------------------------------------------------------
`include "uvm_macros.svh"
`include "dut_config.svh"

package floonoc_uvm_pkg;

  import uvm_pkg::*;
  import floo_tb_types_pkg::*;

  `include "floonoc_flit_item.sv"
  `include "floonoc_smoke_seq.sv"
  `include "floonoc_driver.sv"
  `include "floonoc_monitor.sv"
  `include "floonoc_agent.sv"
  `include "floonoc_scoreboard.sv"
  `include "floonoc_cov.sv"
  `include "floonoc_env.sv"
  `include "floonoc_smoke_test.sv"
  `include "floonoc_negative_tests.sv"

endpackage : floonoc_uvm_pkg
