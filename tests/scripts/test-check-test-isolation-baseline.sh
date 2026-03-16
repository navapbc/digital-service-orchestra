#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-check-test-isolation-baseline.sh
# Tests for --baseline flag in scripts/check-test-isolation.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-check-test-isolation-baseline.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
HARNESS="$REPO_ROOT/scripts/check-test-isolation.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/isolation-rules"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-test-isolation-baseline.sh ==="

# ---- Setup: create fixtures ----

rm -rf "$FIXTURES_DIR/tmp-baseline-"*

# Create a temp rules dir with two dummy rules
TEMP_RULES_DIR="$FIXTURES_DIR/tmp-baseline-rules-$$"
mkdir -p "$TEMP_RULES_DIR"

# Rule 1: flags lines containing "BAD_PATTERN"
cat > "$TEMP_RULES_DIR/no-bad-pattern.sh" << 'RULE_EOF'
#!/usr/bin/env bash
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

# Rule 2: flags lines containing "UGLY_THING"
cat > "$TEMP_RULES_DIR/no-ugly-thing.sh" << 'RULE_EOF'
#!/usr/bin/env bash
file="$1"
line_num=0
while IFS= read -r line; do
    (( line_num++ ))
    if echo "$line" | grep -q "UGLY_THING"; then
        echo "$file:$line_num:no-ugly-thing:Found UGLY_THING"
    fi
done < "$file"
RULE_EOF
chmod +x "$TEMP_RULES_DIR/no-ugly-thing.sh"

# Create a .py test file with violations from both rules
PY_FILE="$FIXTURES_DIR/tmp-baseline-test-$$.py"
cat > "$PY_FILE" << 'FIXTURE_EOF'
import pytest

def test_something():
    BAD_PATTERN
    UGLY_THING
    assert True

def test_another():
    BAD_PATTERN
    assert 1 == 1
FIXTURE_EOF

# Create a .sh test file with violations
SH_FILE="$FIXTURES_DIR/tmp-baseline-test-$$.sh"
cat > "$SH_FILE" << 'FIXTURE_EOF'
#!/usr/bin/env bash
BAD_PATTERN
echo "ok"
FIXTURE_EOF

# Create a clean file (no violations)
CLEAN_FILE="$FIXTURES_DIR/tmp-baseline-clean-$$.py"
cat > "$CLEAN_FILE" << 'FIXTURE_EOF'
import pytest

def test_clean():
    assert True
FIXTURE_EOF

# ── test_baseline_mode_exits_zero ────────────────────────────────────────────
# Baseline mode should always exit 0 even when violations are found
_snapshot_fail
output=$(RULES_DIR="$TEMP_RULES_DIR" bash "$HARNESS" --baseline "$PY_FILE" "$SH_FILE" 2>/dev/null)
exit_code=$?
assert_eq "test_baseline_mode_exits_zero" "0" "$exit_code"
assert_pass_if_clean "test_baseline_mode_exits_zero"

# ── test_baseline_mode_outputs_counts_by_rule ────────────────────────────────
# Should show per-rule violation counts
_snapshot_fail
output=$(RULES_DIR="$TEMP_RULES_DIR" bash "$HARNESS" --baseline "$PY_FILE" "$SH_FILE" 2>/dev/null)
# The .py file has 2 BAD_PATTERN + 1 UGLY_THING; the .sh file has 1 BAD_PATTERN
# Total: no-bad-pattern=3, no-ugly-thing=1
assert_contains "test_baseline_mode_outputs_counts_by_rule: has by-rule section" "By rule:" "$output"
assert_contains "test_baseline_mode_outputs_counts_by_rule: no-bad-pattern count" "no-bad-pattern" "$output"
assert_contains "test_baseline_mode_outputs_counts_by_rule: no-ugly-thing count" "no-ugly-thing" "$output"
# Verify actual counts
assert_contains "test_baseline_mode_outputs_counts_by_rule: bad-pattern has 3" "no-bad-pattern: 3" "$output"
assert_contains "test_baseline_mode_outputs_counts_by_rule: ugly-thing has 1" "no-ugly-thing: 1" "$output"
assert_pass_if_clean "test_baseline_mode_outputs_counts_by_rule"

# ── test_baseline_mode_outputs_counts_by_type ────────────────────────────────
# Should show per-file-type violation counts
_snapshot_fail
output=$(RULES_DIR="$TEMP_RULES_DIR" bash "$HARNESS" --baseline "$PY_FILE" "$SH_FILE" 2>/dev/null)
# .py file: 3 violations; .sh file: 1 violation
assert_contains "test_baseline_mode_outputs_counts_by_type: has by-type section" "By file type:" "$output"
assert_contains "test_baseline_mode_outputs_counts_by_type: .py count" ".py: 3" "$output"
assert_contains "test_baseline_mode_outputs_counts_by_type: .sh count" ".sh: 1" "$output"
assert_pass_if_clean "test_baseline_mode_outputs_counts_by_type"

# ── test_baseline_mode_outputs_total ─────────────────────────────────────────
_snapshot_fail
output=$(RULES_DIR="$TEMP_RULES_DIR" bash "$HARNESS" --baseline "$PY_FILE" "$SH_FILE" 2>/dev/null)
assert_contains "test_baseline_mode_outputs_total: total count" "Total violations: 4" "$output"
assert_pass_if_clean "test_baseline_mode_outputs_total"

# ── test_baseline_mode_exits_zero_even_with_violations ───────────────────────
# Verify it exits 0 even when non-baseline mode would exit 1
_snapshot_fail
non_baseline_exit=0
RULES_DIR="$TEMP_RULES_DIR" bash "$HARNESS" "$PY_FILE" > /dev/null 2>&1 || non_baseline_exit=$?
assert_eq "test_baseline_mode_exits_zero_even_with_violations: non-baseline exits 1" "1" "$non_baseline_exit"

baseline_exit=0
RULES_DIR="$TEMP_RULES_DIR" bash "$HARNESS" --baseline "$PY_FILE" > /dev/null 2>&1 || baseline_exit=$?
assert_eq "test_baseline_mode_exits_zero_even_with_violations: baseline exits 0" "0" "$baseline_exit"
assert_pass_if_clean "test_baseline_mode_exits_zero_even_with_violations"

# ── test_baseline_mode_no_violations_report ──────────────────────────────────
_snapshot_fail
output=$(RULES_DIR="$TEMP_RULES_DIR" bash "$HARNESS" --baseline "$CLEAN_FILE" 2>/dev/null)
exit_code=$?
assert_eq "test_baseline_mode_no_violations_report: exits 0" "0" "$exit_code"
assert_contains "test_baseline_mode_no_violations_report: total is 0" "Total violations: 0" "$output"
assert_pass_if_clean "test_baseline_mode_no_violations_report"

# ---- Cleanup ----
rm -rf "$FIXTURES_DIR/tmp-baseline-"*

print_summary
