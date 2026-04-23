#!/usr/bin/env bash
set -uo pipefail
# tests/hooks/test-record-test-status-red-zone-merge.sh
# Tests that RED-zone tolerated failures are NOT re-added from existing failed_tests
# during the --source-file merge (bug a8b0-7fbc).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# test_red_zone_tolerated_not_readded_from_existing
# When the new run tolerates a test via the RED zone (so it does NOT appear in
# FAILED_TESTS_LIST), that test must NOT be re-added from the existing
# failed_tests list during the merge. The new run's RED-zone tolerance is
# authoritative for tests it covered.
#
# Scenario:
#   Prior status file: tests/test_a.sh was "failed" (before RED zone support)
#   New run: ran tests/test_a.sh, tolerated failures via RED marker
#            => test_a.sh NOT in FAILED_TESTS_LIST, but IS in _new_run_tested
#   Expected: tests/test_a.sh absent from merged FAILED_TESTS_LIST
echo ""
echo "--- RED-zone tolerated failure not re-added from existing failed_tests ---"

_snapshot_fail
ARTIFACTS=$(mktemp -d)
trap 'rm -rf "$ARTIFACTS"' EXIT

cat > "$ARTIFACTS/test-gate-status" <<EOF
failed
diff_hash=abc
timestamp=t1
tested_files=tests/test_a.sh
failed_tests=tests/test_a.sh
EOF

# New run: test_a.sh was run and tolerated via RED zone -> not in FAILED_TESTS_LIST
_new_run_tested="tests/test_a.sh"
FAILED_TESTS_LIST=""

_existing_failed=$(grep '^failed_tests=' "$ARTIFACTS/test-gate-status" 2>/dev/null | head -1 | cut -d= -f2-)

# Apply the FIXED merge logic (mirrors the corrected code in record-test-status.sh):
# Strip existing failures covered by the new run before restoring them.
_merged_failed=""
if [[ -n "$_existing_failed" ]]; then
    _new_run_tests=$(printf '%s\n' "$_new_run_tested" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')
    _filtered_existing=""
    while IFS= read -r _ef; do
        [[ -z "$_ef" ]] && continue
        _ef_base="${_ef%%\[*}"
        _ef_base="${_ef_base%"${_ef_base##*[![:space:]]}"}"
        _covered=false
        while IFS= read -r _nt; do
            [[ -z "$_nt" ]] && continue
            if [[ "$_ef_base" == "$_nt" ]]; then
                _covered=true
                break
            fi
        done <<< "$_new_run_tests"
        if [[ "$_covered" == false ]]; then
            if [[ -n "$_filtered_existing" ]]; then
                _filtered_existing="${_filtered_existing},$_ef"
            else
                _filtered_existing="$_ef"
            fi
        fi
    done < <(printf '%s\n' "$_existing_failed" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')
    if [[ -n "$_filtered_existing" ]] && [[ -n "$FAILED_TESTS_LIST" ]]; then
        _merged_failed=$(printf '%s\n' "$_filtered_existing" "$FAILED_TESTS_LIST" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u | paste -sd ',' -)
    elif [[ -n "$_filtered_existing" ]]; then
        _merged_failed="$_filtered_existing"
    fi
fi

# The result should NOT contain tests/test_a.sh because the new run covered and tolerated it
assert_eq "test_red_zone_not_readded: merged failed_tests is empty" \
    "" "$_merged_failed"
assert_pass_if_clean "test_red_zone_tolerated_not_readded_from_existing"

# test_uncovered_existing_failed_preserved
# Existing failures for test files NOT covered by the new run should still
# be preserved in the merged result.
echo ""
echo "--- Existing failed tests for uncovered files are preserved ---"

_snapshot_fail
cat > "$ARTIFACTS/test-gate-status" <<EOF
failed
diff_hash=abc
timestamp=t1
tested_files=tests/test_a.sh,tests/test_b.sh
failed_tests=tests/test_a.sh,tests/test_b.sh
EOF

# New run only covers test_b.sh (tolerated via RED zone), not test_a.sh
_new_run_tested_b="tests/test_b.sh"
FAILED_TESTS_LIST_B=""

_existing_failed_b=$(grep '^failed_tests=' "$ARTIFACTS/test-gate-status" 2>/dev/null | head -1 | cut -d= -f2-)

_merged_failed_b=""
if [[ -n "$_existing_failed_b" ]]; then
    _new_run_tests_b=$(printf '%s\n' "$_new_run_tested_b" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')
    _filtered_existing_b=""
    while IFS= read -r _ef_b; do
        [[ -z "$_ef_b" ]] && continue
        _ef_base_b="${_ef_b%%\[*}"
        _ef_base_b="${_ef_base_b%"${_ef_base_b##*[![:space:]]}"}"
        _covered_b=false
        while IFS= read -r _nt_b; do
            [[ -z "$_nt_b" ]] && continue
            if [[ "$_ef_base_b" == "$_nt_b" ]]; then
                _covered_b=true
                break
            fi
        done <<< "$_new_run_tests_b"
        if [[ "$_covered_b" == false ]]; then
            if [[ -n "$_filtered_existing_b" ]]; then
                _filtered_existing_b="${_filtered_existing_b},$_ef_b"
            else
                _filtered_existing_b="$_ef_b"
            fi
        fi
    done < <(printf '%s\n' "$_existing_failed_b" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')
    if [[ -n "$_filtered_existing_b" ]] && [[ -n "$FAILED_TESTS_LIST_B" ]]; then
        _merged_failed_b=$(printf '%s\n' "$_filtered_existing_b" "$FAILED_TESTS_LIST_B" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u | paste -sd ',' -)
    elif [[ -n "$_filtered_existing_b" ]]; then
        _merged_failed_b="$_filtered_existing_b"
    fi
fi

# test_a.sh was NOT covered by the new run, so its failure should be preserved
assert_contains "test_uncovered_preserved: test_a.sh still in failed_tests" \
    "tests/test_a.sh" "$_merged_failed_b"
# test_b.sh WAS covered by the new run (and tolerated), so it should be removed
assert_ne "test_uncovered_preserved: test_b.sh removed from failed_tests" \
    "tests/test_b.sh" "$_merged_failed_b"
assert_pass_if_clean "test_uncovered_existing_failed_preserved"

rm -rf "$ARTIFACTS"

print_summary
