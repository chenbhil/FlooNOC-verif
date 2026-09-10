# -----------------------------------------------------------------------------
# FlooNoC router UVM smoke bench (Verilator 5.052)
#
#   make setup    - fetch FlooNoC (pinned) + Bender deps, verify UVM
#   make sources  - generate deterministic Verilator filelist (build/sources.f)
#   make lint     - Verilator lint-only pass on DUT + minimal wrapper
#   make build    - compile the UVM smoke test
#   make run      - execute the smoke test
#   make waves    - run with FST tracing (waves/tb_top.fst)
#   make cov      - annotated coverage report (logs/coverage_report/)
#   make clean    - remove generated build outputs
#   make doctor   - print tool/dependency/DUT resolution status
#
#   make lint-mesh  - Verilator lint-only pass on the mesh DUT, no UVM/TB
#   make lint-mesh-uvm - fast compile-check of the mesh UVM classes, no top
#   make build-mesh - compile the mesh bench (own top module, own obj dir)
#   make run-mesh   - run the mesh UVM smoke test (expects PASS)
#   make cov-mesh   - annotated mesh coverage report (logs/coverage_report_mesh/)
# -----------------------------------------------------------------------------

# --- Pinned revisions ----------------------------------------------------------
# FlooNoC pin: tag v0.8.4
export FLOONOC_COMMIT ?= 14c253c996fcdc78b793fe28ac18964769b768df
# UVM_HOME must point at your Accellera UVM 1800.2-2017 1.0 kit (the directory
# containing src/uvm_pkg.sv). Set it in your environment or on the command line,
# e.g.  make setup UVM_HOME=/path/to/1800.2-2017-1.0
# `make setup` / `make doctor` report clearly if it is unset or wrong.
export UVM_HOME       ?=
export REQUIRED_VERILATOR ?= 5.052

FLOONOC_DIR := rtl_or_vendor/floonoc

.PHONY: all setup sources lint build build-vcd run run-negative waves waves-vcd cov clean doctor lint-mesh lint-mesh-uvm build-mesh run-mesh cov-mesh

all: build

setup:
	./scripts/setup_deps.sh

sources:
	./scripts/bender_sources.sh

build/sources.f:
	./scripts/bender_sources.sh

lint: build/sources.f
	./scripts/run_verilator.sh lint

build: build/sources.f
	./scripts/run_verilator.sh build fst

build-vcd: build/sources.f
	./scripts/run_verilator.sh build vcd

run:
	./scripts/run_verilator.sh run

# Negative self-tests: each injects one fault into the checking path and MUST
# fail with the expected diagnostic (proves the checkers are not vacuous).
run-negative:
	./scripts/run_verilator.sh run-neg floonoc_neg_payload_test 'integrity/order mismatch'
	./scripts/run_verilator.sh run-neg floonoc_neg_route_test   'unexpected flit|integrity/order mismatch|never delivered'
	./scripts/run_verilator.sh run-neg floonoc_neg_stall_test   'forward progress stopped'
	@echo "[run-negative] all 3 fault injections were caught — checkers are effective"

# --- Mesh bench (2x2 mesh of floo_router, independent top-level) ---------------
# Built and run as a SEPARATE Verilator binary from the single-router bench:
# different top module, different obj dir, different coverage file. The two
# benches must never share a compile unit — see config/dut_config_mesh.svh.
lint-mesh: build/sources.f
	./scripts/run_verilator.sh lint-mesh

# Fast compile-check of the mesh UVM classes (floonoc_mesh_uvm_pkg) against
# uvm_pkg, with no top-level elaboration and no C++ build. build-mesh now
# compiles the same package for real; this stays as the seconds-not-minutes
# check while iterating on the classes. Details in the case body in
# scripts/run_verilator.sh.
lint-mesh-uvm: build/sources.f
	./scripts/run_verilator.sh lint-mesh-uvm

build-mesh: build/sources.f
	./scripts/run_verilator.sh build-mesh

run-mesh:
	./scripts/run_verilator.sh run-mesh

# Mesh coverage report. Same three-way split as `make cov`, over the mesh
# bench's own coverage file so the two benches' numbers never conflate.
cov-mesh:
	@mkdir -p logs/coverage_report_mesh
	@{ \
	  echo "=== FUNCTIONAL coverage (covergroups) ==="; \
	  verilator_coverage --filter-type covergroup --report summary,hier logs/coverage_mesh.dat; \
	  echo; \
	  echo "=== ASSERTION coverage (SVA cover points) ==="; \
	  verilator_coverage --filter-type user --report summary,hier logs/coverage_mesh.dat; \
	  echo; \
	  echo "=== CODE coverage (DUT line coverage) ==="; \
	  verilator_coverage --filter-type line --report summary logs/coverage_mesh.dat; \
	} | tee logs/coverage_summary_mesh.log
	@verilator_coverage --annotate logs/coverage_report_mesh logs/coverage_mesh.dat > /dev/null
	@echo "[cov-mesh] split summary: logs/coverage_summary_mesh.log; annotated source: logs/coverage_report_mesh/"

waves:
	./scripts/run_verilator.sh waves

waves-vcd:
	./scripts/run_verilator.sh waves-vcd

# Coverage report, split by kind so functional coverage can't be conflated
# with code/assertion coverage (verilator_coverage --filter-type):
#   FUNCTIONAL = covergroup bins   ASSERTION = SVA cover points ('user')
#   CODE       = line coverage of the DUT closure (UVM/TB excluded,
#                see config/coverage_scope.vlt)
cov:
	@mkdir -p logs/coverage_report
	@{ \
	  echo "=== FUNCTIONAL coverage (covergroups) ==="; \
	  verilator_coverage --filter-type covergroup --report summary,hier logs/coverage.dat; \
	  echo; \
	  echo "=== ASSERTION coverage (SVA cover points) ==="; \
	  verilator_coverage --filter-type user --report summary,hier logs/coverage.dat; \
	  echo; \
	  echo "=== CODE coverage (DUT line coverage) ==="; \
	  verilator_coverage --filter-type line --report summary logs/coverage.dat; \
	} | tee logs/coverage_summary.log
	@verilator_coverage --annotate logs/coverage_report logs/coverage.dat > /dev/null
	@echo "[cov] split summary: logs/coverage_summary.log; annotated source: logs/coverage_report/"

clean:
	rm -rf build waves/*.fst waves/*.vcd
	@echo "[clean] removed build outputs (logs/ kept as evidence)"

doctor:
	@echo "verilator : $$(verilator --version 2>/dev/null || echo MISSING)"
	@echo "required  : Verilator $(REQUIRED_VERILATOR)"
	@echo "bender    : $$(bender --version 2>/dev/null || echo MISSING)"
	@echo "cxx       : $$(c++ --version 2>/dev/null | head -1 || echo MISSING)"
	@echo "make      : $$(make --version 2>/dev/null | head -1)"
	@echo "floonoc   : $(FLOONOC_DIR) @ $$(git -C $(FLOONOC_DIR) rev-parse HEAD 2>/dev/null || echo 'NOT CLONED (run make setup)')"
	@echo "pinned    : $(FLOONOC_COMMIT)"
	@echo "uvm       : $(UVM_HOME) $$(test -f $(UVM_HOME)/src/uvm_pkg.sv && echo OK || echo MISSING)"
	@echo "dut       : floo_router (5 ports, XYRouting, 1 VC) — see docs/dut_scope.md"
	@echo "sources   : $$(test -f build/sources.f && echo 'build/sources.f ('$$(grep -cv '+incdir+' build/sources.f)' files)' || echo 'not generated (run make sources)')"
