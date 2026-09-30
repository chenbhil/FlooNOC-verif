# Verilator 5.052 / FlooNoC Compatibility Report

Generated after the first fully passing smoke run (2026-07-12); updated
2026-07-13 with the coverage split, negative self-tests, measured FST
retry statistics, VCD fallback, and tracked lockfile. Re-verified 2026-09-09
on Verilator 5.052 (bumped from 5.050): lint, build, positive run, and all
three negative self-tests re-confirmed green with no bench changes.

## Tool and revision pins

| Item | Value |
|---|---|
| Verilator | `Verilator 5.052 2026-09-05 rev vUNKNOWN-built20260905` (Homebrew, macOS arm64); was `5.050 2026-07-01` before the 2026-09-09 bump |
| Bender | 0.32.1 |
| FlooNoC | `14c253c996fcdc78b793fe28ac18964769b768df` (tag `v0.8.4`), unmodified |
| common_cells | 1.39.0 @ `9ca8a7655f741e7dd5736669a20a301325194c28` (Bender.lock) |
| axi (axi_pkg.sv only) | 0.39.9 @ `a256a3b86394fedf19e361047fccfdd7f6ef83e4` (Bender.lock) |
| UVM | Accellera 1800.2-2017 1.0 kit (`UVM_HOME`), `+define+UVM_NO_DPI`, unmodified — tested version; nothing 1.0-specific is used, so any compatible 1800.2 UVM should work |
| Other Bender deps (iDMA, cvfpu, atomics, ...) | fetched/pinned by Bender.lock, **not compiled** |

## Selected DUT and configuration

`floo_router`, 5 ports (N/E/S/W/Eject), `XYRouting` at (1,1), 1 virtual /
1 physical channel, `InFifoDepth=2`, `OutFifoDepth=2`, generic 64-bit
flit, collectives disabled. Full rationale: `docs/dut_scope.md`.

## Command lines

Key options (full `.f` in `config/verilator.f`, exact command preserved in
`build/build_cmd_fst.txt` / `build_cmd_vcd.txt` and
`logs/build_fst.log` / `logs/build_vcd.log`):

```
verilator --binary -j 0 -sv --timing --assert
  --coverage-user --coverage-line config/coverage_scope.vlt
  --trace-fst --trace-structs --x-initial 0 --x-assign 0
  +define+UVM_NO_DPI config/verilator_waivers.vlt
  -CFLAGS -I<lz4>/include -LDFLAGS "-L<lz4>/lib -llz4"
  -f build/sources.f <uvm_pkg.sv> <tb sources> --top-module tb_top
```

(`--coverage-line` is scoped to the DUT closure by
`config/coverage_scope.vlt`; UVM and TB sources are excluded from code
coverage. A second flavor with `--trace-vcd` builds into
`build/obj_dir_vcd/` for the stable waveform fallback.)

Lint: `verilator --lint-only -sv --timing` on DUT + `lint_wrapper` (no UVM).
Run: `Vtb_top +UVM_TESTNAME=floonoc_smoke_test +UVM_NO_RELNOTES
+verilator+coverage+file+logs/coverage.dat [+trace]`.

## Results

| Stage | Result | Evidence |
|---|---|---|
| Lint (DUT + wrapper) | **PASS** — zero *unwaived* warnings; 8 waivers, each documented with observed message, reason, and revisit condition | `logs/lint.log`, `docs/waiver_register.md` |
| Compile (UVM smoke test, FST + VCD flavors) | **PASS** (~40 s wall each) | `logs/build_fst.log`, `logs/build_vcd.log` |
| Simulation | **PASS** — 25 flits accepted, 25 delivered, 25 matched, 0 mismatches, `UVM_ERROR: 0`, `*** TEST PASSED ***` | `logs/run.log` |
| Coverage — functional (covergroup) | **62.2%** (23/37 bins, 25 real samples) — this is pure covergroup data, reported separately from code/assertion coverage | `make cov` § FUNCTIONAL, `logs/coverage_summary.log` |
| Coverage — assertion (SVA cover) | **100%** (3/3 cover points: in-handshake ×25, out-handshake ×25, backpressure ×6) | `make cov` § ASSERTION |
| Coverage — code (DUT line) | **47.8%** (43/90 points, DUT closure only — UVM/TB excluded via `config/coverage_scope.vlt`) | `make cov` § CODE, `logs/coverage_report/` |
| Negative self-tests (N1–N4) | **PASS**: payload corruption, wrong-route expectation, held backpressure and an x/y-swapped driver encode (N4) each produced the required controlled failure with the expected diagnostic, so the checkers are proven non-vacuous. N4 was also shown to **pass** (0 `UVM_ERROR`) when the scoreboard is fed from the input monitor instead of the driver, which confirms the hole it guards was real | `make run-negative`, `logs/run_floonoc_neg_*.log` |
| FST waves | **PASS via automated retry (KI-1)** — measured 10/10 green, worst case attempt 2/5; ~23% raw writer-crash rate absorbed by retry (residual ≈ 0.1%) | `waves/tb_top.fst`, `docs/known_issues.md` |
| VCD waves (stable fallback) | **PASS deterministically** — separate `--trace-vcd` build, no retry needed | `make waves-vcd`, `waves/tb_top.vcd` |
| Reproducibility | **PASS** — `Bender.lock` tracked at repo root; `make setup` fails on any drift vs. the pinned checkout (drift path tested) | `Bender.lock`, `scripts/setup_deps.sh` |

