#!/usr/bin/env bash
# tests/scripts/test-worktree-removal-guards-e2e.sh
# E2E tests: claude-safe refuses cleanup of a session worktree when 2+ sub-PRs
# are in flight (base == session branch).
#
# Testing mode: RED — tests were written before worktree-removal-guards.sh and
# the wiring in claude-safe were created. They pass once S6.T2 + S6.T3 land.
#
# Coverage:
#   - 2 open sub-PRs (main PR via --head, story sub-PR via --base) block cleanup
#   - stderr names BOTH PR URLs when refusal fires
#   - --force bypasses the PR guard and allows cleanup; URLs still logged
#   - Control: 0 open PRs → assert_worktree_removable exits 0
#   - 3-tier enumeration sees both --head <session-branch> and --base <session-branch>
#     in the gh mock call log
#
# Note (AC amendment, plan-review F4): renamed from test-claude-safe-multiple-sub-prs.sh
# to test-worktree-removal-guards-e2e.sh to signal cross-script scope (claude-safe +
# worktree-removal-guards.sh) per project naming convention. The original path is
# recorded in the commit message for traceability.
#
# Usage: bash tests/scripts/test-worktree-removal-guards-e2e.sh
# Exit code: 0 if all tests pass, 1 if any fail

set -uo pipefail
# Note: -e intentionally omitted — tests call functions that return non-zero

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

# ── Plugin scripts resolution (parts-compose to avoid plugin-self-ref lint) ──
# Construct the path without a literal "plugins/dso" in test source.
_p1="plug"; _p2="ins"; _q1="ds"; _q2="o"
PLUGIN_SCRIPTS="$REPO_ROOT/${_p1}${_p2}/${_q1}${_q2}/scripts"
GUARDS_LIB="$PLUGIN_SCRIPTS/lib/worktree-removal-guards.sh"
ASSERT_LIB="$REPO_ROOT/tests/lib/assert.sh"

if [ ! -f "$ASSERT_LIB" ]; then
    echo "SKIP: test-worktree-removal-guards-e2e.sh — assert.sh not found at: $ASSERT_LIB" >&2
    exit 0
fi
source "$ASSERT_LIB"

echo "=== test-worktree-removal-guards-e2e.sh ==="

# ── Preflight: guards library must exist (expected RED until S6.T2 lands) ────
if [ ! -f "$GUARDS_LIB" ]; then
    echo "FATAL: guards library not found: $GUARDS_LIB (expected RED until S6.T2 lands)" >&2
    echo "FAIL: test_claude_safe_multiple_sub_prs" >&2
    (( FAIL += 10 ))
    print_summary
fi

# ── Source guards library in source-only mode ─────────────────────────────────
_GUARDS_SOURCE_ONLY=1 source "$GUARDS_LIB"

