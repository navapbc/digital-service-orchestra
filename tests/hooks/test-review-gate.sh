#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-review-gate.sh
# Tests for .claude/hooks/review-gate.sh
#
# review-gate.sh is a PreToolUse HARD GATE hook (Bash matcher) that blocks
# git commit if code review hasn't passed for the current diff state.

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/review-gate.sh"
_OLD_CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"

# Use an isolated temp directory so tests don't clobber production artifacts.
# Export WORKFLOW_PLUGIN_ARTIFACTS_DIR so get_artifacts_dir() returns this dir
# instead of the real one. Without this, test runs corrupt the real review-status
# file (blocking all commits) and stage dummy files in the real repo.
_TEST_ARTIFACTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-review-gate-XXXXXX")
export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST_ARTIFACTS_DIR"
# Note: EXIT trap is set after RGATE_TMP is created (see cleanup_all below).

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
# Clean up at test start to ensure isolated state (not just on EXIT trap).
rm -f "$REVIEW_STATE"

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

# Clean up test state (isolated dir — no restore needed since we own this temp dir)
rm -f "$REVIEW_STATE"

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
cleanup_all() {
    rm -rf "$RGATE_TMP" 2>/dev/null || true
    rm -rf "$_TEST_ARTIFACTS_DIR" 2>/dev/null || true
}
trap cleanup_all EXIT

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

# ============================================================
# test_review_gate_mismatch_writes_diagnostic_dump
#
# When hook_review_gate() detects a hash mismatch, it should write a
# diagnostic dump file to $ARTIFACTS_DIR/mismatch-diagnostics-*.log
# before returning exit 2.
#
# ISOLATION: Uses a temp git repo so no files are staged in the real repo.
# ============================================================

# Source pre-bash-functions.sh to get hook_review_gate()
source "$REPO_ROOT/lockpick-workflow/hooks/lib/pre-bash-functions.sh"

# Create isolated temp git repo for mismatch tests
_DIAG_TMPDIR=$(mktemp -d)
_DIAG_ARTIFACTS=$(mktemp -d)
_MISMATCH_CLEANUP_DIRS=("$_DIAG_TMPDIR" "$_DIAG_ARTIFACTS")
(
    cd "$_DIAG_TMPDIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "initial"
) 2>/dev/null

# Run the mismatch diagnostic test in the isolated repo
_DIAG_REVIEW_STATE="$_DIAG_ARTIFACTS/review-status"
mkdir -p "$_DIAG_ARTIFACTS"
printf "passed\ntimestamp=2026-01-01T00:00:00Z\ndiff_hash=FAKE_HASH_WILL_NOT_MATCH\nreview_hash=xyz\n" > "$_DIAG_REVIEW_STATE"

# Stage a dummy file in the isolated repo
echo "dummy" > "$_DIAG_TMPDIR/dummy.txt"
git -C "$_DIAG_TMPDIR" add dummy.txt 2>/dev/null

INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"feat: trigger mismatch\""}}'
_DIAG_EXIT=0
(
    cd "$_DIAG_TMPDIR"
    # Use WORKFLOW_PLUGIN_ARTIFACTS_DIR so get_artifacts_dir() returns the isolated dir.
    # Export ARTIFACTS_DIR directly so hook_review_gate uses it (avoids inheriting outer
    # ARTIFACTS_DIR which points to _TEST_ARTIFACTS_DIR, blocking at "no review recorded").
    # Set _DEPS_LOADED=1 to skip full deps.sh reload; export hash_stdin, check_tool, and
    # get_artifacts_dir so compute-diff-hash.sh subprocess has them without reloading deps.sh.
    # get_artifacts_dir reads WORKFLOW_PLUGIN_ARTIFACTS_DIR (an env var, always available).
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_DIAG_ARTIFACTS"
    export ARTIFACTS_DIR="$_DIAG_ARTIFACTS"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"
    export _DEPS_LOADED=1
    get_artifacts_dir() { mkdir -p "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}"; echo "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}"; }
    export -f get_artifacts_dir hash_stdin check_tool 2>/dev/null || true
    hook_review_gate "$INPUT" 2>/dev/null
) || _DIAG_EXIT=$?

assert_eq "test_review_gate_mismatch_writes_diagnostic_dump: exit code" "2" "$_DIAG_EXIT"

# Check that a mismatch-diagnostics file was created
_DIAG_FILES=( "$_DIAG_ARTIFACTS"/mismatch-diagnostics-*.log )
_DIAG_FOUND="no"
if [[ -f "${_DIAG_FILES[0]}" ]]; then
    _DIAG_FOUND="yes"
fi
assert_eq "test_review_gate_mismatch_writes_diagnostic_dump: dump file exists" "yes" "$_DIAG_FOUND"

# Check that all required fields are present in the dump
if [[ "$_DIAG_FOUND" == "yes" ]]; then
    _DIAG_CONTENT=$(cat "${_DIAG_FILES[0]}")
    assert_contains "test_review_gate_mismatch_writes_diagnostic_dump: has recorded_hash" "recorded_hash=" "$_DIAG_CONTENT"
    assert_contains "test_review_gate_mismatch_writes_diagnostic_dump: has current_hash" "current_hash=" "$_DIAG_CONTENT"
    assert_contains "test_review_gate_mismatch_writes_diagnostic_dump: has git_status" "git_status=" "$_DIAG_CONTENT"
    assert_contains "test_review_gate_mismatch_writes_diagnostic_dump: has git_diff_names" "git_diff_names=" "$_DIAG_CONTENT"
    assert_contains "test_review_gate_mismatch_writes_diagnostic_dump: has untracked_files" "untracked_files=" "$_DIAG_CONTENT"
    assert_contains "test_review_gate_mismatch_writes_diagnostic_dump: has breadcrumb_log" "breadcrumb_log=" "$_DIAG_CONTENT"
