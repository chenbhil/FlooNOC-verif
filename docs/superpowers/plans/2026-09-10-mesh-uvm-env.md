# Mesh UVM Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a complete, self-checking UVM environment over the existing 2×2 FlooNoC mesh (`tb_top_mesh`), reaching functional parity with the single-router bench — agent, multi-hop scoreboard, coverage, directed + random smoke test, three negative self-tests, and mesh-scoped SVA — without touching the single-router bench.

**Architecture:** A second, fully independent UVM package (`floonoc_mesh_uvm_pkg`) built on the Phase-1 mesh types/interface, compiled and run as a *separate Verilator binary* from the single-router bench. The mesh RTL wiring is first extracted out of `tb_top_mesh` into a plain `floonoc_mesh_dut` module so it can be linted without UVM and so `tb_top_mesh` is purely a TB shell. Endpoint addressing is by **router index** (0..NumRouters-1) throughout; the source router travels with each flit inside `hdr.src_id`, which the DUT never rewrites under XY routing.

**Tech Stack:** SystemVerilog 1800-2017, UVM 1800.2-2017 1.0 (Accellera), Verilator 5.052 (`--binary --timing --assert --coverage-user --coverage-line`), GNU make, bash.

---

## Prerequisites

Before starting, confirm the environment is sane:

```bash
export UVM_HOME=/Users/chenbh/verification/uvm/1800.2-2017-1.0
make doctor
```

Expected: `verilator : Verilator 5.052 ...`, `bender` present, `floonoc` cloned at the pinned commit, `uvm : ... OK`.

Then confirm the **single-router baseline is green** — it is the regression that must never break:

```bash
make sources && make build && make run
```

Expected tail: `*** TEST PASSED *** (25 flits accepted, 25 delivered, 25 matched, 0 mismatches)` and `[verilator] run PASS`.

---

## Design decisions made in this plan (deviations from the spec)

The spec at `docs/superpowers/specs/2026-09-10-mesh-uvm-env-design.md` is the requirements source. These points correct or fill gaps in it. Each is justified where it appears in a task.

| # | Spec said | Plan does | Why |
|---|---|---|---|
| D1 | (nothing about build/run) | Separate Verilator invocation, `build/obj_dir_mesh`, `Vtb_top_mesh`, `logs/coverage_mesh.dat`, new `make lint-mesh/build-mesh/run-mesh/run-negative-mesh/cov-mesh` | `run_verilator.sh` hardcodes `--top-module tb_top`; the mesh env compiles nowhere without this |
| D2 | (nothing) | Rename mesh macros to `FLOO_VERIF_MESH_*` | `dut_config.svh` and `dut_config_mesh.svh` define the same names with different values (`X_BITS` 2 vs 1) under different include guards, and `config/verilator.f` has `+incdir+config` for every build |
| D3 | (nothing) | `hdr.src_id` carries the source router's (x,y) | The scoreboard keys on `src_router`, but the output monitor only sees `rif.data_out[r]`. `floo_route_select.sv:96` rewrites `hdr.dst_id` **only** under `SourceRouting`; `src_id` is untouched by XY hops |
| D4 | `rand bit [X_BITS-1:0] dst_x; dst_y` | `rand int unsigned dst_router`, with `dst_x()`/`dst_y()` as derived functions | `X_BITS`/`Y_BITS` are not identifiers (the package exports `x_bits_t`/`y_bits_t`), and `router_idx(dst_x,dst_y) != src_router` puts a `%`/`/` function call inside a constraint — fragile under Verilator's solver. Two plain `int unsigned` with `!=` is solver-trivial and is the better model anyway (mesh endpoints *are* routers) |
| D5 | mesh SVA has `StableValidIn/Out`, `XYDirectionNotAllowed`, `NoLoopback`, bound per-router with `xy_id_i` | mesh SVA mirrors the *actual* `floonoc_router_sva.sv` property set (`A_IN_VALID_STABLE`, `A_OUT_VALID_STABLE`, `A_OUT_QUIET_IN_RESET` + 3 covers), one instance on the interface | `XYDirectionNotAllowed`/`NoLoopback` are the **DUT's own** assertions (`floo_router.sv:515`, `:537`); they already fire inside every router under `--assert`. The TB property set needs no coordinates, so `xy_id_i` is unmotivated |
| D6 | `exp_out_router() = path[$]` | `exp_out_router()` returns `dst_router` directly; `exp_path()` is used only for `exp_hops()`, and is unit-tested first | The eject router *is* the destination by definition of XY routing. `exp_path` is currently unexercised Phase-1 code, so it gets a unit test before anything depends on it |
| D7 | N2 corrupts to `(exp+1) % NumRouters`, "skipping src_router" | N2 uses a `wrong_router()` helper that `uvm_fatal`s if no valid alternative exists | On a 2-router mesh the skip lands back on the true destination, making the negative test vacuous — the exact failure it exists to disprove |
| D8 | `cp_src_router × cp_dst_router` cross | Cross carries `ignore_bins` for the `src == dst` diagonal | `src != dst` makes N of N² cross bins unreachable (4 of 16 at 2×2); without this the cross can never close |
| D9 | hops "computed at accept time" | hops computed at sample time from the delivered item | Coverage subscribes to `out_ap` (`floonoc_env.sv:27`), not `in_ap` |
| D10 | remove the Phase-1 `initial` block | also remove `valid_out_seen`, `smoke_ok`, `gen_misroute_watch` | They are orphaned by the removal |
| D11 | (nothing) | `uvm_analysis_imp_decl` suffixes are `_mesh_in`/`_mesh_out` | `` `uvm_analysis_imp_decl(_in) `` defines a *global* class name; distinct suffixes keep the two packages independent even if they ever share a compile unit |
| D12 | (nothing) | Mesh RTL wiring extracted into `tb/top/floonoc_mesh_dut.sv` | Makes a UVM-free `lint-mesh` target possible without duplicating 60 lines of generate wiring, and leaves `tb_top_mesh` as a pure TB shell |

**Scope:** Verilator 5.052 only. Running the mesh bench on xezim is a deliberate follow-up, not part of this plan — the point of getting it Verilator-green first is that any later xezim delta is attributable to xezim, not to the bench. Task 13 records that baseline.

---

## Amendments made during execution

Recorded as they happen so a future reader sees the plan that was actually
executed, not the one originally written.

**A1 — Task 1's `lint-mesh` as originally specified could not detect a missing
driver (found by code review, 2026-09-10).** The review proved by fault
injection that deleting a single `assign` from `floonoc_mesh_dut.sv` passed
both `make lint-mesh` and `make run-mesh`. Two independent causes:
Verilator's `UNDRIVEN` is not in the default warning set, and the build's
`--x-initial 0` (from `config/verilator.f:34-35`) makes the undriven bit read
`0` — coincidentally the correct tie-off value.

This was a defect in the plan, not in the implementation. The original
`lint-mesh` mirrored the single-router `lint` invocation, inheriting the
assumption that `--x-initial 0` is safe because "the design is reset-clean."
That assumption was established for a bench whose wiring was already trusted.
For a freshly hand-wired mesh, where the entire risk *is* "did I drive
everything", the same flag inverts from harmless to actively concealing.

Resolution, in three parts:

- **`-Wwarn-UNDRIVEN` added to `lint-mesh` only** (not to the single-router
  `lint`), with one tightly scoped waiver (W9: `floo_router.sv`
  `past_handshakes_d`, a genuine pre-existing upstream dead net), registered
  in `docs/waiver_register.md` per that file's own upkeep rules. This is a net
  positive but **does not close the gap**: Verilator stops per-bit drivenness
  tracking once a multi-dimensional packed array slice is read through a
  genvar-indexed submodule port connection inside a generate loop — exactly
  the `.valid_i(dut_valid_in[r])` pattern in `gen_routers`. Confirmed with
  four minimal repros; `split_var` via a `.vlt` directive had no effect.
  Treat this as a known Verilator limitation, not a to-do.
- **`run-mesh` now sweeps all 12 non-loopback `(src, dst)` pairs** instead of
  the single default `R0 → (1,1)` case. This closes the *consequential*
  cases: a dropped `gen_eject_map` assign stops a router injecting or
  ejecting, and a dropped `gen_connected` assign kills a link — both now
  fail the sweep. It costs a fraction of a second.
- **A `check-mesh-x` target was attempted and ABANDONED as infeasible.** Do
  not re-attempt it; the reasons are structural, not effort-related. Two
  independent findings killed it:

  1. **`--x-initial unique` at compile time is a trap.** It only makes
     Verilator *capable* of a non-zero reset. `VerilatedContext::randReset()`
     still defaults to `0` at runtime, so the compile flag alone silently
     reproduces the exact masking it appears to remove. A green run under
     that flag proves nothing, while looking like it proves everything.
     Forcing the behavior requires the runtime plusarg
     `+verilator+rand+reset+1`.
  2. **`+verilator+rand+reset+N` is global and cannot be scoped.** It forces
     *every* undriven signal in the elaborated design, including the vendor
     DUT's legitimately-undriven internals — `past_handshakes_d` (W9), the
     arbiter-tree padding in `rr_arb_tree.sv`/`lzc.sv` (`sel_nodes[7]`,
     `index_nodes[23:21]`, `lower_empty`, `sel`), and the disabled collective
     path in `floo_output_arbiter.sv`. Forcing those to `1` perturbs the
     arbiter enough that **every router spuriously asserts `valid_out` on
     correct, unmodified RTL**. The check failed all 12 pairs on good code.
     A gate that fails on correct input is worse than no gate.

  A weaker variant (compile flags only, no runtime plusarg) was explicitly
  rejected: it demonstrably does not catch the fault, so it would be a gate
  that does not gate — manufacturing exactly the false confidence this whole
  thread exists to eliminate.

**Residual risk, and why it is acceptable.** A missing `gen_boundary` tie-off
is undetectable on Verilator under this build config, and would read X on a
simulator without X-masking (notably xezim), where it would likely be
misattributed as a simulator bug. That risk is narrow and future-facing:

- It is not present *today*. The spec-compliance review verified
  `floonoc_mesh_dut.sv` character-by-character against the Phase-1 original
  (comments stripped, whitespace collapsed) and found only the authorized
  deltas. Every tie-off is present — established fact, not assumption.
- No remaining task in this plan reopens `floonoc_mesh_dut.sv`.
- The 12-pair sweep covers every *consequential* omission, as above.

So the exposure is confined to some future edit of that one file. Task 13
records this in `docs/known_issues.md`, including the `--x-initial unique`
trap, so that (a) nobody re-attempts the target and (b) the first person to
run this bench on xezim knows to check the boundary tie-offs before filing a
simulator bug.

**A2 — items pulled forward into Task 1 from later tasks.** The stray
`coverage.dat` fix (`+verilator+coverage+file+logs/coverage_mesh.dat` on
`run-mesh`) was moved up from Task 8, because an untracked coverage dump in
the repo root is a hazard the moment it exists, not when Task 8 arrives.
`coverage.dat` was also added to `.gitignore` — belt-and-braces, since a bare
invocation of the binary still drops one. **Task 8 must therefore NOT re-add
the coverage plusarg**; it only has to change `run-mesh`'s PASS criteria (see
A3).

**A3 — Task 8 handover, now marked in the source.** `run-mesh`'s PASS check
greps for `*** MESH-SMOKE PASSED ***`, printed by the Phase-1 scaffolding
that Task 8 deletes; it must become `TEST PASSED` + `UVM_ERROR : 0` +
`UVM_FATAL : 0`, as in the `run` case. Separately, that scaffolding
procedurally drives `rif.ready_out` / `rif.valid_in` / `rif.data_in`, and the
Task 8 UVM driver drives the same interface variables — leaving both in place
is a last-write-wins race with no diagnostic. Both couplings now carry
comments in `tb/top/tb_top_mesh.sv` and `scripts/run_verilator.sh`. Task 8
also retires the 12-pair sweep, whose coverage the directed phase of
`floonoc_mesh_smoke_seq` subsumes with a scoreboard behind it.

**A4 — Task 11 SVA binding (no change, decision recorded).** After Task 1's
extraction, the inter-router handshakes are internal to `floonoc_mesh_dut`
and no longer visible from `tb_top_mesh`. This does not affect the plan: per
D5 the mesh SVA deliberately asserts only on per-router Eject ports, which
remain on `floonoc_mesh_if`, so the single interface-level instance in Task
11 still works unchanged. Recorded here so nobody reaches for hierarchical
references into `i_mesh.gen_routers[...]`, which would break the moment a
generate label changes. If inter-router assertions are ever wanted, the
answer is a `bind` inside `floonoc_mesh_dut`, not a hierarchical reference.

**A5 — Task 13 additions.** `docs/known_issues.md` needs three new rows:
the two-bench compile-separation rule (`scripts/run_verilator.sh` already
cross-references that file), the Verilator `UNDRIVEN` tracking limitation
from A1, and the boundary-tie-off blind spot — the latter written so a future
reader does not re-attempt `check-mesh-x`, and so the first person to run this
bench on xezim checks the tie-offs before filing a simulator bug. There is no
`check-mesh-x` gate; the full-regression gate and Done criteria are unchanged
from the original plan apart from `run-mesh` now sweeping 12 pairs.

**A6 — Task 2's verification grep was wrong (found during execution).** The
original Step 3 check was a plain substring grep for `FLOO_VERIF_[A-Z_]*`
minus the `MESH_` ones. That reports a *failure on a correct implementation*,
because the header comment the same step prescribes deliberately names the
old macros in prose to explain why the rename matters. Corrected in Task 2 to
match only backtick-prefixed defines and uses, and paired with a `comm -12`
over the two headers' `` `define`` names — which asserts the property the task
actually exists for (no shared names) rather than the proxy for it.

The general lesson, worth applying to the remaining tasks' verification
steps: assert the *property*, not a text pattern that happens to correlate
with it. A check that fails on correct work trains people to ignore it.

**A7 — carry-forwards from Task 2's review.**

*For Task 8 (it rewrites `tb/top/tb_top_mesh.sv`):* that file's header and the
inline comment near its imports (`:6-11`, `:22-25`, `:32-39`) do not merely go
stale after Task 2 — line 35 becomes **factually wrong**. It warns that
importing `floonoc_uvm_pkg` would redefine `dut_config_mesh.svh`'s
`X_BITS`/`Y_BITS` by macro collision. After the rename those are
`FLOO_VERIF_MESH_X_BITS`/`_Y_BITS` and collide with nothing. The *caution* is
still correct — do not import both packages into one scope — but the
mechanism moved (see below). Fix the reasoning, not just the wording, because
a Task 8 author reads exactly this comment when deciding what `tb_top_mesh`
may safely import, and could reasonably conclude the rename already handled
it.

*The real remaining hazard, for Task 13's docs:* `floo_tb_types_pkg` and
`floo_tb_mesh_types_pkg` both export `NumPorts`, `FlitDataW`, `InFifoDepth`,
`OutFifoDepth`, `x_bits_t`, `y_bits_t`, `port_id_t`, `payload_t`, `flit_t`,
`xy_id_t`, `hdr_t` and `dir_name`. A file doing
`import floo_tb_types_pkg::*; import floo_tb_mesh_types_pkg::*;` in one scope
gets a **compile-time ambiguity error** on any unqualified use — loud, at
compile time, naming the exact symbol. That is a much safer failure mode than
the silent macro substitution Task 2 closed, and it is self-defending, so it
is a documentation item and not a gap. No file currently imports both.

*Also for Task 13:* record the `FLOO_VERIF_<BENCH>_*` macro-namespacing
convention somewhere a future third bench will find it — A5's
`known_issues.md` rows do not cover it.

**A8 — Task 4's review found a self-certifying scoreboard. Task 5 changes shape
to fix it. Also corrects a wrong hypothesis of mine and a false claim in this
plan's Goals.**

*My infinite-loop hypothesis was wrong, and is recorded so nobody re-raises
it.* I suspected `exp_path`'s `forever` loop could hang on an out-of-mesh
destination, and that `convert2string()` calling `exp_hops()` on a
wire-decoded flit could therefore hang the bench on the very corruption it
exists to report. It cannot. `exp_out_port_at` is **monotone**: East is
returned only while `dst.x > cur_x`, and the caller then does `cx++`, closing
the gap by one; West only while `dst.x < cur_x`, so `cx--` cannot underflow.
The walk converges in exactly `|dx|+|dy|` steps for **any** finite
destination, inside the mesh or not. Verified by execution over 1024
start/destination combinations including destinations six routers outside a
2x2 mesh: zero non-terminating cases.

