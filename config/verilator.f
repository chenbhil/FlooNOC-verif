// -----------------------------------------------------------------------------
// Common Verilator options for the FlooNoC UVM smoke bench (Verilator 5.050).
// Every option is documented; warning suppressions live ONLY in
// config/verilator_waivers.vlt with per-entry justification.
// -----------------------------------------------------------------------------

// SystemVerilog mode
-sv

// Event/timing scheduler: required for UVM (delays, wait, clocking)
--timing

// Enable SVA assert/cover execution at runtime
--assert

// Functional + user coverage (covergroups, cover properties)
--coverage-user

// Code coverage (statement/line). Toggle coverage is intentionally off for
// the smoke milestone: it multiplies bins on the 64-bit flit datapath and
// drowns the functional numbers; enable per-experiment if needed.
--coverage-line

// Restrict code coverage to the DUT closure (UVM + TB excluded)
config/coverage_scope.vlt

// Trace format flag (--trace-fst or --trace-vcd) is added by
// scripts/run_verilator.sh per build flavor; runtime-gated by +trace.

// Workaround for an incomplete non-binary (X/Z) encoding path in the
// 5.050 fstcpp writer (FST_CHECK enc == BINARY abort at exit, see
// docs/known_issues.md): initialize all X to 0 so traced signals are
// two-state. Does not mask DUT bugs at this scope (design is reset-clean).
--x-initial 0
--x-assign 0

// Trace into class/struct-heavy scopes conservatively
--trace-structs

// UVM library: no DPI available under Verilator's UVM bring-up path
+define+UVM_NO_DPI

// Documented, reviewed warning waivers (no global suppression)
config/verilator_waivers.vlt

// TB include roots (dut_config.svh and class includes)
+incdir+config
+incdir+tb/sequences
+incdir+tb/agents
+incdir+tb/env
+incdir+tb/coverage
+incdir+tb/tests
