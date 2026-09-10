# Known Issues

## KI-1 — Verilator 5.050 fstcpp FST writer: intermittent crash at exit (upstream tool bug)

**Status on 5.052 (2026-09-09):** did not reproduce in 3/3 `make waves`
attempts after the version bump from 5.050. Too small a sample to call it
fixed — the original measured rate was ~23% per attempt, so 3/3 clean is not
yet statistically distinguishing "fixed" from "still ~23% and we got
lucky" (p(3 clean | still broken) ≈ 0.77³ ≈ 46%). Treat as open until a
larger sample (10+ raw attempts, not `make waves`-retried) is run on 5.052;
the retry logic below stays in place either way since it's cheap insurance.

**Symptom:** with `+trace`, ~10–25% of runs die at exit with SIGTRAP
(exit 133, empty FST) or SIGABRT (exit 134, truncated FST,
`FST_CHECK failed: enc == EncodingType::BINARY`). The simulation itself
always completes correctly first (identical UVM output to passing runs).

**Root cause:** heap corruption in Verilator 5.050's new built-in fstcpp
FST writer; the encoding check that sometimes fires is an
admitted-incomplete path (`include/fstcpp/fstcpp_variable_info.h:559`,
`FST_CHECK(enc == EncodingType::BINARY);  // TODO`). An lldb backtrace of
the SIGTRAP variant shows libmalloc's integrity check trapping in an
unrelated UVM allocation, i.e. the heap was already corrupted.
Reproduces with a pure-RTL dump scope; `--x-initial 0 --x-assign 0`
reduces but does not eliminate it. Not caused by FlooNoC RTL, UVM, or
local scaffold code.

**Workaround (automated and measured):** `make waves` retries up to 5
times and validates the FST is non-empty; successful runs produce a
complete, byte-identical FST. Measured 2026-07-13: 10/10 `make waves`
invocations green; 3 of 13 underlying attempts crashed (~23% raw rate,
inside the 10–25% estimate), all absorbed by attempt ≤ 2. Residual
failure probability at 5 attempts is ~0.25⁵ ≈ 0.1%.
`--x-initial 0 --x-assign 0` kept in `config/verilator.f`.

**Stable fallback:** `make waves-vcd` produces `waves/tb_top.vcd` via a
separate VCD build (`build/obj_dir_vcd/`) with no retry needed — the
crash is specific to the fstcpp writer. CI that must be deterministic
should prefer the VCD path.

**Upstream report:** draft ready to file at
`docs/verilator_fst_issue.md`. Likely fixed by a later Verilator release
(tool bug, not architectural).

**Side note:** on macOS/Homebrew, `--trace-fst` also requires manual lz4
flags (`-CFLAGS -I$(brew --prefix lz4)/include`, `-LDFLAGS "-L... -llz4"`),
handled in `scripts/run_verilator.sh`.

## KI-2 — UVM_NO_DPI startup warnings (cosmetic)

With `+define+UVM_NO_DPI` (required — Verilator provides no SV-DPI for
the UVM regex/name-check helpers), UVM 1800.2-2017 emits at time 0:
one `UVM/COMP/NAMECHECK` info ("name checks require DPI") and one benign
`UVM/COMP/NAME` warning per component ("uvm_test_top ... violates name
constraints", 28 total in the smoke test). Functionality (config_db
wildcard matching for our simple `"*"`/`"vif"` keys, factory, phasing)
is unaffected. Accepted as cosmetic; do not add these to error greps.

## KI-3 — Verilator covergroup limitations (worked around)

- Coverpoints referencing enclosing **class members** are unsupported
  (`COVERIGN` warning, covergroup silently ignored). Workaround: pass
  sampled values as `with function sample(...)` arguments
  (`tb/coverage/floonoc_cov.sv`).
- Array bins (`bins b[] = {[0:4]}`) are recorded as one aggregated
  counter per coverpoint in `coverage.dat` rather than per-bin entries;
  explicit named bins (as used here) report correctly.
- A comment whose first word is `verilator` inside SV source is parsed
  as a metacomment and rejected (`BADVLTPRAGMA`) — avoid starting
  comments with the tool name.

## KI-4 — Simulator exit code does not reflect UVM errors

UVM ends via `$finish` (exit 0) regardless of `UVM_ERROR` count.
`scripts/run_verilator.sh run` therefore greps the log for
`UVM_ERROR :    0`, `UVM_FATAL :    0` and the `TEST PASSED` banner and
returns nonzero otherwise. Any CI integration must call the script (or
replicate the grep), not the raw binary.

## KI-5 — Stack-size warning at startup (cosmetic)

`%Warning: System has stack size 8176 kb which may be too small...` —
Verilator requests a larger stack for deep UVM call chains; macOS caps
`ulimit -s`. No observed failure at this design size. If deep recursion
ever crashes, re-launch via a thread with a larger stack or raise the
hard limit.

## KI-6 — The two benches must never share a Verilator invocation (by design)

**Status:** structural, permanent. Not a defect — a rule the build enforces.

