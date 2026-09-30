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
#   run_verilator.sh lint-mesh             - lint-only pass on the mesh DUT
#   run_verilator.sh lint-mesh-uvm         - lint-only pass on the mesh UVM
#                                            classes (no UVM top yet; compile-
#                                            check only, see the case body)
#   run_verilator.sh build-mesh            - compile the mesh bench
#   run_verilator.sh run-mesh [+plusargs]  - execute the mesh UVM smoke test
#                                            (expects PASS)
#   run_verilator.sh run-neg-mesh <test> <re>
#                                          - run a mesh negative test (expects a
#                                            controlled FAIL matching <re>)
#   run_verilator.sh cov-mesh              - mesh coverage report
#
# Mesh size / FIFO depth (all mesh targets): environment variables MESH_X,
# MESH_Y, MESH_IN_FIFO_DEPTH, MESH_OUT_FIFO_DEPTH become +define+s overriding
# config/dut_config_mesh.svh. Any non-default value tags the obj dir, logs and
# coverage file (e.g. _5x5, _5x5_i4o2) so binaries for different sizes
# coexist; with none set, every path is exactly the untagged 2x2 one.
# MESH_TEST selects the run-mesh test; a non-smoke test gets its own run log
# and coverage file so it never overwrites the smoke evidence.
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

# Mesh bench sources. Fully disjoint from TB_SOURCES: the two benches are
# never compiled into the same Verilator invocation (see docs/known_issues.md
# and config/dut_config_mesh.svh). Order matters: the UVM package must follow
# the types package and the interface it uses, and precede the top that
# imports it, and the SVA module must precede the top that instantiates it.
TB_MESH_SOURCES=(
  tb/pkg/floo_tb_mesh_types_pkg.sv
  tb/interfaces/floonoc_mesh_if.sv
  tb/interfaces/floonoc_mesh_link_if.sv
  tb/top/floonoc_mesh_dut.sv
  tb/assertions/floonoc_mesh_router_sva.sv
  tb/pkg/floonoc_mesh_uvm_pkg.sv
  tb/top/tb_top_mesh.sv
)

# --- Mesh size parameterization ------------------------------------------------
MESH_DEFINES=()
MESH_TAG=""
if [ -n "${MESH_X:-}${MESH_Y:-}" ]; then
  MESH_DEFINES+=("+define+FLOO_VERIF_MESH_X=${MESH_X:-2}" "+define+FLOO_VERIF_MESH_Y=${MESH_Y:-2}")
  if [ "${MESH_X:-2}x${MESH_Y:-2}" != "2x2" ]; then MESH_TAG="_${MESH_X:-2}x${MESH_Y:-2}"; fi
fi
FIFO_TAG=""
if [ -n "${MESH_IN_FIFO_DEPTH:-}" ]; then
  MESH_DEFINES+=("+define+FLOO_VERIF_MESH_IN_FIFO_DEPTH=$MESH_IN_FIFO_DEPTH")
  [ "$MESH_IN_FIFO_DEPTH" != 2 ] && FIFO_TAG="${FIFO_TAG}i$MESH_IN_FIFO_DEPTH"
fi
if [ -n "${MESH_OUT_FIFO_DEPTH:-}" ]; then
  MESH_DEFINES+=("+define+FLOO_VERIF_MESH_OUT_FIFO_DEPTH=$MESH_OUT_FIFO_DEPTH")
  [ "$MESH_OUT_FIFO_DEPTH" != 2 ] && FIFO_TAG="${FIFO_TAG}o$MESH_OUT_FIFO_DEPTH"
fi
if [ -n "$FIFO_TAG" ]; then
  [ -z "$MESH_TAG" ] && MESH_TAG="_2x2"
  MESH_TAG="${MESH_TAG}_$FIFO_TAG"
fi
MESH_OBJ="$BUILD/obj_dir_mesh$MESH_TAG"
MESH_SMOKE_TEST=floonoc_mesh_smoke_test

# Primary (positive-run) coverage file for a mesh test: the smoke test keeps
# the historical name, any other test gets its own.
mesh_cov_file() { # $1 = testname
  if [ "$1" = "$MESH_SMOKE_TEST" ]; then echo "logs/coverage_mesh$MESH_TAG.dat"
  else echo "logs/coverage_mesh${MESH_TAG}_$1.dat"; fi
}

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

