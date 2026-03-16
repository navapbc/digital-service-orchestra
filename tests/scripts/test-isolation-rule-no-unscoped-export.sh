#!/usr/bin/env bash
# tests/scripts/test-isolation-rule-no-unscoped-export.sh
# Tests for scripts/test-isolation-rules/no-unscoped-export.sh
#
# Usage: bash tests/scripts/test-isolation-rule-no-unscoped-export.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
RULE="$REPO_ROOT/scripts/test-isolation-rules/no-unscoped-export.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/isolation-rules"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-isolation-rule-no-unscoped-export.sh ==="

# ── test_rule_exists_and_executable ──────────────────────────────────────────
_snapshot_fail
rule_exec=0
[ -x "$RULE" ] && rule_exec=1
assert_eq "test_rule_exists_and_executable" "1" "$rule_exec"
assert_pass_if_clean "test_rule_exists_and_executable"

# ── test_no_unscoped_export_catches_bare_export ──────────────────────────────
# Fixture with export FOO=bar at top level should trigger violations
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/bad-unscoped-export.sh" 2>/dev/null)
exit_code=$?
# Should find violations (non-zero exit)
assert_ne "test_no_unscoped_export_catches_bare_export: non-zero exit" "0" "$exit_code"
# Output should contain structured violation format
assert_contains "test_no_unscoped_export_catches_bare_export: has rule name" "no-unscoped-export" "$output"
# Should catch the bare exports (lines 4, 5, 11)
assert_contains "test_no_unscoped_export_catches_bare_export: catches line 4" ":4:no-unscoped-export:" "$output"
assert_contains "test_no_unscoped_export_catches_bare_export: catches line 5" ":5:no-unscoped-export:" "$output"
assert_contains "test_no_unscoped_export_catches_bare_export: catches line 11" ":11:no-unscoped-export:" "$output"
assert_pass_if_clean "test_no_unscoped_export_catches_bare_export"

# ── test_no_unscoped_export_passes_subshell ──────────────────────────────────
# Fixture wrapping export in ( ... ) subshell should pass
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/good-scoped-export.sh" 2>/dev/null)
exit_code=$?
assert_eq "test_no_unscoped_export_passes_subshell: exit 0" "0" "$exit_code"
assert_pass_if_clean "test_no_unscoped_export_passes_subshell"

# ── test_no_unscoped_export_passes_save_restore ──────────────────────────────
# The good fixture also contains save/restore pattern — verify no violations
_snapshot_fail
# Count violations — should be 0
violation_count=0
if [[ -n "$output" ]]; then
    violation_count=$(echo "$output" | grep -c "no-unscoped-export" || true)
fi
assert_eq "test_no_unscoped_export_passes_save_restore: no violations" "0" "$violation_count"
assert_pass_if_clean "test_no_unscoped_export_passes_save_restore"

# ── test_output_format_is_structured ─────────────────────────────────────────
# Verify the output matches file:line:rule-name:message format
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/bad-unscoped-export.sh" 2>/dev/null)
# Each line should match the pattern
first_line=$(echo "$output" | head -1)
# Check it contains file path, line number, rule name
assert_contains "test_output_format_is_structured: has file path" "bad-unscoped-export.sh" "$first_line"
assert_contains "test_output_format_is_structured: has rule name" "no-unscoped-export" "$first_line"
assert_pass_if_clean "test_output_format_is_structured"

# ── test_integration_with_harness ────────────────────────────────────────────
# Verify the rule works when invoked via the harness
_snapshot_fail
harness="$REPO_ROOT/scripts/check-test-isolation.sh"
if [ -x "$harness" ]; then
    harness_output=$(bash "$harness" "$FIXTURES_DIR/bad-unscoped-export.sh" 2>/dev/null)
    harness_exit=$?
    assert_eq "test_integration_with_harness: exit 1 for bad file" "1" "$harness_exit"
    assert_contains "test_integration_with_harness: harness finds violations" "no-unscoped-export" "$harness_output"
else
    echo "SKIP: test_integration_with_harness (harness not found)"
fi
assert_pass_if_clean "test_integration_with_harness"

print_summary
