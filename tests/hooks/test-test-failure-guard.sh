#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-test-failure-guard.sh
# Tests for hook_test_failure_guard — blocks commits when test status files
# contain "FAILED" on their first line.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$PLUGIN_ROOT/hooks/lib/pre-bash-functions.sh"

# Helper: build JSON input and call hook_test_failure_guard directly
run_guard() {
    local artifacts_dir="$1"
    local command="$2"
    local json
    # Escape double quotes in command for valid JSON
    local escaped_cmd="${command//\"/\\\"}"
    json=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$escaped_cmd")
    local exit_code=0
    ARTIFACTS_DIR="$artifacts_dir" hook_test_failure_guard "$json" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# ============================================================
# Group 1: No status files → commit allowed
# ============================================================
echo ""
echo "=== Group 1: No status files → commit allowed ==="
_dir1=$(mktemp -d)
mkdir -p "$_dir1/test-status"
result=$(run_guard "$_dir1" 'git commit -m "test"')
assert_eq "No status files → commit allowed" "0" "$result"
rm -rf "$_dir1"

_dir1b=$(mktemp -d)
result=$(run_guard "$_dir1b" 'git commit -m "test"')
assert_eq "No test-status dir → commit allowed" "0" "$result"
rm -rf "$_dir1b"

# ============================================================
# Group 2: All PASSED → commit allowed
# ============================================================
echo ""
echo "=== Group 2: All PASSED → commit allowed ==="
_dir2=$(mktemp -d)
mkdir -p "$_dir2/test-status"
echo "PASSED" > "$_dir2/test-status/unit.status"
echo "PASSED" > "$_dir2/test-status/e2e.status"
echo "PASSED" > "$_dir2/test-status/lint.status"
result=$(run_guard "$_dir2" 'git commit -m "test"')
assert_eq "All PASSED → commit allowed" "0" "$result"
rm -rf "$_dir2"

# ============================================================
# Group 3: Any FAILED → commit blocked
# ============================================================
echo ""
echo "=== Group 3: Any FAILED → commit blocked ==="
_dir3=$(mktemp -d)
mkdir -p "$_dir3/test-status"
echo "FAILED" > "$_dir3/test-status/unit.status"
result=$(run_guard "$_dir3" 'git commit -m "test"')
assert_eq "Single FAILED → commit blocked" "2" "$result"
rm -rf "$_dir3"

# ============================================================
# Group 4: Non-commit commands → always allowed
# ============================================================
echo ""
echo "=== Group 4: Non-commit commands → always allowed ==="
_dir4=$(mktemp -d)
mkdir -p "$_dir4/test-status"
echo "FAILED" > "$_dir4/test-status/unit.status"
result=$(run_guard "$_dir4" "ls -la")
assert_eq "ls with FAILED status → allowed" "0" "$result"
result=$(run_guard "$_dir4" "make test")
assert_eq "make test with FAILED status → allowed" "0" "$result"
result=$(run_guard "$_dir4" "git status")
assert_eq "git status with FAILED status → allowed" "0" "$result"
result=$(run_guard "$_dir4" "git push")
assert_eq "git push with FAILED status → allowed" "0" "$result"
rm -rf "$_dir4"

# ============================================================
# Group 5: Mix of PASSED and FAILED → blocked
# ============================================================
echo ""
echo "=== Group 5: Mix of PASSED and FAILED → blocked ==="
_dir5=$(mktemp -d)
mkdir -p "$_dir5/test-status"
echo "PASSED" > "$_dir5/test-status/unit.status"
echo "FAILED" > "$_dir5/test-status/e2e.status"
echo "PASSED" > "$_dir5/test-status/lint.status"
result=$(run_guard "$_dir5" 'git commit -m "test"')
assert_eq "Mix PASSED+FAILED → commit blocked" "2" "$result"
rm -rf "$_dir5"

# ============================================================
# Group 6: WIP/merge/pre-compact commits → exempt
# ============================================================
echo ""
echo "=== Group 6: WIP/merge/pre-compact commits → exempt ==="
_dir6=$(mktemp -d)
mkdir -p "$_dir6/test-status"
echo "FAILED" > "$_dir6/test-status/unit.status"
result=$(run_guard "$_dir6" 'git commit -m "WIP: save progress"')
assert_eq "WIP commit with FAILED → exempt" "0" "$result"
result=$(run_guard "$_dir6" 'git commit -m "wip save"')
assert_eq "wip (lowercase) commit with FAILED → exempt" "0" "$result"
result=$(run_guard "$_dir6" 'git merge feature-branch --no-edit')
assert_eq "git merge with FAILED → exempt" "0" "$result"
result=$(run_guard "$_dir6" 'git commit -m "pre-compact checkpoint"')
assert_eq "pre-compact commit with FAILED → exempt" "0" "$result"
result=$(run_guard "$_dir6" 'git commit -m "checkpoint save"')
assert_eq "checkpoint commit with FAILED → exempt" "0" "$result"
rm -rf "$_dir6"

# ============================================================
# Group 7: Unexpected content — only exact "FAILED" blocks
# ============================================================
echo ""
echo "=== Group 7: Unexpected content ==="
_dir7=$(mktemp -d)
mkdir -p "$_dir7/test-status"

echo -n "" > "$_dir7/test-status/unit.status"
result=$(run_guard "$_dir7" 'git commit -m "test"')
assert_eq "test_guard_allows_empty_status_file" "0" "$result"

echo "ERROR" > "$_dir7/test-status/unit.status"
result=$(run_guard "$_dir7" 'git commit -m "test"')
assert_eq "test_guard_allows_error_status_value" "0" "$result"

echo "F" > "$_dir7/test-status/unit.status"
result=$(run_guard "$_dir7" 'git commit -m "test"')
assert_eq "test_guard_allows_partial_f_string" "0" "$result"

echo "PASS" > "$_dir7/test-status/unit.status"
result=$(run_guard "$_dir7" 'git commit -m "test"')
assert_eq "test_guard_allows_pass_not_passed" "0" "$result"

rm -rf "$_dir7"

print_summary
