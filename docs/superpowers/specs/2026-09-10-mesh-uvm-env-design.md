# Mesh UVM environment — design spec

Date: 2026-09-10
Status: approved (brainstorming), ready for implementation planning

## Context

Phase 1 (already implemented and verified) built a 2×2 mesh of `floo_router`
instances wired together at RTL level: `tb/top/tb_top_mesh.sv`,
`tb/pkg/floo_tb_mesh_types_pkg.sv`, `tb/interfaces/floonoc_mesh_if.sv`,
`config/dut_config_mesh.svh`. It is lint-clean on Verilator 5.052 and passes
6/6 directed routing cases via a hand-rolled `initial`-block smoke check —
pure SystemVerilog, deliberately no UVM layer, to avoid a `` `define``
collision between `dut_config.svh` (single-router) and `dut_config_mesh.svh`
(mesh) if both ever landed in the same compile unit.

This spec covers the next step: a full UVM environment over the mesh,
reaching parity with the existing single-router bench
(`tb/pkg/floonoc_uvm_pkg.sv` and everything it includes) — agent, multi-hop
scoreboard, coverage, directed+random smoke test, negative self-tests, and
mesh-scoped SVA.

The single-router bench (`main`, `tb_top.sv`, `floonoc_uvm_pkg.sv` and
everything it depends on) must stay completely untouched — same constraint
Phase 1 already established for the RTL layer.

## Goals

- A mesh UVM env with the same *kind* of coverage the single-router bench
  has today: routing correctness, payload/header integrity, no-loss/no-dup,
  per-pair ordering, backpressure exercise, functional + assertion coverage,
  and negative self-tests proving the checkers aren't vacuous.
- Fully independent from the single-router UVM classes — no shared base
  classes, no shared package. Mirrors the pattern already set by
  `floonoc_mesh_if.sv` / `floo_tb_mesh_types_pkg.sv` / `tb_top_mesh.sv`.
- Generic over mesh shape (`MeshX`/`MeshY`/`NumRouters` from
  `floo_tb_mesh_types_pkg`) — no literal "2×2" or "4 routers" baked into any
  new UVM code, so a later bump of `dut_config_mesh.svh` to a larger NxM
  mesh doesn't require rewriting this layer.

## Non-goals (explicit, don't implement without a fresh spec)

- Protocol-level (e.g. AXI) traffic — this stays flit-level, same
  abstraction as the single-router bench. AXI-over-mesh is a distinct future
  direction (floogen ships `axi_mesh_*.yml` examples) with its own
  brainstorm when it's actually scheduled.
- Any change to mesh size beyond what `dut_config_mesh.svh` already
  parameterizes — staying generic in code is in scope; actually verifying
  a 3×3 or NxM mesh is not.
- Any change to the single-router bench or its files.
- Credit-counter / VC-level checks (same deferral as the single-router
  bench's `docs/verification_plan.md` — `VcNaive`, credits inert).

## Architecture

New package `tb/pkg/floonoc_mesh_uvm_pkg.sv`, parallel to
`floonoc_uvm_pkg.sv`: `` `include``s `uvm_macros.svh` and
`dut_config_mesh.svh`, imports `uvm_pkg::*` and
`floo_tb_mesh_types_pkg::*`, `` `include``s every mesh UVM class below in
dependency order.

| Single-router file | Mesh counterpart | Key change |
|---|---|---|
| `tb/sequences/floonoc_flit_item.sv` | `tb/sequences/floonoc_mesh_flit_item.sv` | `src_port` (0-4 direction within one router) → `src_router` (0..NumRouters-1, injection router); routing model → `exp_path()`/multi-hop instead of one-shot `exp_out_port()` |
| `tb/sequences/floonoc_smoke_seq.sv` | `tb/sequences/floonoc_mesh_smoke_seq.sv` | directed traffic generated from mesh topology (loops over `has_neighbor`/`neighbor_idx`/corners), not a literal per-router table |
| `tb/agents/floonoc_driver.sv` | `tb/agents/floonoc_mesh_driver.sv` | loops over `NumRouters` (Eject port only) instead of `NumPorts` (all 5 directions per single router) |
| `tb/agents/floonoc_monitor.sv` | `tb/agents/floonoc_mesh_monitor.sv` | same structure, observes `floonoc_mesh_if` |
| `tb/agents/floonoc_agent.sv` | `tb/agents/floonoc_mesh_agent.sv` | structurally identical: wraps mesh driver/monitor/sequencer |
| `tb/env/floonoc_scoreboard.sv` | `tb/env/floonoc_mesh_scoreboard.sv` | FIFO keyed `expected[src_router][dst_router][$]` instead of `[src_port][out_port][$]`; same R1/R2/R5/R6 checks |
| `tb/coverage/floonoc_cov.sv` | `tb/coverage/floonoc_mesh_cov.sv` | `cp_src_router` x `cp_dst_router` cross, `cp_hops` bins, `cp_backpressure` |
| `tb/env/floonoc_env.sv` | `tb/env/floonoc_mesh_env.sv` | same shape: agent + scoreboard + coverage |
| `tb/tests/floonoc_smoke_test.sv` | `tb/tests/floonoc_mesh_smoke_test.sv` | same watchdog/drain/report structure; budgets scaled by mesh diameter |
| `tb/tests/floonoc_negative_tests.sv` | `tb/tests/floonoc_mesh_negative_tests.sv` | N1-N3 mirrored, re-keyed to router pairs |
| `tb/assertions/floonoc_router_sva.sv` | `tb/assertions/floonoc_mesh_router_sva.sv` | new — same property set, reparameterized over `floo_tb_mesh_types_pkg`, instantiated once per router |

**`tb_top_mesh.sv` changes:**
- add `import floonoc_mesh_uvm_pkg::*;` and `initial run_test();`
- publish `rif` (the `floonoc_mesh_if` instance) via `uvm_config_db`
- instantiate `floonoc_mesh_router_sva` once per router inside the existing
  `gen_routers` loop, using that router's own `xy_id_i` (not a fixed
  `RouterX`/`RouterY` like the single-router bench's SVA)
- **remove** the Phase 1 hand-rolled directed-smoke `initial` block — its
  own header comment already calls it "temporary scaffolding for the wiring
  checkpoint, not a regression test," and its job is fully subsumed by the
  directed phase of `floonoc_mesh_smoke_seq`

## Traffic model

`floonoc_mesh_flit_item`:

```systemverilog
rand int unsigned src_router;         // 0..NumRouters-1, injection router
rand bit [X_BITS-1:0] dst_x;
rand bit [Y_BITS-1:0] dst_y;          // together identify the destination router
rand payload_t payload;

