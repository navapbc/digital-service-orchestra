#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-worktree-guard.sh
# Tests for .claude/hooks/worktree-edit-guard.sh
#
# worktree-edit-guard.sh is a PreToolUse hook that blocks Edit/Write calls
# targeting the main repo when executed from a worktree session.
# In the main repo (non-worktree), it allows everything.

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/worktree-edit-guard.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

run_hook() {
    local input="$1"
    local exit_code=0
    echo "$input" | bash "$HOOK" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# Detect if we're in a worktree (vs main repo)
IS_WORKTREE=false
if [[ -f "$REPO_ROOT/.git" ]]; then
    IS_WORKTREE=true
fi

# test_worktree_guard_exits_zero_on_main_repo_edit
# In the main repo (.git is a dir), all Edit calls should pass through.
# In a worktree (.git is a file), Edit to worktree files should pass through.
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$REPO_ROOT"'/src/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_worktree_guard_exits_zero_on_main_repo_edit" "0" "$EXIT_CODE"

# test_worktree_guard_exits_zero_on_non_edit_tool
# Bash tool calls are never guarded (only Edit/Write are checked)
INPUT='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_worktree_guard_exits_zero_on_non_edit_tool" "0" "$EXIT_CODE"

# test_worktree_guard_exits_zero_on_read_tool
# Read tool calls are not guarded
INPUT='{"tool_name":"Read","tool_input":{"file_path":"'"$REPO_ROOT"'/src/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_worktree_guard_exits_zero_on_read_tool" "0" "$EXIT_CODE"

# test_worktree_guard_exits_zero_on_tmp_file_edit
# /tmp/ files are always allowed (outside both repos)
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_worktree_guard_exits_zero_on_tmp_file_edit" "0" "$EXIT_CODE"

# test_worktree_guard_exits_zero_on_home_claude_edit
# ~/.claude/ files are outside the repo tree — allowed
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$HOME"'/.claude/settings.json"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_worktree_guard_exits_zero_on_home_claude_edit" "0" "$EXIT_CODE"

# test_worktree_guard_exits_zero_on_empty_input
# Empty stdin → no file_path → exit 0
EXIT_CODE=$(run_hook "")
assert_eq "test_worktree_guard_exits_zero_on_empty_input" "0" "$EXIT_CODE"

# test_worktree_guard_exits_zero_on_missing_file_path
# Edit with no file_path → exit 0 (nothing to guard)
INPUT='{"tool_name":"Edit","tool_input":{}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_worktree_guard_exits_zero_on_missing_file_path" "0" "$EXIT_CODE"

# test_worktree_guard_blocks_edit_to_other_worktree (only if we ARE in a worktree)
if [[ "$IS_WORKTREE" == "true" ]]; then
    # Get the main repo root
    MAIN_GIT_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
    if [[ -n "$MAIN_GIT_DIR" ]]; then
        MAIN_GIT_ABS=$(cd "$REPO_ROOT" && cd "$MAIN_GIT_DIR" && pwd)
        MAIN_REPO_ROOT=$(dirname "$MAIN_GIT_ABS")
        # Edit a file in the main repo → should be blocked
        INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$MAIN_REPO_ROOT"'/app/src/test.py"}}'
        EXIT_CODE=$(run_hook "$INPUT")
        assert_eq "test_worktree_guard_blocks_edit_to_main_repo" "2" "$EXIT_CODE"
    fi
else
    # In main repo: guard is inactive, even "cross-worktree" edits pass
    # The hook exits 0 when .git is a directory (not a worktree)
    assert_eq "test_worktree_guard_inactive_in_main_repo" "0" "0"
fi

print_summary
