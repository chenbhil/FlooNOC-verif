# Plan: mesh hotspot test + mesh size as a build parameter

**Handoff:** `2026-09-29-mesh-hotspot-handoff.md` · **Branch:** `feat/mesh-hotspot`, based on
`fix/checker-gaps` (which is ahead of `feat/mesh-uvm-env` and already provides
`floonoc_mesh_link_if` + the per-hop RM8 check + NM4). Consequence: the mesh negative
set is NM1–NM4 before this work, so the new simultaneity test is **NM5** and
`make run-negative-mesh` runs **5** tests, not 4.

Baseline on the base branch (2026-09-30, Verilator 5.052): 2×2 smoke 30/30/30, 40 hops
checked, NM1–NM4 caught.

## Part A — mesh size as a build parameter

1. `config/dut_config_mesh.svh`: every macro under `` `ifndef ``. `X_BITS`/`Y_BITS` default to
   `((X > 1) ? $clog2(X) : 1)`, which is 1 at 2×2 (unchanged), 2 at 3×3/4×4 and 3 at 5×5.
   `MeshCoordWidthGuard` is kept.
2. `scripts/run_verilator.sh`: env `MESH_X`, `MESH_Y`, `MESH_IN_FIFO_DEPTH`,
   `MESH_OUT_FIFO_DEPTH` become `+define+`s on every mesh invocation. A size tag
   (`_5x5`, plus `_i<N>o<M>` when a depth is overridden) is empty at the 2×2 default and
   suffixes the obj dir, build/lint/run logs and the coverage file. Non-smoke tests
   (`MESH_TEST`) also get their own run log and coverage file, so a hotspot run never
   overwrites smoke evidence. `Makefile` exports the variables and maps `TEST=` →
   `MESH_TEST`, `PLUSARGS=` → extra plusargs.
3. `+mesh_num_random=N` (default 15) for the random phase.
4. Fix the stale "12 directed + 15 random = 27" comment in the negative tests. State the
   rule instead: NM1/NM2's indices (3, 5) must stay inside phase A, which has at least
   8 flits on any 2-D mesh ≥ 2×2.

## Part B — per-router drivers (structural)

- **Agent:** one agent, arrays `sqr[NumRouters]` / `drv[NumRouters]` named `sqr_<r>` /
  `drv_<r>`, one monitor (it already loops over all routers). Driver *r* learns its index
  through config_db (`router_idx`) and owns only `valid_in[r]`, `data_in[r]` and `ready_out[r]`.
- **Driver contract unchanged:** hold valid until valid&&ready, then publish a clone on
  `sent_ap`. It also stamps `accept_time` (the handshake edge) on the item before cloning,
  so the sequence and the scoreboard both see it. Every `sent_ap` connects to `sb.in_imp`.
  The scoreboard's queues are per (src, dst), and `write_mesh_in` already clones, so
  same-timestep writes from several drivers need no structural change.
- **Ready control:** a shared `floonoc_mesh_ready_ctrl` object (config_db `ready_ctrl`) with
  per-router `hold` and `pct_override`. Each driver reads its own entry every cycle.
  Precedence: hold → 0, else override ≥ 0, else `ready_pct`. The sequence drives it
  deterministically; there are no timing guesses.
- **Virtual sequencer:** `floonoc_mesh_vsequencer` has handles to every per-router
  sequencer, the ready-control object and the vif (for clock-aligned waits).
- **Smoke:** `floonoc_mesh_smoke_seq` becomes a virtual sequence. It keeps the same order
  and phases, and sends each item as a one-item leaf sequence (`floonoc_mesh_send_seq`)
  on `sqr[src_router]`, blocking, so it stays serial. NM3's `ready_pct` path becomes
  `env.agent.drv_*`.

## Part C — hotspot

### Knobs (plusargs on the test, with defaults)

| plusarg | default |
|---|---|
| `+hs_target=` | `router_idx(MeshX/2, MeshY/2)` |
| `+hs_d=` | the largest d ≤ 2 with all four T±d inside the mesh, at least 1 |
| `+hs_mode=axis\|ring` | `axis` |
| `+hs_k=` | see below |
| `+hs_fill` | off |
| `+hs_hold=0\|1` | 1 |
| `+hs_hold_cycles=` | derived, logged |

The payload is `{16'h4853 "HS", 16'(src), 16'(T), 16'(k)}`. At 2×2 the mode degrades
(only sources inside the mesh are used) and the run logs how many of T's input ports
are reached.

### Simultaneity (C2)

After a clock edge, one leaf sequence per source is forked in the same timestep on
its own sequencer. After the join, the stimulus self-check compares every source's
first `accept_time` and raises `uvm_error("HOTSPOT", "simultaneity violated ...")`,
naming the late source. **NM5** `floonoc_mesh_neg_simul_test` delays one source by one
clock edge.

### Hold / release

T's `ready_out` is held from the first injection and then released to 100%, so the
arbitration order is measured without random Eject stalls. **Deviation, decided up
front:** the handoff's "release when all K×S flits are accepted at their sources,
or after H cycles, whichever is first" releases too early in `local` mode. There, all
flits are accepted at their sources within a few cycles, before they have even reached
T, so no pile-up would form. Release is therefore at H cycles after the first
injection, with H = 4·(d+1) + 2·K + 16 by default, logged, and overridable.

### Monitoring

A new passive `floonoc_mesh_hotspot_monitor`, created only when the test sets
`hotspot_target` (so the smoke run's components and coverage are unchanged):

- **Contention coverage:** it reads T's inputs through the existing
  `floonoc_mesh_link_if`. T's input from `dir` is neighbor n's output toward
  `opposite_dir(dir)`, because `lif.valid[n][opp]` **is** `dut_valid_in[T][dir]` and
  `lif.ready[n][opp]` **is** `dut_ready_in[T][dir]`, so no second interface is needed.
  The covergroup is constructed with T's live-input count, so bins derive from
  `has_neighbor`. It covers:
  - per-live-input "stalled";
  - "all live inputs stalled in one cycle";
  - the number of T's inputs presenting a flit for T when T's Eject handshakes
    (bins 1..n). This is input-port pressure: the arbiter's FIFO-head requests are
    vendor-internal and deliberately not read.
- **Backpressure per router:** from `mon.in_ap` (currently unsubscribed), counting
  handshakes with `backpressured` set.
- **Arbitration report** (a metric, not a check):
  - the source order at T's Eject after release;
  - per-source deliveries per window of S consecutive T-ejections;
  - the maximum number of other-source flits that left T while a given source had one
    inside T (entered T over a link, not yet ejected).

### Latency (every run)

The driver stamps `accept_time`; the monitor stamps `obs_time` on each output item.
The scoreboard computes (obs − accept) / 10 ns on each match and prints min/avg/max
by hop count and by source in `report_phase`.

### K and pass/fail

K for `local` is InFifoDepth + 1, as the handoff specifies. If measurement shows that
doesn't stall all four inputs (T's shared Eject output FIFO absorbs part of it), the
default is revised and the reason recorded below. `fill` uses the handoff formula as
a starting point, with the observed result recorded.

No new pass/fail bound other than simultaneity. Fairness, backpressure-reached and
all-stalled are measurements, and their acceptance is read from the report and the
SVA covers. So only NM5 is added.

## Execution record (2026-09-30)

Commits on `feat/mesh-hotspot`:
- `81ad0de` Part A, size parameters
- `f6bd435` Part B, per-router drivers
- `4e2e9f0` Part C, hotspot, NM5 and latency
- docs, in the final commit

**Part A.** 2x2 with no variables was identical before and after: 30/30, 40
hops, NM1–NM4 caught, same file names. 3x3, 4x4 and 5x5 smoke with
`+mesh_num_random=60` gave 91, 115 and 147 flits, all matched, with link
coverage 100% at every size. Numbers are in compatibility.md.

**Part B.** Smoke stayed serial with the same order. One side effect: the
random-phase draws changed, because starting a sub-sequence per item consumes
the parent thread's RNG when seeding the new objects. Only the random flits
differ; counts and every check are unchanged. NM3's config path is now
`env.agent.drv_*`.

**Part C, deviations from the handoff, each with its reason:**
1. **K(local) = In + Out + 1, not In + 1.** Measured at 5x5 with `+hs_k=3`:
   only S and W stalled, "all inputs stalled" was 0 cycles, and stall
   coverage was 75%. T's shared Eject output FIFO absorbs two of the flits.
2. **Release after a fixed H, not "all accepted or H".** In local mode every
   flit is accepted at its source within a few cycles, before any reaches T,
   so the handoff's rule would release before a pile-up forms.
   H = 4·(d+1) + 2·K + 16, logged in every run.
3. **Contention bins over T's 4 directions.** Verilator 5.052 rejects
   covergroup constructor arguments in bin ranges, so the bins can't be sized
   by `has_neighbor`. The all-stalled cover is derived from `has_neighbor`.
4. **"Requesting Eject" means T's input ports presenting a flit for T.** The
   arbiter's FIFO-head requests are vendor-internal.
5. **The negative test is NM5, and `run-negative-mesh` runs 5, not 4**, because
   the base branch already had NM4 (G2).
6. **Backpressure-reached-the-sources is a measurement, not a check.** It is
   reported per router, with acceptance read from the report plus
   `C_IN_BACKPRESSURE`, so it needs no negative test of its own.

**NM5 found a real stimulus bug.** It first ran vacuous: the hotspot fork was
issued during reset, and every driver's `wait (rst_n)` plus one edge aligned
the sources, absorbing the one-cycle delay. The positive runs' "same cycle"
was produced by reset, not by the sequence. Before blaming Verilator, a
10-line probe confirmed that a forked `@(posedge)` does wait for the next
edge. Fix: wait for reset plus 2 edges before aligning. NM5 is now caught at
every size.

**Acceptance: all met.**
- 2x2 default smoke 30/30, and NM1–NM5 caught.
- 3x3 and 4x4 axis local and fill pass.
- 5x5 axis and ring, local and fill, pass.
- Every run has its first flits in the same cycle and hits the
  all-live-stalled cover.
- Every fill run shows Eject-input backpressure at every source.
- 5x5 ring fill has assertion coverage 100% (4/4).

**Surprises:**
- Ring mode is fair per input port, not per flow. The E and W single sources
  wait behind at most 3 others; the N and S merged sources wait behind up to 8.
- At 2x2 the first two post-release ejections come from the same source.
- Latency is 2 cycles per router plus 2 at every size, matching the reference.
