#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Verilator driver: version guard, lint, build, run, negative self-tests.
#
#   run_verilator.sh lint                  - lint-only pass on DUT + lint_wrapper
#   run_verilator.sh build [fst|vcd]       - compile the UVM bench (default fst)
#   run_verilator.sh run [+plusargs]       - execute smoke test (expects PASS)
#   run_verilator.sh run-neg <test> <re>   - run negative test (expects a
#                                            controlled FAIL matching <re>)
#   run_verilator.sh waves                 - FST run with bounded retry (KI-1)
#   run_verilator.sh waves-vcd             - VCD run (stable fallback, no retry)
#
# Logs go to logs/, exact command lines preserved in the logs and
# build/build_cmd*.txt. Nonzero exit on any failure, incl. UVM_ERROR > 0
# for positive runs and MISSING failure evidence for negative runs.
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REQUIRED_VERILATOR="${REQUIRED_VERILATOR:-5.052}"
UVM_HOME="${UVM_HOME:?UVM_HOME must be set (see Makefile)}"
BUILD="$ROOT/build"
mkdir -p "$BUILD" logs waves

# --- Version guard -------------------------------------------------------------
VER_STR="$(verilator --version 2>/dev/null || true)"
if ! echo "$VER_STR" | grep -q "Verilator $REQUIRED_VERILATOR "; then
  echo "[verilator] ERROR: this project requires Verilator $REQUIRED_VERILATOR." >&2
  echo "            Found: ${VER_STR:-<verilator not on PATH>}" >&2
  echo "            Override at your own risk: REQUIRED_VERILATOR=<ver> make ..." >&2
  exit 1
fi

TB_SOURCES=(
  tb/pkg/floo_tb_types_pkg.sv
  tb/interfaces/floonoc_router_if.sv
  tb/assertions/floonoc_router_sva.sv
  tb/pkg/floonoc_uvm_pkg.sv
  tb/top/tb_top.sv
)

require_sources() {
  if [ ! -f "$BUILD/sources.f" ]; then
    echo "[verilator] ERROR: build/sources.f missing — run 'make sources' first" >&2
    exit 1
  fi
}

log_and_run() {
  local log="$1"; shift
  echo "\$ $*" | tee "$log"
  "$@" 2>&1 | tee -a "$log"
  return "${PIPESTATUS[0]}"
}

do_build() { # $1 = fst|vcd
  local fmt="${1:-fst}" trace_flag obj
  case "$fmt" in
    fst) trace_flag="--trace-fst"; obj="$BUILD/obj_dir" ;;
    vcd) trace_flag="--trace-vcd"; obj="$BUILD/obj_dir_vcd" ;;
    *) echo "[verilator] ERROR: unknown trace format '$fmt'" >&2; exit 2 ;;
  esac
  require_sources
  # FST writer in Verilator 5.050 requires lz4 (not bundled on macOS/brew)
  local lz4_cflags="" lz4_ldflags="-llz4"
  if command -v brew >/dev/null 2>&1 && brew --prefix lz4 >/dev/null 2>&1; then
    local lz4_prefix; lz4_prefix="$(brew --prefix lz4)"
    lz4_cflags="-I$lz4_prefix/include"
    lz4_ldflags="-L$lz4_prefix/lib -llz4"
  fi
  log_and_run "logs/build_$fmt.log" \
    verilator --binary -j 0 \
      ${lz4_cflags:+-CFLAGS "$lz4_cflags"} \
      -LDFLAGS "$lz4_ldflags" \
      "$trace_flag" \
      -f config/verilator.f \
      -f "$BUILD/sources.f" \
      +incdir+"$UVM_HOME/src" \
      "$UVM_HOME/src/uvm_pkg.sv" \
      "${TB_SOURCES[@]}" \
      --top-module tb_top \
      -Mdir "$obj" \
      -o Vtb_top
  grep '^\$' "logs/build_$fmt.log" > "$BUILD/build_cmd_$fmt.txt"
  echo "[verilator] build ($fmt) PASS -> $obj/Vtb_top (log: logs/build_$fmt.log)"
}

do_sim() { # $1 = fst|vcd, $2 = testname, $3 = logfile, rest = extra plusargs
  local fmt="$1" test="$2" log="$3"; shift 3
  local obj="$BUILD/obj_dir"; [ "$fmt" = vcd ] && obj="$BUILD/obj_dir_vcd"
  if [ ! -x "$obj/Vtb_top" ]; then
    echo "[verilator] ERROR: $obj/Vtb_top missing — run 'make build' (or build vcd) first" >&2
    exit 1
  fi
  # Negative tests get a scratch coverage file so they never clobber the
  # primary logs/coverage.dat evidence from the passing smoke run.
  local cov_file="${COV_FILE:-logs/coverage.dat}"
  set +e
  log_and_run "$log" \
    "$obj/Vtb_top" "+UVM_TESTNAME=$test" +UVM_NO_RELNOTES \
      "+verilator+coverage+file+$cov_file" \
      "$@"
  local rc=$?
  set -e
  return $rc
}

