#!/usr/bin/env bash
# tests/smoke-test-dso-shim.sh
# Thin wrapper — delegates to tests/scripts/test-shim-cross-context.sh.
#
# This file satisfies DD1: "bash tests/smoke-test-dso-shim.sh exits 0 from repo root"
# The underlying tests/scripts/test-shim-cross-context.sh satisfies DD2 (auto-discovered
# by tests/scripts/run-script-tests.sh).
#
# Usage:
#   bash tests/smoke-test-dso-shim.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/scripts/test-shim-cross-context.sh" "$@"