fi

# ============================================================
# test_synthetic_mismatch_produces_complete_diagnostic_dump
#
# Validates that each field in the diagnostic dump has a non-empty value
# (not just the key= prefix with nothing after it).
#
# ISOLATION: Uses a temp git repo so no files are staged in the real repo.
# ============================================================

# Create a second isolated temp git repo
_SYNTH_TMPDIR=$(mktemp -d)
_SYNTH_ARTIFACTS=$(mktemp -d)
_MISMATCH_CLEANUP_DIRS+=("$_SYNTH_TMPDIR" "$_SYNTH_ARTIFACTS")
(
    cd "$_SYNTH_TMPDIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "initial"
) 2>/dev/null

_SYNTH_REVIEW_STATE="$_SYNTH_ARTIFACTS/review-status"
mkdir -p "$_SYNTH_ARTIFACTS"
printf "passed\ntimestamp=2026-02-15T12:30:00Z\ndiff_hash=SYNTHETIC_MISMATCH_HASH\nreview_hash=abc\n" > "$_SYNTH_REVIEW_STATE"

# Stage a dummy file in the isolated repo
echo "synthetic" > "$_SYNTH_TMPDIR/synth.txt"
git -C "$_SYNTH_TMPDIR" add synth.txt 2>/dev/null

INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"feat: synthetic mismatch\""}}'
_SYNTH_EXIT=0
(
    cd "$_SYNTH_TMPDIR"
    # Use WORKFLOW_PLUGIN_ARTIFACTS_DIR so get_artifacts_dir() returns the isolated dir.
    # Export ARTIFACTS_DIR directly so hook_review_gate uses it (avoids inheriting outer
    # ARTIFACTS_DIR which points to _TEST_ARTIFACTS_DIR, blocking at "no review recorded").
    # Set _DEPS_LOADED=1 to skip full deps.sh reload; export hash_stdin, check_tool, and
    # get_artifacts_dir so compute-diff-hash.sh subprocess has them without reloading deps.sh.
    # get_artifacts_dir reads WORKFLOW_PLUGIN_ARTIFACTS_DIR (an env var, always available).
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_SYNTH_ARTIFACTS"
    export ARTIFACTS_DIR="$_SYNTH_ARTIFACTS"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"
    export _DEPS_LOADED=1
    get_artifacts_dir() { mkdir -p "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}"; echo "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}"; }
    export -f get_artifacts_dir hash_stdin check_tool 2>/dev/null || true
    hook_review_gate "$INPUT" 2>/dev/null
) || _SYNTH_EXIT=$?

assert_eq "test_synthetic_mismatch_produces_complete_diagnostic_dump: exit code" "2" "$_SYNTH_EXIT"

_SYNTH_FILES=( "$_SYNTH_ARTIFACTS"/mismatch-diagnostics-*.log )
_SYNTH_FOUND="no"
if [[ -f "${_SYNTH_FILES[0]}" ]]; then
    _SYNTH_FOUND="yes"
fi
assert_eq "test_synthetic_mismatch_produces_complete_diagnostic_dump: dump file exists" "yes" "$_SYNTH_FOUND"

if [[ "$_SYNTH_FOUND" == "yes" ]]; then
    _SYNTH_CONTENT=$(cat "${_SYNTH_FILES[0]}")

    # Each field must have a non-empty value after the = sign
    _check_nonempty_field() {
        local label="$1" field="$2" content="$3"
        local value
        value=$(echo "$content" | grep "^${field}=" | head -1 | cut -d= -f2-)
        if [[ -n "$value" ]]; then
            (( ++PASS ))
        else
            (( ++FAIL ))
            printf "FAIL: %s — field '%s' is empty or missing\n" "$label" "$field" >&2
        fi
    }

    _check_nonempty_field "test_synthetic: recorded_hash non-empty" "recorded_hash" "$_SYNTH_CONTENT"
    _check_nonempty_field "test_synthetic: current_hash non-empty" "current_hash" "$_SYNTH_CONTENT"
    _check_nonempty_field "test_synthetic: timestamp non-empty" "timestamp" "$_SYNTH_CONTENT"
    _check_nonempty_field "test_synthetic: review_timestamp non-empty" "review_timestamp" "$_SYNTH_CONTENT"
    # git_status may legitimately be empty if no changes, but we staged a file so it should have content
    _check_nonempty_field "test_synthetic: git_status non-empty" "git_status" "$_SYNTH_CONTENT"
    # breadcrumb_log can be "NOT FOUND" which is still non-empty
    _check_nonempty_field "test_synthetic: breadcrumb_log non-empty" "breadcrumb_log" "$_SYNTH_CONTENT"
fi

# Clean up all temp dirs from mismatch tests
for _dir in "${_MISMATCH_CLEANUP_DIRS[@]}"; do
    rm -rf "$_dir" 2>/dev/null || true
done

# Restore exported variables
if [[ -n "$_OLD_CLAUDE_PLUGIN_ROOT" ]]; then
    export CLAUDE_PLUGIN_ROOT="$_OLD_CLAUDE_PLUGIN_ROOT"
else
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
fi

print_summary
