#!/usr/bin/env bash
# tests/scripts/test-worktree-removal-guards.sh
# RED unit tests for plugins/dso/scripts/lib/worktree-removal-guards.sh
#
# Coverage:
#   - Protected branch guard (main, master, develop, release/*)
#   - Uncommitted/unpushed guard
#   - Open-PR guard: 3-tier fallback chain (--head + --base enumeration)
#   - Sub-PR enumeration via --base <session-branch>
#   - --force bypass: guards run + emit URLs, but exit 0
#   - Protected branch NOT bypassable by --force
#   - gh unavailability fail-closed (3 modes)
#   - WORKTREE_REMOVAL_SKIP_PR_CHECK override: both vars required
#   - Worktree paths with spaces, unicode, leading dash
#
# Tests invoke the library via _GUARDS_SOURCE_ONLY=1 source, then call the
# exported functions directly. gh is mocked via PATH override (executable stub
# in a tmp bin dir prepended to PATH), so subprocess invocations are intercepted.
#
# Usage: bash tests/scripts/test-worktree-removal-guards.sh
# Exit code: 0 if all tests pass, 1 if any fail
#
# NOTE: This test file is intentionally RED — the library under test does not
# exist yet. All assertions will fail until T2 creates the library.

set -uo pipefail
# Note: set -e intentionally omitted — tests call functions that return non-zero

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
LIBRARY="$PLUGIN_ROOT/plugins/dso/scripts/lib/worktree-removal-guards.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-worktree-removal-guards.sh ==="

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
# write_mock_gh <bin_dir> <script_body>
# Creates bin_dir/gh as an executable with the given body.
write_mock_gh() {
    local bin_dir="$1"
    local body="$2"
    mkdir -p "$bin_dir"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$bin_dir/gh"
    chmod +x "$bin_dir/gh"
}

# ── Helper: create an isolated git repo for commit/push guard tests ───────────
# Returns path to the created repo in $1 (nameref) or via stdout
_make_isolated_git_repo() {
    local repo_dir
    repo_dir="$(_new_tmpdir)"
    git init "$repo_dir" -q 2>/dev/null
    git -C "$repo_dir" config user.email "test@example.com"
    git -C "$repo_dir" config user.name "Test"
    # Create initial commit so HEAD exists
    printf 'init\n' > "$repo_dir/README.md"
    git -C "$repo_dir" add README.md
    git -C "$repo_dir" commit -q -m "init"
    echo "$repo_dir"
}

