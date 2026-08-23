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
