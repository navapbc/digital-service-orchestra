#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-check-test-isolation.sh
# Tests for scripts/check-test-isolation.sh — test isolation rule harness
#
# Usage: bash lockpick-workflow/tests/scripts/test-check-test-isolation.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HARNESS="$REPO_ROOT/scripts/check-test-isolation.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/isolation-rules"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-check-test-isolation.sh ==="

# ---- Setup: create fixtures ----

# Clean fixture directory
rm -rf "$FIXTURES_DIR/tmp-test-*"

# Create a temp rules dir with a dummy rule for testing
TEMP_RULES_DIR="$FIXTURES_DIR/tmp-test-rules-$$"
mkdir -p "$TEMP_RULES_DIR"

# Dummy rule: flags lines containing "BAD_PATTERN"
cat > "$TEMP_RULES_DIR/no-bad-pattern.sh" << 'RULE_EOF'
#!/usr/bin/env bash
# Rule: no-bad-pattern
# Flags lines containing BAD_PATTERN
file="$1"
line_num=0
while IFS= read -r line; do
    (( line_num++ ))
    if echo "$line" | grep -q "BAD_PATTERN"; then
        echo "$file:$line_num:no-bad-pattern:Found BAD_PATTERN"
    fi
done < "$file"
RULE_EOF
chmod +x "$TEMP_RULES_DIR/no-bad-pattern.sh"

# Create a clean test file (no violations)
CLEAN_FILE="$FIXTURES_DIR/tmp-test-clean-$$.py"
cat > "$CLEAN_FILE" << 'FIXTURE_EOF'
import pytest

def test_something():
    assert True

def test_another():
    assert 1 == 1
FIXTURE_EOF

# Create a bad test file (has violations)
BAD_FILE="$FIXTURES_DIR/tmp-test-bad-$$.py"
cat > "$BAD_FILE" << 'FIXTURE_EOF'
import pytest

def test_something():
    BAD_PATTERN
    assert True

def test_another():
    BAD_PATTERN
    assert 1 == 1
FIXTURE_EOF

# Create a file with suppression annotation
SUPPRESSED_FILE="$FIXTURES_DIR/tmp-test-suppressed-$$.py"
cat > "$SUPPRESSED_FILE" << 'FIXTURE_EOF'
import pytest

def test_something():
    BAD_PATTERN  # isolation-ok: intentional for testing
    assert True

def test_another():
    BAD_PATTERN
    assert 1 == 1
FIXTURE_EOF

# Create a crashing rule
cat > "$TEMP_RULES_DIR/crash-rule.sh" << 'CRASH_EOF'
#!/usr/bin/env bash
# Rule: crash-rule — intentionally crashes
exit 2
CRASH_EOF
chmod +x "$TEMP_RULES_DIR/crash-rule.sh"

# ── test_harness_exists_and_executable ───────────────────────────────────────
_snapshot_fail
harness_exec=0
[ -x "$HARNESS" ] && harness_exec=1
assert_eq "test_harness_exists_and_executable" "1" "$harness_exec"
assert_pass_if_clean "test_harness_exists_and_executable"

# ── test_rules_directory_exists ──────────────────────────────────────────────
_snapshot_fail
rules_dir_exists=0
[ -d "$REPO_ROOT/scripts/test-isolation-rules" ] && rules_dir_exists=1
assert_eq "test_rules_directory_exists" "1" "$rules_dir_exists"
assert_pass_if_clean "test_rules_directory_exists"

# ── test_harness_discovers_and_executes_rule_from_directory ──────────────────
_snapshot_fail
output=$(RULES_DIR="$TEMP_RULES_DIR" bash "$HARNESS" "$BAD_FILE" 2>/dev/null)
exit_code=$?
# Should find violations and exit 1
assert_eq "test_harness_discovers_and_executes_rule_from_directory: exit 1" "1" "$exit_code"
# Output should contain the violation
assert_contains "test_harness_discovers_and_executes_rule_from_directory: output has violation" "no-bad-pattern" "$output"
assert_pass_if_clean "test_harness_discovers_and_executes_rule_from_directory"