# ── Source the library (source-only mode) ────────────────────────────────────
# The library must honour _GUARDS_SOURCE_ONLY=1 to skip any top-level
# invocation logic, analogous to _CLAUDE_SAFE_SOURCE_ONLY=1 in claude-safe.
_GUARDS_SOURCE_ONLY=1 source "$LIBRARY" 2>/dev/null || {
    echo "FATAL: cannot source $LIBRARY — library does not exist yet (expected RED)" >&2
    # Emit a parseable FAIL: <identifier> line so suite-engine can extract the
    # name and match it against the .test-index RED marker for tolerance.
    echo "FAIL: test_worktree_removal_guards" >&2
    # Increment FAIL for every test that would have run (~30 tests)
    FAIL=$((FAIL + 30))
    print_summary
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1: Protected-branch guard
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- protected_branch_guard: fires on main ---"
_snapshot_fail
rc=0
guard_protected_branch "main" 2>/dev/null || rc=$?
assert_ne "test_worktree_removal_guards: protected_branch_guard fires on main (non-zero exit)" \
    "0" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- protected_branch_guard: fires on master ---"
_snapshot_fail
rc=0
guard_protected_branch "master" 2>/dev/null || rc=$?
assert_ne "test_worktree_removal_guards: protected_branch_guard fires on master" \
    "0" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- protected_branch_guard: fires on develop ---"
_snapshot_fail
rc=0
guard_protected_branch "develop" 2>/dev/null || rc=$?
assert_ne "test_worktree_removal_guards: protected_branch_guard fires on develop" \
    "0" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- protected_branch_guard: fires on release/v1.2.3 ---"
_snapshot_fail
rc=0
guard_protected_branch "release/v1.2.3" 2>/dev/null || rc=$?
assert_ne "test_worktree_removal_guards: protected_branch_guard fires on release/v1.2.3" \
    "0" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- protected_branch_guard: does NOT fire on session branch ---"
_snapshot_fail
rc=0
guard_protected_branch "session/abc-123" 2>/dev/null || rc=$?
assert_eq "test_worktree_removal_guards: protected_branch_guard passes on session branch" \
    "0" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2: Uncommitted / unpushed guard
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- uncommitted_guard: fires on modified file ---"
_snapshot_fail
_repo="$(_make_isolated_git_repo)"
printf 'dirty\n' > "$_repo/dirty.txt"
git -C "$_repo" add dirty.txt
# modified but NOT committed
rc=0
guard_uncommitted "$_repo" 2>/dev/null || rc=$?
assert_ne "test_worktree_removal_guards: uncommitted_guard fires on staged change" \
    "0" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- uncommitted_guard: fires on unstaged modification ---"
_snapshot_fail
_repo2="$(_make_isolated_git_repo)"
printf 'unstaged\n' >> "$_repo2/README.md"
rc=0
guard_uncommitted "$_repo2" 2>/dev/null || rc=$?
assert_ne "test_worktree_removal_guards: uncommitted_guard fires on unstaged modification" \
    "0" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- unpushed_guard: fires on committed-but-unpushed commits ---"
_snapshot_fail
_repo3="$(_make_isolated_git_repo)"
# Create a remote so git log @{u}.. has a tracking branch to compare
_remote_dir="$(_new_tmpdir)"
git init --bare "$_remote_dir" -q 2>/dev/null
git -C "$_repo3" remote add origin "$_remote_dir"
git -C "$_repo3" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$_repo3" branch --set-upstream-to=origin/main 2>/dev/null || \
    git -C "$_repo3" push -q -u origin HEAD:refs/heads/main 2>/dev/null || true
# Make a new commit that hasn't been pushed
printf 'unpushed\n' > "$_repo3/new.txt"
git -C "$_repo3" add new.txt
git -C "$_repo3" commit -q -m "unpushed commit"
rc=0
guard_unpushed "$_repo3" 2>/dev/null || rc=$?
assert_ne "test_worktree_removal_guards: unpushed_guard fires on unpushed commits" \
    "0" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- uncommitted_guard + unpushed_guard: pass on clean+pushed tree ---"
_snapshot_fail
_repo4="$(_make_isolated_git_repo)"
_remote_dir4="$(_new_tmpdir)"
git init --bare "$_remote_dir4" -q 2>/dev/null
git -C "$_repo4" remote add origin "$_remote_dir4"
git -C "$_repo4" push -q -u origin HEAD:refs/heads/main 2>/dev/null || true
rc_uc=0; rc_up=0
guard_uncommitted "$_repo4" 2>/dev/null || rc_uc=$?
guard_unpushed "$_repo4" 2>/dev/null || rc_up=$?
assert_eq "test_worktree_removal_guards: uncommitted_guard passes on clean tree" \
    "0" "$rc_uc"
assert_eq "test_worktree_removal_guards: unpushed_guard passes when all pushed" \
    "0" "$rc_up"
assert_pass_if_clean "test_worktree_removal_guards"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3: Open-PR guard — 3-tier fallback + sub-PR enumeration via --base
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- open_pr_guard: tier-1 (--head) finds open PR, guard fires ---"
_snapshot_fail
_bin1="$(_new_tmpdir)/bin"
write_mock_gh "$_bin1" '
# Mock: gh pr list --head <branch> returns 1 open PR; all other calls return empty
case "$*" in
  *"pr list"*"--head"*)
    printf "123\tOpen PR\thttps://github.com/org/repo/pull/123\tOPEN\n"
    exit 0
    ;;
  *"pr list"*"--base"*)
    exit 0
    ;;
  *"auth status"*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'
rc=0
stderr_out="$(PATH="$_bin1:$PATH" guard_open_pr "session/test-branch" "abc1234" 2>&1)" || rc=$?
assert_ne "test_worktree_removal_guards: open_pr_guard fires when tier-1 head finds PR" \
    "0" "$rc"
assert_contains "test_worktree_removal_guards: open_pr_guard emits PR URL to stderr" \
    "https://github.com/org/repo/pull/123" "$stderr_out"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- open_pr_guard: sub-PR enumeration via --base finds sub-PR, guard fires ---"
_snapshot_fail
_bin2="$(_new_tmpdir)/bin"
write_mock_gh "$_bin2" '
# Mock: --head returns main session PR; --base returns story sub-PR
case "$*" in
  *"pr list"*"--head"*)
    printf "200\tSession PR\thttps://github.com/org/repo/pull/200\tOPEN\n"
    exit 0
    ;;
  *"pr list"*"--base"*)
    printf "201\tStory sub-PR\thttps://github.com/org/repo/pull/201\tOPEN\n"
    exit 0
    ;;
  *"auth status"*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'
