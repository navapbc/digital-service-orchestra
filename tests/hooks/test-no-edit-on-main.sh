#!/usr/bin/env bash
# tests/hooks/test-no-edit-on-main.sh
# Tests for hook_no_edit_on_main in pre-bash-functions.sh.
#
# The hook blocks Edit/Write/MultiEdit on tracked files when HEAD is on the
# default branch (main/master) in the PRIMARY checkout. Linked worktrees fall
# through (hook_worktree_edit_guard owns that direction).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Build a disposable git repo on disk where we can flip branches at will.
TMP_REPO=$(mktemp -d "${TMPDIR:-/tmp}/test-no-edit-on-main.XXXXXX")
trap 'rm -rf "$TMP_REPO"' EXIT

(
    cd "$TMP_REPO" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "Test"
    echo "v1" > VERSION
    git add VERSION
    git commit -q -m "init"
    git checkout -q -b feature/x
    git checkout -q main
)

# Invoke the hook function with a controlled CWD and clean env. The function
# is sourced from pre-bash-functions.sh; we exec a fresh bash for isolation.
run_hook() {
    local cwd="$1" input="$2"
    shift 2
    local exit_code=0
    (
        cd "$cwd" || return 1
        # Strip the escape envs by default; callers re-add via "$@"
        unset DSO_ALLOW_EDIT_ON_MAIN DSO_ALLOW_EDIT_ON_MAIN_REASON DSO_MECHANICAL_AMEND
        local kv
        for kv in "$@"; do
            # shellcheck disable=SC2163  # NAME=value form, export reads from string
            export "${kv?}"
        done
        bash -c "
            source '$DSO_PLUGIN_DIR/hooks/lib/pre-bash-functions.sh'
            hook_no_edit_on_main \"\$1\"
        " _ "$input"
    ) >/dev/null 2>&1 || exit_code=$?
    echo "$exit_code"
}

VERSION_PATH="$TMP_REPO/VERSION"

# Before the fix, hook_no_edit_on_main did not exist — this test would have
# failed to source. After the fix, all assertions below must pass.

# --- BLOCKING cases (return 2) ---

# Edit on main → block
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$VERSION_PATH"'"}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT")
assert_eq "blocks_edit_on_main" "2" "$EXIT"

# Write on main → block
INPUT='{"tool_name":"Write","tool_input":{"file_path":"'"$VERSION_PATH"'"}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT")
assert_eq "blocks_write_on_main" "2" "$EXIT"

# MultiEdit on main → block
INPUT='{"tool_name":"MultiEdit","tool_input":{"file_path":"'"$VERSION_PATH"'"}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT")
assert_eq "blocks_multiedit_on_main" "2" "$EXIT"

# DSO_ALLOW_EDIT_ON_MAIN=1 without REASON → still block
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$VERSION_PATH"'"}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT" DSO_ALLOW_EDIT_ON_MAIN=1)
assert_eq "blocks_when_bypass_without_reason" "2" "$EXIT"

# --- PASSTHROUGH cases (return 0) ---

# On feature branch → allow
(cd "$TMP_REPO" && git checkout -q feature/x)
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$VERSION_PATH"'"}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT")
assert_eq "allows_on_feature_branch" "0" "$EXIT"
(cd "$TMP_REPO" && git checkout -q main)

# DSO_ALLOW_EDIT_ON_MAIN=1 with REASON → allow
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$VERSION_PATH"'"}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT" DSO_ALLOW_EDIT_ON_MAIN=1 DSO_ALLOW_EDIT_ON_MAIN_REASON="legit reason")
assert_eq "allows_when_bypass_with_reason" "0" "$EXIT"

# DSO_MECHANICAL_AMEND=1 → allow (merge-to-main pipeline)
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$VERSION_PATH"'"}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT" DSO_MECHANICAL_AMEND=1)
assert_eq "allows_with_mechanical_amend" "0" "$EXIT"

# DSO_MERGE_TO_MAIN_PHASE=version_bump → allow (parallels bump-version.sh allowlist)
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$VERSION_PATH"'"}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT" DSO_MERGE_TO_MAIN_PHASE=version_bump)
assert_eq "allows_with_merge_to_main_phase_version_bump" "0" "$EXIT"

# DSO_MERGE_TO_MAIN_PHASE=other → block (only version_bump is allowlisted)
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$VERSION_PATH"'"}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT" DSO_MERGE_TO_MAIN_PHASE=other)
assert_eq "blocks_with_merge_to_main_phase_other" "2" "$EXIT"

# /tmp/ file → allow
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/foo.txt"}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT")
assert_eq "allows_tmp_file" "0" "$EXIT"

# $HOME/.claude/ file → allow
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$HOME"'/.claude/settings.json"}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT")
assert_eq "allows_home_claude_file" "0" "$EXIT"

# Non-Edit tool (Read) → allow
INPUT='{"tool_name":"Read","tool_input":{"file_path":"'"$VERSION_PATH"'"}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT")
assert_eq "allows_non_edit_tool" "0" "$EXIT"

# Missing file_path → allow
INPUT='{"tool_name":"Edit","tool_input":{}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT")
assert_eq "allows_missing_file_path" "0" "$EXIT"

# File outside the repo → allow
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/some/other/path"}}'
EXIT=$(run_hook "$TMP_REPO" "$INPUT")
assert_eq "allows_file_outside_repo" "0" "$EXIT"

# --- Linked worktree → falls through to allow (worktree-edit-guard owns it) ---
WORKTREE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-no-edit-on-main-wt.XXXXXX")
rm -rf "$WORKTREE_DIR"
# shellcheck disable=SC2015  # fallback when 'main' already has a worktree
(cd "$TMP_REPO" && git worktree add -q "$WORKTREE_DIR" main 2>/dev/null || git worktree add -q -B wt-main "$WORKTREE_DIR")
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$WORKTREE_DIR"'/VERSION"}}'
EXIT=$(run_hook "$WORKTREE_DIR" "$INPUT")
assert_eq "allows_in_linked_worktree" "0" "$EXIT"
(cd "$TMP_REPO" && git worktree remove -f "$WORKTREE_DIR" 2>/dev/null || true)

echo
print_summary
