# Lint waiver register

Policy: `make lint` is reported as **"zero unwaived warnings"**, never as
"zero warnings" — warnings that were waived still happened. Every suppression
lives in `config/verilator_waivers.vlt`, is scoped as narrowly as Verilator's
config syntax allows (rule + file, plus `-match` where possible), and has an
entry here with the observed message, the reason it is benign, and the
condition under which it must be re-audited. There is no global suppression.

To re-audit any entry: delete it from `config/verilator_waivers.vlt`, run
`make lint`, and read the resurfaced warning in `logs/lint.log`.

| ID | Rule | File / scope | Observed message (abridged) | Why benign | Revisit when |
|----|------|--------------|------------------------------|------------|--------------|
| W1 | `WIDTHTRUNC` | `common_cells/src/rr_arb_tree.sv` (upstream dep) | `assert (NumIn)`: 32-bit parameter used as 1-bit boolean condition | Upstream assertion style; nonzero parameter truncates to 1 as intended. Not DUT logic. | common_cells pin moves past 1.39.0, or the assert is rewritten upstream |
| W2 | `UNSIGNED` | `common_cells/src/rr_arb_tree.sv` (upstream dep) | `(i > rr_q)` comparison is constant under this parameterization | Genvar comparison degenerates for NumIn at this config; arbiter behavior unaffected. | DUT reconfigured with different port/VC count (changes NumIn) |
| W3 | `WIDTHEXPAND` | `axi/src/axi_pkg.sv` (upstream dep) | Width-extending arithmetic in beat-address helper functions | Constant math in helper functions that the router datapath never calls; package needed only for typedefs. | axi pin moves past 0.39.9, or router scope starts using AXI beat helpers |
| W4 | `WIDTHEXPAND` | `floonoc/hw/floo_router.sv` (core DUT) | NoLoopback assertion compares 1-bit `hdr.collective_op` to 4-bit `Unicast` enum literal (value 0) | Zero-extension makes the comparison semantically correct; assertion still guards loopback. | FlooNoC pin moves past v0.8.4, or collectives are enabled (widens `collective_op`) |
| W5 | `UNSIGNED` | `floonoc/hw/floo_output_arbiter.sv` (core DUT) | `i < NumParallelRedRoutes` constant-false with reductions disabled | With `NumParallelRedRoutes == 0` the loop body is correctly unreachable dead code. | Collective/reduction support is enabled in the DUT config |
| W6 | all rules | `uvm*/src/*` (UVM 1800.2-2017 library) | Many (the UVM BCL is not Verilator-lint-clean) | Pinned, unmodified third-party verification library; linting it is not a goal of this project. Scoped to the UVM tree only — TB code is NOT covered by this entry. | UVM library version changes, or Accellera publishes a lint-clean release |
| W7 | `WIDTHTRUNC` | `tb/*` with `-match "*uvm_report_enabled*"` | `uvm_info`/`uvm_error` macros expand to `if (uvm_report_enabled(...))` where the function returns `int` | UVM API signature, expanded into our code by UVM macros; not local logic. Matched on message content so genuine TB width bugs still surface. | UVM macro implementation changes |
| W8 | `WIDTHTRUNC` | `tb/*` with `-match "*METHODCALL 'randomize'*"` | `randomize()` returns `int` used in boolean context | SystemVerilog-standard `randomize()` signature; call sites check success. Same narrow `-match` scoping as W7. | never expected — standard API |

Register upkeep rules:

1. A new waiver may not land without a row here (same commit).
2. Rows W1–W3 (upstream deps) and W4–W5 (DUT) must be re-audited on every
   pin bump — `make setup` prints the resolved revisions.
3. If a re-audit shows the warning is gone, delete both the `.vlt` entry and
   the row (keep the ID retired; do not renumber).
