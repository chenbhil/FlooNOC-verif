# Verification Plan — floo_router smoke milestone

Scope: single `floo_router` (5 ports, XYRouting, 1 VC), smoke-level.
Statuses: `planned | implemented | passing | blocked`.

This plan is organized around DUT requirements. For the orthogonal
*methodology* view — which UVM constructs the bench exercises and where — see
[uvm_coverage.md](uvm_coverage.md).

## Requirement-to-test matrix

| Req ID | Requirement statement | Source / citation | DUT scope | Test / sequence | Scoreboard check | Assertion | Coverage item | Status |
|---|---|---|---|---|---|---|---|---|
| R1 | Basic connectivity/routing: a flit accepted on any input is delivered at exactly the output selected by the XY rule (X first, then Y, then eject) | `hw/floo_route_select.sv:99-155` (gen_xy_routing + port map comment); `hw/floo_pkg.sv:48-56` (direction enum) | floo_router | `floonoc_smoke_test` / `floonoc_smoke_seq` (10 directed covering all 5 outputs + 15 random) | `write_out`: observed port == `exp_out_port(dst)` (R1 block) | — (checked by scoreboard, not SVA) | `cp_out`, `x_src_out` | **passing** |
| R2 | Payload preservation: payload and header arrive unmodified | `FLOO_TYPEDEF_GENERIC_FLIT_T` (payload opaque); `floo_route_select.sv:190-191` (`channel_o = channel_i` for XY) | floo_router | same | `write_out`: payload + dst compare vs expectation (R2 block) | — | `cp_src` (all sources exercised) | **passing** |
| R3 | Handshake/backpressure: valid held until ready; transfer only on valid&&ready; no output transfer without valid | `floo_router.sv:494-512` (StableValidIn/Out asserts); docs/assumptions.md A1 | floo_router ports | same (driver holds valid; ~20% random output stall) | accepted/delivered counts derived only from valid&&ready samples | `A_IN_VALID_STABLE`, `A_OUT_VALID_STABLE` + covers `C_IN/OUT_HANDSHAKE`, `C_OUT_BACKPRESSURE` | `cp_backpressure` | **passing** |
| R4 | Reset behavior: outputs quiescent while reset asserted | docs/assumptions.md A3 (inference from fifo_v3/`FF` reset) | floo_router | reset phase of every run | — | `A_OUT_QUIET_IN_RESET` | — | **passing** |
| R5 | No loss / no duplication: every accepted flit delivered exactly once; no unexpected output flits | wormhole router structure (FIFOs + crossbar, no drop/replay path); end-to-end check | floo_router | same + drain phase + 200ns idle tail | `check_phase`: pending==0, accepted==delivered; `write_out`: error on empty expectation queue | — | — | **passing** |
| R6 | Ordering: per (input,output) pair, delivery order == acceptance order | docs/assumptions.md A4 (per-pair FIFO structure; deliberately NOT cross-input) | floo_router | same (random phase produces repeated pairs) | per-pair FIFO expectation queues; `pop_front` compare | — | — | **passing** |
| R7 | Illegal/unsupported destination behavior | not externally specified upstream | — | — | — | — | — | **blocked** (out of scope by requirement; docs/assumptions.md A6) |

## Negative self-tests (checker effectiveness)

Each injects one controlled fault into the *checking path only* (never
the DUT or upstream RTL) and must end in `*** TEST FAILED ***` with a
specific diagnostic. `make run-negative` inverts the pass criteria: a
run that does NOT fail, or fails without the expected message, fails the
target. This proves the checks in R1/R2/R5/R6 and the watchdogs are not
vacuous.

| Neg ID | Fault injected | Knob | Checker that must fire | Expected diagnostic | Status |
|---|---|---|---|---|---|
| N1 | Expected payload of accepted flit #3 corrupted in the scoreboard model | `corrupt_payload_idx` (config_db, `env.sb`) | R2 integrity compare | `integrity/order mismatch` | **passing** (caught) |
| N2 | Accepted flit #5 modeled at the wrong output port | `corrupt_route_idx` (config_db, `env.sb`) | R1/R5/R6 (unexpected flit, stuck expectation) | `unexpected flit` / `integrity/order mismatch` / `never delivered` | **passing** (caught) |
| N3 | Permanent output backpressure (`ready_pct = 0` on all outputs) | config_db, `env.agent.drv` | forward-progress watchdogs (sequence + drain budgets) | `forward progress stopped` | **passing** (caught) |

Negative runs write coverage to a scratch file (`logs/coverage_neg.dat`)
so they never pollute the primary `logs/coverage.dat` evidence.

## Coverage implemented