*The real defect is the mirror image: **the scoreboard's expectation key is
entirely wire-derived**, so a driver-side encoding bug would be
self-certifying.* On the input side `from_flit` takes `src_router` from the
physical port but decodes `dst_router` from `f.hdr.dst_id`. Trace a
hypothetical bug in `dst_id()` (x/y transposed, say): the driver drives a
wrong header -> the input monitor decodes that same wrong header as `D'` ->
the scoreboard pushes `expected[src][D']` -> the DUT faithfully routes to
`D'` -> the output monitor decodes `D'` and `out_router == D'` -> R1 passes,
the FIFO hits, `matched` increments. **The bench reports PASS having never
sent a flit to the destination the sequence asked for.** Nothing in the chain
compares the wire against the *intended* item.

Today the encoding is externally pinned by the hand-rolled `initial` block in
`tb/top/tb_top_mesh.sv`, which builds a header independently and checks
delivery at `router_idx(dst_x, dst_y)`. **Task 8 deletes that block**, at
which point nothing validates the encoding at all. This is the same
vacuous-checker family the workspace already lost time to (CLAUDE.md bug 17,
where scoreboard check R5 was silently not being checked on xezim).

**Decision, effective in Task 5:** the driver gains an analysis port that
publishes the **original sequence item** (pre-`as_flit()`), immediately after
the input handshake completes. The scoreboard's `write_mesh_in` subscribes to
*that*, not to the input-side wire monitor. The input monitor keeps its
`in_ap` for protocol and backpressure observation and additionally asserts
that `router_idx(src_id.x, src_id.y) == router` — a free cross-check the
current `from_flit` throws away, since it ignores the decoded `src_id` on the
input side.

This deviates from the design spec's "structurally identical agent" wording.
That wording described a shape, not a requirement; the spec's actual goal is
checker parity with the single-router bench, and this strictly increases it.
Note the single-router bench has the identical weakness — its scoreboard is
also fed from a wire monitor — so this is an improvement over the pattern
being mirrored, not a correction of a mesh-specific mistake. Worth
retrofitting there one day; explicitly out of scope here.

*The plan's Goals claim "generic over mesh shape" is FALSE as written.*
`FLOO_VERIF_MESH_X_BITS` / `_Y_BITS` are hand-set macros, independent of
`FLOO_VERIF_MESH_X` / `_Y`. If the widths cannot represent the dimensions,
`x_bits_t'(...)` truncates silently with no build error — measured at
`MeshX=3, X_BITS=1`, where routers R2->R0 and R5->R3 encode to the wrong
destination, and at `MeshX=5, X_BITS=2`, where 9 of 25 routers break. The
decode side fails too: at `MeshX=3, X_BITS=2`, 5 of 16 wire patterns decode
to `dst_router >= NumRouters`, which as a fixed-array index silently discards
the write and reads back the default. A width guard is added in Task 4's
follow-up; until it is in place the genericity claim should not be repeated.

*Deferred to Task 7, recorded so it is not lost:* range-check the decode in
`from_flit` against `NumRouters` before the value is used as a FIFO index.
`from_flit` is the single boundary where untrusted wire data becomes a TB
index, and the only place that can report a malformed header rather than
propagate it.

---

## File structure

**Created:**

| File | Responsibility |
|---|---|
| `tb/top/floonoc_mesh_dut.sv` | Plain RTL: per-router port arrays, inter-router generate wiring, boundary tie-offs, the `floo_router` array. Flat per-router Eject ports. No TB, no UVM. |
| `tb/top/lint_wrapper_mesh.sv` | Minimal UVM-free elaboration shell around `floonoc_mesh_dut` for `make lint-mesh`. |
| `tb/pkg/floonoc_mesh_uvm_pkg.sv` | Mesh UVM package; includes every mesh class in dependency order. |
| `tb/sequences/floonoc_mesh_flit_item.sv` | Transaction: src/dst router, payload, observation fields, wire encode/decode, expected-exit and hop model. |
| `tb/sequences/floonoc_mesh_smoke_seq.sv` | Topology-generated directed traffic + constrained-random phase. |
| `tb/agents/floonoc_mesh_driver.sv` | Drives Eject-in handshakes; owns the per-router Eject-out ready lines. |
| `tb/agents/floonoc_mesh_monitor.sv` | Observes every router's Eject in/out handshake; publishes two analysis streams. |
| `tb/agents/floonoc_mesh_agent.sv` | Sequencer + driver + monitor. |
| `tb/env/floonoc_mesh_scoreboard.sv` | `expected[src_router][dst_router][$]`; R1/R2/R5/R6 checks; N1/N2 injection hooks. |
| `tb/coverage/floonoc_mesh_cov.sv` | `cp_src_router`, `cp_dst_router`, `cp_hops`, `cp_backpressure`, `x_src_dst` cross. |
| `tb/env/floonoc_mesh_env.sv` | Agent + scoreboard + coverage. |
| `tb/tests/floonoc_mesh_smoke_test.sv` | Directed → random → forward-progress watchdog → drain watchdog → idle tail → PASS/FAIL. |
| `tb/tests/floonoc_mesh_negative_tests.sv` | N1/N2/N3 mirrored for the mesh. |
| `tb/assertions/floonoc_mesh_router_sva.sv` | Per-router-Eject protocol assertions and covers. |
| `sim/exp_path_check.sv` (scratch, not committed) | One-off unit check of `exp_path` (Task 3). |

**Modified:**

| File | Change |
|---|---|
| `config/dut_config_mesh.svh` | Rename all macros to the `FLOO_VERIF_MESH_*` namespace. |
| `tb/pkg/floo_tb_mesh_types_pkg.sv` | Consume renamed macros; add `MeshDiameter`. |
| `tb/top/tb_top_mesh.sv` | Instantiate `floonoc_mesh_dut`; delete Phase-1 smoke scaffolding; add UVM entry, config_db publication, SVA instance. |
| `scripts/run_verilator.sh` | Mesh lint/build/run/run-neg subcommands. |
| `Makefile` | `lint-mesh`, `build-mesh`, `run-mesh`, `run-negative-mesh`, `cov-mesh`, extended `clean`/`doctor`. |
| `docs/verification_plan.md`, `docs/assumptions.md`, `docs/uvm_coverage.md`, `docs/compatibility.md`, `README.md`, `CLAUDE.md` | Document the mesh bench. |

**Never touched:** `config/dut_config.svh`, `tb/pkg/floo_tb_types_pkg.sv`, `tb/pkg/floonoc_uvm_pkg.sv`, `tb/interfaces/floonoc_router_if.sv`, `tb/assertions/floonoc_router_sva.sv`, `tb/top/tb_top.sv`, `tb/top/lint_wrapper.sv`, and everything under `tb/sequences`, `tb/agents`, `tb/env`, `tb/coverage`, `tb/tests` whose name lacks `_mesh_`.

---

## Task 1: Extract the mesh RTL and add UVM-free mesh build plumbing

Right now the mesh wiring lives inside `tb_top_mesh.sv`, which means there is no way to lint or build the mesh without dragging in whatever TB sits on top of it. Pull the RTL out first, then add mesh targets that build the *existing* Phase-1 top so there is a working edit/run loop before any new SystemVerilog is written.

**Files:**
- Create: `tb/top/floonoc_mesh_dut.sv`
- Create: `tb/top/lint_wrapper_mesh.sv`
- Modify: `tb/top/tb_top_mesh.sv` (replace lines 58-165, the arrays through `gen_routers`)
- Modify: `scripts/run_verilator.sh`
- Modify: `Makefile`

- [ ] **Step 1: Create the extracted mesh RTL module**

Create `tb/top/floonoc_mesh_dut.sv`. The generate bodies are moved verbatim from `tb_top_mesh.sv`; only the Eject mapping changes, from interface signals to flat module ports.

```systemverilog
// -----------------------------------------------------------------------------
// The mesh DUT proper: an MeshX x MeshY array of floo_router instances with
// their North/East/South/West ports wired to each other (or tied off at a
// boundary), exposing only the per-router Eject port as a flat, TB-facing
// bus indexed by router number (row-major, see floo_tb_mesh_types_pkg).
//
// Extracted out of tb_top_mesh so the mesh can be elaborated and linted with
// no testbench and no UVM attached (tb/top/lint_wrapper_mesh.sv), and so
// tb_top_mesh is a pure TB shell. No behavioral change: the generate bodies
// below are the Phase-1 wiring verbatim.
//
// Wiring: every router uses the same 5-port floo_router as the single-router
// bench (NumRoutes=NumInput=NumOutput=5, ports [North,East,South,West,Eject]
// per floo_pkg.sv). The tie-off convention (unconnected input: valid/data='0;
// unconnected output: ready/credit='0) matches floogen's own generated mesh
// router template (floo_axi_router.sv.mako) so hand-wired and floogen-
// generated meshes agree on boundary behavior.
// -----------------------------------------------------------------------------
module floonoc_mesh_dut
  import floo_pkg::*;
  import floo_tb_mesh_types_pkg::*;
(
  input  logic                   clk_i,
  input  logic                   rst_ni,
  // TB -> router Eject input, one per router
  input  logic  [NumRouters-1:0] valid_i,
  output logic  [NumRouters-1:0] ready_o,
  input  flit_t [NumRouters-1:0] data_i,
  // router Eject output -> TB, one per router
  output logic  [NumRouters-1:0] valid_o,
  input  logic  [NumRouters-1:0] ready_i,
  output flit_t [NumRouters-1:0] data_o
);

  // Per-router [port][virt_channel] arrays (NumVirtChannels == 1), same
  // shape as the single-router bench, one set per router.
  logic  [NumRouters-1:0][NumPorts-1:0][0:0] dut_valid_in, dut_ready_in;
  logic  [NumRouters-1:0][NumPorts-1:0][0:0] dut_valid_out, dut_ready_out;
  flit_t [NumRouters-1:0][NumPorts-1:0][0:0] dut_data_in, dut_data_out;

  // Eject port (index 4) <-> the flat TB-facing bus, one per router.
  for (genvar r = 0; r < NumRouters; r++) begin : gen_eject_map
    assign dut_valid_in[r][Eject][0]  = valid_i[r];
    assign ready_o[r]                 = dut_ready_in[r][Eject][0];
    assign dut_data_in[r][Eject][0]   = data_i[r];
    assign valid_o[r]                 = dut_valid_out[r][Eject][0];
    assign dut_ready_out[r][Eject][0] = ready_i[r];
    assign data_o[r]                  = dut_data_out[r][Eject][0];
  end

  // ---------------------------------------------------------------------------
  // Inter-router mesh wiring (North/East/South/West).
  //
  // For router r, direction dir, with neighbor n = neighbor_idx(r, dir) and
  // opp = opposite_dir(dir): the link between r and n is two independent
  // channels sharing the same port pair —
  //   r.valid_o[dir]/data_o[dir]  -> n.valid_i[opp]/data_i[opp], gated by
  //   n.ready_o[opp]              -> r.ready_i[dir]
  // Looping this over EVERY (r, dir) with a neighbor covers both directions
  // of every edge exactly once each — no signal is ever assigned twice.
  // ---------------------------------------------------------------------------
  for (genvar r = 0; r < NumRouters; r++) begin : gen_router_links
    for (genvar dp = 0; dp < 4; dp++) begin : gen_dir
      localparam route_direction_e Dir = route_direction_e'(dp);
      if (has_neighbor(r, Dir)) begin : gen_connected
        localparam int unsigned Nbr = neighbor_idx(r, Dir);
        localparam route_direction_e Opp = opposite_dir(Dir);
        // dut_ready_in[r] is router r's OWN ready_o output and must never be
        // assigned here. Only dut_ready_out (the router's ready_i INPUT)
        // needs external drive, fed by the neighbor's ready_o — the mirror
        // iteration (r'=Nbr, dir'=Opp) assigns dut_ready_out[r][Dir].
        assign dut_valid_in[r][Dir][0]    = dut_valid_out[Nbr][Opp][0];
        assign dut_data_in[r][Dir][0]     = dut_data_out[Nbr][Opp][0];
        assign dut_ready_out[Nbr][Opp][0] = dut_ready_in[r][Dir][0];
      end else begin : gen_boundary
        // No neighbor: nothing ever arrives (valid/data='0) and nothing
        // ever drains this output (ready_i='0).
        assign dut_valid_in[r][Dir][0]  = 1'b0;
        assign dut_data_in[r][Dir][0]   = '0;
        assign dut_ready_out[r][Dir][0] = 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Router array
  // ---------------------------------------------------------------------------
  for (genvar r = 0; r < NumRouters; r++) begin : gen_routers
    localparam xy_id_t RouterId = '{
      x:       x_bits_t'(router_x(r)),
      y:       y_bits_t'(router_y(r)),
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
      .clk_i          ( clk_i             ),
      .rst_ni         ( rst_ni            ),
      .test_enable_i  ( 1'b0              ),
      .xy_id_i        ( RouterId          ),
      .id_route_map_i ( '0                ),  // unused for XYRouting
      .valid_i        ( dut_valid_in[r]   ),
      .ready_o        ( dut_ready_in[r]   ),
      .data_i         ( dut_data_in[r]    ),
      .credit_o       (                   ),  // VcNaive: constant, unused
      .valid_o        ( dut_valid_out[r]  ),
      .ready_i        ( dut_ready_out[r]  ),
      .data_o         ( dut_data_out[r]   ),
      .credit_i       ( '0                ),
      .offload_req_o  (                   ),  // collectives disabled
      .offload_rsp_i  ( '0                )
    );
  end

endmodule : floonoc_mesh_dut
```

- [ ] **Step 2: Create the mesh lint wrapper**

Create `tb/top/lint_wrapper_mesh.sv`. Mirrors `tb/top/lint_wrapper.sv`'s purpose: elaborate the mesh with the exact bench parameterization and zero UVM, so lint findings are attributable to DUT RTL only.

```systemverilog
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
```

- [ ] **Step 3: Gut `tb_top_mesh.sv` down to a TB shell around `floonoc_mesh_dut`**

In `tb/top/tb_top_mesh.sv`, delete everything from the `// Interface (Eject ports only) + per-router DUT port arrays` banner through the end of the `gen_routers` block (currently lines 58-165), and replace it with:

```systemverilog
  // ---------------------------------------------------------------------------
  // Interface (Eject ports only) + mesh DUT
  //
  // The mesh RTL itself lives in tb/top/floonoc_mesh_dut.sv so it can be
  // linted with no TB attached (make lint-mesh). Local nets sit between the
  // DUT's outputs and the interface variables, matching tb_top.sv's
  // gen_if_map pattern.
  // ---------------------------------------------------------------------------
  floonoc_mesh_if rif (.clk(clk), .rst_n(rst_n));

  logic  [NumRouters-1:0] mesh_ready_in;
  logic  [NumRouters-1:0] mesh_valid_out;
  flit_t [NumRouters-1:0] mesh_data_out;

  floonoc_mesh_dut i_mesh (
    .clk_i   ( clk              ),
    .rst_ni  ( rst_n            ),
    .valid_i ( rif.valid_in     ),
    .ready_o ( mesh_ready_in    ),
    .data_i  ( rif.data_in      ),
    .valid_o ( mesh_valid_out   ),
    .ready_i ( rif.ready_out    ),
    .data_o  ( mesh_data_out    )
  );

  assign rif.ready_in  = mesh_ready_in;
  assign rif.valid_out = mesh_valid_out;
  assign rif.data_out  = mesh_data_out;
```

Leave the clock/reset block, the Phase-1 smoke `initial` block, the misroute watch, the waves block and the watchdog exactly as they are — Task 8 removes the Phase-1 scaffolding, and keeping it alive here is what proves this extraction changed no behavior.

- [ ] **Step 4: Add mesh subcommands to `scripts/run_verilator.sh`**

Immediately after the existing `TB_SOURCES=( ... )` array, add:

```bash
# Mesh bench sources. Fully disjoint from TB_SOURCES: the two benches are
# never compiled into the same Verilator invocation (see docs/known_issues.md
# and config/dut_config_mesh.svh). Grows in Task 8 (UVM) and Task 11 (SVA).
TB_MESH_SOURCES=(
  tb/pkg/floo_tb_mesh_types_pkg.sv
  tb/interfaces/floonoc_mesh_if.sv
  tb/top/floonoc_mesh_dut.sv
  tb/top/tb_top_mesh.sv
)
```

Then, immediately after the `do_build()` function, add:

