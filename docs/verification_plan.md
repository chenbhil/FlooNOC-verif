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
| N4 | Driven flit #0 (directed row 0, Eject→(2,1)=East) encoded on the wire with `dst_x`/`dst_y` **swapped** → (1,2)=North, while the driver's `sent_ap` publishes the true intent. A stand-in for an `as_flit()` encode bug | `corrupt_encode_idx` (config_db, `env.agent.drv`) | R1/R5 against driver-intent expectations | `unexpected flit` / `never delivered` | **passing** (caught) |

**N4 proves a hole that existed.** Until 2026-09, the single-router
scoreboard took its expectations from the input monitor's `from_flit()`
decode of the wire, so an encode bug was self-certifying: the wrong header
decoded into the same wrong expectation and the DUT routed it "correctly".
Measured by mutation on Verilator 5.052: with `sb.in_imp` temporarily fed from
`mon.in_ap` again, N4 **passes** (`accepted=25 delivered=25 matched=25
mismatched=0`, 0 `UVM_ERROR`). With the driver feed, N4 fails as intended:
`unexpected flit at output 0(North) (nothing pending from input 4)` plus
`1 accepted flit(s) never delivered` (`matched=22 mismatched=3 pending=1`;
the two extra mismatches are the Eject→East FIFO shifting by one). The
scoreboard is now fed by the driver's `sent_ap` (the original item, cloned
after the input handshake), exactly like the mesh bench. The input monitor
additionally checks on every input handshake that `hdr.src_id` decodes to
the physical input port.

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

**Mesh size is a build parameter.** `make build-mesh MESH_X=5 MESH_Y=5`
(also `MESH_IN_FIFO_DEPTH` / `MESH_OUT_FIFO_DEPTH`) overrides
`config/dut_config_mesh.svh` through `+define+`. Non-default values tag the
obj dir, logs and coverage file (`_5x5`), and the default stays the untagged
2x2 bench. Every bound above the config header is derived (`NumRouters`,
`MeshDiameter`, `NumLinks`, coordinate widths via `$clog2`), and the traffic
comes from the topology helpers. Verified shapes: **2x2, 3x3, 4x4 and 5x5**.
Each passes smoke (`+mesh_num_random=60` above 2x2) and NM1–NM5; numbers are in
[compatibility.md](compatibility.md).

**Stimulus structure.** There is one sequencer and one driver per router
(`env.agent.sqr_<r>` / `drv_<r>`) under a virtual sequencer. The smoke virtual
sequence sends each flit on its source router's sequencer and blocks, so it
stays serial. The hotspot virtual sequence forks one leaf sequence per source
in the same timestep.

### Requirement-to-test matrix (mesh)