rc=0
stderr_out="$(PATH="$_bin2:$PATH" guard_open_pr "session/test-branch" "abc1234" 2>&1)" || rc=$?
assert_ne "test_worktree_removal_guards: open_pr_guard fires on sub-PR via --base" \
    "0" "$rc"
assert_contains "test_worktree_removal_guards: open_pr_guard includes main PR URL" \
    "https://github.com/org/repo/pull/200" "$stderr_out"
assert_contains "test_worktree_removal_guards: open_pr_guard includes sub-PR URL" \
    "https://github.com/org/repo/pull/201" "$stderr_out"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- open_pr_guard: tier-1 empty, tier-2 (commits SHA) finds PR, guard fires ---"
_snapshot_fail
_bin3="$(_new_tmpdir)/bin"
write_mock_gh "$_bin3" '
case "$*" in
  *"pr list"*"--head"*)
    # Empty — no head PR
    exit 0
    ;;
  *"pr list"*"--base"*)
    # Empty — no base PR
    exit 0
    ;;
  *"api"*"commits"*"pulls"*)
    # Tier-2: commits/<sha>/pulls returns an open PR
    printf "[{\"number\":300,\"html_url\":\"https://github.com/org/repo/pull/300\",\"state\":\"open\"}]"
    exit 0
    ;;
  *"auth status"*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'
rc=0
stderr_out="$(PATH="$_bin3:$PATH" guard_open_pr "session/empty-head" "deadbeef" 2>&1)" || rc=$?
assert_ne "test_worktree_removal_guards: open_pr_guard fires on tier-2 commit SHA match" \
    "0" "$rc"
assert_contains "test_worktree_removal_guards: open_pr_guard tier-2 emits PR URL" \
    "300" "$stderr_out"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- open_pr_guard: tiers 1+2 empty, tier-3 (search) finds PR, guard fires ---"
_snapshot_fail
_bin4="$(_new_tmpdir)/bin"
write_mock_gh "$_bin4" '
case "$*" in
  *"pr list"*"--head"*)
    exit 0
    ;;
  *"pr list"*"--base"*)
    exit 0
    ;;
  *"api"*"commits"*"pulls"*)
    printf "[]"
    exit 0
    ;;
  *"pr list"*"--search"*)
    # Tier-3: search returns a PR
    printf "400\tSearch match\thttps://github.com/org/repo/pull/400\tOPEN\n"
    exit 0
    ;;
  *"auth status"*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'
rc=0
stderr_out="$(PATH="$_bin4:$PATH" guard_open_pr "session/search-branch" "cafebabe" 2>&1)" || rc=$?
assert_ne "test_worktree_removal_guards: open_pr_guard fires on tier-3 search match" \
    "0" "$rc"
assert_contains "test_worktree_removal_guards: open_pr_guard tier-3 emits PR URL" \
    "400" "$stderr_out"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- open_pr_guard: all tiers empty, guard does NOT fire ---"
_snapshot_fail
_bin5="$(_new_tmpdir)/bin"
write_mock_gh "$_bin5" '
case "$*" in
  *"auth status"*)
    exit 0
    ;;
  *)
    # All queries return empty
    exit 0
    ;;
esac
'
rc=0
PATH="$_bin5:$PATH" guard_open_pr "session/no-pr" "00000000" 2>/dev/null || rc=$?
assert_eq "test_worktree_removal_guards: open_pr_guard passes when no open PRs" \
    "0" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4: gh unavailability — fail-CLOSED (3 modes)
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- gh_unavailability: gh not in PATH → exits non-zero with GUARD_PR_CHECK_UNAVAILABLE ---"
_snapshot_fail
_empty_bin="$(_new_tmpdir)/emptybin"
mkdir -p "$_empty_bin"
rc=0
stderr_out="$(PATH="$_empty_bin" guard_open_pr "session/no-gh" "abc123" 2>&1)" || rc=$?
assert_ne "test_worktree_removal_guards: gh missing from PATH exits non-zero" \
    "0" "$rc"
assert_contains "test_worktree_removal_guards: gh missing emits GUARD_PR_CHECK_UNAVAILABLE" \
    "GUARD_PR_CHECK_UNAVAILABLE" "$stderr_out"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- gh_unavailability: gh auth status fails → exits non-zero with GUARD_PR_CHECK_UNAVAILABLE ---"
