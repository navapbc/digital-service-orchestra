#!/usr/bin/env bash
# tests/hooks/test-no-force-merge-guard.sh
#
# The `--admin` force-merge guard (pre-bash-functions.sh hook_no_force_merge)
# must distinguish an actual `gh pr merge ... --admin` INVOCATION (block — it
# overrides branch protection) from a mere MENTION of the literal inside a
# quoted argument, a commit message, or a heredoc body (allow). The prior
# substring match (`*"gh pr merge"*"--admin"*`) over-fired on mentions and
# blocked legitimate commands (a grep whose pattern contained the string, a
# commit message that referenced it). This test pins both directions:
#   - real invocations still BLOCK (the safety function must not regress), and
#   - mentions ALLOW (the false-positive class being fixed).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/dso/hooks/lib/pre-bash-functions.sh"

echo "=== test-no-force-merge-guard.sh ==="

# _expect <block|allow> <command> <label>
_expect() {
    local expected="$1" cmd="$2" label="$3"
    _snapshot_fail
    local got="allow"
    if _is_admin_merge_invocation "$cmd"; then got="block"; fi
    assert_eq "$label" "$expected" "$got"
    assert_pass_if_clean "$label"
}

# --- BLOCK: genuine admin-override invocations (must not regress) ---
_expect block "gh pr merge 546 --admin --merge"               "real_invocation_basic"
_expect block "gh pr merge 546 --merge --admin"               "real_invocation_flag_last"
# shellcheck disable=SC2016  # intentional literal command string under test (no expansion wanted)
_expect block 'X=1 GH_TOKEN="$(cat tok)" gh pr merge 546 --admin --merge' "real_invocation_spaced_env_prefix"
_expect block "git fetch && gh pr merge 7 --admin --squash"   "real_invocation_after_separator"

# --- ALLOW: mere mentions of the literal (the false-positive class) ---
_expect allow 'grep -n "Use gh pr merge --admin here" file.md'        "mention_in_grep_pattern"
_expect allow 'git commit -m "doc: explain gh pr merge --admin path"' "mention_in_commit_message"
_expect allow 'echo "gh pr merge --admin"'                            "mention_in_echo"
# Heredoc body mention (the real failure that motivated this fix):
_HEREDOC=$'git commit -F - <<\'EOF\'\nnote: so gh pr merge --admin from the agent fails\nEOF'
_expect allow "$_HEREDOC"                                             "mention_in_heredoc_body"
# Unrelated commands are unaffected.
_expect allow "ls -la && echo done"                                   "unrelated_command"

print_summary
