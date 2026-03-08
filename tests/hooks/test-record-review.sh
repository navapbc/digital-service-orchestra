#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-record-review.sh
# Tests for .claude/hooks/record-review.sh
#
# record-review.sh is a utility that records a code review result.
# It requires a full review JSON on stdin AND --reviewer-hash flag.
# Exits 1 on validation failures.

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/record-review.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

run_hook_exit() {
    local input="$1"
    shift
    local exit_code=0
    echo "$input" | bash "$HOOK" "$@" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# test_record_review_exits_nonzero_without_required_fields
# Empty JSON {} → missing scores, summary, etc → exit 1
EXIT_CODE=$(run_hook_exit "{}")
assert_ne "test_record_review_exits_nonzero_without_required_fields" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_empty_input
# Empty stdin → "review JSON required on stdin" → exit 1
EXIT_CODE=$(run_hook_exit "")
assert_ne "test_record_review_exits_nonzero_on_empty_input" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_missing_scores
# JSON without scores object → exit 1
INPUT='{"summary":"This is a test review summary","feedback":{"files_targeted":["app/src/test.py"]}}'
EXIT_CODE=$(run_hook_exit "$INPUT")
assert_ne "test_record_review_exits_nonzero_on_missing_scores" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_missing_summary
# JSON with scores but missing summary → exit 1
INPUT='{"scores":{"code_hygiene":4,"object_oriented_design":4,"readability":4,"functionality":4,"testing_coverage":4},"feedback":{"files_targeted":["app/src/test.py"]}}'
EXIT_CODE=$(run_hook_exit "$INPUT")
assert_ne "test_record_review_exits_nonzero_on_missing_summary" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_missing_feedback
# JSON with scores and summary but missing feedback → exit 1
INPUT='{"scores":{"code_hygiene":4,"object_oriented_design":4,"readability":4,"functionality":4,"testing_coverage":4},"summary":"A sufficient review summary here"}'
EXIT_CODE=$(run_hook_exit "$INPUT")
assert_ne "test_record_review_exits_nonzero_on_missing_feedback" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_score_out_of_range
# Score outside 1-5 range → exit 1
INPUT='{"scores":{"code_hygiene":6,"object_oriented_design":4,"readability":4,"functionality":4,"testing_coverage":4},"summary":"A sufficient review summary here","feedback":{"files_targeted":["app/src/test.py"]}}'
EXIT_CODE=$(run_hook_exit "$INPUT")
assert_ne "test_record_review_exits_nonzero_on_score_out_of_range" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_malformed_json
# Malformed JSON → exit 1
EXIT_CODE=$(run_hook_exit "not json {{")
assert_ne "test_record_review_exits_nonzero_on_malformed_json" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_without_reviewer_hash
# A structurally valid review JSON still requires --reviewer-hash → exit 1
# (Also requires reviewer-findings.json file to exist)
# This test verifies the mandatory --reviewer-hash argument check
INPUT='{"scores":{"code_hygiene":4,"object_oriented_design":4,"readability":4,"functionality":4,"testing_coverage":4},"summary":"A sufficient review summary here that is long enough","feedback":{"files_targeted":["app/src/test.py"]},"findings":[]}'
EXIT_CODE=$(run_hook_exit "$INPUT")
assert_ne "test_record_review_exits_nonzero_without_reviewer_hash" "0" "$EXIT_CODE"

# ============================================================
# test_record_review_portable_state_path
#
# Verify that record-review.sh writes review-status to /tmp/workflow-plugin-*/
# not /tmp/lockpick-test-artifacts-*/ .
#
# Approach: source deps.sh from the hook directory and call get_artifacts_dir()
# with a controlled REPO_ROOT. Assert the returned path does NOT contain
# 'lockpick-test-artifacts'.
#
# MUST FAIL until Task j46vp.3.9 implements get_artifacts_dir() in record-review.sh.
# ============================================================

RRSTATE_TMP=$(mktemp -d)
cleanup_rrstate() { rm -rf "$RRSTATE_TMP"; }
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
