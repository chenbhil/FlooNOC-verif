#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Fetch and pin all upstream dependencies:
#   - FlooNoC at the pinned commit into rtl_or_vendor/floonoc (unmodified)
#   - FlooNoC's HDL dependencies via Bender (pinned by upstream Bender.lock)
#   - Verify the UVM 1800.2-2017 1.0 library is available at UVM_HOME
# Idempotent: safe to re-run.
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FLOONOC_URL="${FLOONOC_URL:-https://github.com/pulp-platform/FlooNoC.git}"
FLOONOC_COMMIT="${FLOONOC_COMMIT:?FLOONOC_COMMIT must be set (see Makefile)}"
FLOONOC_DIR="$ROOT/rtl_or_vendor/floonoc"
UVM_HOME="${UVM_HOME:?UVM_HOME must be set (see Makefile)}"

# --- FlooNoC ------------------------------------------------------------------
if [ ! -d "$FLOONOC_DIR/.git" ]; then
  echo "[setup] cloning FlooNoC into $FLOONOC_DIR"
  git clone "$FLOONOC_URL" "$FLOONOC_DIR"
fi
git -C "$FLOONOC_DIR" fetch --tags --quiet
git -C "$FLOONOC_DIR" checkout --quiet "$FLOONOC_COMMIT"
echo "[setup] FlooNoC pinned at $(git -C "$FLOONOC_DIR" rev-parse HEAD)"

# Guard: refuse to proceed if the upstream tree has local modifications
if [ -n "$(git -C "$FLOONOC_DIR" status --porcelain)" ]; then
  echo "[setup] ERROR: rtl_or_vendor/floonoc has local modifications:" >&2
  git -C "$FLOONOC_DIR" status --porcelain >&2
  exit 1
fi

# --- Bender + HDL dependencies -------------------------------------------------
if ! command -v bender >/dev/null 2>&1; then
  echo "[setup] ERROR: bender not found. Install with: brew install bender" >&2
  exit 1
fi

# Reproducibility guard: the version-controlled lockfile at the project root
# is the source of truth for dependency resolution. The vendor checkout's
# Bender.lock (shipped by FlooNoC at the pinned tag) must match it exactly;
# otherwise the build is not the one this project has validated.
ROOT_LOCK="$ROOT/Bender.lock"
VENDOR_LOCK="$FLOONOC_DIR/Bender.lock"
if [ ! -f "$ROOT_LOCK" ]; then
  cp "$VENDOR_LOCK" "$ROOT_LOCK"
  echo "[setup] seeded tracked lockfile $ROOT_LOCK from the pinned checkout —"
  echo "        commit it; it is part of the project's source of truth."
elif ! diff -q "$ROOT_LOCK" "$VENDOR_LOCK" >/dev/null; then
  echo "[setup] ERROR: Bender.lock drift between tracked root lockfile and" >&2
  echo "        the pinned FlooNoC checkout:" >&2
  diff -u "$ROOT_LOCK" "$VENDOR_LOCK" >&2 || true
  echo "        If the FlooNoC pin changed intentionally, update the root" >&2
  echo "        Bender.lock in the same commit. Refusing to continue." >&2
  exit 1
else
  echo "[setup] Bender.lock verified: root lockfile matches pinned checkout"
fi

echo "[setup] resolving HDL dependencies (bender checkout, pinned by Bender.lock)"
(cd "$FLOONOC_DIR" && bender checkout >/dev/null)

# --- UVM -----------------------------------------------------------------------
if [ ! -f "$UVM_HOME/src/uvm_pkg.sv" ]; then
  echo "[setup] ERROR: UVM library not found at UVM_HOME=$UVM_HOME" >&2
  echo "        Expected the Accellera UVM 1800.2-2017 1.0 kit (src/uvm_pkg.sv)." >&2
  echo "        Download: https://www.accellera.org/downloads/standards/uvm" >&2
  echo "        Then: make setup UVM_HOME=/path/to/1800.2-2017-1.0" >&2
  exit 1
fi
echo "[setup] UVM found at $UVM_HOME"
echo "[setup] OK"
