#!/usr/bin/env bash
# tests/hooks/test-merge-helpers-special-chars.sh
# Behavioral test: merge-helpers.sh state functions must handle branch names
# containing special characters (single quotes, double quotes, backslashes,
# newlines) without shell/python injection corruption.
#
# This is the regression test for the env-var injection fix in _state_init,
# _state_write_phase, and other state functions: variables are now passed via
# _DSO_BRANCH / _DSO_PHASE env vars to python3 -c (read via os.environ) instead
# of being interpolated into the python source string.
#
# Tests:
#  1. test_state_init_handles_single_quote_branch_name
#
# Usage: bash tests/hooks/test-merge-helpers-special-chars.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_HELPERS_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"

# shellcheck source=../lib/assert.sh
source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-helpers-special-chars.sh ==="

# ── Cleanup on exit ───────────────────────────────────────────────────────────
_TEST_STATE_FILES=()
_cleanup_test_state_files() {
    for f in "${_TEST_STATE_FILES[@]}"; do
        rm -f "$f" "${f}.tmp" 2>/dev/null || true
    done
    # Also remove any per-process init markers we may have created
    rm -f /tmp/merge-state-init-marker-* 2>/dev/null || true
}
trap _cleanup_test_state_files EXIT

# ── Test 1: _state_init handles a single-quote in BRANCH ──────────────────────
# A pre-fix _state_init would have produced python source like:
#   d = {'branch': 'feat/'injected'-name', ...}
# which is a syntax error. The fix uses os.environ['_DSO_BRANCH'], so the
# literal value passes through unmodified.
test_state_init_handles_single_quote_branch_name() {
    _snapshot_fail

    # Special-character branch name. The single quote is the historical
    # injection vector. Slashes are sanitized to '-' for the filename, but the
    # in-file `branch` field must contain the raw literal.
    local _branch
    _branch="feat/o'malley-test-branch"

    # Set BRANCH in the test scope (merge-helpers.sh reads it during _state_file_path).
    BRANCH="$_branch"
    # shellcheck source=/dev/null
    source "$MERGE_HELPERS_LIB"

    # Call the function under test.
    _state_init

    # Resolve the expected state file path the same way _state_file_path does.
    local _sanitized="${_branch//\//-}"
    local _sf="/tmp/merge-to-main-state-${_sanitized}.json"
    _TEST_STATE_FILES+=("$_sf")

    assert_eq \
        "test_state_init_handles_single_quote_branch_name: state file written" \
        "1" "$(test -f "$_sf" && echo 1 || echo 0)"

    # Confirm the literal branch name made it into the JSON intact (no
    # injection corruption, no truncation at the quote).
    local _stored_branch
    _stored_branch=$(_DSO_SF="$_sf" python3 -c "
import json, os
with open(os.environ['_DSO_SF']) as f:
    print(json.load(f).get('branch', ''))
" 2>/dev/null || echo "")

    assert_eq \
        "test_state_init_handles_single_quote_branch_name: branch field matches literal input" \
        "$_branch" "$_stored_branch"

    assert_pass_if_clean "test_state_init_handles_single_quote_branch_name"
}

# ── Run tests ────────────────────────────────────────────────────────────────
echo ""
test_state_init_handles_single_quote_branch_name

print_summary
