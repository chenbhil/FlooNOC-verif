# Known Issues

## KI-1 — Verilator 5.050 fstcpp FST writer: intermittent crash at exit (upstream tool bug)

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