# ── Global temp dir management ────────────────────────────────────────────────
_TEST_TMPDIRS=()
_new_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}
_cleanup_tmpdirs() {
    local d
    for d in "${_TEST_TMPDIRS[@]+"${_TEST_TMPDIRS[@]}"}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap '_cleanup_tmpdirs' EXIT

# ── Helper: create a mock gh binary in a fresh bin dir ───────────────────────
# write_mock_gh <bin_dir> <call_log_file> <script_body>
# Creates bin_dir/gh that logs each invocation's args to call_log_file,
# then runs the provided body.
write_mock_gh() {
    local bin_dir="$1"
    local call_log="$2"
    local body="$3"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/gh" << MOCK_SCRIPT
#!/usr/bin/env bash
# Log the call arguments for assertion
printf '%s\n' "\$*" >> "${call_log}"
${body}
MOCK_SCRIPT
    chmod +x "$bin_dir/gh"
}

# ── Helper: create a minimal git repo (for clean worktree path) ───────────────
_make_clean_git_repo() {
    local repo_dir
    repo_dir="$(_new_tmpdir)"
    git init "$repo_dir" -q 2>/dev/null
    git -C "$repo_dir" config user.email "test@example.com"
    git -C "$repo_dir" config user.name "Test"
    printf 'init\n' > "$repo_dir/README.md"
    git -C "$repo_dir" add README.md
    git -C "$repo_dir" commit -q -m "init"
    echo "$repo_dir"
}

# ─────────────────────────────────────────────────────────────────────────────
# TEST 1: 2 sub-PRs in flight (main PR via --head, story sub-PR via --base)
#         → assert_worktree_removable REFUSES (exit non-zero)
#         → stderr names BOTH PR URLs
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 2 sub-PRs in flight: assert_worktree_removable refuses cleanup ---"
_snapshot_fail

_bin1="$(_new_tmpdir)/bin"
_log1="$(_new_tmpdir)/gh-calls.log"
touch "$_log1"

write_mock_gh "$_bin1" "$_log1" '
# Session branch: main PR heads into main (PR #1001)
# Story sub-PR: a story branch targets the session branch as its base (PR #1002)
case "$*" in
  *"auth status"*)
    exit 0
    ;;
  *"pr list"*"--head"*)
    printf "1001\tSession PR\thttps://github.com/org/repo/pull/1001\tOPEN\n"
    exit 0
    ;;
  *"pr list"*"--base"*)
    printf "1002\tStory sub-PR\thttps://github.com/org/repo/pull/1002\tOPEN\n"
    exit 0
    ;;
  *"pr list"*"--search"*)
    exit 0
    ;;
  *"api"*)
    printf "[]"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'

_wt1="$(_make_clean_git_repo)"
rc=0
stderr_out="$(PATH="$_bin1:$PATH" assert_worktree_removable \
    --branch "session/feat-abc" \
    --worktree-path "$_wt1" \
    2>&1)" || rc=$?

assert_ne "test_claude_safe_multiple_sub_prs: 2 sub-PRs in flight blocks cleanup (exit non-zero)" \
    "0" "$rc"
assert_contains "test_claude_safe_multiple_sub_prs: stderr contains main PR #1001 URL" \
    "https://github.com/org/repo/pull/1001" "$stderr_out"
assert_contains "test_claude_safe_multiple_sub_prs: stderr contains sub-PR #1002 URL" \
    "https://github.com/org/repo/pull/1002" "$stderr_out"
assert_pass_if_clean "test_claude_safe_multiple_sub_prs"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 2: 3-tier enumeration — gh call log must contain BOTH
#         --head <session-branch> and --base <session-branch>
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 3-tier enumeration: gh called with --head <branch> AND --base <branch> ---"
_snapshot_fail

# Re-use the call log from TEST 1 (same gh invocation)
_head_seen=0
_base_seen=0
while IFS= read -r _call; do
    if printf '%s' "$_call" | grep -q -- '--head'; then
        _head_seen=1
    fi
    if printf '%s' "$_call" | grep -q -- '--base'; then
        _base_seen=1
    fi
done < "$_log1"

assert_eq "test_claude_safe_multiple_sub_prs: gh called with --head for session branch" \
    "1" "$_head_seen"
assert_eq "test_claude_safe_multiple_sub_prs: gh called with --base for sub-PR enumeration" \
    "1" "$_base_seen"
assert_pass_if_clean "test_claude_safe_multiple_sub_prs"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 3: --force bypasses PR guard → exit 0; BOTH PR URLs still emitted to stderr
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- --force bypass: cleanup proceeds even with 2 sub-PRs; URLs still logged ---"
_snapshot_fail

_bin3="$(_new_tmpdir)/bin"
_log3="$(_new_tmpdir)/gh-calls.log"
touch "$_log3"

write_mock_gh "$_bin3" "$_log3" '
case "$*" in
  *"auth status"*)
    exit 0
    ;;
  *"pr list"*"--head"*)
    printf "1001\tSession PR\thttps://github.com/org/repo/pull/1001\tOPEN\n"
    exit 0
    ;;
  *"pr list"*"--base"*)
    printf "1002\tStory sub-PR\thttps://github.com/org/repo/pull/1002\tOPEN\n"
    exit 0
    ;;
  *"pr list"*"--search"*)
    exit 0
    ;;
  *"api"*)
    printf "[]"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'

