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
#   run_verilator.sh build-mesh            - compile the mesh bench
#   run_verilator.sh run-mesh [+plusargs]  - explicit plusargs: single run;
#                                            no plusargs: sweep all non-
#                                            loopback (src,dst) pairs
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
# and config/dut_config_mesh.svh). Grows in Task 8 (UVM) and Task 11 (SVA).
TB_MESH_SOURCES=(
  tb/pkg/floo_tb_mesh_types_pkg.sv
  tb/interfaces/floonoc_mesh_if.sv
  tb/top/floonoc_mesh_dut.sv
  tb/top/tb_top_mesh.sv
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

do_build_mesh() {
  require_sources
  local lz4_cflags="" lz4_ldflags="-llz4"
  if command -v brew >/dev/null 2>&1 && brew --prefix lz4 >/dev/null 2>&1; then
    local lz4_prefix; lz4_prefix="$(brew --prefix lz4)"
    lz4_cflags="-I$lz4_prefix/include"
    lz4_ldflags="-L$lz4_prefix/lib -llz4"
  fi
  log_and_run "logs/build_mesh.log" \
    verilator --binary -j 0 \
      ${lz4_cflags:+-CFLAGS "$lz4_cflags"} \
      -LDFLAGS "$lz4_ldflags" \
      --trace-fst \
      -f config/verilator.f \
      -f "$BUILD/sources.f" \
      "${TB_MESH_SOURCES[@]}" \
      --top-module tb_top_mesh \
      -Mdir "$BUILD/obj_dir_mesh" \
      -o Vtb_top_mesh
  grep '^\$' "logs/build_mesh.log" > "$BUILD/build_cmd_mesh.txt"
  echo "[verilator] mesh build PASS -> $BUILD/obj_dir_mesh/Vtb_top_mesh (log: logs/build_mesh.log)"
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

  lint-mesh)
    require_sources
    # -Wwarn-UNDRIVEN: NOT added to the single-router `lint` case above —
    # scoped to mesh lint only, where a missing tie-off in the generated
    # inter-router wiring (floonoc_mesh_dut.sv) is exactly the defect class
    # a "moved verbatim, still correct" refactor needs a structural check
    # for. See docs/waiver_register.md W9 for the one pre-existing vendor
    # finding it surfaces (floo_router.sv, unrelated to the mesh wiring).
    log_and_run logs/lint_mesh.log \
      verilator --lint-only -sv --timing \
        -Wwarn-UNDRIVEN \
        config/verilator_waivers.vlt \
        +incdir+config \
        -f "$BUILD/sources.f" \
        tb/pkg/floo_tb_mesh_types_pkg.sv \
        tb/top/floonoc_mesh_dut.sv \
        tb/top/lint_wrapper_mesh.sv \
        --top-module lint_wrapper_mesh
    echo "[verilator] mesh lint PASS: zero unwaived warnings (waiver register:"
    echo "            docs/waiver_register.md; log: logs/lint_mesh.log)"
    ;;

  build-mesh)
    do_build_mesh
    ;;

  run-mesh)
    shift
    if [ ! -x "$BUILD/obj_dir_mesh/Vtb_top_mesh" ]; then
      echo "[verilator] ERROR: $BUILD/obj_dir_mesh/Vtb_top_mesh missing — run 'make build-mesh' first" >&2
      exit 1
    fi
    # Mirrors do_sim's cov_file pattern: without an explicit plusarg the
    # coverage-instrumented binary (config/verilator.f's --coverage-user
    # --coverage-line) drops Verilator's default ./coverage.dat at the repo
    # root instead of into logs/.
    MESH_COV_FILE="${COV_FILE:-logs/coverage_mesh.dat}"

    # MESH-SMOKE PASSED is printed by the Phase-1 hand-rolled `initial` block
    # in tb_top_mesh.sv, not by a UVM test — that scaffolding is deleted once
    # the mesh UVM env lands (Task 8), at which point this check becomes
    # `TEST PASSED` + `UVM_ERROR : 0`, mirroring the `run` case above.
    run_one_mesh() { # $1 = per-run log, rest = plusargs
      local log="$1"; shift
      local rc
      set +e
      log_and_run "$log" "$BUILD/obj_dir_mesh/Vtb_top_mesh" \
        "+verilator+coverage+file+$MESH_COV_FILE" "$@"
      rc=$?
      set -e
      if [ $rc -ne 0 ]; then
        echo "[verilator] mesh run FAILED (simulator exit $rc, log: $log)" >&2
        return 1
      fi
      if ! grep -q '\*\*\* MESH-SMOKE PASSED \*\*\*' "$log"; then
        echo "[verilator] mesh run FAILED: missing PASS banner (log: $log)" >&2
        return 1
      fi
      return 0
    }

    if [ "$#" -gt 0 ]; then
      # Explicit plusargs given: run exactly that one case, unswept. A
      # separate log file so an ad-hoc debug run never clobbers
      # logs/run_mesh.log, which the sweep below uses as its combined
      # evidence log.
      RUN_LOG=logs/run_mesh_single.log
      run_one_mesh "$RUN_LOG" "$@" || exit 1
      echo "[verilator] mesh run PASS (log: $RUN_LOG, coverage: $MESH_COV_FILE)"
    else
      # No plusargs: sweep all non-loopback (src_router, dst) pairs across
      # the mesh. A single default-args run only ever exercises src_router=0
      # -> (1,1); a transposed index affecting only one direction's wiring
      # (e.g. South or West) would still pass that one case cleanly. The
      # src==dst pairs are the diagonal loopback case, which is genuinely
      # illegal here (the DUT's own NoLoopback assertion aborts) — skipped,
      # not run. dst_router = dst_y*MX + dst_x, the row-major mapping
      # router_idx() uses in tb/pkg/floo_tb_mesh_types_pkg.sv.
      #
      # Mesh dimensions are read from config/dut_config_mesh.svh rather than
      # hardcoded, so the sweep can't silently fall out of sync with the
      # DUT's actual topology and still print a completeness claim it
      # doesn't earn. Parsing failure is fatal, not defaulted — a sweep that
      # silently runs 0 pairs and prints PASS is exactly the bug this
      # derivation exists to prevent.
      MESH_CFG="config/dut_config_mesh.svh"
      MX="$(grep -E "^\`define[[:space:]]+FLOO_VERIF_MESH_X[[:space:]]" "$MESH_CFG" | awk '{print $3}')"
      MY="$(grep -E "^\`define[[:space:]]+FLOO_VERIF_MESH_Y[[:space:]]" "$MESH_CFG" | awk '{print $3}')"
      if ! [[ "$MX" =~ ^[0-9]+$ ]] || ! [[ "$MY" =~ ^[0-9]+$ ]]; then
        echo "[verilator] ERROR: could not parse FLOO_VERIF_MESH_X/_Y as integers from $MESH_CFG" >&2
        echo "            got MX='$MX' MY='$MY'" >&2
        exit 1
      fi
      NROUTERS=$(( MX * MY ))
      : > logs/run_mesh.log   # combined evidence; each pair also gets its own log
      fail=0
      npairs=0
      failed_pairs=()
      for (( src=0; src<NROUTERS; src++ )); do
        for (( dy=0; dy<MY; dy++ )); do
          for (( dx=0; dx<MX; dx++ )); do
            dst=$(( dy * MX + dx ))
            if [ "$src" -eq "$dst" ]; then
              continue   # diagonal: illegal loopback, skipped by design
            fi
            npairs=$(( npairs + 1 ))
            PAIR_LOG="logs/run_mesh_src${src}_dst${dst}.log"
            echo "[verilator] mesh sweep: src_router=$src -> dst_x=$dx dst_y=$dy (dst_router=$dst)"
            if run_one_mesh "$PAIR_LOG" "+src_router=$src" "+dst_x=$dx" "+dst_y=$dy"; then
              cat "$PAIR_LOG" >> logs/run_mesh.log
            else
              echo "[verilator] mesh run FAILED: pair src_router=$src -> dst_router=$dst (log: $PAIR_LOG)" >&2
              cat "$PAIR_LOG" >> logs/run_mesh.log
              failed_pairs+=("src${src}->dst${dst}")
              fail=1
            fi
          done
        done
      done
      if [ $fail -ne 0 ]; then
        echo "[verilator] mesh run FAILED: ${#failed_pairs[@]}/$npairs pair(s) failed: ${failed_pairs[*]}" >&2
        exit 1
      fi
      echo "[verilator] mesh run PASS: all $npairs non-loopback (src,dst) pairs passed"
      echo "            (${MX}x${MY} mesh; per-pair logs: logs/run_mesh_src*_dst*.log, combined: logs/run_mesh.log, coverage: $MESH_COV_FILE)"
    fi
    ;;

  *)
    echo "usage: $0 {lint|build [fst|vcd]|run [+plusargs]|run-neg <test> <re>|waves|waves-vcd|lint-mesh|build-mesh|run-mesh [+plusargs]}" >&2
    exit 2
    ;;
esac