int unsigned out_router;              // observation: which router's Eject delivered it
bit backpressured;

constraint c_legal_route {
  src_router < NumRouters;
  32'(dst_x) < MeshX; 32'(dst_y) < MeshY;
  router_idx(dst_x, dst_y) != src_router;   // NoLoopback — the only illegal case
}
```

Since the TB only ever touches a router's Eject port (never raw
North/East/South/West), the single-router item's per-source-direction
constraint table (`XYRouteOpt` tie-offs, per-direction loopback rules) does
not apply here — `src_router != dst_router` is the only illegal combination.
`exp_path()` (already implemented in `floo_tb_mesh_types_pkg`) gives the full
route; `exp_out_router() = path[$]`; `exp_hops() = path.size() - 1`.

**Directed phase** (`floonoc_mesh_smoke_seq`), generated rather than a
literal table so it scales to NxM:
- every adjacent router pair in both directions, via `has_neighbor`/
  `neighbor_idx` — every physical link exercised as a 1-hop case
- both mesh corners, both hop orders — guarantees at least one
  longest-path (full mesh diameter) case is always directed
- the illegal `src==dst` case is **not** re-tested at UVM level: it can't
  even be constructed by `randomize()` under `c_legal_route`, and Phase 1's
  RTL-level smoke check already confirmed the DUT's own `NoLoopback`
  assertion fires for it

**Random phase:** unchanged shape — `repeat(num_random) randomize()`,
drawing `src_router`/`dst_x`/`dst_y` freely under the one constraint.

## Checking

**Scoreboard** (`floonoc_mesh_scoreboard`): `expected[src_router][dst_router][$]`,
same checks as today —
- R1 routing: observed exit router == `exp_out_router()`
- R2 integrity: payload + dst compare vs. expectation
- R5 no loss/dup: `check_phase` pending==0, accepted==delivered; error on
  output with an empty expectation queue
- R6 ordering: per (src_router,dst_router) pair FIFO, `pop_front` compare

Hop count is **not** an extra scoreboard assertion — `floonoc_mesh_if` only
exposes Eject-port endpoints, not the path taken, so intermediate-router
correctness stays Phase 1's job (RTL wiring level), not this scoreboard's.
Hop count is a coverage signal only, computed from the item's known
src/dst at accept time.

**Coverage** (`floonoc_mesh_cov`): `cp_src_router` x `cp_dst_router` cross
(bins sized to `NumRouters`), `cp_hops` (bins 1..mesh diameter, i.e.
`MeshX+MeshY-2`), `cp_backpressure` (stalled/free) — same shape as today's
`flit_cg`.

**SVA** (`floonoc_mesh_router_sva`): same property set as
`floonoc_router_sva.sv` (`StableValidIn/Out`, `XYDirectionNotAllowed`,
`NoLoopback`), reparameterized to import `floo_tb_mesh_types_pkg` and bound
per-router using that router's own `xy_id_i`.

## Test structure

`floonoc_mesh_smoke_test`: same shape as `floonoc_smoke_test` — directed
phase → random phase → forward-progress watchdog on the sequence → drain
watchdog on `pending_count()` → idle tail → explicit PASS/FAIL in
`report_phase`. `drain_cycle_budget` becomes `base_budget + max_hops *
per_hop_cycles` (mesh-diameter-derived) instead of a flat literal, so it
won't silently under-budget if the mesh grows later — still effectively a
constant for the current 2×2 shape.

`floonoc_mesh_negative_tests`, N1-N3 mirrored:
- **N1** (`corrupt_payload_idx`): unchanged mechanism — payload corruption
  on the Nth accepted flit.
- **N2** (`corrupt_route_idx`): corrupt to
  `(exp_out_router()+1) % NumRouters`, skipping `src_router` so the
  corrupted expectation is still legal-shaped — same failure signature
  ("unexpected flit" / "never delivered").
- **N3** (permanent backpressure): unchanged — `ready_pct=0` via
  `uvm_config_db` on the mesh driver.

## Explicitly out of scope for this spec

- Any AXI/protocol-level layer.
- Verifying a mesh size other than the currently-configured 2×2 (code stays
  generic; verification target does not change).
- Sharing code with the single-router UVM classes.