| ID | Requirement | Stimulus | Checker | SVA | Coverage | Status |
|---|---|---|---|---|---|---|
| RM1 | Routing: every accepted flit is ejected at exactly the router named by its destination header | `floonoc_mesh_smoke_seq` — every physical link both directions, both mesh diagonals, plus 15 random | `write_mesh_out` R1 block, checked before the expectation lookup so a misroute is diagnosed directly rather than as a spurious flit | — | `cp_dst_router`, `x_src_dst` | **passing** |
| RM2 | Payload arrives unmodified across every hop | same | `write_mesh_out` R2 block (payload compare against the driver-published expectation) | — | `cp_src_router` | **passing** |
| RM3 | Handshake/backpressure at every Eject port | smoke (driver holds valid; ~20% random Eject stall) + hotspot `+hs_fill` (Eject-input backpressure) | accepted/delivered counted only on valid&&ready | `A_IN_VALID_STABLE`, `A_OUT_VALID_STABLE`, covers `C_IN/OUT_HANDSHAKE`, `C_IN/OUT_BACKPRESSURE`, per router | `cp_backpressure` | **passing**. `A_IN_VALID_STABLE` is vacuous in smoke and **live** in the hotspot fill runs; see below |
| RM4 | Reset: every router's Eject output quiescent while reset asserted | reset phase of every run | — | `A_OUT_QUIET_IN_RESET` per router | — | **passing** |
| RM5 | No loss / no duplication end to end across the mesh | same + drain phase + 200ns idle tail | `check_phase`: pending==0, accepted==delivered; `write_mesh_out`: error on empty expectation queue; malformed-header decode reported at the boundary | — | — | **passing** |
| RM6 | Ordering per (src router, dst router) pair | directed 3-flit same-pair burst (phase C), plus whatever repeats the random phase draws | per-pair FIFO expectation queues, `pop_front` compare | — | — | **passing**, proven live by mutation |
| RM7 | Hop-count distribution reaches the mesh diameter | directed diagonals guarantee a `MeshDiameter` case | — | — | `cp_hops` | **passing** |
| RM8 | Path correctness at intermediate routers | same (every link is crossed in both directions by phase A) | `floonoc_mesh_link_monitor` observes every North/East/South/West output handshake through a read-only `floonoc_mesh_link_if`; `write_mesh_hop` requires each hop to leave in the direction `exp_out_port_at(router x, router y, hdr.dst_id)` predicts (`path violation` otherwise). `check_phase` completeness invariant: hops observed == Σ `exp_hops()` over accepted flits. A `valid` toward a boundary port (no neighbor, ready tied 0) is an immediate `LINKMON` error. TB-owned, so it still runs under `-D ASSERTS_OFF` | DUT's own `XYDirectionNotAllowed` / `NoLoopback` remain as a second, non-independent layer | `link_cg` (one bin per existing link) | **passing** (40 hops checked, 40 predicted, 0 violations) |
| RM10 | Contention at one output and backpressure propagation: several inputs competing for one Eject at once, FIFOs filling, backpressure travelling upstream hop by hop to the sources | `floonoc_mesh_hotspot_test` (`axis`/`ring`, `local`/`fill`) at 2x2..5x5 | all RM1/RM2/RM5/RM6/RM8 checks unchanged, plus the hotspot **simultaneity self-check** (every source's first flit hand-shakes in the same cycle) | `C_IN_BACKPRESSURE` at every source router in `fill` runs | `floonoc_mesh_hotspot_monitor`: per-input stall at T, all-live-inputs-stalled, inputs-requesting-at-eject. Also reports per-router Eject-input backpressure and an arbitration report. Fairness is a **measurement**, not a check (A8-M) | **passing** |
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

**`A_IN_VALID_STABLE` is vacuous in smoke and live in the hotspot fill
runs.** Its antecedent is input-side backpressure. The smoke test cannot
produce any: the 2x2 mesh holds 80 flit slots
(`NumRouters * NumPorts * (InFifoDepth + OutFifoDepth)`), and smoke stimulus is
serial with one flit outstanding. `C_IN_BACKPRESSURE`, the exact antecedent,
reads 0 there, so smoke assertion coverage is 75% (3/4) by design.
`floonoc_mesh_hotspot_test +hs_fill` sends enough flits per source to fill
every buffer on its path to a stalled target. Every source router then shows
Eject-input backpressure (for example at 5x5 ring fill, 3–7 backpressured
handshakes and 51–108 stalled cycles per source), and assertion coverage for
that run is **100% (4/4)**. See [compatibility.md](compatibility.md).

**What the hotspot test is.** S routers at Manhattan distance d from a target
T each send K flits to T, forked in the same timestep on their own
sequencers, while T's Eject output is held stalled for H cycles and then
released to 100% ready. `axis` uses T±d on both axes, so each source arrives
on a different input port of T. `ring` uses every router at distance d, so
off-axis sources merge onto T's N/S inputs. The four-way case needs at least
3x3; on 2x2 the test degrades to two sources and says so. K defaults to
InFifoDepth + OutFifoDepth + 1 (`local`) or
d·(In + Out) + In + Out + 1 (`fill`). The handoff's In + 1 was measured
too small, because T's shared Eject output FIFO absorbs two flits; see the plan.

**The simultaneity self-check found a real stimulus bug.** Its negative test
(NM5, one source delayed a cycle) first ran vacuous. The hotspot fork was
issued during reset, so every driver's reset wait lined the sources up and
absorbed the delay; the positive runs' "same cycle" was produced by reset, not
by the sequence. The sequence now waits for reset plus two edges before
aligning, and NM5 is caught at every size.

**What RM1 is and is not.** It compares two independent sources — the
wire-decoded `hdr.dst_id` and the physical Eject port the monitor observed —
so it catches a real DUT misroute. It is not a check of the XY routing
*model*: under XY routing the eject router is the destination by definition,
so the expectation makes no prediction. The routing *model*
(`exp_out_port_at`) is checked by RM8, one hop at a time.

**How RM8 checks the path.** The internal link signals live in our own
wrapper, `floonoc_mesh_dut` (`dut_valid_out` / `dut_ready_out` /
`dut_data_out`, indexed `[router][direction][vc]`). `tb_top_mesh` copies them
into a read-only `floonoc_mesh_link_if` by hierarchical reference. It never
touches vendor RTL and never changes the wrapper's ports. The check is
stateless: flits carry no ID, and none is needed, because "a flit for `dst`
leaving router (x,y) must go the way `exp_out_port_at` says" depends only on
the header and the location. If every hop decision matches the model, the
path equals `exp_path()` by induction, and the final Eject decision is RM1.
The completeness invariant (Σ `exp_hops()` == hops observed, enforced once
the mesh has drained) catches a hop the monitor missed. The directed phase
alone contributes 8×1 + 4×2 + 3×2 = 22 link hops; the smoke run totals 40.
It replaced reliance on the DUT's own `XYDirectionNotAllowed` / `NoLoopback`
assertions, which are designer-written (not independent) and compiled out
under `-D ASSERTS_OFF`, the xezim configuration. Verified: a scratch build
with `+define+ASSERTS_OFF` has 0 references to `XYDirectionNotAllowed` in the
generated C++ (12 normally), and still reports 40 hops checked and still
catches NM4.

The boundary-valid check cannot be proven live by a negative test. That
would need a DUT-side fault, which the negative-test rule forbids. It is
covered by construction: a boundary output's `ready` is tied 0, so without
the check an off-mesh route would surface only as a watchdog timeout.

**Why the expectation side is fed by the driver, not the input monitor.** The
scoreboard subscribes to the driver's `sent_ap` — the original sequence item,
cloned, published once the input handshake completes — rather than to a
wire-decoded input observation. Keying expectations off the wire would make a
driver-side encoding bug self-certifying: a transposed `dst_id()` would be
decoded back into the same wrong expectation, faithfully routed there by the
DUT, and scored as a match, with the bench reporting PASS having never sent a
flit where the sequence asked. The input monitor keeps its own port for
protocol observation and independently checks that each flit's `hdr.src_id`
decodes to the port it was physically injected on. The single-router bench
now uses the same arrangement; see N4.

### Negative self-tests (mesh checker effectiveness)

| ID | Fault injected | Knob | Checker that must fire | Expected diagnostic | Status |
|---|---|---|---|---|---|
| NM1 | Expected payload of one accepted flit corrupted in the scoreboard model | `corrupt_payload_idx` (config_db, `env.sb`) | RM2 integrity compare | `integrity/order mismatch` | **passing** (caught) |
| NM2 | One accepted flit modeled as ejecting at the wrong router | `corrupt_route_idx` (config_db, `env.sb`) | RM1/RM5/RM6 | `unexpected flit` / `integrity/order mismatch` / `never delivered` | **passing** (caught) |
| NM3 | Permanent Eject backpressure on every router (`ready_pct = 0`) | config_db, `env.agent.drv` | forward-progress watchdogs (sequence + drain budgets) | `forward progress stopped` | **passing** (caught) |
| NM4 | The XY model's expected direction for observed link hop #0 perturbed to the next direction (mod 4), in the scoreboard | `corrupt_hop_idx` (config_db, `env.sb`) | RM8 per-hop path check | `path violation` | **passing** (caught: `flit for R2(0,1) at R0(0,0) left North, XY model says East`) |
| NM5 | One hotspot source's start delayed by one clock edge (stimulus path, not the DUT) | `late_src_idx` (field of `floonoc_mesh_neg_simul_test`) | RM10 simultaneity self-check | `simultaneity violated: source R<n>` | **passing** (caught at 2x2..5x5, e.g. `source R1's first flit hand-shook at t=95000, 1 cycle(s) after the earliest source (t=85000)`) |

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