case "${1:-}" in

  lint)
    require_sources
    log_and_run logs/lint.log \
      verilator --lint-only -sv --timing \
        config/verilator_waivers.vlt \
        +incdir+config \
        -f "$BUILD/sources.f" \
        tb/pkg/floo_tb_types_pkg.sv \
        tb/top/lint_wrapper.sv \
        --top-module lint_wrapper
    echo "[verilator] lint PASS: zero unwaived warnings (waiver register:"
    echo "            docs/waiver_register.md; log: logs/lint.log)"
    ;;

  build)
    do_build "${2:-fst}"
    ;;

  run)
    shift
    RUN_LOG=logs/run.log
    if do_sim fst floonoc_smoke_test "$RUN_LOG" "$@"; then :; else
      echo "[verilator] run FAILED (simulator exit $?, log: $RUN_LOG)" >&2
      exit 1
    fi
    # UVM does not propagate error counts into the exit code; enforce here.
    if ! grep -q '^UVM_ERROR :    0$' "$RUN_LOG" || \
       ! grep -q '^UVM_FATAL :    0$' "$RUN_LOG" || \
       ! grep -q 'TEST PASSED' "$RUN_LOG"; then
      echo "[verilator] run FAILED: UVM errors or missing PASS banner (log: $RUN_LOG)" >&2
      exit 1
    fi
    echo "[verilator] run PASS (log: $RUN_LOG, coverage: logs/coverage.dat)"
    ;;

  run-neg)
    TESTNAME="${2:?usage: run-neg <testname> <expected-regex>}"
    EXPECT_RE="${3:?usage: run-neg <testname> <expected-regex>}"
    NEG_LOG="logs/run_$TESTNAME.log"
    export COV_FILE="logs/coverage_neg.dat"
    do_sim fst "$TESTNAME" "$NEG_LOG" || {
      echo "[verilator] run-neg FAILED: simulator crashed instead of reporting (log: $NEG_LOG)" >&2
      exit 1
    }
    # Inverted criteria: the injected fault MUST be caught and reported.
    if grep -q '^UVM_ERROR :    0$' "$NEG_LOG"; then
      echo "[verilator] run-neg FAILED: $TESTNAME reported no UVM_ERROR — checker is vacuous!" >&2
      exit 1
    fi
    if ! grep -q 'TEST FAILED' "$NEG_LOG"; then
      echo "[verilator] run-neg FAILED: $TESTNAME missing TEST FAILED banner" >&2
      exit 1
    fi
    if ! grep -Eq "$EXPECT_RE" "$NEG_LOG"; then
      echo "[verilator] run-neg FAILED: $TESTNAME did not report expected diagnostic /$EXPECT_RE/" >&2
      exit 1
    fi
    echo "[verilator] run-neg PASS: $TESTNAME failed as intended with /$EXPECT_RE/ (log: $NEG_LOG)"
    ;;

  waves)
    # Verilator 5.050's fstcpp FST writer intermittently corrupts the heap
    # and crashes at exit (~10-25% of runs) — upstream tool bug, see
    # docs/known_issues.md KI-1 and docs/verilator_fst_issue.md. The
    # simulation itself completes correctly; only trace finalization dies.
    # Bounded retry; stable fallback: 'make waves-vcd'.
    for attempt in 1 2 3 4 5; do
      if "$0" run +trace +tracefile=waves/tb_top.fst && [ -s waves/tb_top.fst ]; then
        echo "[verilator] waves PASS on attempt $attempt -> waves/tb_top.fst"
        exit 0
      fi
      echo "[verilator] waves attempt $attempt hit known FST-writer crash (KI-1); retrying" >&2
    done
    echo "[verilator] waves FAILED after 5 attempts — beyond known intermittency." >&2
    echo "            Use the stable fallback: make waves-vcd" >&2
    exit 1
    ;;

  waves-vcd)
    [ -x "$BUILD/obj_dir_vcd/Vtb_top" ] || do_build vcd
    RUN_LOG=logs/run_vcd.log
    do_sim vcd floonoc_smoke_test "$RUN_LOG" +trace +tracefile=waves/tb_top.vcd || {
      echo "[verilator] waves-vcd FAILED (log: $RUN_LOG)" >&2; exit 1; }
    if ! grep -q 'TEST PASSED' "$RUN_LOG" || [ ! -s waves/tb_top.vcd ]; then
      echo "[verilator] waves-vcd FAILED: missing PASS banner or empty VCD" >&2
      exit 1
    fi
    echo "[verilator] waves-vcd PASS -> waves/tb_top.vcd (log: $RUN_LOG)"
    ;;

  *)
    echo "usage: $0 {lint|build [fst|vcd]|run [+plusargs]|run-neg <test> <re>|waves|waves-vcd}" >&2
    exit 2
    ;;
esac
