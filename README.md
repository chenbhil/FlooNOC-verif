# FlooNoC × Verilator 5.052 × UVM — Smoke-Test Workspace

Independent, reproducible UVM verification scaffold around the
[PULP FlooNoC](https://github.com/pulp-platform/FlooNoC) `floo_router`,
simulated with **Verilator 5.052** and the **Accellera UVM 1800.2-2017
1.0** library. This is a feasibility/scaffolding milestone: it proves the
RTL + toolchain + methodology stack end-to-end on the smallest meaningful
DUT — it does not verify the whole NoC.

**Status: PASSING** — see `docs/compatibility.md` for the full report.

## Architecture overview

`tb_top.sv` generates clock/reset, instantiates one `floo_router`
(5 ports, XY routing at (1,1), 1 virtual channel, generic 64-bit flit —
types built with FlooNoC's own `floo_noc/typedef.svh` macros) behind a
purpose-built `floonoc_router_if`, and publishes the virtual interface
through `uvm_config_db` before `run_test()`. A single active agent
drives flit items (10 directed + 15 constrained-random, all constrained
to routes that are legal under the router's `NoLoopback`/`XYRouteOpt`
defaults) into the input ports and randomly backpressures the outputs;
the monitor publishes every accepted/delivered handshake through
analysis ports to a scoreboard (routing per the documented XY rule,
payload integrity, no loss/duplication, per input→output ordering) and
a covergroup subscriber (src/out/backpressure + src×out cross).
Interface-level SVA mirrors the DUT's own valid-stability contracts.
Upstream FlooNoC sources are a pinned, unmodified checkout; all
dependencies resolve through Bender at `Bender.lock` revisions.

## Prerequisites

- **Verilator 5.052 exactly** (build fails early on other versions;
  override with `REQUIRED_VERILATOR=` at your own risk)
- **Bender** ≥ 0.28 (`brew install bender`)
- **lz4** headers for FST tracing on macOS (`brew install lz4`)
- **A UVM 1800.2 library** the testbench and simulator both accept — point
  `UVM_HOME` at the kit's root (the directory containing `src/uvm_pkg.sv`).
  Developed and tested against the **Accellera 1800.2-2017 1.0** kit; nothing
  release-specific is used, so a compatible UVM should work. `UVM_HOME` is not
  version-gated — `make setup` only verifies `UVM_HOME/src/uvm_pkg.sv` exists.
- git, a C++17 compiler, GNU make

## Quick start

```sh
make setup         # clone/pin FlooNoC v0.8.4 + bender checkout + verify UVM
                   #   (verifies tracked ./Bender.lock matches the pinned checkout)
make sources       # generate build/sources.f (deterministic filelist)
make lint          # Verilator lint-only; zero unwaived warnings
                   #   (waivers documented in docs/waiver_register.md)
make build         # compile the UVM smoke test (~40 s)
make run           # execute; nonzero exit on any UVM error
make run-negative  # 3 fault-injection self-tests that MUST fail with the
                   #   expected diagnostic (proves checkers aren't vacuous)
make waves         # FST tracing -> waves/tb_top.fst (auto-retry, KI-1)
make waves-vcd     # deterministic VCD fallback -> waves/tb_top.vcd
make cov           # coverage report split into FUNCTIONAL / ASSERTION / CODE
make doctor        # print tool/pin/DUT status
make clean         # remove build outputs (keeps logs/)
```

Expected `make run` tail:

```
UVM_INFO ... [SB] accepted=25 delivered=25 matched=25 mismatched=0 pending=0
UVM_INFO ... [RESULT] *** TEST PASSED *** (25 flits accepted, 25 delivered, 25 matched, 0 mismatches)
UVM_ERROR :    0
[verilator] run PASS (log: logs/run.log, coverage: logs/coverage.dat)
```

## Pinned revisions

| Component | Revision |
|---|---|
| FlooNoC | `14c253c996fcdc78b793fe28ac18964769b768df` (`v0.8.4`) |
| HDL deps | `./Bender.lock` (version-controlled source of truth; `make setup` fails on drift vs. the pinned checkout) |
| UVM | Accellera 1800.2-2017 kit 1.0 (tested; not version-gated — any compatible 1800.2 UVM should work) |
| Verilator | 5.052 (enforced) |

## Layout

```
Bender.lock       tracked HDL dependency lockfile (source of truth)
config/           verilator.f, documented waivers, coverage scope, DUT config, filelist whitelist
rtl_or_vendor/    floonoc/ — pinned upstream checkout (never edited)
tb/               top/ interfaces/ pkg/ tests/ sequences/ agents/ env/ coverage/ assertions/
scripts/          setup_deps.sh, bender_sources.sh, run_verilator.sh
docs/             dut_scope, assumptions, verification_plan, uvm_coverage, waiver_register, compatibility, known_issues
build/ logs/ waves/   generated (gitignored)
```

## Known limitations

- FST writing crashed intermittently at exit on Verilator 5.050 due to a
  fstcpp writer bug (`docs/known_issues.md` KI-1, upstream issue draft in
  `docs/verilator_fst_issue.md`); on 5.052 it has not reproduced in a small
  retest (3/3 clean), but that is too few runs to call it fixed given how
  intermittent it was. `make waves` still retries automatically and
  `make waves-vcd` remains a deterministic fallback — prefer it where CI
  must not depend on retries.
- UVM runs with `UVM_NO_DPI`: benign component-name warnings at startup;
  regex config_db patterns unavailable (KI-2).
- Covergroups require `with function sample(...)` style; array bins are
  aggregated in `coverage.dat` (KI-3).
- Pass/fail is enforced by `scripts/run_verilator.sh` grepping the UVM
  report summary (KI-4) — use the script, not the raw binary, in CI.
- Smoke scope only: single-flit packets, 1 VC, no illegal-destination
  testing (unspecified upstream), no AXI chimneys.

## License

This testbench and its scaffolding (everything under `tb/`, `config/`,
`scripts/`, `docs/`, and the build files) are licensed under
**Apache-2.0** — see [`LICENSE`](LICENSE).

Upstream [PULP FlooNoC](https://github.com/pulp-platform/FlooNoC) RTL is
fetched unmodified at the pinned revision by `make setup` and remains under
its own licenses (Solderpad SHL-0.51 / Apache-2.0); it is not redistributed
in this repository. The Accellera UVM library is likewise obtained separately
under its own license and is not included here.
