#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-session-push.sh
# merge-to-main.sh must push the session branch to origin when
# running from a session worktree (.git is a file, not a directory).
#
# Background: CI's per-story review job fetches origin/${SPRINT_SESSION_ID}
# to compute per-story deltas. If the session branch is missing from origin,
# CI fails with "fatal: couldn't find remote ref <session-branch>".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

_write_config() {
    local cfg_file="$1" strategy="$2"
    mkdir -p "$(dirname "$cfg_file")"
    printf 'merge.strategy=%s\nci.workflow_name=test-ci\n' "$strategy" > "$cfg_file"
}

# ---------------------------------------------------------------------------
# test_session_worktree_pushes_session_branch

# ---------------------------------------------------------------------------
test_session_worktree_pushes_session_branch() {
    local _T _push_log
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-session-push-test.XXXXXX")"
    _push_log="$_T/git-push.log"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    touch "$_push_log"

    local bin_dir="$_T/bin"
    mkdir -p "$bin_dir"

    # Git stub: record push calls; return fake session branch for --show-current.
    # Must handle both `git push` and `git -C <dir> push` forms.
    cat > "$bin_dir/git" <<GSTUB
#!/usr/bin/env bash
args=("\$@")
# Strip leading -C <dir> to inspect the subcommand
if [[ "\${args[0]:-}" == "-C" ]]; then
    subcmd="\${args[2]:-}"
else
    subcmd="\${args[0]:-}"
fi
if [[ "\$subcmd" == "push" ]]; then
    echo "git \$*" >> "$_push_log"
    exit 0
elif [[ "\$subcmd" == "branch" ]]; then
    echo "worktree-20260514-session-test"
    exit 0
elif [[ "\${args[0]:-}" == "-C" ]]; then
    shift; dir="\$1"; shift
    exec /usr/bin/git -C "\$dir" "\$@"
else
    exec /usr/bin/git "\$@"
fi
GSTUB
    chmod +x "$bin_dir/git"

    # Simulate session worktree: .git is a file (not a directory)
    printf 'gitdir: /nonexistent/.git/worktrees/test\n' > "$_T/.git"

    # Strategy stub: exits 0 so we can examine what happened before exec
    cat > "$bin_dir/merge-to-main-direct.sh" <<'SSTUB'
#!/usr/bin/env bash
exit 0
SSTUB
    chmod +x "$bin_dir/merge-to-main-direct.sh"

    _write_config "$_T/.claude/dso-config.conf" "direct"

    local merge_exit=0
    PATH="$bin_dir:$PATH" \
    PROJECT_ROOT="$_T" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$MERGE_SCRIPT" 2>/dev/null || merge_exit=$?
    assert_eq "session worktree: merge-to-main exits 0" "0" "$merge_exit"

    local push_count
    push_count="$(wc -l < "$_push_log" | tr -d ' ')"
    assert_eq "session worktree: at least 1 git push call" "true" \
        "$([[ "$push_count" -ge 1 ]] && echo true || echo false)"

    local branch_match
    branch_match="$(grep -l "worktree-20260514-session-test" "$_push_log" 2>/dev/null || true)"
    assert_eq "session branch name present in push args" "true" \
        "$([[ -n "$branch_match" ]] && echo true || echo false)"
}

# ---------------------------------------------------------------------------
# test_non_session_worktree_no_extra_push
# GREEN/REGRESSION: standard worktree (.git is a directory) must not trigger
# the extra session-branch push.
# ---------------------------------------------------------------------------
test_non_session_worktree_no_extra_push() {
    local _T _push_log
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-session-push-test.XXXXXX")"
    _push_log="$_T/git-push.log"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    touch "$_push_log"

    local bin_dir="$_T/bin"
    mkdir -p "$bin_dir"

    cat > "$bin_dir/git" <<GSTUB
#!/usr/bin/env bash
args=("\$@")
if [[ "\${args[0]:-}" == "-C" ]]; then
    subcmd="\${args[2]:-}"
else
    subcmd="\${args[0]:-}"
fi
if [[ "\$subcmd" == "push" ]]; then
    echo "git \$*" >> "$_push_log"
    exit 0
elif [[ "\${args[0]:-}" == "-C" ]]; then
    shift; dir="\$1"; shift
    exec /usr/bin/git -C "\$dir" "\$@"
else
    exec /usr/bin/git "\$@"
fi
GSTUB
    chmod +x "$bin_dir/git"

    # Standard worktree: .git is a directory
    mkdir -p "$_T/.git"

    cat > "$bin_dir/merge-to-main-direct.sh" <<'SSTUB'
#!/usr/bin/env bash
exit 0
SSTUB
    chmod +x "$bin_dir/merge-to-main-direct.sh"

    _write_config "$_T/.claude/dso-config.conf" "direct"

    local merge_exit=0
    PATH="$bin_dir:$PATH" \
    PROJECT_ROOT="$_T" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$MERGE_SCRIPT" 2>/dev/null || merge_exit=$?
    assert_eq "non-session worktree: merge-to-main exits 0" "0" "$merge_exit"

    local push_count
    push_count="$(wc -l < "$_push_log" | tr -d ' ')"
    assert_eq "non-session worktree: no session-branch push" "0" "$push_count"
}

test_session_worktree_pushes_session_branch
test_non_session_worktree_no_extra_push

print_summary
