#!/usr/bin/env bash
# tests/scripts/test-skill-trace-analyze-shim.sh
# TDD tests for the extensionless skill-trace-analyze wrapper shim.
#
# Verifies:
#   - The extensionless wrapper exists at plugins/dso/scripts/skill-trace-analyze
#   - The wrapper is executable
#   - Running it with --help exits 0
#
# Usage: bash tests/scripts/test-skill-trace-analyze-shim.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PLUGIN_ROOT/plugins/dso/scripts/skill-trace-analyze"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-skill-trace-analyze-shim.sh ==="

# ── test_wrapper_exists ───────────────────────────────────────────────────────
# The extensionless wrapper must exist at plugins/dso/scripts/skill-trace-analyze.
test_wrapper_exists() {
    if [[ -f "$WRAPPER" ]]; then
        assert_eq "test_wrapper_exists" "exists" "exists"
    else
        assert_eq "test_wrapper_exists" "exists" "missing"
    fi
}

# ── test_wrapper_is_executable ────────────────────────────────────────────────
# The wrapper must be executable (chmod +x).
test_wrapper_is_executable() {
    if [[ -x "$WRAPPER" ]]; then
        assert_eq "test_wrapper_is_executable" "executable" "executable"
    else
        assert_eq "test_wrapper_is_executable" "executable" "not-executable"
    fi
}

# ── test_wrapper_help_exits_zero ──────────────────────────────────────────────
# Running the wrapper with --help must exit 0.
test_wrapper_help_exits_zero() {
    if [[ ! -x "$WRAPPER" ]]; then
        assert_eq "test_wrapper_help_exits_zero" "0" "wrapper-not-executable"
        return
    fi
    local exit_code=0
    "$WRAPPER" --help >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_wrapper_help_exits_zero" "0" "$exit_code"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_wrapper_exists
test_wrapper_is_executable
test_wrapper_help_exits_zero

print_summary
