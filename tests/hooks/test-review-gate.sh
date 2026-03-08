#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-review-gate.sh
# Tests for .claude/hooks/review-gate.sh
#
# review-gate.sh is a PreToolUse HARD GATE hook (Bash matcher) that blocks
# git commit if code review hasn't passed for the current diff state.

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/review-gate.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"

ARTIFACTS_DIR=$(get_artifacts_dir)
REVIEW_STATE="$ARTIFACTS_DIR/review-status"

run_hook() {
    local input="$1"
    local exit_code=0
    echo "$input" | bash "$HOOK" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# test_review_gate_exits_zero_on_non_commit_command
# Non-commit Bash commands should pass through
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_review_gate_exits_zero_on_non_commit_command" "0" "$EXIT_CODE"

# test_review_gate_exits_zero_on_non_bash_tool
# Non-Bash tool calls should pass through
INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_review_gate_exits_zero_on_non_bash_tool" "0" "$EXIT_CODE"

# test_review_gate_exits_zero_on_edit_tool
# Edit tool → not a Bash commit → pass through
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_review_gate_exits_zero_on_edit_tool" "0" "$EXIT_CODE"

# test_review_gate_exits_zero_on_empty_input
# Empty stdin → exit 0
EXIT_CODE=$(run_hook "")
assert_eq "test_review_gate_exits_zero_on_empty_input" "0" "$EXIT_CODE"

# test_review_gate_exits_zero_on_wip_commit
# WIP commits are exempt from review gate
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"WIP: save progress\""}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_review_gate_exits_zero_on_wip_commit" "0" "$EXIT_CODE"

# test_review_gate_exits_zero_on_checkpoint_commit
# Checkpoint/pre-compact commits are exempt
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"checkpoint: pre-compaction auto-save\""}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_review_gate_exits_zero_on_checkpoint_commit" "0" "$EXIT_CODE"

# test_review_gate_exits_zero_on_git_log_command
# git log is not a commit command
INPUT='{"tool_name":"Bash","tool_input":{"command":"git log --oneline -5"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_review_gate_exits_zero_on_git_log_command" "0" "$EXIT_CODE"

# test_review_gate_blocks_commit_without_review
# git commit with no review state → blocked (exit 2)
ORIG_STATE=""
if [[ -f "$REVIEW_STATE" ]]; then
    ORIG_STATE=$(cat "$REVIEW_STATE")
    rm -f "$REVIEW_STATE"
fi

INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"feat: add feature\""}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_review_gate_blocks_commit_without_review" "2" "$EXIT_CODE"

# test_review_gate_blocks_commit_with_failed_review
# git commit when review has failed → blocked (exit 2)
mkdir -p "$ARTIFACTS_DIR"
printf "failed\ntimestamp=2026-01-01T00:00:00Z\ndiff_hash=abc123\nscore=2\nreview_hash=xyz\n" > "$REVIEW_STATE"

INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"feat: add feature\""}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_review_gate_blocks_commit_with_failed_review" "2" "$EXIT_CODE"

# Restore original state
if [[ -n "$ORIG_STATE" ]]; then
    echo "$ORIG_STATE" > "$REVIEW_STATE"
else
    rm -f "$REVIEW_STATE"
fi

# ============================================================
# test_review_gate_uses_workflow_plugin_artifact_dir
#
# Verify that review-gate.sh constructs ARTIFACTS_DIR using get_artifacts_dir()
# not the old lockpick-test-artifacts-* pattern.
#
# Approach: extract the ARTIFACTS_DIR path that review-gate.sh would use by
# inspecting the REVIEW_STATE_FILE variable name it sets when blocking a commit.
# We use a fake REPO_ROOT to avoid touching real state and then check that the
# path it computes does NOT match 'lockpick-test-artifacts'.
#
# MUST FAIL until Task j46vp.3.9 implements get_artifacts_dir() in the hook.
# ============================================================

# Create a fake REPO_ROOT so we can inspect what path review-gate.sh uses
RGATE_TMP=$(mktemp -d)
cleanup_rgate() { rm -rf "$RGATE_TMP"; }
trap cleanup_rgate EXIT

# Initialize a minimal fake git repo so git rev-parse works
git -C "$RGATE_TMP" init --quiet 2>/dev/null || true

# Source deps.sh into a subshell with the fake REPO_ROOT and call get_artifacts_dir().
# review-gate.sh will call get_artifacts_dir() to obtain ARTIFACTS_DIR once it is
# refactored (Task j46vp.3.9). Until then, the function does not exist and the path
# will contain 'lockpick-test-artifacts' (hardcoded). This test asserts the NEW
# behavior: the path must contain 'workflow-plugin' not 'lockpick-test-artifacts'.

HOOK_DIR_ABS="$(cd "$(dirname "$HOOK")" && pwd)"
DETECTED_DIR=""
DETECTED_DIR=$(
    cd "$RGATE_TMP"
    # Source deps.sh and call get_artifacts_dir() if it exists;
    # otherwise fall back to the old hardcoded construction so we can compare.
    source "$HOOK_DIR_ABS/lib/deps.sh" 2>/dev/null || true
    if declare -f get_artifacts_dir > /dev/null 2>&1; then
        REPO_ROOT="$RGATE_TMP" get_artifacts_dir 2>/dev/null
    else
        # Function does not exist — reproduce the old hardcoded path so the assertion fails
        WORKTREE_NAME=$(basename "$RGATE_TMP")
        echo "/tmp/lockpick-test-artifacts-${WORKTREE_NAME}"
    fi
) 2>/dev/null

OLD_PREFIX_FOUND_RGATE="no"
if [[ "$DETECTED_DIR" == *lockpick-test-artifacts* ]]; then
    OLD_PREFIX_FOUND_RGATE="yes"
fi

assert_eq \
    "test_review_gate_uses_workflow_plugin_artifact_dir: ARTIFACTS_DIR does not use lockpick-test-artifacts" \
    "no" \
    "$OLD_PREFIX_FOUND_RGATE"

print_summary