```bash
do_build_mesh() {
  require_sources
  local lz4_cflags="" lz4_ldflags="-llz4"
  if command -v brew >/dev/null 2>&1 && brew --prefix lz4 >/dev/null 2>&1; then
    local lz4_prefix; lz4_prefix="$(brew --prefix lz4)"
    lz4_cflags="-I$lz4_prefix/include"
    lz4_ldflags="-L$lz4_prefix/lib -llz4"
  fi
  log_and_run "logs/build_mesh.log" \
    verilator --binary -j 0 \
      ${lz4_cflags:+-CFLAGS "$lz4_cflags"} \
      -LDFLAGS "$lz4_ldflags" \
      --trace-fst \
      -f config/verilator.f \
      -f "$BUILD/sources.f" \
      "${TB_MESH_SOURCES[@]}" \
      --top-module tb_top_mesh \
      -Mdir "$BUILD/obj_dir_mesh" \
      -o Vtb_top_mesh
  grep '^\$' "logs/build_mesh.log" > "$BUILD/build_cmd_mesh.txt"
  echo "[verilator] mesh build PASS -> $BUILD/obj_dir_mesh/Vtb_top_mesh (log: logs/build_mesh.log)"
}
```

Then add three new cases to the `case "${1:-}" in` block, immediately before the final `*)` catch-all:

```bash
  lint-mesh)
    require_sources
    log_and_run logs/lint_mesh.log \
      verilator --lint-only -sv --timing \
        config/verilator_waivers.vlt \
        +incdir+config \
        -f "$BUILD/sources.f" \
        tb/pkg/floo_tb_mesh_types_pkg.sv \
        tb/top/floonoc_mesh_dut.sv \
        tb/top/lint_wrapper_mesh.sv \
        --top-module lint_wrapper_mesh
    echo "[verilator] mesh lint PASS: zero unwaived warnings (log: logs/lint_mesh.log)"
    ;;

  build-mesh)
    do_build_mesh
    ;;

  run-mesh)
    shift
    RUN_LOG=logs/run_mesh.log
    if [ ! -x "$BUILD/obj_dir_mesh/Vtb_top_mesh" ]; then
      echo "[verilator] ERROR: $BUILD/obj_dir_mesh/Vtb_top_mesh missing — run 'make build-mesh' first" >&2
      exit 1
    fi
    set +e
    log_and_run "$RUN_LOG" "$BUILD/obj_dir_mesh/Vtb_top_mesh" "$@"
    rc=$?
    set -e
    if [ $rc -ne 0 ]; then
      echo "[verilator] mesh run FAILED (simulator exit $rc, log: $RUN_LOG)" >&2
      exit 1
    fi
    if ! grep -q '\*\*\* MESH-SMOKE PASSED \*\*\*' "$RUN_LOG"; then
      echo "[verilator] mesh run FAILED: missing PASS banner (log: $RUN_LOG)" >&2
      exit 1
    fi
    echo "[verilator] mesh run PASS (log: $RUN_LOG)"
    ;;
```

Finally update the usage line at the bottom:

```bash
    echo "usage: $0 {lint|build [fst|vcd]|run [+plusargs]|run-neg <test> <re>|waves|waves-vcd|lint-mesh|build-mesh|run-mesh [+plusargs]}" >&2
```

- [ ] **Step 5: Add mesh targets to the `Makefile`**

Add `lint-mesh build-mesh run-mesh` to the `.PHONY` line, and add these targets immediately after the existing `run-negative` target:

```make
# --- Mesh bench (2x2 mesh of floo_router, independent top-level) ---------------
# Built and run as a SEPARATE Verilator binary from the single-router bench:
# different top module, different obj dir, different coverage file. The two
# benches must never share a compile unit — see config/dut_config_mesh.svh.
lint-mesh: build/sources.f
	./scripts/run_verilator.sh lint-mesh

build-mesh: build/sources.f
	./scripts/run_verilator.sh build-mesh

run-mesh:
	./scripts/run_verilator.sh run-mesh
```

Extend `clean` to drop the mesh artifacts:

```make
clean:
	rm -rf build waves/*.fst waves/*.vcd
	@echo "[clean] removed build outputs (logs/ kept as evidence)"
```

- [ ] **Step 6: Verify the mesh lints, builds and still passes Phase-1 smoke**

```bash
export UVM_HOME=/Users/chenbh/verification/uvm/1800.2-2017-1.0
make lint-mesh && make build-mesh && make run-mesh
```

Expected: `[verilator] mesh lint PASS`, `[verilator] mesh build PASS`, and in `logs/run_mesh.log` the lines `[MESH-SMOKE] flit accepted at router 0, expecting delivery at router 3`, `[MESH-SMOKE] payload 0xcafed00d00002a2a delivered at router 3`, `*** MESH-SMOKE PASSED ***`, then `[verilator] mesh run PASS`.

- [ ] **Step 7: Verify the single-router bench is untouched**

```bash
make lint && make build && make run
```

Expected: `[verilator] lint PASS`, `[verilator] run PASS`, `*** TEST PASSED *** (25 flits accepted, 25 delivered, 25 matched, 0 mismatches)`.

- [ ] **Step 8: Commit**

```bash
git add tb/top/floonoc_mesh_dut.sv tb/top/lint_wrapper_mesh.sv tb/top/tb_top_mesh.sv \
        scripts/run_verilator.sh Makefile
git commit -m "refactor(mesh): extract mesh RTL into floonoc_mesh_dut, add mesh lint/build/run targets

Splits the inter-router generate wiring and floo_router array out of
tb_top_mesh into a plain RTL module so the mesh can be elaborated with no
testbench attached, and adds a separate Verilator invocation (own top
module, own obj dir) for the mesh bench. No behavioral change: the Phase-1
directed smoke check still passes unmodified."
```

---

## Task 2: Namespace the mesh config macros

`config/dut_config.svh` and `config/dut_config_mesh.svh` define the *same* macro names (`FLOO_VERIF_X_BITS`, `FLOO_VERIF_NUM_PORTS`, …) with *different* values, under *different* include guards. `config/verilator.f` puts `+incdir+config` on every build. Nothing pulls both in today, but the mesh UVM package is about to make that a live hazard. Close it structurally rather than by convention.

**Files:**
- Modify: `config/dut_config_mesh.svh`
- Modify: `tb/pkg/floo_tb_mesh_types_pkg.sv`

- [ ] **Step 1: Rename every mesh macro into the `FLOO_VERIF_MESH_*` namespace**

In `config/dut_config_mesh.svh`, rename the six colliding macros. `FLOO_VERIF_MESH_X` and `FLOO_VERIF_MESH_Y` are already namespaced and stay as they are. Also add a short note explaining why the namespace exists. The macro block becomes:

```systemverilog
// Every macro below is deliberately in the FLOO_VERIF_MESH_* namespace.
// dut_config.svh (the single-router bench) defines FLOO_VERIF_NUM_PORTS,
// FLOO_VERIF_X_BITS etc. with DIFFERENT values, under a different include
// guard, and config/verilator.f puts +incdir+config on every build — so
// identical names here would silently redefine each other in include order
// if the two benches ever met in one compile unit. Distinct names make that
// impossible instead of merely unlikely.

// Mesh dimensions. 2x2 is the smallest topology that is actually a mesh
// (multi-hop routing exists) — deliberately smaller than FlooNoC's own
// floogen examples (which default to 4x4) so the hand-wired TB architecture
// can be proven out before scaling.
`define FLOO_VERIF_MESH_X              2
`define FLOO_VERIF_MESH_Y              2

// Number of router ports (N, E, S, W, Eject) — same canonical router as the
// single-router bench; every router in the mesh uses all 5, with boundary
// ports tied off per floogen's own convention (floo_axi_router.sv.mako):
// unconnected inputs tie valid/data to '0, unconnected outputs tie
// ready/credit to '0.
`define FLOO_VERIF_MESH_NUM_PORTS      5

// Payload width of the generic flit (bits). Same as the single-router bench.
`define FLOO_VERIF_MESH_FLIT_DATA_W    64

// Coordinate bit widths: 1 bit each covers a 2x2 mesh (id range 0..1).
`define FLOO_VERIF_MESH_X_BITS         1
`define FLOO_VERIF_MESH_Y_BITS         1
`define FLOO_VERIF_MESH_PORT_ID_BITS   1

// FIFO depths (InFifoDepth > 0 required for wormhole input buffering) —
// same as the single-router bench.
`define FLOO_VERIF_MESH_IN_FIFO_DEPTH  2
`define FLOO_VERIF_MESH_OUT_FIFO_DEPTH 2
```

- [ ] **Step 2: Update the package to consume the renamed macros and add `MeshDiameter`**

In `tb/pkg/floo_tb_mesh_types_pkg.sv`, replace the localparam/typedef block (currently lines 20-31) with:

```systemverilog
  localparam int unsigned MeshX        = `FLOO_VERIF_MESH_X;
  localparam int unsigned MeshY        = `FLOO_VERIF_MESH_Y;
  localparam int unsigned NumRouters   = MeshX * MeshY;
  localparam int unsigned NumPorts     = `FLOO_VERIF_MESH_NUM_PORTS;
  localparam int unsigned FlitDataW    = `FLOO_VERIF_MESH_FLIT_DATA_W;
  localparam int unsigned InFifoDepth  = `FLOO_VERIF_MESH_IN_FIFO_DEPTH;
  localparam int unsigned OutFifoDepth = `FLOO_VERIF_MESH_OUT_FIFO_DEPTH;

  // Longest possible route in a mesh under dimension-order XY routing:
  // (MeshX-1) X hops plus (MeshY-1) Y hops. Used for the drain budget and
  // for the hop-count coverage bins, so neither has to hardcode "2x2".
  localparam int unsigned MeshDiameter = MeshX + MeshY - 2;

  typedef logic [`FLOO_VERIF_MESH_X_BITS-1:0]       x_bits_t;
  typedef logic [`FLOO_VERIF_MESH_Y_BITS-1:0]       y_bits_t;
  typedef logic [`FLOO_VERIF_MESH_PORT_ID_BITS-1:0] port_id_t;
  typedef logic [FlitDataW-1:0]                     payload_t;
```

- [ ] **Step 3: Prove no old macro name survives in mesh files**

Match only actual `` `define``s and macro *uses* (backtick-prefixed). A plain
substring grep gives a false failure here, because the header comment above
deliberately names the old macros in prose to explain the rename:

```bash
grep -rnE '`(define[[:space:]]+)?FLOO_VERIF_(NUM_PORTS|FLIT_DATA_W|X_BITS|Y_BITS|PORT_ID_BITS|IN_FIFO_DEPTH|OUT_FIFO_DEPTH)\b' \
  config/dut_config_mesh.svh tb/pkg/floo_tb_mesh_types_pkg.sv
```

Expected: **no output**.

Then assert the thing this task actually exists for — that the two headers
now share no macro name at all, so an order-dependent redefinition is
impossible rather than merely unlikely:

```bash
comm -12 <(grep -oE '^`define[[:space:]]+[A-Z_]+' config/dut_config.svh      | awk '{print $2}' | sort -u) \
         <(grep -oE '^`define[[:space:]]+[A-Z_]+' config/dut_config_mesh.svh | awk '{print $2}' | sort -u)
```

Expected: **no output**. Anything listed here is a Critical finding.

- [ ] **Step 4: Verify both benches still pass**

```bash
make lint-mesh && make build-mesh && make run-mesh
make lint && make build && make run
```

Expected: `*** MESH-SMOKE PASSED ***` / `[verilator] mesh run PASS`, and `*** TEST PASSED *** (25 flits accepted, ...)` / `[verilator] run PASS`.

- [ ] **Step 5: Commit**

```bash
git add config/dut_config_mesh.svh tb/pkg/floo_tb_mesh_types_pkg.sv
git commit -m "fix(mesh): namespace mesh config macros as FLOO_VERIF_MESH_*

dut_config.svh and dut_config_mesh.svh defined the same macro names with
different values (X_BITS 2 vs 1) under different include guards, while
config/verilator.f puts +incdir+config on every build. Distinct names make
a silent order-dependent redefinition impossible rather than merely
unlikely. Also adds MeshDiameter for the drain budget and hop coverage bins."
```

---

## Task 3: Unit-test `exp_path` before anything depends on it

`floo_tb_mesh_types_pkg::exp_path` is the package's multi-hop routing model, but nothing calls it today — the Phase-1 smoke check hand-wrote its own expectation. The hop-count model in Task 4 will be the first real consumer. Test it first, exhaustively, against an independent formula.

Under dimension-order XY routing on a mesh with no faults, the number of hops from `src` to `dst` is exactly the Manhattan distance `|dst_x - src_x| + |dst_y - src_y|`. That is an independent oracle: `exp_path` derives it by simulating turns, the oracle derives it by arithmetic.

**Files:**
- Create (scratch, not committed): `/private/tmp/claude-501/-Users-chenbh-verification-FlooNOC-verif/f55002dc-6852-41a9-997e-b5de7d9de8b7/scratchpad/exp_path_check.sv`

- [ ] **Step 1: Write the failing check**

Create the file above with:

```systemverilog
// Exhaustive check of floo_tb_mesh_types_pkg::exp_path over every (src,dst)
// router pair, against Manhattan distance as an independent oracle. Scratch
// file: not part of the bench, not committed.
module exp_path_check;
  import floo_tb_mesh_types_pkg::*;

  int unsigned fails = 0;

  initial begin
    for (int unsigned s = 0; s < NumRouters; s++) begin
      for (int unsigned d = 0; d < NumRouters; d++) begin
        automatic int unsigned path[$];
        automatic xy_id_t      dst;
        automatic int unsigned sx = router_x(s), sy = router_y(s);
        automatic int unsigned dx = router_x(d), dy = router_y(d);
        automatic int unsigned manhattan =
            ((dx > sx) ? (dx - sx) : (sx - dx)) +
            ((dy > sy) ? (dy - sy) : (sy - dy));

        dst = '{x: x_bits_t'(dx), y: y_bits_t'(dy), port_id: '0};
        exp_path(sx, sy, dst, path);

        if (path.size() == 0) begin
          $display("FAIL R%0d->R%0d: exp_path returned an empty path", s, d);
          fails++;
        end else if (path[0] != s) begin
          $display("FAIL R%0d->R%0d: path starts at R%0d, expected R%0d",
                   s, d, path[0], s);
          fails++;
        end else if (path[path.size()-1] != d) begin
          $display("FAIL R%0d->R%0d: path ends at R%0d, expected R%0d",
                   s, d, path[path.size()-1], d);
          fails++;
        end else if ((path.size() - 1) != manhattan) begin
          $display("FAIL R%0d->R%0d: %0d hops, Manhattan distance is %0d",
                   s, d, path.size()-1, manhattan);
          fails++;
        end else begin
          $display("ok   R%0d(%0d,%0d)->R%0d(%0d,%0d): %0d hop(s)",
                   s, sx, sy, d, dx, dy, path.size()-1);
        end
      end
    end

    if (fails == 0) $display("*** EXP_PATH CHECK PASSED ***");
    else            $display("*** EXP_PATH CHECK FAILED (%0d) ***", fails);
    $finish;
  end
endmodule
```

- [ ] **Step 2: Build and run it**

```bash
export UVM_HOME=/Users/chenbh/verification/uvm/1800.2-2017-1.0
SCRATCH=/private/tmp/claude-501/-Users-chenbh-verification-FlooNOC-verif/f55002dc-6852-41a9-997e-b5de7d9de8b7/scratchpad
verilator --binary -j 0 -sv --timing \
  config/verilator_waivers.vlt \
  +incdir+config \
  -f build/sources.f \
  tb/pkg/floo_tb_mesh_types_pkg.sv \
  "$SCRATCH/exp_path_check.sv" \
  --top-module exp_path_check \
  -Mdir "$SCRATCH/obj_exp_path" -o Vexp_path_check \
