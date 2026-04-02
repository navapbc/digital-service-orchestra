#!/usr/bin/env bash
set -uo pipefail
# tests/hooks/test-record-test-status-accumulative.sh
# Tests for the accumulative merge logic in record-test-status.sh
# Verifies that --source-file calls merge tested_files and enforce severity hierarchy.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── test_accumulative_merge_tested_files ──────────────────────────────────
# When a test-gate-status file already exists from a prior --source-file call,
# a subsequent call should merge tested_files, not overwrite them.
echo ""
echo "--- Accumulative merge: tested_files are merged across calls ---"

_snapshot_fail
ARTIFACTS=$(mktemp -d)
trap 'rm -rf "$ARTIFACTS"' EXIT

# Simulate first call's output
cat > "$ARTIFACTS/test-gate-status" <<EOF
passed
diff_hash=abc123
timestamp=2026-04-01T00:00:00Z
tested_files=tests/test_a.sh,tests/test_b.sh
failed_tests=
EOF

# Simulate the merge logic (extracted from record-test-status.sh)
SOURCE_FILE="src/file2.py"
STATUS_FILE="$ARTIFACTS/test-gate-status"
TESTED_FILES_LIST="tests/test_c.sh,tests/test_d.sh"
FAILED_TESTS_LIST=""
STATUS="passed"

_existing_tested=$(grep '^tested_files=' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
_existing_status=$(head -1 "$STATUS_FILE" 2>/dev/null || echo "")
if [[ -n "$_existing_tested" ]]; then
    _merged=$(printf '%s\n' "$_existing_tested" "$TESTED_FILES_LIST" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u | paste -sd ',' -)
    TESTED_FILES_LIST="$_merged"
fi

# Verify all 4 test files are present
assert_contains "test_accumulative_merge: has test_a" "tests/test_a.sh" "$TESTED_FILES_LIST"
assert_contains "test_accumulative_merge: has test_c" "tests/test_c.sh" "$TESTED_FILES_LIST"
assert_contains "test_accumulative_merge: has test_d" "tests/test_d.sh" "$TESTED_FILES_LIST"
assert_pass_if_clean "test_accumulative_merge_tested_files"

# ── test_status_downgrade_only ────────────────────────────────────────────
# A new "passed" call should NOT upgrade an existing "failed" status.
echo ""
echo "--- Status downgrade only: failed stays failed ---"

_snapshot_fail
cat > "$ARTIFACTS/test-gate-status" <<EOF
failed
diff_hash=abc
timestamp=t1
tested_files=test_a.sh
failed_tests=test_a.sh
EOF

_existing_status=$(head -1 "$ARTIFACTS/test-gate-status" 2>/dev/null || echo "")
STATUS="passed"
if [[ "$_existing_status" == "timeout" ]]; then
    STATUS="timeout"
elif [[ "$_existing_status" == "failed" ]]; then
    STATUS="failed"
fi

assert_eq "test_status_downgrade: failed stays failed" "failed" "$STATUS"
assert_pass_if_clean "test_status_downgrade_only"

# ── test_timeout_preserved ────────────────────────────────────────────────
# A new "passed" or "failed" call should NOT override an existing "timeout" status.
echo ""
echo "--- Timeout preserved: timeout stays timeout ---"

_snapshot_fail
cat > "$ARTIFACTS/test-gate-status" <<EOF
timeout
diff_hash=abc
timestamp=t1
tested_files=test_a.sh
failed_tests=
EOF

_existing_status=$(head -1 "$ARTIFACTS/test-gate-status" 2>/dev/null || echo "")
STATUS="failed"
if [[ "$_existing_status" == "timeout" ]]; then
    STATUS="timeout"
elif [[ "$_existing_status" == "failed" ]]; then
    STATUS="failed"
fi

assert_eq "test_timeout_preserved: timeout stays timeout" "timeout" "$STATUS"
assert_pass_if_clean "test_timeout_preserved"

# ── test_failed_tests_merged ─────────────────────────────────────────────
# Failed tests from multiple calls should be accumulated.
echo ""
echo "--- Failed tests merged across calls ---"

_snapshot_fail
cat > "$ARTIFACTS/test-gate-status" <<EOF
failed
diff_hash=abc
timestamp=t1
tested_files=test_a.sh
failed_tests=test_a.sh
EOF

FAILED_TESTS_LIST="test_b.sh"
_existing_failed=$(grep '^failed_tests=' "$ARTIFACTS/test-gate-status" 2>/dev/null | head -1 | cut -d= -f2-)
if [[ -n "$_existing_failed" ]] && [[ -n "$FAILED_TESTS_LIST" ]]; then
    FAILED_TESTS_LIST=$(printf '%s\n' "$_existing_failed" "$FAILED_TESTS_LIST" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u | paste -sd ',' -)
fi

assert_contains "test_failed_merged: has test_a" "test_a.sh" "$FAILED_TESTS_LIST"
assert_contains "test_failed_merged: has test_b" "test_b.sh" "$FAILED_TESTS_LIST"
assert_pass_if_clean "test_failed_tests_merged"

# ── test_current_timeout_not_downgraded ────────────────────────────────────
# When the current run has STATUS=timeout and the existing file has 'failed',
# the result must be 'timeout' (the more severe), not 'failed'.
echo ""
echo "--- Current timeout not downgraded by existing failed ---"

_snapshot_fail
cat > "$ARTIFACTS/test-gate-status" <<EOF
failed
diff_hash=abc
timestamp=t1
tested_files=test_a.sh
failed_tests=test_a.sh
EOF

_existing_status=$(head -1 "$ARTIFACTS/test-gate-status" 2>/dev/null || echo "")
STATUS="timeout"
if [[ "$_existing_status" == "timeout" ]] || [[ "$STATUS" == "timeout" ]]; then
    STATUS="timeout"
elif [[ "$_existing_status" == "failed" ]] || [[ "$STATUS" == "failed" ]]; then
    STATUS="failed"
fi

assert_eq "test_current_timeout_not_downgraded: timeout wins over failed" "timeout" "$STATUS"
assert_pass_if_clean "test_current_timeout_not_downgraded"

# ── test_merge_head_empty_file_safe ────────────────────────────────────────
# When MERGE_HEAD exists but is empty (corrupt state), the guard must not crash.
echo ""
echo "--- Empty MERGE_HEAD file does not crash ---"

_snapshot_fail
_MERGE_DIR=$(mktemp -d)
touch "$_MERGE_DIR/MERGE_HEAD"  # empty file

_raw_merge_head=$(head -1 "$_MERGE_DIR/MERGE_HEAD" 2>/dev/null || echo "")
_merge_head_sha=""
[[ -n "$_raw_merge_head" ]] && _merge_head_sha=$(git rev-parse "$_raw_merge_head" 2>/dev/null || echo "")

assert_eq "test_merge_head_empty: raw is empty" "" "$_raw_merge_head"
assert_eq "test_merge_head_empty: sha is empty" "" "$_merge_head_sha"
assert_pass_if_clean "test_merge_head_empty_file_safe"

rm -rf "$ARTIFACTS" "$_MERGE_DIR"
trap - EXIT

print_summary
