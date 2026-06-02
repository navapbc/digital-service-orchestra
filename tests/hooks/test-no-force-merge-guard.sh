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
# Quoting the flag does NOT evade the guard — shlex unquotes `"--admin"` back to
# a real token, so the override is still a real invocation (the under-block hole).
_expect block 'gh pr merge 1 "--admin" --merge'               "real_invocation_quoted_flag"
_expect block "gh pr merge 1 '--admin' --merge"               "real_invocation_single_quoted_flag"
# Invocation hidden behind eval / bash -c is still a real invocation.
_expect block 'eval "gh pr merge 9 --admin --merge"'          "real_invocation_via_eval"
_expect block 'bash -c "gh pr merge 9 --admin --merge"'       "real_invocation_via_bash_c"
# Real invocation on a non-first line of a multi-line script (not anchored at
# token 0) must still BLOCK.
_REAL_MULTILINE=$'echo start\ngh pr merge 5 --admin --merge'
_expect block "$_REAL_MULTILINE"                              "real_invocation_second_line"
# Command-position bypass class: gh shifted off token 0 by a wrapper, an
# absolute path, a subshell, or command substitution must still BLOCK.
_expect block "command gh pr merge 9 --admin --merge"         "real_invocation_command_wrapper"
_expect block "/usr/bin/gh pr merge 9 --admin --merge"        "real_invocation_absolute_path"
_expect block "env gh pr merge 9 --admin --merge"             "real_invocation_env_wrapper"
_expect block "timeout 60 gh pr merge 9 --admin --merge"      "real_invocation_timeout_wrapper"
_expect block "(gh pr merge 9 --admin --merge)"               "real_invocation_subshell"
# shellcheck disable=SC2016  # literal command-substitution string under test (no expansion wanted)
_expect block 'x=$(gh pr merge 9 --admin --merge)'            "real_invocation_command_substitution"
_expect block "if true; then gh pr merge 9 --admin --merge; fi" "real_invocation_compound"
# shellcheck disable=SC2016  # literal backtick command-substitution string under test
_expect block 'x=`gh pr merge 9 --admin --merge`'             "real_invocation_backticks"
_expect block "cat <(gh pr merge 9 --admin --merge)"          "real_invocation_process_substitution"
# Backslash-newline line continuation: the shell collapses `\`+newline, so these
# run as one admin override and must BLOCK (shlex does not collapse them itself).
_CONT_FLAG=$'gh pr merge 546 \\\n  --admin --merge'
_expect block "$_CONT_FLAG"                                   "real_invocation_continuation_before_flag"
_CONT_NOSPACE=$'gh pr merge 9 \\\n--admin'
_expect block "$_CONT_NOSPACE"                                "real_invocation_continuation_no_space"
_CONT_SUBCMD=$'gh pr \\\nmerge 546 --admin'
_expect block "$_CONT_SUBCMD"                                 "real_invocation_continuation_in_subcommand"
# Whitespace / quoted-subcommand normalization (pre-filter must not drop these).
_expect block "gh  pr  merge 9 --admin --merge"               "real_invocation_double_space"
_expect block 'gh "pr" merge 9 --admin --merge'               "real_invocation_quoted_subcommand"

# --- ALLOW: mere mentions of the literal (the false-positive class) ---
_expect allow 'grep -n "Use gh pr merge --admin here" file.md'        "mention_in_grep_pattern"
_expect allow 'git commit -m "doc: explain gh pr merge --admin path"' "mention_in_commit_message"
_expect allow 'echo "gh pr merge --admin"'                            "mention_in_echo"
# Heredoc body mention (the real failure that motivated this fix):
_HEREDOC=$'git commit -F - <<\'EOF\'\nnote: so gh pr merge --admin from the agent fails\nEOF'
_expect allow "$_HEREDOC"                                             "mention_in_heredoc_body"
# Heredoc delimiters with a hyphen or dot must also strip the body — the prior
# `\w+` delimiter regex missed these, over-blocking the mention (blocking finding).
_HEREDOC_HYPHEN=$'cat <<MY-DELIM\ngh pr merge 5 --admin --merge\nMY-DELIM'
_expect allow "$_HEREDOC_HYPHEN"                                     "mention_in_heredoc_hyphen_delim"
_HEREDOC_DOT=$'cat <<DELIM.v1\ngh pr merge 5 --admin --merge\nDELIM.v1'
_expect allow "$_HEREDOC_DOT"                                        "mention_in_heredoc_dot_delim"
# `gh pr merge` WITHOUT --admin is not an admin override (e.g. fp-recovery's
# `--disable-auto`) — must ALLOW.
_expect allow "gh pr merge 553 --disable-auto"                       "gh_pr_merge_without_admin"
# Heredoc delimiter ending in punctuation: the line-position close anchor strips
# the body (a `\b` word-boundary anchor would not), so the mention is ALLOWED.
_HEREDOC_PUNCT=$'cat <<DELIM.\ngh pr merge 5 --admin --merge\nDELIM.'
_expect allow "$_HEREDOC_PUNCT"                                     "mention_in_heredoc_punct_delim"
# Unrelated commands are unaffected.
_expect allow "ls -la && echo done"                                   "unrelated_command"

# --- Fallback path: python3 / detect-admin-merge.py unavailable ---
# _admin_merge_fallback is the degraded detector. It must still BLOCK on the
# --admin literal but ALLOW non-admin merges so the everyday workflow (and the
# fp-recovery --disable-auto command) is not broken when python3 is absent.
_expect_fallback() {
    local expected="$1" cmd="$2" label="$3"
    _snapshot_fail
    local got="allow"
    if _admin_merge_fallback "$cmd"; then got="block"; fi
    assert_eq "$label" "$expected" "$got"
    assert_pass_if_clean "$label"
}
_expect_fallback block "gh pr merge 5 --admin --merge"   "fallback_blocks_admin"
_expect_fallback allow "gh pr merge 5 --disable-auto"    "fallback_allows_disable_auto"
_expect_fallback allow "gh pr merge 5 --auto --merge"    "fallback_allows_auto_merge"
_expect_fallback allow "gh pr merge 5 --merge"           "fallback_allows_plain_merge"

print_summary