_snapshot_fail
_bin_unauth="$(_new_tmpdir)/bin"
write_mock_gh "$_bin_unauth" '
case "$*" in
  *"auth status"*)
    echo "You are not logged in" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
'
rc=0
stderr_out="$(PATH="$_bin_unauth:$PATH" guard_open_pr "session/unauth" "abc123" 2>&1)" || rc=$?
assert_ne "test_worktree_removal_guards: gh auth failure exits non-zero" \
    "0" "$rc"
assert_contains "test_worktree_removal_guards: gh auth failure emits GUARD_PR_CHECK_UNAVAILABLE" \
    "GUARD_PR_CHECK_UNAVAILABLE" "$stderr_out"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- gh_unavailability: gh returns HTTP 403 rate-limit → exits non-zero with GUARD_PR_CHECK_UNAVAILABLE ---"
_snapshot_fail
_bin_rate="$(_new_tmpdir)/bin"
write_mock_gh "$_bin_rate" '
case "$*" in
  *"auth status"*)
    exit 0
    ;;
  *)
    echo "error: API rate limit exceeded" >&2
    exit 1
    ;;
esac
'
rc=0
stderr_out="$(PATH="$_bin_rate:$PATH" guard_open_pr "session/rate-limited" "abc123" 2>&1)" || rc=$?
assert_ne "test_worktree_removal_guards: rate-limited gh exits non-zero" \
    "0" "$rc"
assert_contains "test_worktree_removal_guards: rate-limited gh emits GUARD_PR_CHECK_UNAVAILABLE" \
    "GUARD_PR_CHECK_UNAVAILABLE" "$stderr_out"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- gh_unavailability: SKIP_PR_CHECK with only one var is insufficient ---"
_snapshot_fail
_empty_bin2="$(_new_tmpdir)/emptybin"
mkdir -p "$_empty_bin2"
rc=0
# Only WORKTREE_REMOVAL_SKIP_PR_CHECK=1, no REASON — must still fail-closed
stderr_out="$(WORKTREE_REMOVAL_SKIP_PR_CHECK=1 PATH="$_empty_bin2" \
    guard_open_pr "session/one-var" "abc123" 2>&1)" || rc=$?
assert_ne "test_worktree_removal_guards: single-var SKIP_PR_CHECK insufficient, still exits non-zero" \
    "0" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- gh_unavailability: SKIP_PR_CHECK with BOTH vars overrides fail-closed ---"
_snapshot_fail
_empty_bin3="$(_new_tmpdir)/emptybin"
mkdir -p "$_empty_bin3"
rc=0
WORKTREE_REMOVAL_SKIP_PR_CHECK=1 \
    WORKTREE_REMOVAL_SKIP_PR_CHECK_REASON="test-authorized-skip" \
    PATH="$_empty_bin3" \
    guard_open_pr "session/both-vars" "abc123" 2>/dev/null || rc=$?
assert_eq "test_worktree_removal_guards: both-var SKIP_PR_CHECK overrides fail-closed" \
    "0" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5: assert_worktree_removable orchestrator
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- assert_worktree_removable: any single guard fires → exit non-zero ---"
_snapshot_fail
_bin_orch="$(_new_tmpdir)/bin"
write_mock_gh "$_bin_orch" '
case "$*" in
  *"auth status"*) exit 0 ;;
  *) exit 0 ;;
esac
'
# Use protected branch "main" to trigger the protected-branch guard reliably
rc=0
stderr_out="$(PATH="$_bin_orch:$PATH" assert_worktree_removable \
    --branch "main" \
    --worktree-path "$(mktemp -d)" \
    2>&1)" || rc=$?
assert_ne "test_worktree_removal_guards: orchestrator exits non-zero when guard fires" \
    "0" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- assert_worktree_removable: refusal message identifies WHICH guard fired ---"
_snapshot_fail
_bin_orch2="$(_new_tmpdir)/bin"
write_mock_gh "$_bin_orch2" '
case "$*" in
  *"auth status"*) exit 0 ;;
  *) exit 0 ;;
esac
'
rc=0
stderr_out="$(PATH="$_bin_orch2:$PATH" assert_worktree_removable \
    --branch "main" \
    --worktree-path "$(mktemp -d)" \
    2>&1)" || rc=$?
# The refusal must mention the protected-branch guard
assert_contains "test_worktree_removal_guards: refusal message names the fired guard" \
    "protected" "$stderr_out"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- assert_worktree_removable: --force → guards run, PR URLs emitted, exit 0 ---"
