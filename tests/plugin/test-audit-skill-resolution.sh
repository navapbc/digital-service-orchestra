#!/usr/bin/env bash
# lockpick-workflow/tests/plugin/test-audit-skill-resolution.sh
#
# Tests that audit-skill-resolution.sh exists in the canonical plugin directory
# and is executable.
#
# Tests covered:
#   A. Script exists at canonical plugin path (lockpick-workflow/scripts/)
#   B. Script is executable
#   C. Script produces PASS output when run
#
# Manual run:
#   bash lockpick-workflow/tests/plugin/test-audit-skill-resolution.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANONICAL_SCRIPT="$PLUGIN_ROOT/scripts/audit-skill-resolution.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== audit-skill-resolution plugin test ==="
echo ""

# ---------------------------------------------------------------------------
# test_audit_skill_resolution_in_plugin_and_executable
# ---------------------------------------------------------------------------
echo "--- test_audit_skill_resolution_in_plugin_and_executable ---"

assert_eq "lockpick-workflow/scripts/audit-skill-resolution.sh exists" "true" \
    "$(test -f "$CANONICAL_SCRIPT" && echo true || echo false)"

assert_eq "lockpick-workflow/scripts/audit-skill-resolution.sh is executable" "true" \
    "$(test -x "$CANONICAL_SCRIPT" && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test C: Script produces PASS output when run
# ---------------------------------------------------------------------------
echo ""
echo "--- script produces PASS output ---"

if test -f "$CANONICAL_SCRIPT"; then
    SCRIPT_OUTPUT=$(bash "$CANONICAL_SCRIPT" 2>&1 || true)
    assert_contains "script output contains PASS" "PASS" "$SCRIPT_OUTPUT"
else
    assert_eq "script must exist before testing output" "true" "false"
fi

# ---------------------------------------------------------------------------
# test_wrapper_delegates_to_plugin
# ---------------------------------------------------------------------------
echo ""
echo "--- test_wrapper_delegates_to_plugin ---"

REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
WRAPPER_SCRIPT="$REPO_ROOT/scripts/audit-skill-resolution.sh"

assert_eq "scripts/audit-skill-resolution.sh wrapper exists" "true" \
    "$(test -f "$WRAPPER_SCRIPT" && echo true || echo false)"

assert_contains "scripts/audit-skill-resolution.sh wrapper contains exec delegation" "exec" \
    "$(cat "$WRAPPER_SCRIPT" 2>/dev/null || echo '')"

LINE_COUNT="$(wc -l < "$WRAPPER_SCRIPT" 2>/dev/null || echo 999)"
assert_eq "scripts/audit-skill-resolution.sh wrapper is < 15 lines" "true" \
    "$([ "$LINE_COUNT" -lt 15 ] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