`floonoc_cov.flit_cg` (samples every *delivered* flit from the monitor's
output analysis port): `cp_src` (5 named bins), `cp_out` (5 named bins),
`cp_backpressure` (stalled/free), cross `x_src_out`. `make cov` reports
coverage split by kind so the numbers cannot be conflated: functional
(covergroup) 62.2% = 23/37 bins over 25 flits; assertion (SVA cover)
100% = 3/3; DUT code (line, scoped by `config/coverage_scope.vlt`)
47.8% = 43/90. Closure is a non-goal at this milestone; the artifact
proves end-to-end covergroup operation.

## Mesh bench (tb_top_mesh)

Independent second bench over a `MeshX` x `MeshY` array of `floo_router`
instances (`tb/top/floonoc_mesh_dut.sv`), driven by `floonoc_mesh_uvm_pkg`.
Shares no code with the single-router bench and is compiled as a separate
Verilator binary (`make build-mesh` / `make run-mesh`; see
[known_issues.md](known_issues.md) KI-6 for why the separation is a rule and
not a convenience). Endpoints are router indices; only per-router Eject ports
face the TB, so North/East/South/West are inter-router links inside the mesh
DUT and are not observable from the interface.

Verified shape: **2x2**. Every bound above `config/dut_config_mesh.svh` is
derived (`NumRouters`, `MeshDiameter`), and the traffic is generated from the
topology helpers rather than a literal table, so the code is generic — but
only 2x2 has been run.

### Requirement-to-test matrix (mesh)

| ID | Requirement | Stimulus | Checker | SVA | Coverage | Status |
|---|---|---|---|---|---|---|
| RM1 | Routing: every accepted flit is ejected at exactly the router named by its destination header | `floonoc_mesh_smoke_seq` — every physical link both directions, both mesh diagonals, plus 15 random | `write_mesh_out` R1 block, checked before the expectation lookup so a misroute is diagnosed directly rather than as a spurious flit | — | `cp_dst_router`, `x_src_dst` | **passing** |
| RM2 | Payload arrives unmodified across every hop | same | `write_mesh_out` R2 block (payload compare against the driver-published expectation) | — | `cp_src_router` | **passing** |
| RM3 | Handshake/backpressure at every Eject port | same (driver holds valid; ~20% random Eject stall) | accepted/delivered counted only on valid&&ready | `A_IN_VALID_STABLE`, `A_OUT_VALID_STABLE`, covers `C_IN/OUT_HANDSHAKE`, `C_IN/OUT_BACKPRESSURE`, per router | `cp_backpressure` | **passing**, with `A_IN_VALID_STABLE` currently vacuous — see below |
| RM4 | Reset: every router's Eject output quiescent while reset asserted | reset phase of every run | — | `A_OUT_QUIET_IN_RESET` per router | — | **passing** |
| RM5 | No loss / no duplication end to end across the mesh | same + drain phase + 200ns idle tail | `check_phase`: pending==0, accepted==delivered; `write_mesh_out`: error on empty expectation queue; malformed-header decode reported at the boundary | — | — | **passing** |
| RM6 | Ordering per (src router, dst router) pair | directed 3-flit same-pair burst (phase C), plus whatever repeats the random phase draws | per-pair FIFO expectation queues, `pop_front` compare | — | — | **passing**, proven live by mutation |
| RM7 | Hop-count distribution reaches the mesh diameter | directed diagonals guarantee a `MeshDiameter` case | — | — | `cp_hops` | **passing** |
| RM8 | Path correctness at intermediate routers | — | **not checked**: `floonoc_mesh_if` exposes only Eject endpoints. Covered instead by the DUT's own per-router `XYDirectionNotAllowed` / `NoLoopback` assertions, which elaborate in all four routers and run under `--assert` | DUT-internal | — | **by DUT assertion** |
| RM9 | Illegal destination (src == dst) | — | not re-tested at UVM level: `c_legal_route` makes it unconstructible, and the DUT's own `NoLoopback` assertion covers it | — | — | **out of scope** |

**Stimulus, in full.** `floonoc_mesh_smoke_seq` sends 30 flits at 2x2:
8 one-hop link cases (every physical link, both directions), 4 two-hop
diagonal cases (both diagonals, both directions), a 3-flit same-pair burst,
and 15 constrained-random legal flits. Every case is derived from the
topology helpers (`has_neighbor`, `neighbor_idx`, `router_idx`), not from a
literal table, so the set rescales with `config/dut_config_mesh.svh`.

