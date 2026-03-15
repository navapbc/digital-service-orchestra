#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-isolation-rule-no-direct-os-environ.sh
# Tests for scripts/test-isolation-rules/no-direct-os-environ.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-isolation-rule-no-direct-os-environ.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
RULE="$REPO_ROOT/scripts/test-isolation-rules/no-direct-os-environ.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/isolation-rules"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-isolation-rule-no-direct-os-environ.sh ==="

# ── test_rule_exists_and_executable ──────────────────────────────────────────
_snapshot_fail
rule_exec=0
[ -x "$RULE" ] && rule_exec=1
assert_eq "test_rule_exists_and_executable" "1" "$rule_exec"
assert_pass_if_clean "test_rule_exists_and_executable"

# ── test_no_direct_os_environ_catches_assignment ─────────────────────────────
# Fixture with os.environ["KEY"] = "value" should trigger violation
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/bad-os-environ.py" 2>/dev/null)
exit_code=$?
# Rule should produce output (violations found)
assert_ne "test_no_direct_os_environ_catches_assignment: has output" "" "$output"
# Output should contain the rule name
assert_contains "test_no_direct_os_environ_catches_assignment: rule name in output" "no-direct-os-environ" "$output"
# Should catch the os.environ["MY_KEY"] = "value" assignment
assert_contains "test_no_direct_os_environ_catches_assignment: catches bracket assignment" 'os.environ[' "$output"
assert_pass_if_clean "test_no_direct_os_environ_catches_assignment"

# ── test_no_direct_os_environ_catches_setdefault ─────────────────────────────
# Fixture with os.environ.setdefault(...) should trigger violation
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/bad-os-environ.py" 2>/dev/null)
assert_contains "test_no_direct_os_environ_catches_setdefault: catches setdefault" "setdefault" "$output"
assert_pass_if_clean "test_no_direct_os_environ_catches_setdefault"

# ── test_no_direct_os_environ_catches_update ─────────────────────────────────
# Fixture with os.environ.update(...) should trigger violation
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/bad-os-environ.py" 2>/dev/null)
assert_contains "test_no_direct_os_environ_catches_update: catches update" "update" "$output"
assert_pass_if_clean "test_no_direct_os_environ_catches_update"

# ── test_no_direct_os_environ_passes_monkeypatch ─────────────────────────────
# Fixture using monkeypatch.setenv should pass (no violations)
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/good-monkeypatch.py" 2>/dev/null)
exit_code=$?
# Should produce no output
assert_eq "test_no_direct_os_environ_passes_monkeypatch: no output" "" "$output"
assert_pass_if_clean "test_no_direct_os_environ_passes_monkeypatch"

# ── test_output_format_is_structured ─────────────────────────────────────────
# Each violation line should follow file:line:rule:message format
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/bad-os-environ.py" 2>/dev/null)
# Extract first violation line
first_line=$(echo "$output" | head -1)
# Should have 4 colon-separated fields
field_count=$(echo "$first_line" | tr ':' '\n' | wc -l | tr -d ' ')
# At least 4 fields (file:line:rule:message — message may contain colons)
is_structured=0
[[ "$field_count" -ge 4 ]] && is_structured=1
assert_eq "test_output_format_is_structured: at least 4 fields" "1" "$is_structured"
# Second field should be a line number
linenum=$(echo "$first_line" | cut -d: -f2)
is_numeric=0
[[ "$linenum" =~ ^[0-9]+$ ]] && is_numeric=1
assert_eq "test_output_format_is_structured: line number is numeric" "1" "$is_numeric"
assert_pass_if_clean "test_output_format_is_structured"

# ── test_violation_count ─────────────────────────────────────────────────────
# bad-os-environ.py has 3 violations (assignment, setdefault, update)
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/bad-os-environ.py" 2>/dev/null)
violation_count=$(echo "$output" | grep -c "no-direct-os-environ" || true)
assert_eq "test_violation_count: 3 violations in bad fixture" "3" "$violation_count"
assert_pass_if_clean "test_violation_count"

print_summary
