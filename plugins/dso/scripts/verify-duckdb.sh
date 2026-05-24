#!/usr/bin/env bash
set -euo pipefail
# verify-duckdb.sh
#
# Verifies that duckdb is installed and reports its version.
#
# ── Exit codes ────────────────────────────────────────────────────────────────
#   0  = duckdb is installed; emits "OK <version>" to stdout
#   1  = duckdb is not found in PATH; emits remediation hint to stderr

if ! command -v duckdb >/dev/null 2>&1; then
    echo "ERROR: duckdb not found in PATH. To install, see https://duckdb.org/docs/installation/ or use brew (macOS) to install duckdb." >&2
    exit 1
fi

version="$(duckdb --version)"
echo "OK ${version}"
