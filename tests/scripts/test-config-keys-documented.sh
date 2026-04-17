#!/usr/bin/env bash
# tests/scripts/test-config-keys-documented.sh
# Behavioral test: every config key read by DSO plugin code is documented in
# CONFIGURATION-REFERENCE.md. Passes (GREEN) when zero gap keys are reported.
#
# Tests:
#   test_config_keys_documented — scan output is empty (zero gap lines)
#
# Usage: bash tests/scripts/test-config-keys-documented.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED phase: ~20 undocumented keys produce non-empty output → assertion fails.
# GREEN phase: task 2d42-104e adds missing entries → output is empty → passes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCAN_SCRIPT="$REPO_ROOT/plugins/dso/scripts/scan-config-keys.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-config-keys-documented.sh ==="

# ── test_config_keys_documented ──────────────────────────────────────────────
# Given: scan-config-keys.sh is present
# When:  it is invoked with _PLUGIN_GIT_PATH=plugins/dso and the repo root
# Then:  stdout must be empty — every config key is documented
_snapshot_fail

if [[ ! -x "$SCAN_SCRIPT" ]]; then
    echo "SKIP: scan-config-keys.sh not found or not executable at $SCAN_SCRIPT" >&2
    (( ++FAIL ))
    assert_pass_if_clean "test_config_keys_documented"
    print_summary
fi

gap_output=$(_PLUGIN_GIT_PATH=plugins/dso bash "$SCAN_SCRIPT" "$REPO_ROOT" 2>/dev/null || true)

assert_eq "all config keys are documented in CONFIGURATION-REFERENCE.md (zero gap lines)" "" "$gap_output"

if [[ -n "$gap_output" ]]; then
    echo "  undocumented keys found:" >&2
    echo "$gap_output" | sed 's/^/    /' >&2
fi

assert_pass_if_clean "test_config_keys_documented"

print_summary
