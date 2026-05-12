#!/usr/bin/env bash
# tests/scripts/test-check-precondition-emit.sh
# RED test suite for plugins/dso/hooks/check-precondition-emit.sh
#
# All 7 tests are expected to FAIL because the hook does not yet exist.
# Once the hook is implemented (GREEN task), these tests should all pass.
#
# The hook accepts DSO_STAGED_DIFF_FILE env var to read diff from a file
# instead of running git diff --cached.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"

SUT="$REPO_ROOT/plugins/dso/hooks/check-precondition-emit.sh"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures/precondition-emit"

# ── Helpers ───────────────────────────────────────────────────────────────────

_run_sut() {
    local fixture_file="$1"
    local exit_code=0
    DSO_STAGED_DIFF_FILE="$fixture_file" bash "$SUT" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# test_trigger_no_landmark: diff adds 'fall through' to target file; no EMIT-PRECONDITIONS
# in hunk → expect exit 1
test_trigger_no_landmark() {
    _snapshot_fail
    local exit_code
    exit_code=$(_run_sut "$FIXTURES_DIR/trigger-no-landmark.diff")
    assert_eq "test_trigger_no_landmark: exit 1 when trigger present without landmark" "1" "$exit_code"
    assert_pass_if_clean "test_trigger_no_landmark"
}

# test_trigger_with_nearby_landmark: diff adds 'fall through'; EMIT-PRECONDITIONS appears
# 5 lines after in same hunk → expect exit 0
test_trigger_with_nearby_landmark() {
    _snapshot_fail
    local exit_code
    exit_code=$(_run_sut "$FIXTURES_DIR/trigger-with-nearby-landmark.diff")
    assert_eq "test_trigger_with_nearby_landmark: exit 0 when landmark is within 10 lines" "0" "$exit_code"
    assert_pass_if_clean "test_trigger_with_nearby_landmark"
}

# test_trigger_with_distant_landmark: diff adds 'fall through'; EMIT-PRECONDITIONS appears
# 11 lines later (beyond N=10 window) → expect exit 1
test_trigger_with_distant_landmark() {
    _snapshot_fail
    local exit_code
    exit_code=$(_run_sut "$FIXTURES_DIR/trigger-with-distant-landmark.diff")
    assert_eq "test_trigger_with_distant_landmark: exit 1 when landmark is beyond 10-line window" "1" "$exit_code"
    assert_pass_if_clean "test_trigger_with_distant_landmark"
}

# test_suppression_annotation: diff adds 'fall through # precondition-emit-ok' → expect exit 0
test_suppression_annotation() {
    _snapshot_fail
    local exit_code
    exit_code=$(_run_sut "$FIXTURES_DIR/trigger-suppressed.diff")
    assert_eq "test_suppression_annotation: exit 0 when suppression annotation is present" "0" "$exit_code"
    assert_pass_if_clean "test_suppression_annotation"
}

# test_preexisting_not_flagged: diff has context line (space prefix, not +) with 'fall through';
# no added trigger → expect exit 0
test_preexisting_not_flagged() {
    _snapshot_fail
    local exit_code
    exit_code=$(_run_sut "$FIXTURES_DIR/preexisting-not-flagged.diff")
    assert_eq "test_preexisting_not_flagged: exit 0 when trigger is in context line, not added line" "0" "$exit_code"
    assert_pass_if_clean "test_preexisting_not_flagged"
}

# test_non_target_file: diff adds 'fall through' to README.md (non-target file) → expect exit 0
test_non_target_file() {
    _snapshot_fail
    local exit_code
    exit_code=$(_run_sut "$FIXTURES_DIR/non-target-file.diff")
    assert_eq "test_non_target_file: exit 0 when trigger is in non-target file" "0" "$exit_code"
    assert_pass_if_clean "test_non_target_file"
}

# test_no_trigger_keyword: diff adds prose to target file with no trigger keywords → expect exit 0
test_no_trigger_keyword() {
    _snapshot_fail
    local exit_code
    exit_code=$(_run_sut "$FIXTURES_DIR/no-trigger-keyword.diff")
    assert_eq "test_no_trigger_keyword: exit 0 when no trigger keywords present" "0" "$exit_code"
    assert_pass_if_clean "test_no_trigger_keyword"
}

# ── Runner ────────────────────────────────────────────────────────────────────

test_trigger_no_landmark
test_trigger_with_nearby_landmark
test_trigger_with_distant_landmark
test_suppression_annotation
test_preexisting_not_flagged
test_non_target_file
test_no_trigger_keyword

print_summary