`floo_tb_types_pkg` (single-router) and `floo_tb_mesh_types_pkg` (mesh) both
export `NumPorts`, `FlitDataW`, `InFifoDepth`, `OutFifoDepth`, `x_bits_t`,
`y_bits_t`, `port_id_t`, `payload_t`, `flit_t`, `xy_id_t`, `hdr_t` and
`dir_name`, with **different values** — the mesh's coordinate widths and port
counts describe a different DUT. `config/dut_config.svh` and
`config/dut_config_mesh.svh` are likewise parallel headers.

Two independent guards keep them apart:

1. **Separate compiles.** `scripts/run_verilator.sh` keeps `TB_SOURCES` and
   `TB_MESH_SOURCES` disjoint, with separate top modules (`tb_top` /
   `tb_top_mesh`), object directories (`build/obj_dir` /
   `build/obj_dir_mesh`) and coverage files (`logs/coverage.dat` /
   `logs/coverage_mesh.dat`).
2. **Namespaced macros.** Every mesh config macro is `FLOO_VERIF_MESH_*`, so
   even if both headers reached one compile unit there is no `` `define``
   collision. The convention for any future third bench is
   `FLOO_VERIF_<BENCH>_*`; the older single-router header keeps the
   unprefixed names for now.

What is left is the *good* failure mode: a file wildcard-importing both
packages gets a **compile-time ambiguity error** naming the exact symbol, on
the first unqualified use. Loud, immediate, and self-defending — unlike the
silent macro substitution the namespacing closed. No file imports both.

## KI-7 — Verilator cannot track per-bit drivenness through the mesh's generate wiring

**Status:** upstream tool limitation, confirmed with four minimal repros.

`make lint-mesh` runs with `-Wwarn-UNDRIVEN` (the single-router `lint` does
not), which is a net positive but does **not** close the gap it was added
for. Verilator stops per-bit drivenness tracking once a multi-dimensional
packed array slice is read through a genvar-indexed submodule port connection
inside a generate loop — exactly the `.valid_i(dut_valid_in[r])` pattern in
`floonoc_mesh_dut.sv`'s `gen_routers`. A `split_var` `.vlt` directive had no
effect.

**Consequence — the boundary-tie-off blind spot.** A missing `gen_boundary`
tie-off in `floonoc_mesh_dut.sv` is undetectable on Verilator under this
build config: `UNDRIVEN` does not see it, and `config/verilator.f`'s
`--x-initial 0` makes the undriven bit read `0`, which is coincidentally the
correct tie-off value. It was proven by fault injection that deleting a
single `assign` passed both `make lint-mesh` and `make run-mesh`.

**Do not re-attempt an X-injection check for this.** A `check-mesh-x` target
was built and abandoned; the reasons are structural, not effort:

- `--x-initial unique` at compile time is a trap. It only makes Verilator
  *capable* of a non-zero reset; `VerilatedContext::randReset()` still
  defaults to `0` at runtime, so the compile flag alone silently reproduces
  the exact masking it appears to remove. A green run under that flag proves
  nothing while looking like it proves everything. Forcing the behavior needs
  the runtime plusarg `+verilator+rand+reset+1`.
- `+verilator+rand+reset+N` is global and cannot be scoped. It also forces
  the vendor DUT's legitimately-undriven internals (`past_handshakes_d`, the
  arbiter-tree padding in `rr_arb_tree.sv` / `lzc.sv`, the disabled
  collective path in `floo_output_arbiter.sv`), which perturbs the arbiter
  enough that *every* router spuriously asserts `valid_out` on correct,
  unmodified RTL. A gate that fails on correct input is worse than no gate.

**What does cover it:** the smoke sequence's directed phase drives every
physical link in both directions and both diagonals, so every *consequential*
omission (a dropped `gen_eject_map` or `gen_connected` assign) fails the run.
The residual exposure is confined to a future edit of `floonoc_mesh_dut.sv`.

**If you run this bench on xezim:** xezim does not mask X the way
`--x-initial 0` does, so a missing boundary tie-off would show up there as X
propagation and could easily be misattributed to the simulator. Check the
tie-offs in `floonoc_mesh_dut.sv` before filing a simulator bug.

## KI-8 — Mesh scoreboard iteration shapes to re-verify on xezim

**Status:** forward-looking note; nothing wrong on Verilator.

The mesh scoreboard's `expected [NumRouters][NumRouters][$]` is a class
property that is an **array of collections**, and `pending_count()` /
`dump_pending()` iterate it with `foreach (expected[i, o])`. That is exactly
the shape of two xezim bugs this workspace has already paid for (see
`CLAUDE.md` bugs 26 and 17): the element queues had no storage at all, and
the multi-index `foreach` both mis-iterated and made a scoreboard check
silently vacuous. Both are fixed upstream, and four sub-cases of bug 26 were
deliberately left open.

The mesh bench has **not** been run on xezim. When it first is, do not read
`pending=0` as evidence of "nothing in flight" until the iteration itself is
confirmed to work — the failure mode is a check that passes without checking.
The driver's `vif.data_in[r] <= item.as_flit()` is likewise bug 20's exact
shape (a packed-array-element NBA through a virtual interface).