_snapshot_fail
_bin_force="$(_new_tmpdir)/bin"
write_mock_gh "$_bin_force" '
case "$*" in
  *"pr list"*"--head"*)
    printf "999\tForced PR\thttps://github.com/org/repo/pull/999\tOPEN\n"
    exit 0
    ;;
  *"pr list"*"--base"*)
    exit 0
    ;;
  *"auth status"*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'
_clean_repo="$(_make_isolated_git_repo)"
_remote_force="$(_new_tmpdir)"
git init --bare "$_remote_force" -q 2>/dev/null
git -C "$_clean_repo" remote add origin "$_remote_force"
git -C "$_clean_repo" push -q -u origin HEAD:refs/heads/test-force 2>/dev/null || true

rc=0
stderr_out="$(PATH="$_bin_force:$PATH" assert_worktree_removable \
    --branch "session/force-test" \
    --worktree-path "$_clean_repo" \
    --force \
    2>&1)" || rc=$?
assert_eq "test_worktree_removal_guards: --force exits 0 even with open PR" \
    "0" "$rc"
assert_contains "test_worktree_removal_guards: --force emits PR URL to stderr" \
    "https://github.com/org/repo/pull/999" "$stderr_out"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- assert_worktree_removable: protected branch NOT bypassable by --force ---"
_snapshot_fail
_bin_force2="$(_new_tmpdir)/bin"
write_mock_gh "$_bin_force2" '
case "$*" in
  *"auth status"*) exit 0 ;;
  *) exit 0 ;;
esac
'
rc=0
PATH="$_bin_force2:$PATH" assert_worktree_removable \
    --branch "main" \
    --worktree-path "$(mktemp -d)" \
    --force \
    2>/dev/null || rc=$?
assert_ne "test_worktree_removal_guards: protected branch not bypassed by --force" \
    "0" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6: Special worktree paths — space, unicode, leading dash
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- special_paths: path with space handled without word-splitting ---"
_snapshot_fail
_base_dir="$(_new_tmpdir)"
_space_path="$_base_dir/worktree with space"
mkdir -p "$_space_path"
_bin_sp="$(_new_tmpdir)/bin"
write_mock_gh "$_bin_sp" '
case "$*" in
  *"auth status"*) exit 0 ;;
  *) exit 0 ;;
esac
'
# Pass a path containing a space; library must not word-split it
rc=0
PATH="$_bin_sp:$PATH" assert_worktree_removable \
    --branch "session/space-test" \
    --worktree-path "$_space_path" \
    2>/dev/null || rc=$?
# guard should not crash (no word-splitting error); exit code depends on git state
# The critical assertion is the command completes without unbound-variable error
assert_ne "test_worktree_removal_guards: space path does not cause unbound-var abort" \
    "127" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- special_paths: path with unicode (café) handled correctly ---"
_snapshot_fail
_base_dir2="$(_new_tmpdir)"
_unicode_path="$_base_dir2/café-worktree"
mkdir -p "$_unicode_path"
_bin_uc="$(_new_tmpdir)/bin"
write_mock_gh "$_bin_uc" '
case "$*" in
  *"auth status"*) exit 0 ;;
  *) exit 0 ;;
esac
'
rc=0
PATH="$_bin_uc:$PATH" assert_worktree_removable \
    --branch "session/unicode-test" \
    --worktree-path "$_unicode_path" \
    2>/dev/null || rc=$?
assert_ne "test_worktree_removal_guards: unicode path does not cause abort (exit != 127)" \
    "127" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

echo ""
echo "--- special_paths: path starting with leading dash handled correctly ---"
_snapshot_fail
_base_dir3="$(_new_tmpdir)"
_dash_path="$_base_dir3/-startsWithDash"
mkdir -p "$_dash_path"
_bin_dash="$(_new_tmpdir)/bin"
write_mock_gh "$_bin_dash" '
case "$*" in
  *"auth status"*) exit 0 ;;
  *) exit 0 ;;
esac
'
rc=0
PATH="$_bin_dash:$PATH" assert_worktree_removable \
    --branch "session/dash-test" \
    --worktree-path "$_dash_path" \
    2>/dev/null || rc=$?
# Must not treat path as a flag (exit code must not be an "unknown option" code)
assert_ne "test_worktree_removal_guards: leading-dash path not treated as flag (exit != 127)" \
    "127" "$rc"
assert_pass_if_clean "test_worktree_removal_guards"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