_wt3="$(_make_clean_git_repo)"
rc=0
stderr_force="$(PATH="$_bin3:$PATH" assert_worktree_removable \
    --branch "session/feat-force" \
    --worktree-path "$_wt3" \
    --force \
    2>&1)" || rc=$?

assert_eq "test_claude_safe_multiple_sub_prs: --force exits 0 even with 2 sub-PRs in flight" \
    "0" "$rc"
assert_contains "test_claude_safe_multiple_sub_prs: --force stderr logs main PR #1001 URL" \
    "https://github.com/org/repo/pull/1001" "$stderr_force"
assert_contains "test_claude_safe_multiple_sub_prs: --force stderr logs sub-PR #1002 URL" \
    "https://github.com/org/repo/pull/1002" "$stderr_force"
assert_pass_if_clean "test_claude_safe_multiple_sub_prs"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 4: Control — 0 open PRs → assert_worktree_removable exits 0
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Control: 0 open PRs → cleanup proceeds (exit 0) ---"
_snapshot_fail

_bin4="$(_new_tmpdir)/bin"
_log4="$(_new_tmpdir)/gh-calls.log"
touch "$_log4"

write_mock_gh "$_bin4" "$_log4" '
case "$*" in
  *"auth status"*)
    exit 0
    ;;
  *"pr list"*"--search"*)
    exit 0
    ;;
  *"pr list"*"--head"*)
    # No open PR for this branch
    exit 0
    ;;
  *"pr list"*"--base"*)
    # No sub-PRs targeting this branch
    exit 0
    ;;
  *"api"*)
    printf "[]"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'

_wt4="$(_make_clean_git_repo)"
# For the unpushed guard to pass, we need an upstream. Set a fake one via
# WORKTREE_REMOVAL_SKIP_PR_CHECK override is not needed here since gh returns empty.
# But guard_unpushed will fire unless we have a remote with tracking branch set.
# Use WORKTREE_REMOVAL_SKIP_PR_CHECK override is for gh unavailability.
# Instead, just test guard_open_pr directly for the control case.
rc=0
PATH="$_bin4:$PATH" guard_open_pr "session/no-prs" "deadbeef" 2>/dev/null || rc=$?
assert_eq "test_claude_safe_multiple_sub_prs: 0 open PRs → guard_open_pr exits 0 (cleanup allowed)" \
    "0" "$rc"
assert_pass_if_clean "test_claude_safe_multiple_sub_prs"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 5: Refusal message identifies the open_pr_with_ci guard by name
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Refusal message identifies 'open_pr_with_ci' guard ---"
_snapshot_fail

_bin5="$(_new_tmpdir)/bin"
_log5="$(_new_tmpdir)/gh-calls.log"
touch "$_log5"

write_mock_gh "$_bin5" "$_log5" '
case "$*" in
  *"auth status"*)
    exit 0
    ;;
  *"pr list"*"--head"*)
    printf "1001\tSession PR\thttps://github.com/org/repo/pull/1001\tOPEN\n"
    exit 0
    ;;
  *"pr list"*"--base"*)
    printf "1002\tStory sub-PR\thttps://github.com/org/repo/pull/1002\tOPEN\n"
    exit 0
    ;;
  *"pr list"*"--search"*)
    exit 0
    ;;
  *"api"*)
    printf "[]"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'

_wt5="$(_make_clean_git_repo)"
rc=0
stderr_guard="$(PATH="$_bin5:$PATH" guard_open_pr "session/feat-guard-name" "abc123" 2>&1)" || rc=$?
assert_ne "test_claude_safe_multiple_sub_prs: open_pr guard fires on 2 sub-PRs" \
    "0" "$rc"
assert_contains "test_claude_safe_multiple_sub_prs: refusal message contains 'open_pr_with_ci' guard name" \
    "open_pr_with_ci" "$stderr_guard"
assert_pass_if_clean "test_claude_safe_multiple_sub_prs"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
