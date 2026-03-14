#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-isolation-rule-no-temp-without-cleanup.sh
# Tests for scripts/test-isolation-rules/no-temp-without-cleanup.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-isolation-rule-no-temp-without-cleanup.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RULE="$REPO_ROOT/scripts/test-isolation-rules/no-temp-without-cleanup.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/isolation-rules"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-isolation-rule-no-temp-without-cleanup.sh ==="

# ── test_rule_exists_and_executable ──────────────────────────────────────────
_snapshot_fail
rule_exec=0
[ -x "$RULE" ] && rule_exec=1
assert_eq "test_rule_exists_and_executable" "1" "$rule_exec"
assert_pass_if_clean "test_rule_exists_and_executable"

# ── test_no_temp_without_cleanup_catches_mktemp_no_trap ──────────────────────
# Fixture with mktemp but no trap ... EXIT should trigger violation
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/bad-temp-no-cleanup.sh" 2>/dev/null)
exit_code=$?
# Rule should produce output (violations found)
assert_ne "test_no_temp_without_cleanup_catches_mktemp_no_trap: has output" "" "$output"
# Output should contain the rule name
assert_contains "test_no_temp_without_cleanup_catches_mktemp_no_trap: rule name in output" "no-temp-without-cleanup" "$output"
# Output should reference the file
assert_contains "test_no_temp_without_cleanup_catches_mktemp_no_trap: file in output" "bad-temp-no-cleanup.sh" "$output"
# Output format should be file:line:rule:message
assert_contains "test_no_temp_without_cleanup_catches_mktemp_no_trap: structured format" ":5:no-temp-without-cleanup:" "$output"
assert_pass_if_clean "test_no_temp_without_cleanup_catches_mktemp_no_trap"

# ── test_no_temp_without_cleanup_passes_with_trap ────────────────────────────
# Fixture with mktemp + trap 'rm -rf "$dir"' EXIT should pass (no output)
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/good-temp-with-cleanup.sh" 2>/dev/null)
exit_code=$?
# Rule should produce no output (no violations)
assert_eq "test_no_temp_without_cleanup_passes_with_trap: no output" "" "$output"
# Rule should exit 0
assert_eq "test_no_temp_without_cleanup_passes_with_trap: exit 0" "0" "$exit_code"
assert_pass_if_clean "test_no_temp_without_cleanup_passes_with_trap"

# ── test_no_temp_without_cleanup_ignores_non_bash_files ──────────────────────
# Create a temp Python file with mktemp string — should not trigger
_snapshot_fail
TEMP_PY=$(mktemp /tmp/test-isolation-XXXXXX.py)
trap 'rm -f "$TEMP_PY"' EXIT
cat > "$TEMP_PY" << 'EOF'
import subprocess
result = subprocess.run(["mktemp", "-d"], capture_output=True)
tmpdir = result.stdout.strip()
EOF
output=$("$RULE" "$TEMP_PY" 2>/dev/null)
# A .py file should produce no violations (rule targets bash/shell files)
assert_eq "test_no_temp_without_cleanup_ignores_non_bash_files: no output for .py" "" "$output"
assert_pass_if_clean "test_no_temp_without_cleanup_ignores_non_bash_files"

# ── test_no_temp_without_cleanup_no_mktemp_no_violation ──────────────────────
# A bash file with no mktemp usage should produce no violations
_snapshot_fail
TEMP_CLEAN=$(mktemp /tmp/test-isolation-XXXXXX.sh)
cat > "$TEMP_CLEAN" << 'EOF'
#!/usr/bin/env bash
echo "hello world"
EOF
output=$("$RULE" "$TEMP_CLEAN" 2>/dev/null)
assert_eq "test_no_temp_without_cleanup_no_mktemp_no_violation: no output" "" "$output"
assert_pass_if_clean "test_no_temp_without_cleanup_no_mktemp_no_violation"
rm -f "$TEMP_CLEAN"

print_summary
