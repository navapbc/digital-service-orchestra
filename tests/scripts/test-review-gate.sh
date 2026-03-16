#!/usr/bin/env bash
# tests/scripts/test-review-gate.sh
# Script-suite entry point for review-gate.sh tests.
#
# Delegates to the canonical hook test suite in tests/hooks/.
# Tests use isolated artifacts directories (WORKFLOW_PLUGIN_ARTIFACTS_DIR via
# mktemp) and isolated temp git repos so the real repo's review-status and
# git index are never touched.
#
# Usage: bash tests/scripts/test-review-gate.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

HOOK_TEST="$PLUGIN_ROOT/tests/hooks/test-review-gate.sh"

if [[ ! -x "$HOOK_TEST" ]]; then
    echo "ERROR: hook test not found or not executable: $HOOK_TEST" >&2
    exit 1
fi

# Use an isolated artifacts directory (WORKFLOW_PLUGIN_ARTIFACTS_DIR via mktemp)
# so this script-suite run is also isolated from real production state.
# The hook test itself sets WORKFLOW_PLUGIN_ARTIFACTS_DIR internally, but we
# set TMPDIR here so that any mktemp calls use a well-known base.
_SCRIPT_ARTIFACTS=$(mktemp -d "${TMPDIR:-/tmp}/test-review-gate-scripts-XXXXXX")
cleanup_script_artifacts() { rm -rf "$_SCRIPT_ARTIFACTS" 2>/dev/null || true; }
trap cleanup_script_artifacts EXIT

export TMPDIR="$_SCRIPT_ARTIFACTS"

exec bash "$HOOK_TEST"