**RM6 is non-vacuous by construction, and that took a deliberate fix.**
Phases A and B use exclusively distinct `(src,dst)` pairs and the sequence is
serial, so on their own no per-pair FIFO ever holds two entries and the
ordering check has nothing to order. Phase C exists solely to guarantee a
depth-2 queue at every seed and mesh shape. Verified by mutation: swapping
`pop_front` for `pop_back` fails the run, and still fails with the random
phase disabled (4 mismatches on the 15 directed flits alone).

**`A_IN_VALID_STABLE` is currently vacuous, deliberately kept, and
instrumented.** Its antecedent is input-side backpressure, which this
configuration cannot produce: the mesh holds 80 flit slots
(`NumRouters * NumPorts * (InFifoDepth + OutFifoDepth)`), the driver keeps
one flit outstanding, and the test sends 30. `C_IN_BACKPRESSURE` — the exact
antecedent of that assertion — reads 0 and is there to make the vacuity
visible rather than let it hide behind a 100% figure. Mesh assertion coverage
is therefore 75% (3/4) by design. See
[compatibility.md](compatibility.md) for the measurements.

**What RM1 is and is not.** It compares two independent sources — the
wire-decoded `hdr.dst_id` and the physical Eject port the monitor observed —
so it catches a real DUT misroute. It is not a check of the XY routing
*model*: under XY routing the eject router is the destination by definition,
so the expectation makes no prediction. The model (`exp_out_port_at` /
`exp_path`) reaches the scoreboard only through `exp_hops()`, which feeds
coverage and printing. Intermediate-hop checking is RM8, and is deliberately
out of this interface's reach.

**Why the expectation side is fed by the driver, not the input monitor.** The
scoreboard subscribes to the driver's `sent_ap` — the original sequence item,
cloned, published once the input handshake completes — rather than to a
wire-decoded input observation. Keying expectations off the wire would make a
driver-side encoding bug self-certifying: a transposed `dst_id()` would be
decoded back into the same wrong expectation, faithfully routed there by the
DUT, and scored as a match, with the bench reporting PASS having never sent a
flit where the sequence asked. The input monitor keeps its own port for
protocol observation and independently checks that each flit's `hdr.src_id`
decodes to the port it was physically injected on. (The single-router bench
has the same weakness by construction; retrofitting it is a follow-up.)

### Negative self-tests (mesh checker effectiveness)

| ID | Fault injected | Knob | Checker that must fire | Expected diagnostic | Status |
|---|---|---|---|---|---|
| NM1 | Expected payload of one accepted flit corrupted in the scoreboard model | `corrupt_payload_idx` (config_db, `env.sb`) | RM2 integrity compare | `integrity/order mismatch` | **passing** (caught) |
| NM2 | One accepted flit modeled as ejecting at the wrong router | `corrupt_route_idx` (config_db, `env.sb`) | RM1/RM5/RM6 | `unexpected flit` / `integrity/order mismatch` / `never delivered` | **passing** (caught) |
| NM3 | Permanent Eject backpressure on every router (`ready_pct = 0`) | config_db, `env.agent.drv` | forward-progress watchdogs (sequence + drain budgets) | `forward progress stopped` | **passing** (caught) |

Run with `make run-negative-mesh`, which inverts the pass criteria: a
negative test that reports **no** `UVM_ERROR`, or that misses the expected
diagnostic, fails the target. Both failure modes were themselves verified by
pointing the target at a passing test and at a diagnostic that never appears.

NM2's wrong-router helper is fatal rather than silent when no valid
alternative router exists — on a 2-router mesh "skip to the next router"
lands back on the true destination, which would make the test vacuously pass:
the exact failure it exists to disprove.

## Deferred ideas (do not implement without spec backing)

- Output **data** stability under stall — upstream deliberately keeps the
  equivalent assertion commented out (`floo_router.sv:498`), and the
  output arbiter may legally switch payloads between competing inputs
  while valid is high.
- Cross-input arbitration fairness/ordering at one output — `rr_arb_tree`
  behavior, not documented as a router-level guarantee.
- Credit-counter range checks — credits are inert in `VcNaive`
  (`credit_o` constant 1); becomes meaningful only with `VcCredit`.
- Multi-flit packets / route-lock behavior (A2 relaxation).
- Zero-latency/min-latency bounds — microarchitectural timing, not spec.

## Next-milestone candidates (smallest high-value expansion)

1. `NumVirtChannels = 2` (`VcNaive`): exercises the real VC arbiter path
   (`gen_single_phys` in `floo_vc_arbiter`), extends the interface to
   per-VC valid/ready — modest TB change, large new-RTL coverage.
2. Multi-flit wormhole packets: relaxes A2, adds packet-level scoreboard.
3. `IdTable` routing config: exercises `addr_decode` path with a real
   route map.