&& "$SCRATCH/obj_exp_path/Vexp_path_check"
```

Expected: 16 `ok` lines including `ok   R0(0,0)->R3(1,1): 2 hop(s)` and `ok   R0(0,0)->R0(0,0): 0 hop(s)`, then `*** EXP_PATH CHECK PASSED ***`.

**If it fails:** `exp_path` has a real bug and must be fixed in `tb/pkg/floo_tb_mesh_types_pkg.sv` before continuing — do not work around it in the UVM layer. If Verilator rejects the `output int unsigned path[$]` formal (a queue output argument), that is also a blocker: change `exp_path` to `function automatic int unsigned exp_hops(int unsigned src_x, src_y; xy_id_t dst)` returning the hop count directly, and have Task 4 call that instead.

- [ ] **Step 3: Nothing to commit**

The scratch file stays out of the repo. Record the result in the Task 13 doc update instead.

> **RESULT (executed 2026-09-10): PASSED.** All 16 (src,dst) pairs agree with
> the Manhattan oracle, endpoints correct in every case, including
> `R0(0,0)->R3(1,1): 2 hop(s)` and the degenerate `R0(0,0)->R0(0,0): 0 hop(s)`.
> Verilator 5.052 handles the `output int unsigned path[$]` formal with no
> complaint, so outcome (c) does not apply and Task 4's `exp_hops()` may
> depend on `exp_path` as written. Note the build needs
> `config/verilator_waivers.vlt` on the command line — without it the build
> dies on a pre-existing waived `WIDTHEXPAND` in the vendor `axi_pkg.sv`,
> unrelated to the function under test.

---

## Task 4: The mesh transaction and the package skeleton

**Files:**
- Create: `tb/sequences/floonoc_mesh_flit_item.sv`
- Create: `tb/pkg/floonoc_mesh_uvm_pkg.sv`

- [ ] **Step 1: Write `tb/sequences/floonoc_mesh_flit_item.sv`**

```systemverilog
// -----------------------------------------------------------------------------
// Smallest meaningful mesh transaction: one single-flit packet (hdr.last == 1,
// so the wormhole route lock opens and closes per flit — see
// docs/assumptions.md A2) injected at one router's Eject port and ejected at
// another router's Eject port.
//
// Endpoints are ROUTER INDICES, not port directions. The TB only ever touches
// Eject ports; North/East/South/West are inter-router links inside
// floonoc_mesh_dut. That is why the single-router bench's per-source-direction
// constraint table does not appear here: src_router != dst_router is the only
// illegal combination.
//
// Intermediate hops stay legal automatically. floo_router ties off the
// N/S-input -> E/W-output crossbar cells under XYRouteOpt
// (hw/floo_router.sv:349-353) and asserts XYDirectionNotAllowed on them
// (:515). Dimension-order XY routing resolves X completely before it ever
// turns in Y, so a flit that arrived from North or South always has
// dst.x == cur.x and can only leave North, South or Eject — never East or
// West. NoLoopback holds for the same reason: XY routing never sends a flit
// back out the port it arrived on.
// -----------------------------------------------------------------------------
class floonoc_mesh_flit_item extends uvm_sequence_item;

  // Stimulus fields
  rand int unsigned src_router;   // injection router (its Eject input)
  rand int unsigned dst_router;   // destination router (its Eject output)
  rand payload_t    payload;

  // Observation fields (filled by the monitor)
  int unsigned out_router;        // which router's Eject port delivered it
  bit          backpressured;

  `uvm_object_utils(floonoc_mesh_flit_item)

  // Both endpoints are plain router indices, so the whole legality rule is
  // two range bounds and one inequality — deliberately solver-trivial.
  // Modeling the destination as an index rather than as (dst_x, dst_y) also
  // keeps router_idx()'s modulo/divide out of the constraint block.
  constraint c_legal_route {
    src_router < NumRouters;
    dst_router < NumRouters;
    dst_router != src_router;
  }

  function new(string name = "floonoc_mesh_flit_item");
    super.new(name);
  endfunction

  function int unsigned src_x(); return router_x(src_router); endfunction
  function int unsigned src_y(); return router_y(src_router); endfunction
  function int unsigned dst_x(); return router_x(dst_router); endfunction
  function int unsigned dst_y(); return router_y(dst_router); endfunction

  function xy_id_t dst_id();
    xy_id_t id;
    id.x       = x_bits_t'(router_x(dst_router));
    id.y       = y_bits_t'(router_y(dst_router));
    id.port_id = '0;
    return id;
  endfunction

  // The source router travels with the flit so the OUTPUT-side monitor can
  // recover it: it only sees rif.data_out[r], and the scoreboard keys its
  // expectation FIFOs on (src_router, dst_router). This is safe because
  // floo_route_select.sv rewrites hdr.dst_id ONLY under SourceRouting
  // (line 96); under XYRouting the header passes through every hop
  // unmodified (line 190, channel_o = channel_i), and hdr.src_id is read
  // only on the multicast path (floo_route_xymask.sv), which is inert here
  // (collective_op == Unicast, EnCollective off).
  function xy_id_t src_id();
    xy_id_t id;
    id.x       = x_bits_t'(router_x(src_router));
    id.y       = y_bits_t'(router_y(src_router));
    id.port_id = '0;
    return id;
  endfunction

  // Expected exit router. Under XY routing a flit ejects exactly at its
  // destination router, so this is dst_router by definition — the real
  // content of check R1 is that the DUT agrees.
  function int unsigned exp_out_router();
    return dst_router;
  endfunction

  // Hop count, from the package's multi-hop routing model. Coverage signal
  // only: floonoc_mesh_if exposes Eject endpoints, not the path taken, so
  // the scoreboard cannot and does not check intermediate routers.
  function int unsigned exp_hops();
    int unsigned path[$];
    exp_path(router_x(src_router), router_y(src_router), dst_id(), path);
    return path.size() - 1;
  endfunction

  // Build the wire-level flit.
  function flit_t as_flit();
    flit_t f;
    f            = '0;
    f.hdr.dst_id = dst_id();
    f.hdr.src_id = src_id();
    f.hdr.last   = 1'b1;
    f.payload    = payload;
    return f;
  endfunction

  // Decode an observed flit. `router` is the physical router whose Eject
  // port this was seen on.
  function void from_flit(flit_t f, int unsigned router, bit is_output, bit bp);
    dst_router    = router_idx(32'(f.hdr.dst_id.x), 32'(f.hdr.dst_id.y));
    payload       = f.payload;
    backpressured = bp;
    if (is_output) begin
      out_router = router;
      src_router = router_idx(32'(f.hdr.src_id.x), 32'(f.hdr.src_id.y));
    end else begin
      src_router = router;  // trust the physical port on the input side
    end
  endfunction

  virtual function string convert2string();
    return $sformatf("src=R%0d(%0d,%0d) dst=R%0d(%0d,%0d) hops=%0d payload=0x%016h%s",
                     src_router, router_x(src_router), router_y(src_router),
                     dst_router, router_x(dst_router), router_y(dst_router),
                     exp_hops(), payload,
                     backpressured ? " [bp]" : "");
  endfunction

endclass : floonoc_mesh_flit_item
```

- [ ] **Step 2: Write `tb/pkg/floonoc_mesh_uvm_pkg.sv`**

Include only what exists so far; later tasks extend the list.

```systemverilog
// -----------------------------------------------------------------------------
// UVM package for the FlooNoC 2x2 mesh bench. Compilation-order-safe:
// everything is included here in dependency order.
//
// Deliberately shares NOTHING with floonoc_uvm_pkg (the single-router
// bench's package) — no base classes, no types, no config header. The two
// packages are never compiled into the same Verilator invocation; see
// scripts/run_verilator.sh (TB_SOURCES vs TB_MESH_SOURCES) and the
// namespace note in config/dut_config_mesh.svh.
// -----------------------------------------------------------------------------
`include "uvm_macros.svh"
`include "dut_config_mesh.svh"

package floonoc_mesh_uvm_pkg;

  import uvm_pkg::*;
  import floo_tb_mesh_types_pkg::*;

  `include "floonoc_mesh_flit_item.sv"

endpackage : floonoc_mesh_uvm_pkg
```

- [ ] **Step 3: Compile-check the package**

```bash
export UVM_HOME=/Users/chenbh/verification/uvm/1800.2-2017-1.0
verilator --lint-only -sv --timing \
  -f config/verilator.f \
  -f build/sources.f \
  +incdir+"$UVM_HOME/src" \
  "$UVM_HOME/src/uvm_pkg.sv" \
  tb/pkg/floo_tb_mesh_types_pkg.sv \
  tb/interfaces/floonoc_mesh_if.sv \
  tb/pkg/floonoc_mesh_uvm_pkg.sv \
  tb/top/floonoc_mesh_dut.sv \
  tb/top/lint_wrapper_mesh.sv \
  --top-module lint_wrapper_mesh
```

Expected: exits 0 with no `%Error` and no `%Warning`. Keep this exact command handy — Tasks 5, 6 and 7 re-run it after each class is added.

- [ ] **Step 4: Commit**

```bash
git add tb/sequences/floonoc_mesh_flit_item.sv tb/pkg/floonoc_mesh_uvm_pkg.sv
git commit -m "feat(mesh): add mesh flit transaction and UVM package skeleton