# ── test_harness_suppression_skips_annotated_lines ───────────────────────────
_snapshot_fail
output=$(RULES_DIR="$TEMP_RULES_DIR" bash "$HARNESS" "$SUPPRESSED_FILE" 2>/dev/null)
exit_code=$?
# Should still find the unsuppressed violation on line 8
assert_eq "test_harness_suppression_skips_annotated_lines: exit 1" "1" "$exit_code"
# Count violations — should be 1 (line 8), not 2
violation_count=$(echo "$output" | grep -c "no-bad-pattern" || true)
assert_eq "test_harness_suppression_skips_annotated_lines: only 1 violation" "1" "$violation_count"
assert_pass_if_clean "test_harness_suppression_skips_annotated_lines"

# ── test_harness_staged_only_mode_filters ────────────────────────────────────
# When STAGED_ONLY=true and file is NOT staged, harness should skip it
_snapshot_fail
output=$(STAGED_ONLY=true RULES_DIR="$TEMP_RULES_DIR" bash "$HARNESS" "$BAD_FILE" 2>/dev/null)
exit_code=$?
# The fixture file is not staged, so harness should exit 0 (no files to check)
assert_eq "test_harness_staged_only_mode_filters: exit 0 for unstaged" "0" "$exit_code"
assert_pass_if_clean "test_harness_staged_only_mode_filters"

# ── test_harness_exits_zero_no_violations ────────────────────────────────────
_snapshot_fail
output=$(RULES_DIR="$TEMP_RULES_DIR" bash "$HARNESS" "$CLEAN_FILE" 2>/dev/null)
exit_code=$?
assert_eq "test_harness_exits_zero_no_violations" "0" "$exit_code"
assert_pass_if_clean "test_harness_exits_zero_no_violations"

# ── test_harness_exits_one_with_violations ───────────────────────────────────
_snapshot_fail
output=$(RULES_DIR="$TEMP_RULES_DIR" bash "$HARNESS" "$BAD_FILE" 2>/dev/null)
exit_code=$?
assert_eq "test_harness_exits_one_with_violations: exit 1" "1" "$exit_code"
# Output should be structured: file:line:rule:message
assert_contains "test_harness_exits_one_with_violations: structured output" ":4:no-bad-pattern:" "$output"
assert_pass_if_clean "test_harness_exits_one_with_violations"

# ── test_harness_handles_missing_args ────────────────────────────────────────
_snapshot_fail
output=$(bash "$HARNESS" --help 2>&1)
exit_code=$?
# Should show usage information
assert_contains "test_harness_handles_missing_args: shows usage" "Usage" "$output"
assert_pass_if_clean "test_harness_handles_missing_args"

# ── test_harness_rule_contract_documented ────────────────────────────────────
_snapshot_fail
has_contract=0
grep -q "Rule contract" "$HARNESS" 2>/dev/null && has_contract=1
assert_eq "test_harness_rule_contract_documented" "1" "$has_contract"
assert_pass_if_clean "test_harness_rule_contract_documented"

# ── test_harness_handles_rule_crash_gracefully ───────────────────────────────
# Create a rules dir with ONLY the crash rule + the normal rule
CRASH_RULES_DIR="$FIXTURES_DIR/tmp-test-crash-rules-$$"
mkdir -p "$CRASH_RULES_DIR"
cp "$TEMP_RULES_DIR/crash-rule.sh" "$CRASH_RULES_DIR/"
cp "$TEMP_RULES_DIR/no-bad-pattern.sh" "$CRASH_RULES_DIR/"

_snapshot_fail
output=$(RULES_DIR="$CRASH_RULES_DIR" bash "$HARNESS" "$BAD_FILE" 2>&1)
exit_code=$?
# Should still find violations from the non-crashing rule (exit 1)
assert_eq "test_harness_handles_rule_crash_gracefully: exit 1 with violations" "1" "$exit_code"
# Should contain a warning about the crashed rule
assert_contains "test_harness_handles_rule_crash_gracefully: warns about crash" "WARNING" "$output"
# Should still output violations from non-crashing rule
assert_contains "test_harness_handles_rule_crash_gracefully: still finds violations" "no-bad-pattern" "$output"
assert_pass_if_clean "test_harness_handles_rule_crash_gracefully"

# ---- Cleanup ----
rm -rf "$FIXTURES_DIR/tmp-test-"*

print_summary
