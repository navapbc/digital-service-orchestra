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

# Validate test dependencies up front so a missing file or failed source surfaces
# with a clear message instead of a confusing command-not-found mid-suite.
for _dep in "$REPO_ROOT/tests/lib/assert.sh" "$REPO_ROOT/plugins/dso/hooks/lib/pre-bash-functions.sh"; do
    [ -r "$_dep" ] || { echo "FATAL: required test dependency not found: $_dep" >&2; exit 1; }
done

source "$REPO_ROOT/tests/lib/assert.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/dso/hooks/lib/pre-bash-functions.sh"

# Confirm the sourced units actually exposed the functions under test.
for _fn in _is_admin_merge_invocation _admin_merge_fallback hook_no_force_merge assert_eq; do
    command -v "$_fn" >/dev/null 2>&1 || { echo "FATAL: expected function '$_fn' not defined after sourcing dependencies" >&2; exit 1; }
done
# python3 backs the structural detector and the _expect_py cases below. The suite
# genuinely requires it — fail loudly rather than emit a confusing error mid-run.
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required for this suite (structural detector + _expect_py cases)" >&2; exit 1; }

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
# Documented degradation (pinned by design): without python3, the substring
# fallback over-blocks a bare --admin MENTION that co-occurs with a non-admin gh
# merge. This is the accepted, fail-closed cost of the degraded path — python3 is
# a hard dependency of the DSO toolchain, so this path is effectively never hit in
# practice. Pinning it documents the known scope limit rather than masking it.
_expect_fallback block 'echo "note: --admin is blocked" && gh pr merge 5 --auto' "fallback_overblocks_admin_mention_by_design"

# --- Standalone detector unit coverage (drive detect-admin-merge.py directly) ---
# The cases above exercise the detector through the bash wrapper. These assert the
# python module's own error-recovery and recursion paths and its fail-closed
# EXIT CODES directly (0 = block/invocation, 1 = allow/mention), so a regression
# in the ValueError handler, eval/bash -c recursion, depth cap, or bare-exception
# fallback is caught even when the wrapper path masks it.
DETECT_PY="$REPO_ROOT/plugins/dso/hooks/lib/detect-admin-merge.py"
# _expect_py <expected_exit:0|1> <command> <label>
_expect_py() {
    local expected="$1" cmd="$2" label="$3"
    _snapshot_fail
    printf '%s' "$cmd" | python3 "$DETECT_PY"
    local rc=$?
    assert_eq "$label" "$expected" "$rc"
    assert_pass_if_clean "$label"
}
_expect_py 0 "gh pr merge 5 --admin --merge"               "py_block_basic"
_expect_py 1 'git commit -m "see gh pr merge --admin doc"' "py_allow_mention"
# Fail-closed: unbalanced quotes make shlex raise ValueError -> exit 0 (block).
_expect_py 0 'gh pr merge 5 --admin "unterminated'         "py_failclosed_unbalanced_quotes"
# Recursion paths: eval / bash -c payloads are recursed into and still detected.
_expect_py 0 'eval "gh pr merge 5 --admin"'                "py_block_eval_recursion"
_expect_py 0 'bash -c "gh pr merge 5 --admin --merge"'     "py_block_bashc_recursion"
# Depth cap: nesting beyond _MAX_DEPTH fails closed (exit 0), never a traceback.
_DEEP_NEST="gh pr merge 5 --admin"
for _i in 1 2 3 4 5 6 7; do _DEEP_NEST="eval $(printf '%q' "$_DEEP_NEST")"; done
_expect_py 0 "$_DEEP_NEST"                                  "py_failclosed_depth_cap"
# Exit code is ALWAYS bounded to {0,1} — the bare-exception fallback must never
# leak a non-zero traceback exit for a pathological input.
_snapshot_fail
printf '%s' 'gh pr merge 5 --admin `unbalanced backtick' | python3 "$DETECT_PY"; _BOUND_RC=$?
assert_eq "py_exit_code_bounded" "true" "$([ "$_BOUND_RC" = "0" ] || [ "$_BOUND_RC" = "1" ] && echo true || echo false)"
assert_pass_if_clean "py_exit_code_bounded"

# --- End-to-end hook coverage: hook_no_force_merge() with real JSON tool-input ---
# The cases above test the detector helpers in isolation. These exercise the
# actual PreToolUse entry point end-to-end — JSON parsing, the Bash-tool guard,
# the DSO_FP_RECOVERY_ACTIVE bypass, and the block return code (2) — so a
# regression in the hook's wiring (not just its helpers) is caught.
# _expect_hook <expected_rc> <command> <fp_active:0|1> <label>
_expect_hook() {
    local expected="$1" cmd="$2" fp="$3" label="$4"
    _snapshot_fail
    local input rc
    input=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
    DSO_FP_RECOVERY_ACTIVE="$fp" hook_no_force_merge "$input" >/dev/null 2>&1; rc=$?
    assert_eq "$label" "$expected" "$rc"
    assert_pass_if_clean "$label"
}
# Real admin override with no FP-recovery active -> BLOCK (return 2).
_expect_hook 2 "gh pr merge 5 --admin --merge"           0 "hook_blocks_admin_invocation"
# Same command under an active FP-recovery session -> bypass (return 0).
_expect_hook 0 "gh pr merge 5 --admin --merge"           1 "hook_bypass_when_fp_recovery_active"
# A mere mention of the literal -> allow (return 0).
_expect_hook 0 'git commit -m "doc: gh pr merge --admin"' 0 "hook_allows_mention"
# A non-admin merge -> allow (return 0).
_expect_hook 0 "gh pr merge 5 --auto --merge"            0 "hook_allows_non_admin_merge"
# A non-Bash tool call is ignored even if the payload names the flag -> allow.
_snapshot_fail
hook_no_force_merge '{"tool_name":"Edit","tool_input":{"command":"gh pr merge 5 --admin"}}' >/dev/null 2>&1
assert_eq "hook_ignores_non_bash_tool" "0" "$?"
assert_pass_if_clean "hook_ignores_non_bash_tool"

print_summary