do_build_mesh() {
  require_sources
  local lz4_cflags="" lz4_ldflags="-llz4"
  if command -v brew >/dev/null 2>&1 && brew --prefix lz4 >/dev/null 2>&1; then
    local lz4_prefix; lz4_prefix="$(brew --prefix lz4)"
    lz4_cflags="-I$lz4_prefix/include"
    lz4_ldflags="-L$lz4_prefix/lib -llz4"
  fi
  log_and_run "logs/build_mesh$MESH_TAG.log" \
    verilator --binary -j 0 \
      ${lz4_cflags:+-CFLAGS "$lz4_cflags"} \
      -LDFLAGS "$lz4_ldflags" \
      --trace-fst \
      -f config/verilator.f \
      ${MESH_DEFINES[@]+"${MESH_DEFINES[@]}"} \
      -f "$BUILD/sources.f" \
      +incdir+"$UVM_HOME/src" \
      "$UVM_HOME/src/uvm_pkg.sv" \
      "${TB_MESH_SOURCES[@]}" \
      --top-module tb_top_mesh \
      -Mdir "$MESH_OBJ" \
      -o Vtb_top_mesh
  grep '^\$' "logs/build_mesh$MESH_TAG.log" > "$BUILD/build_cmd_mesh$MESH_TAG.txt"
  echo "[verilator] mesh build PASS -> $MESH_OBJ/Vtb_top_mesh (log: logs/build_mesh$MESH_TAG.log)"
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

do_sim_mesh() { # $1 = testname, $2 = logfile, rest = extra plusargs
  local test="$1" log="$2"; shift 2
  if [ ! -x "$MESH_OBJ/Vtb_top_mesh" ]; then
    echo "[verilator] ERROR: $MESH_OBJ/Vtb_top_mesh missing — run 'make build-mesh' (same MESH_* variables) first" >&2
    exit 1
  fi
  # Mirrors do_sim's cov_file pattern: without an explicit plusarg the
  # coverage-instrumented binary (config/verilator.f's --coverage-user
  # --coverage-line) drops Verilator's default ./coverage.dat at the repo
  # root instead of into logs/. Negative tests override COV_FILE with a
  # scratch file so they never clobber the primary logs/coverage_mesh.dat
  # evidence from the passing smoke run.
  local cov_file="${COV_FILE:-$(mesh_cov_file "$test")}"
  set +e
  log_and_run "$log" \
    "$MESH_OBJ/Vtb_top_mesh" \
      "+UVM_TESTNAME=$test" +UVM_NO_RELNOTES \
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

  lint-mesh)
    require_sources
    # -Wwarn-UNDRIVEN: NOT added to the single-router `lint` case above —
    # scoped to mesh lint only, where a missing tie-off in the generated
    # inter-router wiring (floonoc_mesh_dut.sv) is exactly the defect class
    # a "moved verbatim, still correct" refactor needs a structural check
    # for. See docs/waiver_register.md W9 for the one pre-existing vendor
    # finding it surfaces (floo_router.sv, unrelated to the mesh wiring).
    log_and_run "logs/lint_mesh$MESH_TAG.log" \
      verilator --lint-only -sv --timing \
        -Wwarn-UNDRIVEN \
        config/verilator_waivers.vlt \
        +incdir+config \
        ${MESH_DEFINES[@]+"${MESH_DEFINES[@]}"} \
        -f "$BUILD/sources.f" \
        tb/pkg/floo_tb_mesh_types_pkg.sv \
        tb/top/floonoc_mesh_dut.sv \
        tb/top/lint_wrapper_mesh.sv \
        --top-module lint_wrapper_mesh
    echo "[verilator] mesh lint PASS: zero unwaived warnings (waiver register:"
    echo "            docs/waiver_register.md; log: logs/lint_mesh$MESH_TAG.log)"
    ;;

  lint-mesh-uvm)
    require_sources
    # Compile-checks the mesh UVM package against uvm_pkg with no top-level
    # elaboration and no C++ build. Since Task 8, build-mesh compiles the same
    # package for real, so this is no longer the only evidence that it
    # compiles — it is kept as the FAST check (a few seconds against
    # build-mesh's minutes) while iterating on the classes, and because it is
    # the one invocation that exercises them without a UVM top, which is what
    # `make lint-mesh-uvm` is for. Deliberately still NOT folded into
    # `lint-mesh` above, which has no UVM at all.
    log_and_run "logs/lint_mesh_uvm$MESH_TAG.log" \
      verilator --lint-only -sv --timing \
        -f config/verilator.f \
        ${MESH_DEFINES[@]+"${MESH_DEFINES[@]}"} \
        -f "$BUILD/sources.f" \
        +incdir+"$UVM_HOME/src" \
        "$UVM_HOME/src/uvm_pkg.sv" \
        tb/pkg/floo_tb_mesh_types_pkg.sv \
        tb/interfaces/floonoc_mesh_if.sv \
        tb/interfaces/floonoc_mesh_link_if.sv \
        tb/pkg/floonoc_mesh_uvm_pkg.sv \
        tb/top/floonoc_mesh_dut.sv \
        tb/top/lint_wrapper_mesh.sv \
        --top-module lint_wrapper_mesh
    echo "[verilator] mesh UVM lint PASS: floonoc_mesh_uvm_pkg (incl. floonoc_mesh_flit_item)"
    echo "            compiles clean against uvm_pkg (log: logs/lint_mesh_uvm$MESH_TAG.log)"
    ;;

  build-mesh)
    do_build_mesh
    ;;

  run-mesh)
    shift
    MESH_RUN_TEST="${MESH_TEST:-$MESH_SMOKE_TEST}"
    if [ "$MESH_RUN_TEST" = "$MESH_SMOKE_TEST" ]; then RUN_LOG="logs/run_mesh$MESH_TAG.log"
    else RUN_LOG="logs/run_$MESH_RUN_TEST$MESH_TAG.log"; fi
    # The 12-pair (src,dst) sweep that used to live here is retired: it
    # existed because the Phase-1 scaffolding could only drive one hand-built
    # flit per run, so covering every link meant re-running the binary. The
    # directed phase of floonoc_mesh_smoke_seq now sends every link in both
    # directions plus both diagonals within a single run, with a scoreboard
    # behind it rather than a $display banner.
    if do_sim_mesh "$MESH_RUN_TEST" "$RUN_LOG" "$@"; then :; else
      echo "[verilator] mesh run FAILED (simulator exit $?, log: $RUN_LOG)" >&2
      exit 1
    fi
    # UVM does not propagate error counts into the exit code; enforce here.
    if ! grep -q '^UVM_ERROR :    0$' "$RUN_LOG" || \
       ! grep -q '^UVM_FATAL :    0$' "$RUN_LOG" || \
       ! grep -q 'TEST PASSED' "$RUN_LOG"; then
      echo "[verilator] mesh run FAILED: UVM errors or missing PASS banner (log: $RUN_LOG)" >&2
      exit 1
    fi
    echo "[verilator] mesh run PASS (log: $RUN_LOG, coverage: ${COV_FILE:-$(mesh_cov_file "$MESH_RUN_TEST")})"
    ;;

  run-neg-mesh)
    TESTNAME="${2:?usage: run-neg-mesh <testname> <expected-regex>}"
    EXPECT_RE="${3:?usage: run-neg-mesh <testname> <expected-regex>}"
    NEG_LOG="logs/run_$TESTNAME$MESH_TAG.log"
    # Scratch coverage file: a negative run must never overwrite the
    # logs/coverage_mesh.dat evidence produced by the passing smoke run.
    export COV_FILE="logs/coverage_mesh_neg$MESH_TAG.dat"
    shift 3
    do_sim_mesh "$TESTNAME" "$NEG_LOG" "$@" || {
      echo "[verilator] run-neg-mesh FAILED: simulator crashed instead of reporting (log: $NEG_LOG)" >&2
      exit 1
    }
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

  cov-mesh)
    # Same three-way split as `make cov`, over this size's (and test's) own
    # coverage file so different benches/sizes never conflate.
    MESH_RUN_TEST="${MESH_TEST:-$MESH_SMOKE_TEST}"
    COV_IN="$(mesh_cov_file "$MESH_RUN_TEST")"
    SFX="$MESH_TAG"; [ "$MESH_RUN_TEST" != "$MESH_SMOKE_TEST" ] && SFX="${SFX}_$MESH_RUN_TEST"
    [ -f "$COV_IN" ] || { echo "[verilator] ERROR: $COV_IN missing — run 'make run-mesh' first" >&2; exit 1; }
    mkdir -p "logs/coverage_report_mesh$SFX"
    {
      echo "=== FUNCTIONAL coverage (covergroups) ==="
      verilator_coverage --filter-type covergroup --report summary,hier "$COV_IN"
      echo
      echo "=== ASSERTION coverage (SVA cover points) ==="
      verilator_coverage --filter-type user --report summary,hier "$COV_IN"
      echo
      echo "=== CODE coverage (DUT line coverage) ==="
      verilator_coverage --filter-type line --report summary "$COV_IN"
    } | tee "logs/coverage_summary_mesh$SFX.log"
    verilator_coverage --annotate "logs/coverage_report_mesh$SFX" "$COV_IN" > /dev/null
    echo "[cov-mesh] split summary: logs/coverage_summary_mesh$SFX.log; annotated source: logs/coverage_report_mesh$SFX/"
    ;;

  *)
    echo "usage: $0 {lint|build [fst|vcd]|run [+plusargs]|run-neg <test> <re>|waves|waves-vcd|lint-mesh|lint-mesh-uvm|build-mesh|run-mesh [+plusargs]|run-neg-mesh <test> <re> [+plusargs]|cov-mesh}" >&2
    exit 2
    ;;
esac
