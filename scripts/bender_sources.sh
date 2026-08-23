#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Produce the deterministic Verilator source list for the floo_router scope.
#
#   build/bender_full.f   - full bender-resolved flist (reference/debug)
#   build/sources.f       - filtered DUT-scope filelist consumed by Verilator
#   build/Bender.lock     - snapshot of dependency revisions used
#   build/sources_meta.txt- tool + revision metadata
#
# Selection policy (documented in docs/dut_scope.md):
#   - include dirs: common_cells + FlooNoC hw/include
#   - axi_pkg.sv only (floo_pkg references its width functions; the package
#     is self-contained)
#   - ALL common_cells sources in bender topological order (the actual
#     closure is ~10 files; taking the whole verilator-clean package avoids
#     fragile hand-curation)
#   - FlooNoC hw files whitelisted in config/filelists/floo_dut_files.txt
# No upstream TB/VIP, chimney, iDMA, FPnew or atomics sources are included.
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOONOC_DIR="$ROOT/rtl_or_vendor/floonoc"
BUILD="$ROOT/build"
WHITELIST="$ROOT/config/filelists/floo_dut_files.txt"

mkdir -p "$BUILD"

(cd "$FLOONOC_DIR" && bender script flist-plus) > "$BUILD/bender_full.f"

OUT="$BUILD/sources.f"
: > "$OUT"

# Include directories
grep '+incdir+' "$BUILD/bender_full.f" | grep -E 'common_cells|floonoc/hw' >> "$OUT"

# axi_pkg (required by floo_pkg helper functions; self-contained)
grep -E '/axi-[^/]*/src/axi_pkg\.sv$' "$BUILD/bender_full.f" >> "$OUT"

# common_cells, in bender's topological order
grep -E 'common_cells[^ ]*/src/.*\.sv$' "$BUILD/bender_full.f" >> "$OUT"

# Whitelisted FlooNoC DUT files, in whitelist order
while IFS= read -r f; do
  case "$f" in ''|\#*) continue ;; esac
  if ! grep -F "floonoc/hw/$f" "$BUILD/bender_full.f" >> "$OUT"; then
    echo "[sources] ERROR: whitelisted file not in bender flist: $f" >&2
    exit 1
  fi
done < "$WHITELIST"

# Metadata for reproducibility evidence
cp "$FLOONOC_DIR/Bender.lock" "$BUILD/Bender.lock"
{
  echo "generated:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "verilator:        $(verilator --version)"
  echo "bender:           $(bender --version)"
  echo "floonoc_commit:   $(git -C "$FLOONOC_DIR" rev-parse HEAD)"
  echo "floonoc_describe: $(git -C "$FLOONOC_DIR" describe --tags --always)"
  echo "sources_file:     build/sources.f ($(grep -c -v '+incdir+' "$OUT") files)"
} > "$BUILD/sources_meta.txt"

echo "[sources] wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
