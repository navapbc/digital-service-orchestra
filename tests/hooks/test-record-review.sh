#!/usr/bin/env bash
# tests/hooks/test-record-review.sh
# Tests for hooks/record-review.sh
#
# record-review.sh reads directly from reviewer-findings.json (written by
# the code-reviewer sub-agent). It requires --reviewer-hash and validates
# the findings file's integrity and schema. No stdin JSON is accepted.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$DSO_PLUGIN_DIR/hooks/record-review.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Source deps.sh to use get_artifacts_dir()
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# Use an isolated temp directory so tests don't clobber production artifacts.
# Export WORKFLOW_PLUGIN_ARTIFACTS_DIR so record-review.sh (via get_artifacts_dir())
# uses this dir instead of the real one. Without this, concurrent test runs
# delete the production reviewer-findings.json — the root cause of the
# "reviewer-findings.json not found" bug that blocked the commit workflow.
ARTIFACTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-record-review-XXXXXX")
export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR"
FINDINGS_FILE="$ARTIFACTS_DIR/reviewer-findings.json"

cleanup() {
    rm -f "$FINDINGS_FILE"
}
trap 'rm -rf "$ARTIFACTS_DIR"' EXIT

run_hook_exit() {
    local exit_code=0
    bash "$HOOK" "$@" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# test_record_review_exits_nonzero_without_reviewer_hash
# No --reviewer-hash → exit 1
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"scores":{"code_hygiene":5,"object_oriented_design":5,"readability":5,"functionality":5,"testing_coverage":5},"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
EXIT_CODE=$(run_hook_exit)
assert_ne "test_record_review_exits_nonzero_without_reviewer_hash" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_without_findings_file
# No reviewer-findings.json → exit 1
cleanup
EXIT_CODE=$(run_hook_exit --reviewer-hash "abc123")
assert_ne "test_record_review_exits_nonzero_without_findings_file" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_hash_mismatch
# Wrong hash → exit 1
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"scores":{"code_hygiene":5,"object_oriented_design":5,"readability":5,"functionality":5,"testing_coverage":5},"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
EXIT_CODE=$(run_hook_exit --reviewer-hash "0000000000000000000000000000000000000000000000000000000000000000")
assert_ne "test_record_review_exits_nonzero_on_hash_mismatch" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_missing_scores
# Findings file without scores → exit 1
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"findings":[],"summary":"Missing scores object entirely"}' > "$FINDINGS_FILE"
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
EXIT_CODE=$(run_hook_exit --reviewer-hash "$HASH")
assert_ne "test_record_review_exits_nonzero_on_missing_scores" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_missing_summary
# Findings file without summary → exit 1
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"scores":{"code_hygiene":5,"object_oriented_design":5,"readability":5,"functionality":5,"testing_coverage":5},"findings":[]}' > "$FINDINGS_FILE"
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
EXIT_CODE=$(run_hook_exit --reviewer-hash "$HASH")
assert_ne "test_record_review_exits_nonzero_on_missing_summary" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_score_out_of_range
# Score of 6 → exit 1
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"scores":{"code_hygiene":6,"object_oriented_design":5,"readability":5,"functionality":5,"testing_coverage":5},"findings":[],"summary":"Score out of range test review"}' > "$FINDINGS_FILE"
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
EXIT_CODE=$(run_hook_exit --reviewer-hash "$HASH")
assert_ne "test_record_review_exits_nonzero_on_score_out_of_range" "0" "$EXIT_CODE"

# test_record_review_drains_stdin_silently
# Piped stdin should be drained without error (backward compat)
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"scores":{"code_hygiene":5,"object_oriented_design":5,"readability":5,"functionality":5,"testing_coverage":5},"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
EXIT_CODE=0
echo "some old stdin json" | bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || EXIT_CODE=$?
# Should succeed (stdin is drained, not used)
assert_eq "test_record_review_drains_stdin_silently" "0" "$EXIT_CODE"

# ============================================================
# test_record_review_portable_state_path
#
# Verify that record-review.sh writes review-status to /tmp/workflow-plugin-*/
# not /tmp/lockpick-test-artifacts-*/ .
# ============================================================

RRSTATE_TMP=$(mktemp -d)
cleanup_rrstate() { rm -rf "$RRSTATE_TMP" "$ARTIFACTS_DIR"; }
trap cleanup_rrstate EXIT

# Initialize a minimal fake git repo so get_artifacts_dir() can call git rev-parse
git -C "$RRSTATE_TMP" init --quiet 2>/dev/null || true

HOOK_PARENT_DIR="$(cd "$(dirname "$HOOK")" && pwd)"

DETECTED_STATE_DIR=""
DETECTED_STATE_DIR=$(
    cd "$RRSTATE_TMP"
    source "$HOOK_PARENT_DIR/lib/deps.sh" 2>/dev/null || true
    if declare -f get_artifacts_dir > /dev/null 2>&1; then
        REPO_ROOT="$RRSTATE_TMP" get_artifacts_dir 2>/dev/null
    else
        # Function does not yet exist — reproduce old hardcoded path so assertion fails
        WORKTREE_NAME=$(basename "$RRSTATE_TMP")
        echo "/tmp/lockpick-test-artifacts-${WORKTREE_NAME}"
    fi
) 2>/dev/null

OLD_PREFIX_FOUND_RR="no"
if [[ "$DETECTED_STATE_DIR" == *lockpick-test-artifacts* ]]; then
    OLD_PREFIX_FOUND_RR="yes"
fi

assert_eq \
    "test_record_review_portable_state_path: ARTIFACTS_DIR does not use lockpick-test-artifacts" \
    "no" \
    "$OLD_PREFIX_FOUND_RR"

print_summary