## Results — mesh bench (`tb_top_mesh`, 2x2)

Second, independent bench: separate Verilator binary, separate top module,
separate object directory and coverage file (see
[known_issues.md](known_issues.md) KI-6). Numbers below are from the same
session as the single-router results above, Verilator 5.052.

| Stage | Result | Evidence |
|---|---|---|
| Lint (mesh RTL + wrapper, no UVM) | **PASS** — zero unwaived warnings, run with `-Wwarn-UNDRIVEN` on top of the single-router flag set; one waiver (W9), documented | `logs/lint_mesh.log`, `docs/waiver_register.md` |
| Compile (mesh UVM bench) | **PASS** (~45 s wall) | `logs/build_mesh.log` |
| Simulation | **PASS** — 30 flits accepted, 30 delivered, 30 matched, 0 mismatches, 0 pending, `UVM_ERROR: 0`, `UVM_FATAL: 0`, `*** TEST PASSED ***` at t=600 ns | `logs/run_mesh.log` |
| Coverage — functional (covergroup) | **88.9%** (32/36 bins). `flit_cg` 85.7% (24/28, 30 real samples): all four coverpoints 100%, and `x_src_dst` 12/16 = 75%, at its structural ceiling (the 4 unhit bins are exactly the `src == dst` diagonal, which `c_legal_route` makes unreachable). `link_cg` 100% (8/8 links, 40 observed hops) | `make cov-mesh` § FUNCTIONAL, `logs/coverage_summary_mesh.log` |
| Coverage — assertion (SVA cover) | **75.0% (3/4)** — `C_IN_HANDSHAKE`, `C_OUT_HANDSHAKE`, `C_OUT_BACKPRESSURE` hit; **`C_IN_BACKPRESSURE` reads 0**, and that is a measured property of the configuration, not a stimulus accident — see the note below | `make cov-mesh` § ASSERTION |
| Coverage — code (DUT line) | **47.8%** (43/90 points, DUT closure only) | `make cov-mesh` § CODE, `logs/coverage_report_mesh/` |
| Per-hop XY path check (RM8) | **PASS**: 40 link hops checked, 40 predicted by Σ `exp_hops()`, 0 path violations. Also verified with `+define+ASSERTS_OFF` (DUT's `XYDirectionNotAllowed` compiled out: 0 refs in generated C++): still 40 hops checked, and NM4 still caught | `logs/run_mesh.log` (`hops checked=` line) |
| Negative self-tests (NM1–NM4) | **PASS**: payload corruption, wrong-router expectation, held backpressure and a perturbed XY-model hop direction (NM4, `path violation`) each produced the required controlled failure with the expected diagnostic | `make run-negative-mesh`, `logs/run_floonoc_mesh_neg_*.log` |
| Single-router bench unaffected by the mesh work | **PASS**: the mesh bench adds no dependency on single-router sources. (The single-router bench was since changed deliberately by the G1 checker fix: driver-fed expectations and N4. It still passes 25/25 with functional coverage unchanged at 62.2%) | `make lint && make build && make run && make run-negative` |

### Why mesh assertion coverage is 75% and should stay that way

`A_IN_VALID_STABLE` (the TB must hold `valid_in` stable until the DUT takes
the flit) is **vacuous in this configuration**. Its antecedent is input-side
backpressure, and the mesh cannot produce any at this traffic level:

- The mesh holds `NumRouters * NumPorts * (InFifoDepth + OutFifoDepth)` =
  4 x 5 x 4 = **80 flit slots**, the driver keeps at most one flit
  outstanding, and the test sends 30. No Eject input FIFO can fill.
- Measured, not assumed: forcing the driver's `ready_pct` to 10 took
  `C_OUT_BACKPRESSURE` from 3 to 200 while `C_IN_BACKPRESSURE` stayed 0.
  Forcing it to 0 stalled every flit in the mesh (`accepted=27 delivered=0
  pending=27`) and *still* all flits were accepted on the input side with
  `C_IN_BACKPRESSURE` = 0.

`C_IN_BACKPRESSURE` exists precisely to make that visible: it is the exact
antecedent of `A_IN_VALID_STABLE`, so a zero count is standing evidence that
the assertion is currently dead weight rather than a passing check. **Do not
delete the cover to make the percentage read 100%** — the assertion is a real
TB-side obligation and starts working the moment flits in flight exceed the
buffering. The single-router bench has the identical blind spot and reads
100% (3/3) only because it has no equivalent cover; retrofitting one there is
a candidate follow-up.

### Checker effectiveness beyond the negative tests

Two checks were additionally proven live by mutation rather than by argument:

- **Ordering (RM6).** Replacing the scoreboard's `pop_front` with `pop_back`
  fails the run (6 mismatches). With the random phase disabled entirely it
  still fails (4 mismatches on 15 directed flits), so the directed same-pair
  burst — not the random draw — is what gives the check something to order,
  at every seed.
- **The three SVA statements.** Each was mutated individually (Verilator
  aborts at the first failure) and each fired with its own message:
  `A_OUT_QUIET_IN_RESET` at t=5 ns, `A_OUT_VALID_STABLE` at t=145 ns,
  `A_IN_VALID_STABLE` at t=85 ns (antecedent mutated, since its natural
  antecedent never occurs — see above).

## UVM features proven in this setup

| Feature | Status | Where |
|---|---|---|
| `uvm_config_db` | proven | vif set in `tb_top`, get in driver/monitor |
| Virtual interfaces | proven | `virtual floonoc_router_if` throughout agent |
| Phasing & objections | proven | `run_phase` raise/drop, clean shutdown via `run_test()` |
| Sequences/sequencer | proven | `floonoc_smoke_seq` on `uvm_sequencer` |
| TLM analysis ports | proven | monitor `in_ap`/`out_ap` -> scoreboard imps + subscriber |
| Constrained random | proven | `c_legal_route` implication constraints, 15 randomized items |
| SVA assertions | proven | 3 asserts + 3 covers execute (`--assert`); cover counts in coverage.dat (25/25/6) |
| Covergroups | proven (with workaround) | named bins + cross sample 25 real transactions |
| Factory/overrides | exercised implicitly | `type_id::create` everywhere; no override test yet |
| UVM RAL / DPI-based features | out of scope / unavailable | `UVM_NO_DPI` |

## Unsupported constructs encountered

| # | Construct | Category | Error / warning | Workaround | Compromises project value? |
|---|---|---|---|---|---|
| 1 | Covergroup coverpoint referencing enclosing class member | local UVM scaffold | `COVERIGN ... ignoring covergroup` (tb/coverage/floonoc_cov.sv:21 in first draft) | `with function sample(...)` arguments | No — full covergroup function retained |
| 2 | fstcpp FST writer non-binary encoding path | tool (Verilator) | intermittent `FST_CHECK failed: enc == EncodingType::BINARY` / SIGTRAP at exit | `--x-initial 0 --x-assign 0` + bounded retry in `make waves`; upstream issue drafted (`docs/verilator_fst_issue.md`) | Minor — waves reliable via retry; sim correctness unaffected |
| 3 | UVM DPI helpers (regex, name check, backdoor) | upstream verification IP (UVM) | `UVM/COMP/NAMECHECK` info + benign name warnings | `+define+UVM_NO_DPI` (standard for Verilator) | No — smoke scope unaffected |
| 4 | `<lz4.h>` not found building `verilated_fst_c.cpp` | tool packaging (macOS/Homebrew) | fatal C++ compile error | explicit lz4 `-CFLAGS/-LDFLAGS` in run script | No |
| 5 | Width-style warnings in upstream RTL (rr_arb_tree assert, axi_pkg math, floo_router enum compare) | core DUT RTL + required dependency | `WIDTHTRUNC`/`WIDTHEXPAND`/`UNSIGNED` | per-file documented waivers (`config/verilator_waivers.vlt`) | No — semantically benign, each reviewed |

**Core FlooNoC DUT RTL: zero unsupported constructs.** Everything in the
router's elaboration closure (7 floo files + common_cells) compiles,
elaborates, simulates, and passes its own embedded SVA under Verilator
5.052 (and, before the 2026-09-09 bump, 5.050) without modification.

## Verdict

FlooNoC's router-level RTL **is usable as a DUT for a spec-driven UVM
project under Verilator 5.052**. The smoke milestone passes end-to-end,
and the checking path is proven non-vacuous by three negative self-tests
that each force a controlled failure. The only tool-level defect found
(KI-1) affects waveform writing, not simulation semantics; it is covered
by a measured automated retry plus a deterministic VCD fallback.
