// -----------------------------------------------------------------------------
// UVM package for the FlooNoC 2x2 mesh bench. Compilation-order-safe:
// everything is included here in dependency order.
//
// Deliberately shares NOTHING with floonoc_uvm_pkg (the single-router
// bench's package) — no base classes, no types, no config header. The two
// packages are never compiled into the same Verilator invocation; see
// scripts/run_verilator.sh (TB_SOURCES vs TB_MESH_SOURCES) and the
// namespace note in config/dut_config_mesh.svh.
//
// Note the two *_types_pkg.sv packages also export identically-named symbols
// (NumPorts, flit_t, dir_name, ...). Importing both into one scope is a
// compile-time ambiguity error under SV wildcard-import rules — loud and
// immediate, unlike the silent macro redefinition the FLOO_VERIF_MESH_*
// namespacing closed. Do not import floo_tb_types_pkg here.
// -----------------------------------------------------------------------------
`include "uvm_macros.svh"
`include "dut_config_mesh.svh"

package floonoc_mesh_uvm_pkg;

  import uvm_pkg::*;
  import floo_tb_mesh_types_pkg::*;

  `include "floonoc_mesh_flit_item.sv"
  `include "floonoc_mesh_smoke_seq.sv"
  `include "floonoc_mesh_driver.sv"
  `include "floonoc_mesh_monitor.sv"
  `include "floonoc_mesh_agent.sv"
  `include "floonoc_mesh_scoreboard.sv"

endpackage : floonoc_mesh_uvm_pkg