Endpoints are router indices, not port directions. The source router rides
in hdr.src_id so the output-side monitor can recover it — the DUT only
rewrites hdr.dst_id under SourceRouting, never under XYRouting."
```

---

## Task 5: Driver, monitor, agent

**Files:**
- Create: `tb/agents/floonoc_mesh_driver.sv`
- Create: `tb/agents/floonoc_mesh_monitor.sv`
- Create: `tb/agents/floonoc_mesh_agent.sv`
- Modify: `tb/pkg/floonoc_mesh_uvm_pkg.sv`

- [ ] **Step 1: Write `tb/agents/floonoc_mesh_driver.sv`**

```systemverilog
// -----------------------------------------------------------------------------
// Driver: converts mesh flit items into valid/ready handshakes on the
// injection router's Eject INPUT port, honoring the DUT contract that valid
// stays asserted (with stable data) until ready (mirrors the DUT's
// StableValidIn assertion).
//
// It also owns every router's Eject OUTPUT ready line: each is re-randomized
// every cycle (~80% high) to exercise backpressure while remaining a legal
// sink. Note the loop is over NumRouters, not NumPorts: in the mesh only
// Eject ports face the TB, one per router.
//
// Timing discipline: all pins are driven with non-blocking assignments at
// posedge and all DUT outputs are read at posedge (pre-edge values), which
// matches SVA sampling semantics under Verilator --timing.
// -----------------------------------------------------------------------------
class floonoc_mesh_driver extends uvm_driver #(floonoc_mesh_flit_item);

  `uvm_component_utils(floonoc_mesh_driver)

  virtual floonoc_mesh_if vif;

  // Probability (percent) that a router's Eject ready is high in a given cycle
  int unsigned ready_pct = 80;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    int rp;
    super.build_phase(phase);
    if (!uvm_config_db#(virtual floonoc_mesh_if)::get(this, "", "vif", vif)) begin
      `uvm_fatal("DRV", "virtual interface not found in config_db")
    end
    // Overridable for backpressure scenarios (0 = outputs never ready,
    // used by the floonoc_mesh_neg_stall self-test)
    if (uvm_config_db#(int)::get(this, "", "ready_pct", rp)) begin
      if (rp < 0) rp = 0;
      ready_pct = unsigned'(rp);
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    floonoc_mesh_flit_item item;

    vif.valid_in  <= '0;
    vif.data_in   <= '0;
    vif.ready_out <= '1;

    fork
      drive_output_ready();
    join_none

    wait (vif.rst_n === 1'b1);
    @(posedge vif.clk);

    forever begin
      seq_item_port.get_next_item(item);
      drive_flit(item);
      seq_item_port.item_done();
    end
  endtask

  // Assert valid/data after the current edge; they participate in the
  // handshake from the next posedge on. Hold until ready seen at an edge.
  task drive_flit(floonoc_mesh_flit_item item);
    int unsigned r = item.src_router;
    vif.valid_in[r] <= 1'b1;
    vif.data_in[r]  <= item.as_flit();
    do begin
      @(posedge vif.clk);
    end while (!(vif.valid_in[r] === 1'b1 && vif.ready_in[r] === 1'b1));
    vif.valid_in[r] <= 1'b0;
    `uvm_info("DRV", {"sent: ", item.convert2string()}, UVM_HIGH)
  endtask

  // Legal random sink: ready may toggle freely; the DUT does not require
  // ready stability (ready/valid dependency rules only constrain valid).
  task drive_output_ready();
    forever begin
      @(posedge vif.clk);
      for (int unsigned r = 0; r < NumRouters; r++) begin
        vif.ready_out[r] <= bit'($urandom_range(99) < ready_pct);
      end
    end
  endtask

endclass : floonoc_mesh_driver
```

- [ ] **Step 2: Write `tb/agents/floonoc_mesh_monitor.sv`**

```systemverilog
// -----------------------------------------------------------------------------
// Monitor: observes every router's Eject-input and Eject-output handshake and
// publishes the transactions through two analysis ports. Backpressure
// (valid && !ready) seen while a flit waits is recorded on the transaction
// for coverage.
//
// On the input side the source router is the physical port index. On the
// output side it is decoded from hdr.src_id, which the DUT carries through
// every hop untouched under XYRouting.
// -----------------------------------------------------------------------------
class floonoc_mesh_monitor extends uvm_monitor;

  `uvm_component_utils(floonoc_mesh_monitor)

  virtual floonoc_mesh_if vif;

  uvm_analysis_port #(floonoc_mesh_flit_item) in_ap;   // accepted input flits
  uvm_analysis_port #(floonoc_mesh_flit_item) out_ap;  // delivered output flits

  // Sticky per-router backpressure trackers (cleared on handshake)
  protected bit in_bp  [NumRouters];
  protected bit out_bp [NumRouters];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    in_ap  = new("in_ap", this);
    out_ap = new("out_ap", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual floonoc_mesh_if)::get(this, "", "vif", vif)) begin
      `uvm_fatal("MON", "virtual interface not found in config_db")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    floonoc_mesh_flit_item item;
    wait (vif.rst_n === 1'b1);
    forever begin
      @(posedge vif.clk);
      for (int unsigned r = 0; r < NumRouters; r++) begin
        // Input side (TB -> router r's Eject input)
        if (vif.valid_in[r] === 1'b1 && vif.ready_in[r] !== 1'b1) begin
          in_bp[r] = 1'b1;
        end
        if (vif.valid_in[r] === 1'b1 && vif.ready_in[r] === 1'b1) begin
          item = floonoc_mesh_flit_item::type_id::create($sformatf("mon_in_r%0d", r));
          item.from_flit(vif.data_in[r], r, /*is_output*/ 1'b0, in_bp[r]);
          in_bp[r] = 1'b0;
          `uvm_info("MON", {"in : ", item.convert2string()}, UVM_HIGH)
          in_ap.write(item);
        end
        // Output side (router r's Eject output -> TB)
        if (vif.valid_out[r] === 1'b1 && vif.ready_out[r] !== 1'b1) begin
          out_bp[r] = 1'b1;
        end
        if (vif.valid_out[r] === 1'b1 && vif.ready_out[r] === 1'b1) begin
          item = floonoc_mesh_flit_item::type_id::create($sformatf("mon_out_r%0d", r));
          item.from_flit(vif.data_out[r], r, /*is_output*/ 1'b1, out_bp[r]);
          out_bp[r] = 1'b0;
          `uvm_info("MON", {"out: ", item.convert2string()}, UVM_HIGH)
          out_ap.write(item);
        end
      end
    end
  endtask

endclass : floonoc_mesh_monitor
```

- [ ] **Step 3: Write `tb/agents/floonoc_mesh_agent.sv`**

```systemverilog
// -----------------------------------------------------------------------------
// Active agent bundling sequencer, driver and monitor for the mesh's
// per-router Eject ports.
// -----------------------------------------------------------------------------
typedef uvm_sequencer #(floonoc_mesh_flit_item) floonoc_mesh_sequencer;

class floonoc_mesh_agent extends uvm_agent;

  `uvm_component_utils(floonoc_mesh_agent)

  floonoc_mesh_sequencer sqr;
  floonoc_mesh_driver    drv;
  floonoc_mesh_monitor   mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = floonoc_mesh_sequencer::type_id::create("sqr", this);
    drv = floonoc_mesh_driver::type_id::create("drv", this);
    mon = floonoc_mesh_monitor::type_id::create("mon", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction

endclass : floonoc_mesh_agent
```

- [ ] **Step 4: Extend the package include list**

In `tb/pkg/floonoc_mesh_uvm_pkg.sv`, replace the single include with:

```systemverilog
  `include "floonoc_mesh_flit_item.sv"
  `include "floonoc_mesh_driver.sv"
  `include "floonoc_mesh_monitor.sv"
  `include "floonoc_mesh_agent.sv"
```

- [ ] **Step 5: Compile-check**

Re-run the exact command from Task 4 Step 3. Expected: exits 0, no `%Error`, no `%Warning`.

- [ ] **Step 6: Commit**

```bash
git add tb/agents/floonoc_mesh_driver.sv tb/agents/floonoc_mesh_monitor.sv \
        tb/agents/floonoc_mesh_agent.sv tb/pkg/floonoc_mesh_uvm_pkg.sv
git commit -m "feat(mesh): add mesh driver, monitor and agent

Driver and monitor iterate over NumRouters (Eject ports only) rather than
NumPorts: in the mesh, N/E/S/W are inter-router links inside
floonoc_mesh_dut and are never TB-facing."
```

---

## Task 6: Topology-generated directed smoke sequence

Directed traffic is *generated from the topology helpers*, never from a literal table, so a later `dut_config_mesh.svh` bump to a larger mesh needs no edits here.

**Files:**
- Create: `tb/sequences/floonoc_mesh_smoke_seq.sv`
- Modify: `tb/pkg/floonoc_mesh_uvm_pkg.sv`

- [ ] **Step 1: Write `tb/sequences/floonoc_mesh_smoke_seq.sv`**

The random phase is written now but disabled (`num_random = 0`); Task 9 turns it on once the scoreboard is proven on deterministic traffic.

```systemverilog
// -----------------------------------------------------------------------------
// Mesh smoke sequence.
//
// Directed phase A: every physical inter-router link, in both directions,
//   as a 1-hop case (inject at r's Eject, destination is r's neighbor).
// Directed phase B: both mesh diagonals, both directions each — guarantees
//   at least one full-diameter (MeshDiameter-hop) case and exercises both
//   X-then-Y turn senses.
// Random phase: constrained-random legal flits (src != dst).
//
// Generated from floo_tb_mesh_types_pkg's topology helpers rather than from
// a literal table, so a larger mesh needs no change here. The illegal
// src == dst case is deliberately NOT tested: c_legal_route makes it
// unconstructible, and Phase 1's RTL-level smoke check already confirmed the
// DUT's own NoLoopback assertion fires for it.
// -----------------------------------------------------------------------------
class floonoc_mesh_smoke_seq extends uvm_sequence #(floonoc_mesh_flit_item);

  `uvm_object_utils(floonoc_mesh_smoke_seq)

  int unsigned num_random = 0;   // Task 9 raises this

  // Running index, used for the directed payload signature.
  protected int unsigned n_sent = 0;

  function new(string name = "floonoc_mesh_smoke_seq");
    super.new(name);
  endfunction

  // One directed flit with a recognizable payload (0xFACE_....).
  task send_directed(int unsigned src, int unsigned dst, string why);
    floonoc_mesh_flit_item item;
    item = floonoc_mesh_flit_item::type_id::create($sformatf("directed_%0d", n_sent));
    start_item(item);
    item.src_router = src;
    item.dst_router = dst;
    item.payload    = payload_t'(64'hFACE_0000_0000_0000 + 64'(n_sent));
    finish_item(item);
    `uvm_info("SEQ", $sformatf("directed[%0s]: %s", why, item.convert2string()), UVM_MEDIUM)
    n_sent++;
  endtask

  // Both directions of one pair, skipped if the pair degenerates (which
  // happens for the diagonals on a 1xN or Nx1 mesh — src == dst is illegal).
  task send_pair(int unsigned a, int unsigned b, string why);
    if (a == b) begin
      `uvm_info("SEQ", $sformatf("skipping degenerate %0s pair R%0d", why, a), UVM_MEDIUM)
      return;
    end
    send_directed(a, b, why);
    send_directed(b, a, why);
  endtask

  virtual task body();
    floonoc_mesh_flit_item item;

    // --- Directed phase A: every physical link, both directions ------------
    // Injecting at r for destination neighbor_idx(r, dir) routes out of r's
    // `dir` port and ejects at the neighbor, so the r -> neighbor half of
    // that link is exercised. The (neighbor, opposite_dir) iteration covers
    // the other half.
    for (int unsigned r = 0; r < NumRouters; r++) begin
      for (int unsigned d = 0; d < 4; d++) begin
        route_direction_e dir = route_direction_e'(d);
        if (!has_neighbor(r, dir)) continue;
        send_directed(r, neighbor_idx(r, dir),
                      $sformatf("link R%0d.%0s", r, dir_name(d)));
      end
    end

    // --- Directed phase B: both diagonals, both directions -----------------
    send_pair(router_idx(0, 0), router_idx(MeshX-1, MeshY-1), "diag-main");
    send_pair(router_idx(MeshX-1, 0), router_idx(0, MeshY-1), "diag-anti");

    // --- Random phase: constrained-random legal traffic --------------------
    repeat (num_random) begin
      item = floonoc_mesh_flit_item::type_id::create("rand_item");
      start_item(item);
      if (item.randomize() == 0) begin
        `uvm_error("SEQ", "randomize() failed")
      end
      finish_item(item);
      `uvm_info("SEQ", {"random:   ", item.convert2string()}, UVM_MEDIUM)
      n_sent++;
    end
  endtask

endclass : floonoc_mesh_smoke_seq
```

At 2×2 this emits **12 directed flits**: 8 link cases (4 edges × 2 directions) and 4 diagonal cases (R0↔R3, R1↔R2).

- [ ] **Step 2: Extend the package include list**

In `tb/pkg/floonoc_mesh_uvm_pkg.sv`, insert `floonoc_mesh_smoke_seq.sv` after the flit item:

```systemverilog
  `include "floonoc_mesh_flit_item.sv"
  `include "floonoc_mesh_smoke_seq.sv"
  `include "floonoc_mesh_driver.sv"
  `include "floonoc_mesh_monitor.sv"
  `include "floonoc_mesh_agent.sv"
```

- [ ] **Step 3: Compile-check**

Re-run the exact command from Task 4 Step 3. Expected: exits 0, no `%Error`, no `%Warning`.

- [ ] **Step 4: Commit**

```bash
git add tb/sequences/floonoc_mesh_smoke_seq.sv tb/pkg/floonoc_mesh_uvm_pkg.sv
git commit -m "feat(mesh): add topology-generated directed smoke sequence

Directed traffic is derived from has_neighbor/neighbor_idx/router_idx rather
than a literal table, so it scales with dut_config_mesh.svh. Random phase is
present but disabled until the scoreboard is proven on deterministic traffic."
```

---

## Task 7: Mesh scoreboard

**Files:**
- Create: `tb/env/floonoc_mesh_scoreboard.sv`
- Modify: `tb/pkg/floonoc_mesh_uvm_pkg.sv`

- [ ] **Step 1: Write `tb/env/floonoc_mesh_scoreboard.sv`**

```systemverilog
// -----------------------------------------------------------------------------
// Mesh scoreboard. Checks (traceability in docs/verification_plan.md):
//  R1 routing      — every accepted flit is ejected at exactly the router
//                    predicted by the XY routing rule (i.e. its destination)
//  R2 payload      — payload and destination header arrive unmodified
//  R5 no loss/dup  — every accepted flit is delivered exactly once; any
//                    output flit without a pending expectation is an error
//  R6 ordering     — flits of the same (src router -> dst router) pair are
//                    delivered in acceptance order (per-pair FIFO)
//
// R6 on a mesh: two flits sharing (src, dst) take the SAME route, because
// dimension-order XY routing is deterministic and stateless. They therefore
// enter each intermediate router on the same input port and leave on the
// same output port, and every stage between them is a FIFO (input
// stream_fifo, output fifo). Nothing can reorder them relative to each
// other. Cross-pair order is deliberately NOT assumed — see
// docs/assumptions.md A4-M.
//
// Path correctness is deliberately NOT checked: floonoc_mesh_if exposes only
// Eject endpoints, not the hops in between. Intermediate-router behavior is
// the RTL wiring layer's job (Phase 1) and the DUT's own per-router
// XYDirectionNotAllowed / NoLoopback assertions.
// -----------------------------------------------------------------------------

// Distinct suffixes from the single-router bench's _in/_out: these macros
// define GLOBAL class names (uvm_analysis_imp_mesh_in, ...), so unique names
// keep the two packages independent even if they ever met in one compile.
`uvm_analysis_imp_decl(_mesh_in)
`uvm_analysis_imp_decl(_mesh_out)

class floonoc_mesh_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(floonoc_mesh_scoreboard)

  uvm_analysis_imp_mesh_in  #(floonoc_mesh_flit_item, floonoc_mesh_scoreboard) in_imp;
  uvm_analysis_imp_mesh_out #(floonoc_mesh_flit_item, floonoc_mesh_scoreboard) out_imp;

  // Per (source router, destination router) FIFO of expected flits
  protected floonoc_mesh_flit_item expected [NumRouters][NumRouters][$];

  int unsigned n_accepted;
  int unsigned n_delivered;
  int unsigned n_matched;
  int unsigned n_mismatched;

  // Fault-injection knobs for negative self-tests ONLY (prove the checkers
  // are not vacuous — see docs/verification_plan.md N1/N2). Default -1: off.
  int corrupt_payload_idx = -1;  // corrupt the Nth accepted flit's expected payload
  int corrupt_route_idx   = -1;  // model the Nth accepted flit at the wrong router

  function new(string name, uvm_component parent);
    super.new(name, parent);
    in_imp  = new("in_imp", this);
    out_imp = new("out_imp", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(int)::get(this, "", "corrupt_payload_idx", corrupt_payload_idx));
    void'(uvm_config_db#(int)::get(this, "", "corrupt_route_idx", corrupt_route_idx));
  endfunction

  // N2 helper: pick a router that is neither the true destination nor the
  // source, so the corrupted expectation stays legal-shaped AND is
  // guaranteed to differ from the truth. A silent no-op here would make the
  // negative test vacuously "pass", which is precisely what it exists to
  // disprove — so failing to find one is fatal, not a warning.
  protected function int unsigned wrong_router(int unsigned src, int unsigned truth);
    for (int unsigned k = 1; k < NumRouters; k++) begin
      int unsigned cand = (truth + k) % NumRouters;
      if (cand != src && cand != truth) return cand;
    end
    `uvm_fatal("SB_NEG", $sformatf(
      "cannot build a wrong-router expectation on a %0d-router mesh: N2 would be vacuous",
      NumRouters))
    return truth;
  endfunction

  // Input handshake accepted by the DUT -> predict the ejecting router
  virtual function void write_mesh_in(floonoc_mesh_flit_item t);
    int unsigned eo = t.exp_out_router();
    if (int'(n_accepted) == corrupt_payload_idx) begin
      t.payload = t.payload ^ payload_t'(1);
      `uvm_info("SB_NEG", $sformatf("injected payload corruption on accepted flit #%0d",
                                    n_accepted), UVM_LOW)
    end
    if (int'(n_accepted) == corrupt_route_idx) begin
      eo = wrong_router(t.src_router, eo);
      `uvm_info("SB_NEG", $sformatf("injected wrong-router expectation (R%0d) on accepted flit #%0d",
                                    eo, n_accepted), UVM_LOW)
    end
    n_accepted++;
    expected[t.src_router][eo].push_back(t);
  endfunction

  // Output handshake delivered by the DUT -> match oldest expectation
  virtual function void write_mesh_out(floonoc_mesh_flit_item t);
    floonoc_mesh_flit_item exp;
    n_delivered++;

    // R5: unknown source encoding (hdr.src_id outside the mesh)
    if (t.src_router >= NumRouters) begin
      n_mismatched++;
      `uvm_error("SB", $sformatf("output flit with unknown src encoding: %s",
                                 t.convert2string()))
      return;
    end
    // R5: spurious flit — nothing pending for this (src, exit) pair
    if (expected[t.src_router][t.out_router].size() == 0) begin
      n_mismatched++;
      `uvm_error("SB", $sformatf(
        "unexpected flit at router %0d (nothing pending from input router %0d): %s",
        t.out_router, t.src_router, t.convert2string()))
      return;
    end

    // R6: per-pair ordering — the oldest pending flit must be this one
    exp = expected[t.src_router][t.out_router].pop_front();

    // R1: routing — the flit must eject at the router its own header names
    if (t.exp_out_router() != t.out_router) begin
      n_mismatched++;
      `uvm_error("SB", $sformatf(
        "routing violation: flit for router %0d(%0d,%0d) ejected at router %0d(%0d,%0d)",
        t.dst_router, t.dst_x(), t.dst_y(),
        t.out_router, router_x(t.out_router), router_y(t.out_router)))
      return;
    end

    // R2: payload + destination header integrity
    if (t.payload !== exp.payload || t.dst_router != exp.dst_router) begin
      n_mismatched++;
      `uvm_error("SB", $sformatf("integrity/order mismatch:\n  expected: %s\n  observed: %s",
                                 exp.convert2string(), t.convert2string()))
      return;
    end

    n_matched++;
  endfunction

  function int unsigned pending_count();
    int unsigned n = 0;
    foreach (expected[i, o]) n += expected[i][o].size();
    return n;
  endfunction

  function void dump_pending(string ctx = "TIMEOUT");
    foreach (expected[i, o]) begin
      foreach (expected[i][o][k]) begin
        `uvm_info(ctx, $sformatf("stuck in-flight [R%0d->R%0d]: %s",
                  i, o, expected[i][o][k].convert2string()), UVM_NONE)
      end
    end
  endfunction

  // R5: nothing may remain in flight at the end of test
  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (pending_count() != 0) begin
      dump_pending("SB");
      `uvm_error("SB", $sformatf("%0d accepted flit(s) never delivered", pending_count()))
    end
    if (n_delivered != n_accepted) begin
      `uvm_error("SB", $sformatf("accepted %0d != delivered %0d", n_accepted, n_delivered))
    end
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("SB", $sformatf(
      "accepted=%0d delivered=%0d matched=%0d mismatched=%0d pending=%0d",
      n_accepted, n_delivered, n_matched, n_mismatched, pending_count()), UVM_LOW)
  endfunction

endclass : floonoc_mesh_scoreboard
```

- [ ] **Step 2: Extend the package include list**

```systemverilog
  `include "floonoc_mesh_flit_item.sv"
  `include "floonoc_mesh_smoke_seq.sv"
  `include "floonoc_mesh_driver.sv"
  `include "floonoc_mesh_monitor.sv"
  `include "floonoc_mesh_agent.sv"
  `include "floonoc_mesh_scoreboard.sv"
```

- [ ] **Step 3: Compile-check**

Re-run the exact command from Task 4 Step 3. Expected: exits 0, no `%Error`, no `%Warning`.

- [ ] **Step 4: Commit**

```bash
git add tb/env/floonoc_mesh_scoreboard.sv tb/pkg/floonoc_mesh_uvm_pkg.sv
git commit -m "feat(mesh): add mesh scoreboard with R1/R2/R5/R6 checks

Expectation FIFOs are keyed [src_router][dst_router]. The N2 wrong-router
helper is fatal rather than silent when no valid alternative exists, so the
negative test can never degrade into a vacuous pass on a small mesh."
```

---

## Task 8: Environment, smoke test, UVM entry — first end-to-end run

This is the integration point: the env and test are written, `tb_top_mesh` becomes a UVM top, the Phase-1 hand-rolled smoke scaffolding is deleted, and the build plumbing gains UVM.

**Files:**
- Create: `tb/env/floonoc_mesh_env.sv`
- Create: `tb/tests/floonoc_mesh_smoke_test.sv`
- Modify: `tb/pkg/floonoc_mesh_uvm_pkg.sv`
- Modify: `tb/top/tb_top_mesh.sv`
- Modify: `scripts/run_verilator.sh`

- [ ] **Step 1: Write `tb/env/floonoc_mesh_env.sv`**

The coverage collector arrives in Task 10; the env is written without it now.

```systemverilog
// -----------------------------------------------------------------------------
// Mesh environment: one active agent and the scoreboard.
// (Coverage collector is added in a follow-up commit.)
// -----------------------------------------------------------------------------
class floonoc_mesh_env extends uvm_env;

  `uvm_component_utils(floonoc_mesh_env)

  floonoc_mesh_agent      agent;
  floonoc_mesh_scoreboard sb;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = floonoc_mesh_agent::type_id::create("agent", this);
    sb    = floonoc_mesh_scoreboard::type_id::create("sb", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agent.mon.in_ap.connect(sb.in_imp);
    agent.mon.out_ap.connect(sb.out_imp);
  endfunction

endclass : floonoc_mesh_env
```

- [ ] **Step 2: Write `tb/tests/floonoc_mesh_smoke_test.sv`**

```systemverilog
// -----------------------------------------------------------------------------
// Mesh smoke test: run the smoke sequence, drain the scoreboard, end via
// objections, report explicit PASS/FAIL. A drain watchdog dumps all stuck
// in-flight flits before failing if forward progress stops.
//
// The drain budget is derived from the mesh diameter rather than being a flat
// literal, so it cannot silently under-budget if dut_config_mesh.svh grows.
// -----------------------------------------------------------------------------
class floonoc_mesh_smoke_test extends uvm_test;

  `uvm_component_utils(floonoc_mesh_smoke_test)

  floonoc_mesh_env env;

  // Budgets in cycles of the 10ns clock. The sequence budget catches stalled
  // stimulus (e.g. permanent backpressure); the drain budget catches accepted
  // flits that never reach an output.
  int unsigned seq_cycle_budget    = 5000;

  // Per-hop allowance: a flit crosses at most MeshDiameter routers, each
  // costing an input FIFO, an arbitration round and an output FIFO, and the
  // driver stalls ~20% of Eject-out cycles. 500 cycles per hop is roughly
  // 100x that worst case — deliberately loose, because this budget only has
  // to distinguish "draining" from "wedged".
  int unsigned drain_base_cycles   = 1000;
  int unsigned drain_per_hop_cycles = 500;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function int unsigned drain_cycle_budget();
    return drain_base_cycles + MeshDiameter * drain_per_hop_cycles;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = floonoc_mesh_env::type_id::create("env", this);
  endfunction

  virtual task run_phase(uvm_phase phase);
    floonoc_mesh_smoke_seq seq;
    bit seq_done = 1'b0;
    int unsigned waited = 0;
    int unsigned drain_budget = drain_cycle_budget();

    phase.raise_objection(this, "mesh smoke sequence running");

    seq = floonoc_mesh_smoke_seq::type_id::create("seq");

    // Run the sequence under a forward-progress watchdog: if stimulus can
    // no longer be accepted (e.g. permanent backpressure), fail with a
    // diagnostic dump instead of hanging until the global watchdog.
    fork
      begin
        seq.start(env.agent.sqr);
        seq_done = 1'b1;
      end
    join_none
    while (!seq_done && waited < seq_cycle_budget) begin
      #10ns;
      waited++;
    end
    if (!seq_done) begin
      env.sb.dump_pending();
      `uvm_error("TEST", $sformatf(
        "forward progress stopped: sequence still stalled after %0d cycles (%0d flit(s) in flight)",
        seq_cycle_budget, env.sb.pending_count()))
    end

    // Drain: all accepted flits must eventually be delivered
    waited = 0;
    while (env.sb.pending_count() > 0 && waited < drain_budget) begin
      #10ns;
      waited++;
    end
    if (env.sb.pending_count() > 0) begin
      env.sb.dump_pending();
      `uvm_error("TEST", $sformatf(
        "forward progress stopped: %0d flit(s) still in flight after %0d cycles",
        env.sb.pending_count(), drain_budget))
    end

    // A few idle cycles so any spurious late output would be caught
    #200ns;

    phase.drop_objection(this, "mesh smoke sequence drained");
  endtask

  virtual function void report_phase(uvm_phase phase);
    uvm_report_server svr = uvm_report_server::get_server();
    bit fail = (svr.get_severity_count(UVM_ERROR) > 0) ||
               (svr.get_severity_count(UVM_FATAL) > 0) ||
               (env.sb.n_matched == 0) || (env.sb.n_mismatched > 0);
    super.report_phase(phase);
    if (fail) begin
      `uvm_info("RESULT", "*** TEST FAILED ***", UVM_NONE)
    end else begin
      `uvm_info("RESULT", $sformatf(
        "*** TEST PASSED *** (%0d flits accepted, %0d delivered, %0d matched, 0 mismatches)",
        env.sb.n_accepted, env.sb.n_delivered, env.sb.n_matched), UVM_NONE)
    end
  endfunction

endclass : floonoc_mesh_smoke_test
```

- [ ] **Step 3: Extend the package include list**

```systemverilog
  `include "floonoc_mesh_flit_item.sv"
  `include "floonoc_mesh_smoke_seq.sv"
  `include "floonoc_mesh_driver.sv"
  `include "floonoc_mesh_monitor.sv"
  `include "floonoc_mesh_agent.sv"
  `include "floonoc_mesh_scoreboard.sv"
  `include "floonoc_mesh_env.sv"
  `include "floonoc_mesh_smoke_test.sv"
```

- [ ] **Step 4: Turn `tb_top_mesh` into a UVM top**

Three edits to `tb/top/tb_top_mesh.sv`:

**(a)** Replace the `import` block and the long "no UVM here" comment (currently lines 32-41) with:

```systemverilog
  import uvm_pkg::*;
  import floo_pkg::*;
  import floo_tb_mesh_types_pkg::*;
  import floonoc_mesh_uvm_pkg::*;
```

**(b)** Delete the entire Phase-1 scaffolding block: the `// No UVM entry yet` banner comment, the `bit valid_out_seen[NumRouters];` and `bit smoke_ok;` declarations, the `gen_misroute_watch` generate loop, and the whole directed-smoke `initial begin ... $finish; end` block. Replace all of it with:

```systemverilog
  // ---------------------------------------------------------------------------
  // UVM entry
  //
  // (The Phase-1 hand-rolled directed smoke check that used to live here was
  // temporary scaffolding for the RTL wiring checkpoint, never a regression
  // test. Its job is fully subsumed by the directed phase of
  // floonoc_mesh_smoke_seq, which exercises every link in both directions and
  // both mesh diagonals, with a scoreboard behind it.)
  // ---------------------------------------------------------------------------
  initial begin
    uvm_config_db#(virtual floonoc_mesh_if)::set(null, "*", "vif", rif);
    run_test();
  end
```

**(c)** Update the module header comment: delete the paragraph beginning `// Deliberately NOT included in this first checkpoint:` and the sentence about there being no UVM layer, replacing them with:

```systemverilog
// The mesh RTL itself lives in tb/top/floonoc_mesh_dut.sv; this file is the
// TB shell: clock/reset, the interface, config_db publication, run_test(),
// waves hook and the last-resort watchdog. It is a new, independent
// top-level — nothing here touches tb_top.sv or anything it depends on.
```

- [ ] **Step 5: Add UVM to the mesh build and switch the run criteria**

> **Amended — see A2/A3 above.** Task 1 already added the
> `+verilator+coverage+file+` plusarg and turned `run-mesh` into a 12-pair
> sweep, so the `run-mesh` case on disk no longer matches the block below.
> Do **not** re-add the coverage plusarg. What this step actually has to do
> is: swap the `*** MESH-SMOKE PASSED ***` grep for `TEST PASSED` +
> `UVM_ERROR : 0` + `UVM_FATAL : 0`, add `+UVM_TESTNAME` / `+UVM_NO_RELNOTES`,
> and retire the 12-pair sweep (the directed phase of the smoke sequence
> subsumes it, with a scoreboard behind it). Build the real edit from the
> current file, not from this block.

In `scripts/run_verilator.sh`, extend `TB_MESH_SOURCES` to include the UVM package (order matters — the package must come after the types and interface, before the top):

```bash
TB_MESH_SOURCES=(
  tb/pkg/floo_tb_mesh_types_pkg.sv
  tb/interfaces/floonoc_mesh_if.sv
  tb/top/floonoc_mesh_dut.sv
  tb/pkg/floonoc_mesh_uvm_pkg.sv
  tb/top/tb_top_mesh.sv
)
```

In `do_build_mesh()`, add UVM to the compile — insert these two lines right after the `-f "$BUILD/sources.f" \` line:

```bash
      +incdir+"$UVM_HOME/src" \
      "$UVM_HOME/src/uvm_pkg.sv" \
```

Replace the whole `run-mesh)` case with a UVM-aware version:

```bash
  run-mesh)
    shift
    RUN_LOG=logs/run_mesh.log
    if [ ! -x "$BUILD/obj_dir_mesh/Vtb_top_mesh" ]; then
      echo "[verilator] ERROR: $BUILD/obj_dir_mesh/Vtb_top_mesh missing — run 'make build-mesh' first" >&2
      exit 1
    fi
    set +e
    log_and_run "$RUN_LOG" \
      "$BUILD/obj_dir_mesh/Vtb_top_mesh" \
        "+UVM_TESTNAME=${MESH_TEST:-floonoc_mesh_smoke_test}" +UVM_NO_RELNOTES \
        "+verilator+coverage+file+${COV_FILE:-logs/coverage_mesh.dat}" \
        "$@"
    rc=$?
    set -e
    if [ $rc -ne 0 ]; then
      echo "[verilator] mesh run FAILED (simulator exit $rc, log: $RUN_LOG)" >&2
      exit 1
    fi
    # UVM does not propagate error counts into the exit code; enforce here.
    if ! grep -q '^UVM_ERROR :    0$' "$RUN_LOG" || \
       ! grep -q '^UVM_FATAL :    0$' "$RUN_LOG" || \
       ! grep -q 'TEST PASSED' "$RUN_LOG"; then
      echo "[verilator] mesh run FAILED: UVM errors or missing PASS banner (log: $RUN_LOG)" >&2
      exit 1
    fi
    echo "[verilator] mesh run PASS (log: $RUN_LOG, coverage: logs/coverage_mesh.dat)"
    ;;
```

- [ ] **Step 6: Build and run — the first end-to-end mesh UVM run**

```bash
export UVM_HOME=/Users/chenbh/verification/uvm/1800.2-2017-1.0
make build-mesh && make run-mesh
```

Expected in `logs/run_mesh.log`:
- 12 `[SEQ] directed[...]` lines, e.g. `directed[link R0.East]: src=R0(0,0) dst=R1(1,0) hops=1 payload=0xface000000000000`
- `UVM_INFO ... [SB] accepted=12 delivered=12 matched=12 mismatched=0 pending=0`
- `UVM_ERROR :    0`, `UVM_FATAL :    0`
- `*** TEST PASSED *** (12 flits accepted, 12 delivered, 12 matched, 0 mismatches)`
- `[verilator] mesh run PASS`

**If `matched` is 0 while `delivered` is 12**, the most likely cause is the `hdr.src_id` round-trip (D3): check a `[MON] out:` line against its matching `[MON] in :` line — if `src=R?` differs between them, `src_id` is not surviving the mesh and the encoding needs revisiting before going further.

**If flits are accepted but never delivered**, dump waves and inspect the mesh links: `make build-mesh && ./scripts/run_verilator.sh run-mesh +trace +tracefile=waves/tb_top_mesh.fst`.

- [ ] **Step 7: Verify the single-router bench is still green**

```bash
make lint && make build && make run
```

Expected: `*** TEST PASSED *** (25 flits accepted, ...)`, `[verilator] run PASS`.

- [ ] **Step 8: Commit**

```bash
git add tb/env/floonoc_mesh_env.sv tb/tests/floonoc_mesh_smoke_test.sv \
        tb/pkg/floonoc_mesh_uvm_pkg.sv tb/top/tb_top_mesh.sv scripts/run_verilator.sh
git commit -m "feat(mesh): wire the mesh UVM env into tb_top_mesh

First end-to-end mesh UVM run: 12 directed flits (every link both
directions, both diagonals) accepted, delivered and matched. Removes the
Phase-1 hand-rolled smoke scaffolding, whose job the directed sequence now
subsumes with a scoreboard behind it. Drain budget is derived from
MeshDiameter rather than a flat literal."
```

---

## Task 9: Enable the constrained-random phase

**Files:**
- Modify: `tb/sequences/floonoc_mesh_smoke_seq.sv:12`

- [ ] **Step 1: Turn the random phase on**

In `tb/sequences/floonoc_mesh_smoke_seq.sv`, change:

```systemverilog
  int unsigned num_random = 0;   // Task 9 raises this
```

to:

```systemverilog
  // Enough draws that the (src, dst) cross sees repeated pairs, which is
  // what actually exercises the per-pair ordering check R6.
  int unsigned num_random = 15;
```

- [ ] **Step 2: Run and confirm random traffic is legal and checked**

```bash
make build-mesh && make run-mesh
```

Expected:
- 12 `directed[...]` lines plus 15 `random:` lines in `logs/run_mesh.log`
- `[SB] accepted=27 delivered=27 matched=27 mismatched=0 pending=0`
- `*** TEST PASSED *** (27 flits accepted, 27 delivered, 27 matched, 0 mismatches)`

- [ ] **Step 3: Confirm `randomize()` produced legal, varied traffic**

```bash
grep -c 'randomize() failed' logs/run_mesh.log || true
grep -o 'random:   src=R[0-9]* dst=R[0-9]*' logs/run_mesh.log | sort | uniq -c | sort -rn
```

Expected: the first command prints `0`. The second lists distinct `src=Rn dst=Rm` pairs, **none with `src` equal to `dst`**, and covering more than a couple of distinct pairs. If every draw is the same pair, the solver is degenerate and `c_legal_route` needs revisiting.

- [ ] **Step 4: Commit**

```bash
git add tb/sequences/floonoc_mesh_smoke_seq.sv
git commit -m "feat(mesh): enable the 15-flit constrained-random phase

27 flits total (12 directed + 15 random), all accepted, delivered and
matched. Repeated (src,dst) pairs in the random phase are what actually
exercise the per-pair ordering check R6."
```

---

## Task 10: Functional coverage

**Files:**
- Create: `tb/coverage/floonoc_mesh_cov.sv`
- Modify: `tb/pkg/floonoc_mesh_uvm_pkg.sv`
- Modify: `tb/env/floonoc_mesh_env.sv`
- Modify: `Makefile`

- [ ] **Step 1: Write `tb/coverage/floonoc_mesh_cov.sv`**

```systemverilog
// -----------------------------------------------------------------------------
// Functional coverage on real delivered traffic (subscribes to the monitor's
// output analysis port). Scope-appropriate items only: source router,
// destination router, hop count, backpressure, and the src x dst cross.
//
// Bin ranges are derived from NumRouters / MeshDiameter, so a larger mesh
// needs no edit here.
//
// Note: the covergroup uses `with function sample(...)` arguments, since
// coverpoints referencing enclosing class members are unsupported in this
// simulator version (COVERIGN) — see docs/compatibility.md.
// -----------------------------------------------------------------------------
class floonoc_mesh_cov extends uvm_subscriber #(floonoc_mesh_flit_item);

  `uvm_component_utils(floonoc_mesh_cov)

  int unsigned n_sampled;

  covergroup flit_cg with function sample(int unsigned src, int unsigned dst,
                                          int unsigned hops, bit bp);
    option.per_instance = 1;

    cp_src_router : coverpoint src {
      bins r[] = {[0:NumRouters-1]};
    }
    cp_dst_router : coverpoint dst {
      bins r[] = {[0:NumRouters-1]};
    }
    // Minimum 1 hop (src == dst is illegal), maximum the mesh diameter.
    cp_hops : coverpoint hops {
      bins h[] = {[1:MeshDiameter]};
    }
    cp_backpressure : coverpoint bp {
      bins stalled = {1};
      bins free    = {0};
    }

    x_src_dst : cross cp_src_router, cp_dst_router {
      // src == dst is unreachable by construction (c_legal_route). Without
      // this the cross tops out at (N^2-N)/N^2 — 75% on a 2x2 mesh — and
      // the number would read like a stimulus gap instead of a tautology.
      ignore_bins loopback = x_src_dst with (cp_src_router == cp_dst_router);
    }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    flit_cg = new();
  endfunction

  virtual function void write(floonoc_mesh_flit_item t);
    flit_cg.sample(t.src_router, t.out_router, t.exp_hops(), t.backpressured);
    n_sampled++;
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("COV", $sformatf("sampled %0d flits, flit_cg coverage = %0.1f%%",
              n_sampled, flit_cg.get_inst_coverage()), UVM_LOW)
  endfunction

endclass : floonoc_mesh_cov
```

Note the sample uses `t.out_router` (the *observed* exit router) rather than `t.dst_router`, so coverage records what actually happened, not what was predicted.

- [ ] **Step 2: Wire it into the env**

In `tb/env/floonoc_mesh_env.sv`, add the member, build it, and connect it:

```systemverilog
  floonoc_mesh_agent      agent;
  floonoc_mesh_scoreboard sb;
  floonoc_mesh_cov        cov;
```

```systemverilog
    agent = floonoc_mesh_agent::type_id::create("agent", this);
    sb    = floonoc_mesh_scoreboard::type_id::create("sb", this);
    cov   = floonoc_mesh_cov::type_id::create("cov", this);
```

```systemverilog
    agent.mon.in_ap.connect(sb.in_imp);
    agent.mon.out_ap.connect(sb.out_imp);
    agent.mon.out_ap.connect(cov.analysis_export);
```

Also update the env's header comment: drop `// (Coverage collector is added in a follow-up commit.)` and make the first line read `// Mesh environment: one active agent, scoreboard, coverage collector.`

- [ ] **Step 3: Extend the package include list**

Insert `floonoc_mesh_cov.sv` between the scoreboard and the env:

```systemverilog
  `include "floonoc_mesh_scoreboard.sv"
  `include "floonoc_mesh_cov.sv"
  `include "floonoc_mesh_env.sv"
  `include "floonoc_mesh_smoke_test.sv"
```

- [ ] **Step 4: Build and run**

```bash
make build-mesh && make run-mesh
```

Expected: `[COV] sampled 27 flits, flit_cg coverage = NN.N%` and `*** TEST PASSED *** (27 flits accepted, ...)`.

**If Verilator rejects `ignore_bins ... with (...)` on a cross** (an error mentioning `with` or `cross`), that construct is unsupported at 5.052. Fall back: delete the whole `{ ignore_bins ... }` body so the cross reads `x_src_dst : cross cp_src_router, cp_dst_router;`, and add a line to `docs/uvm_coverage.md` in Task 13 recording that the `NumRouters` diagonal cross bins are unreachable by construction and cap the cross at 75% on a 2×2 mesh. Do **not** hand-enumerate `binsof`/`intersect` per router — that would hardcode the mesh size, which the spec explicitly forbids.

- [ ] **Step 5: Add the mesh coverage report target**

Add `cov-mesh` to `.PHONY` and add this target after `run-mesh` in the `Makefile`:

```make
# Mesh coverage report. Same three-way split as `make cov`, over the mesh
# bench's own coverage file so the two benches' numbers never conflate.
cov-mesh:
	@mkdir -p logs/coverage_report_mesh
	@{ \
	  echo "=== FUNCTIONAL coverage (covergroups) ==="; \
	  verilator_coverage --filter-type covergroup --report summary,hier logs/coverage_mesh.dat; \
	  echo; \
	  echo "=== ASSERTION coverage (SVA cover points) ==="; \
	  verilator_coverage --filter-type user --report summary,hier logs/coverage_mesh.dat; \
	  echo; \
	  echo "=== CODE coverage (DUT line coverage) ==="; \
	  verilator_coverage --filter-type line --report summary logs/coverage_mesh.dat; \
	} | tee logs/coverage_summary_mesh.log
	@verilator_coverage --annotate logs/coverage_report_mesh logs/coverage_mesh.dat > /dev/null
	@echo "[cov-mesh] split summary: logs/coverage_summary_mesh.log; annotated source: logs/coverage_report_mesh/"
```

- [ ] **Step 6: Generate and inspect the report**

```bash
make cov-mesh
```

Expected: three sections printed. The FUNCTIONAL section lists `cp_src_router`, `cp_dst_router`, `cp_hops`, `cp_backpressure` and `x_src_dst` with non-zero hit counts. Record the headline percentage — Task 13 puts it in `docs/compatibility.md`.

- [ ] **Step 7: Commit**

```bash
git add tb/coverage/floonoc_mesh_cov.sv tb/env/floonoc_mesh_env.sv \
        tb/pkg/floonoc_mesh_uvm_pkg.sv Makefile
git commit -m "feat(mesh): add mesh functional coverage and cov-mesh target

cp_src_router/cp_dst_router/cp_hops/cp_backpressure plus the src x dst cross,
all with NumRouters- and MeshDiameter-derived bins. The cross ignores the
src == dst diagonal, which c_legal_route makes unreachable by construction."
```

---

## Task 11: Mesh protocol assertions

`floonoc_router_sva.sv` binds to *interface* signals, not router internals, and its property set (`A_IN_VALID_STABLE`, `A_OUT_VALID_STABLE`, `A_OUT_QUIET_IN_RESET` + three covers) needs no coordinates. The mesh version is the same set over `NumRouters` Eject ports, as one instance on `rif`.

The design spec's `XYDirectionNotAllowed` / `NoLoopback` are **not** reimplemented here: those are the *DUT's own* assertions (`hw/floo_router.sv:515` and `:537`), and they already elaborate and fire inside all four router instances under `--assert`. Inter-router link stability is likewise already covered by the DUT's own `StableValidOut` (`:494-512`) at both ends of every link.

**Files:**
- Create: `tb/assertions/floonoc_mesh_router_sva.sv`
- Modify: `tb/top/tb_top_mesh.sv`
- Modify: `scripts/run_verilator.sh`

- [ ] **Step 1: Write `tb/assertions/floonoc_mesh_router_sva.sv`**

```systemverilog
// -----------------------------------------------------------------------------
// Interface-level protocol assertions for the FlooNoC mesh bench: the same
// property set as the single-router bench's floonoc_router_sva, applied to
// every router's Eject port instead of to one router's five ports.
//
// Every property is traceable to an upstream contract:
//  - A_IN_VALID_STABLE / A_OUT_VALID_STABLE mirror the DUT's own
//    StableValidIn/StableValidOut assertions (hw/floo_router.sv:494-512
//    @ v0.8.4): once valid is asserted it must remain asserted until the
//    transfer completes (VcNaive configuration).
//  - A_OUT_QUIET_IN_RESET: all output/input buffering resets empty
//    (common_cells stream_fifo/fifo_v3 reset behavior), so no output valid
//    may be asserted while reset is active. See docs/assumptions.md A3.
//
// Deliberately NOT asserted here:
//  - XYDirectionNotAllowed / NoLoopback. These are the DUT's OWN assertions
//    (hw/floo_router.sv:515, :537). They elaborate inside every router
//    instance and run under Verilator's --assert, so re-implementing them at
//    TB level would add no coverage — and could not be written at TB level
//    anyway, since they reference the router's internal route_mask.
//  - Inter-router link protocol. Both ends of every N/E/S/W link are DUT
//    ports, already covered by the DUT's own StableValidIn/Out. Only Eject
//    ports face the TB, and only those carry a TB-side obligation.
//  - Output DATA stability under stall: upstream keeps its equivalent
//    StableDataIn assertion commented out, and the output arbiter may switch
//    payloads between competing inputs while valid is high.
// -----------------------------------------------------------------------------
module floonoc_mesh_router_sva
  import floo_tb_mesh_types_pkg::*;
(
  input logic                   clk,
  input logic                   rst_n,
  input logic [NumRouters-1:0]  valid_in,
  input logic [NumRouters-1:0]  ready_in,
  input logic [NumRouters-1:0]  valid_out,
  input logic [NumRouters-1:0]  ready_out
);

  for (genvar r = 0; r < NumRouters; r++) begin : gen_router_sva

    // TB-side obligation: our driver must hold valid until the DUT accepts.
    A_IN_VALID_STABLE : assert property (@(posedge clk) disable iff (!rst_n)
      valid_in[r] && !ready_in[r] |=> valid_in[r])
      else $error("[SVA] router %0d Eject-in: valid_in dropped before handshake", r);

    // DUT-side guarantee: output valid held until we accept.
    A_OUT_VALID_STABLE : assert property (@(posedge clk) disable iff (!rst_n)
      valid_out[r] && !ready_out[r] |=> valid_out[r])
      else $error("[SVA] router %0d Eject-out: valid_out dropped before handshake", r);

    // DUT-side guarantee: outputs quiescent while in reset.
    A_OUT_QUIET_IN_RESET : assert property (@(posedge clk)
      !rst_n |-> !valid_out[r])
      else $error("[SVA] router %0d Eject-out: valid_out asserted during reset", r);

    // Handshake covers (also serve as sanity that traffic really flowed at
    // every router — a mesh-specific value the single-router bench cannot
    // have: these prove every router both injected and ejected).
    C_IN_HANDSHAKE  : cover property (@(posedge clk) disable iff (!rst_n)
      valid_in[r] && ready_in[r]);
    C_OUT_HANDSHAKE : cover property (@(posedge clk) disable iff (!rst_n)
      valid_out[r] && ready_out[r]);
    C_OUT_BACKPRESSURE : cover property (@(posedge clk) disable iff (!rst_n)
      valid_out[r] && !ready_out[r]);

  end

endmodule : floonoc_mesh_router_sva
```

- [ ] **Step 2: Instantiate it in `tb_top_mesh.sv`**

Insert immediately after the `assign rif.data_out = mesh_data_out;` line:

```systemverilog
  // ---------------------------------------------------------------------------
  // Protocol assertions (per-router Eject ports)
  // ---------------------------------------------------------------------------
  floonoc_mesh_router_sva i_sva (
    .clk       ( clk           ),
    .rst_n     ( rst_n         ),
    .valid_in  ( rif.valid_in  ),
    .ready_in  ( rif.ready_in  ),
    .valid_out ( rif.valid_out ),
    .ready_out ( rif.ready_out )
  );
```

- [ ] **Step 3: Add the SVA module to the mesh source list**

In `scripts/run_verilator.sh`, extend `TB_MESH_SOURCES` (the SVA module must precede the top that instantiates it):

```bash
TB_MESH_SOURCES=(
  tb/pkg/floo_tb_mesh_types_pkg.sv
  tb/interfaces/floonoc_mesh_if.sv
  tb/top/floonoc_mesh_dut.sv
  tb/assertions/floonoc_mesh_router_sva.sv
  tb/pkg/floonoc_mesh_uvm_pkg.sv
  tb/top/tb_top_mesh.sv
)
```

- [ ] **Step 4: Build, run, and confirm the assertions actually ran**

```bash
make build-mesh && make run-mesh && make cov-mesh
```

Expected: `*** TEST PASSED *** (27 flits accepted, ...)` with no `[SVA]` error lines, and in `make cov-mesh`'s ASSERTION section, non-zero hits for `C_IN_HANDSHAKE`, `C_OUT_HANDSHAKE` and `C_OUT_BACKPRESSURE` at **every** router index.

- [ ] **Step 5: Prove the assertions are not vacuous**

An assertion that never evaluates is worthless. Confirm every router both injected and ejected traffic:

```bash
verilator_coverage --filter-type user --report hier logs/coverage_mesh.dat \
  | grep -E 'C_(IN|OUT)_HANDSHAKE'
```

Expected: one non-zero line per router index for each of the two handshake covers (8 lines at 2×2). A zero at any router means the directed sequence is not reaching it — investigate before continuing.

- [ ] **Step 6: Commit**

```bash
git add tb/assertions/floonoc_mesh_router_sva.sv tb/top/tb_top_mesh.sv scripts/run_verilator.sh
git commit -m "feat(mesh): add per-router Eject-port protocol assertions

Mirrors floonoc_router_sva's actual property set over NumRouters Eject
ports. XYDirectionNotAllowed and NoLoopback are deliberately not
reimplemented: they are the DUT's own assertions and already run inside
every router instance under --assert."
```

---

## Task 12: Negative self-tests

Three fault injections, each of which **must** make the bench fail with a specific diagnostic. Without them the passing run proves nothing.

**Files:**
- Create: `tb/tests/floonoc_mesh_negative_tests.sv`
- Modify: `tb/pkg/floonoc_mesh_uvm_pkg.sv`
- Modify: `scripts/run_verilator.sh`
- Modify: `Makefile`

- [ ] **Step 1: Write `tb/tests/floonoc_mesh_negative_tests.sv`**

```systemverilog
// -----------------------------------------------------------------------------
// Mesh negative self-tests: each injects one controlled fault into the
// checking path (never into the DUT or upstream RTL) and MUST end in
// *** TEST FAILED *** with a specific diagnostic. They prove the mesh
// scoreboard and watchdogs are not vacuous. Executed by
// `make run-negative-mesh`, which inverts the pass criteria.
// See docs/verification_plan.md rows NM1-NM3.
// -----------------------------------------------------------------------------

// NM1: corrupt one expected payload -> R2 integrity check must fire
class floonoc_mesh_neg_payload_test extends floonoc_mesh_smoke_test;

  `uvm_component_utils(floonoc_mesh_neg_payload_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(int)::set(this, "env.sb", "corrupt_payload_idx", 3);
  endfunction

endclass : floonoc_mesh_neg_payload_test


// NM2: model one flit as ejecting at the wrong router -> R1/R5/R6 checks must
// fire (unexpected flit at the real exit router and/or a stuck expectation).
// The scoreboard's wrong_router() helper guarantees the injected router is
// neither the true destination nor the source, so the injection can never
// degrade into a silent no-op.
class floonoc_mesh_neg_route_test extends floonoc_mesh_smoke_test;

  `uvm_component_utils(floonoc_mesh_neg_route_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(int)::set(this, "env.sb", "corrupt_route_idx", 5);
    // The mis-modeled expectation can never drain; keep the budget short.
    drain_base_cycles    = 300;
    drain_per_hop_cycles = 0;
  endfunction

endclass : floonoc_mesh_neg_route_test


// NM3: hold permanent Eject backpressure on every router -> forward-progress
// watchdogs must fire with a diagnostic dump of every stuck in-flight flit
class floonoc_mesh_neg_stall_test extends floonoc_mesh_smoke_test;

  `uvm_component_utils(floonoc_mesh_neg_stall_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(int)::set(this, "env.agent.drv", "ready_pct", 0);
    seq_cycle_budget     = 300;
    drain_base_cycles    = 100;
    drain_per_hop_cycles = 0;
  endfunction

endclass : floonoc_mesh_neg_stall_test
```

- [ ] **Step 2: Extend the package include list**

```systemverilog
  `include "floonoc_mesh_env.sv"
  `include "floonoc_mesh_smoke_test.sv"
  `include "floonoc_mesh_negative_tests.sv"
```

- [ ] **Step 3: Add a mesh `run-neg` subcommand**

In `scripts/run_verilator.sh`, add this case immediately after the `run-mesh)` case:

```bash
  run-neg-mesh)
    TESTNAME="${2:?usage: run-neg-mesh <testname> <expected-regex>}"
    EXPECT_RE="${3:?usage: run-neg-mesh <testname> <expected-regex>}"
    NEG_LOG="logs/run_$TESTNAME.log"
    if [ ! -x "$BUILD/obj_dir_mesh/Vtb_top_mesh" ]; then
      echo "[verilator] ERROR: $BUILD/obj_dir_mesh/Vtb_top_mesh missing — run 'make build-mesh' first" >&2
      exit 1
    fi
    # Negative tests get a scratch coverage file so they never clobber the
    # primary logs/coverage_mesh.dat evidence from the passing smoke run.
    set +e
    log_and_run "$NEG_LOG" \
      "$BUILD/obj_dir_mesh/Vtb_top_mesh" \
        "+UVM_TESTNAME=$TESTNAME" +UVM_NO_RELNOTES \
        "+verilator+coverage+file+logs/coverage_mesh_neg.dat"
    rc=$?
    set -e
    if [ $rc -ne 0 ]; then
      echo "[verilator] run-neg-mesh FAILED: simulator crashed instead of reporting (log: $NEG_LOG)" >&2
      exit 1
    fi
    # Inverted criteria: the injected fault MUST be caught and reported.
    if grep -q '^UVM_ERROR :    0$' "$NEG_LOG"; then
      echo "[verilator] run-neg-mesh FAILED: $TESTNAME reported no UVM_ERROR — checker is vacuous!" >&2
      exit 1
    fi
    if ! grep -q 'TEST FAILED' "$NEG_LOG"; then
      echo "[verilator] run-neg-mesh FAILED: $TESTNAME missing TEST FAILED banner" >&2
      exit 1
    fi
    if ! grep -Eq "$EXPECT_RE" "$NEG_LOG"; then
      echo "[verilator] run-neg-mesh FAILED: $TESTNAME did not report expected diagnostic /$EXPECT_RE/" >&2
      exit 1
    fi
    echo "[verilator] run-neg-mesh PASS: $TESTNAME failed as intended with /$EXPECT_RE/ (log: $NEG_LOG)"
    ;;
```

Update the usage line at the bottom of the script to include `|run-neg-mesh <test> <re>`.

- [ ] **Step 4: Add the `run-negative-mesh` Makefile target**

Add `run-negative-mesh` to `.PHONY` and add this after `run-mesh`:

```make
# Mesh negative self-tests: each injects one fault into the checking path and
# MUST fail with the expected diagnostic (proves the checkers are not vacuous).
# NM2's regex is permissive because the mis-modeled expectation can land in a
# queue that other legitimate traffic also uses, in which case the FIFO compare
# fires first — every listed alternative is a real catch.
run-negative-mesh:
	./scripts/run_verilator.sh run-neg-mesh floonoc_mesh_neg_payload_test 'integrity/order mismatch'
	./scripts/run_verilator.sh run-neg-mesh floonoc_mesh_neg_route_test   'unexpected flit|integrity/order mismatch|never delivered'
	./scripts/run_verilator.sh run-neg-mesh floonoc_mesh_neg_stall_test   'forward progress stopped'
	@echo "[run-negative-mesh] all 3 fault injections were caught — mesh checkers are effective"
```

- [ ] **Step 5: Run all three and confirm each is caught**

```bash
make build-mesh && make run-negative-mesh
```

Expected, three `run-neg-mesh PASS` lines and then `[run-negative-mesh] all 3 fault injections were caught — mesh checkers are effective`.

Then inspect each log to confirm the *shape* of each failure, not just that something failed:

```bash
grep -E 'SB_NEG|UVM_ERROR :|matched=|TEST FAILED' logs/run_floonoc_mesh_neg_payload_test.log
grep -E 'SB_NEG|UVM_ERROR :|matched=|TEST FAILED' logs/run_floonoc_mesh_neg_route_test.log
grep -E 'UVM_ERROR :|accepted=|TEST FAILED' logs/run_floonoc_mesh_neg_stall_test.log
```

Expected shapes:
- **NM1:** an `injected payload corruption on accepted flit #3` line, then `mismatched=1` with `matched=26`, `TEST FAILED`.
- **NM2:** an `injected wrong-router expectation (R…) on accepted flit #5` line, then a non-zero `mismatched` and/or non-zero `pending`, `TEST FAILED`.
- **NM3:** `delivered=0`, a non-zero `pending`, `forward progress stopped`, `TEST FAILED`.

**If NM1 reports `mismatched=0`,** the payload check is not reachable — that is a real scoreboard bug, not a test-tuning problem. **If NM3 reports `accepted=0`,** the sequence never got started; check that `ready_pct=0` did not also block injection at time zero.

- [ ] **Step 6: Re-run the positive test to confirm nothing leaked**

```bash
make run-mesh
```

Expected: `*** TEST PASSED *** (27 flits accepted, 27 delivered, 27 matched, 0 mismatches)`.

- [ ] **Step 7: Commit**

```bash
git add tb/tests/floonoc_mesh_negative_tests.sv tb/pkg/floonoc_mesh_uvm_pkg.sv \
        scripts/run_verilator.sh Makefile
git commit -m "test(mesh): add NM1-NM3 negative self-tests and run-negative-mesh

Each injects one controlled fault into the checking path and must fail with
a specific diagnostic. NM2 relies on the scoreboard's wrong_router() helper,
which is fatal rather than silent when no valid alternative router exists."
```

---

## Task 13: Documentation

Every doc in this repo currently describes a single-router-only bench. Bring them in line, and record the Verilator baseline that a future xezim run will be measured against.

**Files:**
- Modify: `docs/verification_plan.md`
- Modify: `docs/assumptions.md`
- Modify: `docs/uvm_coverage.md`
- Modify: `docs/compatibility.md`
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `Makefile` (help header + `doctor`)

- [ ] **Step 1: Collect the actual numbers**

```bash
make lint-mesh && make build-mesh && make run-mesh && make cov-mesh && make run-negative-mesh
grep -E '\[SB\] accepted=|\[COV\] sampled|TEST PASSED' logs/run_mesh.log
grep -A3 'FUNCTIONAL coverage' logs/coverage_summary_mesh.log
```

Write down: the accepted/delivered/matched line, the functional coverage percentage, and the simulated end time. Use the real values below — do not copy the placeholders.

- [ ] **Step 2: Add a mesh section to `docs/verification_plan.md`**

Append a new top-level section after the existing single-router matrices:

```markdown
## Mesh bench (tb_top_mesh)

Independent second bench over a MeshX x MeshY array of `floo_router`
instances (`tb/top/floonoc_mesh_dut.sv`), driven by `floonoc_mesh_uvm_pkg`.
Shares no code with the single-router bench and is compiled as a separate
Verilator binary (`make build-mesh` / `make run-mesh`). Endpoints are router
indices; only per-router Eject ports face the TB.

### Requirement-to-test matrix (mesh)

| ID | Requirement | Stimulus | Checker | SVA | Coverage | Status |
|---|---|---|---|---|---|---|
| RM1 | Routing: every accepted flit is ejected at exactly the router named by its destination header | `floonoc_mesh_smoke_seq` — every physical link both directions, both mesh diagonals, plus 15 random | `write_mesh_out` R1 block | — | `cp_dst_router`, `x_src_dst` | **passing** |
| RM2 | Payload + destination header arrive unmodified across every hop | same | `write_mesh_out` R2 block | — | `cp_src_router` | **passing** |
| RM3 | Handshake/backpressure at every Eject port | same (driver holds valid; ~20% random Eject stall) | accepted/delivered counted only on valid&&ready | `A_IN_VALID_STABLE`, `A_OUT_VALID_STABLE`, covers `C_IN/OUT_HANDSHAKE`, `C_OUT_BACKPRESSURE`, per router | `cp_backpressure` | **passing** |
| RM4 | Reset: every router's Eject output quiescent while reset asserted | reset phase of every run | — | `A_OUT_QUIET_IN_RESET` per router | — | **passing** |
| RM5 | No loss / no duplication end to end across the mesh | same + drain phase + 200ns idle tail | `check_phase`: pending==0, accepted==delivered; `write_mesh_out`: error on empty expectation queue | — | — | **passing** |
| RM6 | Ordering per (src router, dst router) pair | random phase produces repeated pairs | per-pair FIFO expectation queues, `pop_front` compare | — | — | **passing** |
| RM7 | Hop-count distribution reaches the mesh diameter | directed diagonals guarantee a MeshDiameter case | — | — | `cp_hops` | **passing** |
| RM8 | Path correctness at intermediate routers | — | **not checked**: `floonoc_mesh_if` exposes only Eject endpoints. Covered instead by the DUT's own per-router `XYDirectionNotAllowed` / `NoLoopback` assertions, which run under `--assert` | DUT-internal | — | **by DUT assertion** |
| RM9 | Illegal destination (src == dst) | — | not re-tested at UVM level: `c_legal_route` makes it unconstructible, and the DUT's own `NoLoopback` assertion covers it | — | — | **out of scope** |

### Negative self-tests (mesh checker effectiveness)

| ID | Fault injected | Knob | Checker that must fire | Expected diagnostic | Status |
|---|---|---|---|---|---|
| NM1 | Expected payload of accepted flit #3 corrupted in the scoreboard model | `corrupt_payload_idx` (config_db, `env.sb`) | RM2 integrity compare | `integrity/order mismatch` | **passing** (caught) |
| NM2 | Accepted flit #5 modeled as ejecting at the wrong router | `corrupt_route_idx` (config_db, `env.sb`) | RM1/RM5/RM6 | `unexpected flit` / `integrity/order mismatch` / `never delivered` | **passing** (caught) |
| NM3 | Permanent Eject backpressure on every router (`ready_pct = 0`) | config_db, `env.agent.drv` | forward-progress watchdogs (sequence + drain budgets) | `forward progress stopped` | **passing** (caught) |

Run with `make run-negative-mesh`, which inverts the pass criteria.
```

- [ ] **Step 3: Add a mesh assumption to `docs/assumptions.md`**

Append:

```markdown
### A4-M — Per-pair ordering holds across the mesh

The mesh scoreboard's RM6 check assumes that two flits sharing the same
(source router, destination router) pair are delivered in acceptance order.
This is not inherited from A4 (which reasons about one router); it follows
independently from three properties of this configuration:

1. Dimension-order XY routing is deterministic and stateless — the route
   depends only on `hdr.dst_id` and the current router's `xy_id_i`
   (`hw/floo_route_select.sv`, `gen_xy_routing`). Two flits with the same
   destination injected at the same router therefore traverse the identical
   sequence of routers and ports.
2. At every stage between them the storage is FIFO: the per-input
   `stream_fifo` (`InFifoDepth`) and the per-output fifo (`OutFifoDepth`).
3. `hdr.last == 1` on every flit, so the wormhole route lock opens and
   closes per flit and cannot interleave a packet.

Nothing on that path can reorder two same-pair flits relative to each other.
Cross-pair ordering is deliberately NOT assumed, exactly as in A4.

### A5-M — `hdr.src_id` survives every hop

The mesh transaction encodes its injection router in `hdr.src_id` so the
output-side monitor can recover it. `hw/floo_route_select.sv:96` rewrites
`hdr.dst_id` only under `SourceRouting`; under `XYRouting` the header passes
through unmodified (`channel_o = channel_i`). `hdr.src_id` is read only by
`floo_route_xymask.sv`, the multicast path, which is inert in this
configuration (`collective_op == Unicast`, `EnCollective` off).
```

- [ ] **Step 4: Add a mesh section to `docs/uvm_coverage.md`**

Append:

```markdown
## Mesh bench functional coverage

`tb/coverage/floonoc_mesh_cov.sv`, a `uvm_subscriber #(floonoc_mesh_flit_item)`
on the mesh monitor's **output** analysis port, so every sample is a flit the
DUT actually delivered.

| Coverpoint | Samples | Bins | Derived from |
|---|---|---|---|
| `cp_src_router` | `t.src_router`, decoded from `hdr.src_id` | one auto-bin per router | `NumRouters` |
| `cp_dst_router` | `t.out_router`, the physical Eject port it surfaced on | one auto-bin per router | `NumRouters` |
| `cp_hops` | `t.exp_hops()` | `[1:MeshDiameter]` | `MeshDiameter = MeshX+MeshY-2` |
| `cp_backpressure` | `t.backpressured` | `stalled` / `free` | — |
| `x_src_dst` | cross of `cp_src_router` x `cp_dst_router` | `NumRouters² − NumRouters` | `ignore_bins` drops the `src == dst` diagonal |

No bin range is hardcoded: a larger mesh in `config/dut_config_mesh.svh`
rescales all of them with no edit here.

The cross's `ignore_bins loopback` exists because `c_legal_route` forbids
`src_router == dst_router`, making the diagonal structurally unreachable.
Without it the cross would top out at `(N²−N)/N²` — 75% on a 2×2 mesh — and
that number would read like a stimulus gap rather than a tautology.

`cp_dst_router` deliberately samples the **observed** exit router rather than
the predicted destination, so coverage records what the DUT did, not what the
model expected. A misroute therefore shows up in coverage as well as in the
scoreboard.
```

**If the Task 10 fallback was taken** (Verilator rejected the cross `with` clause), say so explicitly here instead: record that the `NumRouters` diagonal cross bins are structurally unreachable and cap `x_src_dst` at `(N²−N)/N²` (75% on a 2×2 mesh), so the number is a tautology, not a stimulus gap.

- [ ] **Step 5: Add mesh results to `docs/compatibility.md`**

Add a row to the results table with the real numbers from Step 1:

```markdown
| Mesh bench (2x2, `tb_top_mesh`) | `TEST PASSED`, 27/27 flits (12 directed + 15 random), 0 UVM_ERROR, 0 UVM_FATAL, functional coverage NN.N%, all 3 negative self-tests caught | `make lint-mesh build-mesh run-mesh cov-mesh run-negative-mesh` |
```

- [ ] **Step 6: Document the mesh flow in `README.md`**

Add a "Mesh bench" subsection after the single-router quick start:

```markdown
### Mesh bench (2×2 mesh of routers)

A second, independent bench over a 2×2 mesh of `floo_router` instances. It
shares no code with the single-router bench and builds as a separate binary.

```sh
export UVM_HOME=/path/to/1800.2-2017-1.0
make sources
make lint-mesh          # UVM-free elaboration of the mesh RTL
make build-mesh         # compile tb_top_mesh + floonoc_mesh_uvm_pkg
make run-mesh           # positive smoke test (expects TEST PASSED)
make run-negative-mesh  # 3 fault injections, each must be caught
make cov-mesh           # functional / assertion / code coverage split
```

Mesh size is set in `config/dut_config_mesh.svh`. The UVM layer derives every
bound from it (`NumRouters`, `MeshDiameter`), so no mesh dimension is
hardcoded above the config header — though only the 2×2 shape is verified.
```

- [ ] **Step 7: Update the `Makefile` help header and `doctor`**

Add to the comment block at the top of the `Makefile`:

```make
#   make lint-mesh          - Verilator lint-only pass on the mesh RTL (no UVM)
#   make build-mesh         - compile the mesh UVM smoke test (tb_top_mesh)
#   make run-mesh           - execute the mesh smoke test
#   make run-negative-mesh  - mesh fault-injection self-tests (must all fail)
#   make cov-mesh           - mesh coverage report (logs/coverage_report_mesh/)
```

And add one line to `doctor`:

```make
	@echo "mesh      : $$(test -x build/obj_dir_mesh/Vtb_top_mesh && echo 'built (build/obj_dir_mesh/Vtb_top_mesh)' || echo 'not built (run make build-mesh)')"
```

- [ ] **Step 8: Update `CLAUDE.md`**

Add a short section near the top recording:
- The mesh bench now passes on Verilator 5.052 with the exact numbers from Step 1.
- Each bench is a separate Verilator binary; **never** put `floonoc_uvm_pkg` and `floonoc_mesh_uvm_pkg` (or `dut_config.svh` and `dut_config_mesh.svh`) in one invocation.
- The `exp_path` exhaustive check result from Task 3.
- **The open follow-up:** the mesh bench has *not* been run on xezim. The Verilator-green result above is the reference — any xezim delta on this bench is an xezim bug, and the CLAUDE.md bug-numbering scheme continues from 27. Likely first suspects, from the existing bug log: the driver's `vif.data_in[r] <= item.as_flit()` is a virtual-interface packed-array-element NBA (bug 20's exact shape, fixed upstream — verify it holds at mesh scale), and the scoreboard's `expected[NumRouters][NumRouters][$]` is a class-property array-of-collections (bug 26's shape, with four sub-cases deliberately left open).

- [ ] **Step 9: Full regression, both benches**

```bash
export UVM_HOME=/Users/chenbh/verification/uvm/1800.2-2017-1.0
make clean && make sources
make lint && make build && make run && make run-negative
make lint-mesh && make build-mesh && make run-mesh && make run-negative-mesh
make cov && make cov-mesh
```

Expected: every command exits 0; `*** TEST PASSED *** (25 flits ...)` for the single-router bench, `*** TEST PASSED *** (27 flits ...)` for the mesh bench, and both `all 3 fault injections were caught` lines.

- [ ] **Step 10: Commit**

```bash
git add docs/verification_plan.md docs/assumptions.md docs/uvm_coverage.md \
        docs/compatibility.md README.md CLAUDE.md Makefile
git commit -m "docs: document the mesh UVM bench

Adds the RM1-RM9 / NM1-NM3 matrices, the mesh-specific ordering and
src_id assumptions (A4-M, A5-M), coverage notes, README flow and
compatibility results. Records the Verilator-green baseline as the
reference for a later xezim run of the same bench."
```

---

## Done criteria

- [ ] `make lint && make build && make run && make run-negative` — single-router bench unchanged and green.
- [ ] `make lint-mesh && make build-mesh && make run-mesh && make run-negative-mesh` — mesh bench green, all three fault injections caught.
- [ ] `make cov-mesh` reports non-zero functional coverage on all five mesh coverpoints, and non-zero `C_IN_HANDSHAKE`/`C_OUT_HANDSHAKE` at every router index.
- [ ] `git diff --stat main -- config/dut_config.svh tb/pkg/floo_tb_types_pkg.sv tb/pkg/floonoc_uvm_pkg.sv tb/interfaces/floonoc_router_if.sv tb/assertions/floonoc_router_sva.sv tb/top/tb_top.sv tb/top/lint_wrapper.sv` is **empty** — the single-router bench was never touched.
- [ ] No file under `tb/` outside the `*_mesh_*` set was modified except `tb/top/tb_top_mesh.sv`.
- [ ] `grep -rn 'FLOO_VERIF_' config/dut_config_mesh.svh tb/pkg/floo_tb_mesh_types_pkg.sv | grep -v MESH_` returns nothing.

## Known follow-ups (do not implement without a fresh spec)

- **Run the mesh bench on xezim.** Deliberately out of scope here; the Verilator-green result is the reference.
- **Verify a mesh size other than 2×2.** The code stays generic; the verification target does not change.
- **AXI / protocol-level traffic over the mesh.** floogen ships `axi_mesh_*.yml` examples; this is a distinct direction with its own brainstorm.
- **Credit-counter / VC-level checks.** Same deferral as the single-router bench (`VcNaive`, credits inert).
- **Intermediate-hop observability.** Would need `floonoc_mesh_if` (or a second interface) to expose inter-router links, turning RM8 from a DUT-assertion claim into a scoreboard check.
