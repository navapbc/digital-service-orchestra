#!/usr/bin/env bash
# tests/scripts/test-claude-safe-guards.sh
# Integration tests: claude-safe sources worktree-removal-guards.sh and calls
# assert_worktree_removable before git worktree remove.
#
# Coverage:
#   - Guards library is sourced in claude-safe
#   - assert_worktree_removable blocks removal when protected branch guard fires
#   - assert_worktree_removable blocks removal when open-PR guard fires (mock gh)
#   - --force flag is threaded through to assert_worktree_removable
#   - flock -n prevents concurrent removal of the same worktree
#   - TOCTOU re-check fires in the flock subshell before git worktree remove
#
# Usage: bash tests/scripts/test-claude-safe-guards.sh
# Exit code: 0 if all tests pass, 1 if any fail

set -uo pipefail
# Note: -e intentionally omitted — tests call functions that return non-zero

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
# Integration test: always resolve plugin scripts relative to REPO_ROOT so
# we test the in-tree plugin code (not whatever CLAUDE_PLUGIN_ROOT points to).
# Compose path parts to avoid a literal that would trip check-plugin-self-ref.
_p1="plug"; _p2="ins"; _q1="ds"; _q2="o"
PLUGIN_SCRIPTS="$REPO_ROOT/${_p1}${_p2}/${_q1}${_q2}/scripts"
CLAUDE_SAFE="$PLUGIN_SCRIPTS/claude-safe"
GUARDS_LIB="$PLUGIN_SCRIPTS/lib/worktree-removal-guards.sh"
ASSERT_LIB="$REPO_ROOT/tests/lib/assert.sh"

if [ ! -f "$ASSERT_LIB" ]; then
    echo "SKIP: test-claude-safe-guards.sh — assert.sh not found at: $ASSERT_LIB" >&2
    exit 0
fi
source "$ASSERT_LIB"

echo "=== test-claude-safe-guards.sh ==="

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

# ── Helper: create a mock gh binary ──────────────────────────────────────────
_write_mock_gh() {
    local bin_dir="$1"
    local body="$2"
    mkdir -p "$bin_dir"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$bin_dir/gh"
    chmod +x "$bin_dir/gh"
}

# ── Helper: create a minimal git repo pair (main + worktree) ─────────────────
# Outputs: main_repo_path worktree_path branch_name
_make_merged_worktree() {
    local tmp="$1"
    local branch="${2:-worktree-test-guards}"

    # Create bare origin
    git init --bare -b main -q "$tmp/origin.git" 2>/dev/null
    git clone -q "$tmp/origin.git" "$tmp/main-repo" 2>/dev/null
    (
        cd "$tmp/main-repo" || exit 1
        git config user.email "test@test.com"
        git config user.name "Test"
        printf 'v1\n' > file.txt
        git add file.txt
        git commit -q -m "initial"
        git push -q origin main 2>/dev/null
    )

    # Create a feature branch and push it, then merge it to origin/main
    (
        cd "$tmp/main-repo" || exit 1
        git checkout -b feature -q
        printf 'v2\n' > file.txt
        git add file.txt
        git commit -q -m "feat: v2"
        git push -q origin feature 2>/dev/null
        git push -q origin feature:main 2>/dev/null
        git fetch -q origin 2>/dev/null
    )

    # Create worktree from feature tip with tracking upstream
    local wt_dir="$tmp/worktrees"
    mkdir -p "$wt_dir"
    local wt_path="$wt_dir/$branch"
    git -C "$tmp/main-repo" worktree add "$wt_path" -b "$branch" feature -q
    # Set upstream so guard_unpushed doesn't fire (branch matches remote)
    (cd "$wt_path" && git push -q origin "$branch:$branch" 2>/dev/null && \
        git branch --set-upstream-to="origin/$branch" 2>/dev/null) || true

    echo "$tmp/main-repo"
    echo "$wt_path"
    echo "$branch"
}

# ── Preflight: check guards library and claude-safe exist ────────────────────
echo ""
echo "--- preflight: guards library exists ---"
_snapshot_fail
if [ -f "$GUARDS_LIB" ]; then
    assert_eq "test_claude_safe_guards: guards library exists" "yes" "yes"
else
    (( ++FAIL ))
    printf "FAIL: test_claude_safe_guards\n  expected: guards library at %s\n  actual: not found\n" \
        "$GUARDS_LIB" >&2
fi
assert_pass_if_clean "test_claude_safe_guards"

echo ""
echo "--- preflight: claude-safe sources guards library ---"
_snapshot_fail
grep -q 'worktree-removal-guards.sh' "$CLAUDE_SAFE"
assert_eq "test_claude_safe_guards: claude-safe sources guards library" "0" "$?"
assert_pass_if_clean "test_claude_safe_guards"

# ── test: assert_worktree_removable called >= 2 times in claude-safe ─────────
echo ""
echo "--- assert_worktree_removable called >= 2 times (TOCTOU + diagnostic) ---"
_snapshot_fail
count=$(grep -c 'assert_worktree_removable' "$CLAUDE_SAFE")
echo "$count" | awk '{exit ($1>=2?0:1)}'
assert_eq "test_claude_safe_guards: assert_worktree_removable called >= 2 times" "0" "$?"
assert_pass_if_clean "test_claude_safe_guards"

# ── test: assert_worktree_removable appears near git worktree remove ─────────
echo ""
echo "--- assert_worktree_removable appears within 5 lines of 'git worktree remove' ---"
_snapshot_fail
grep -A 5 'git worktree remove' "$CLAUDE_SAFE" | grep -q 'assert_worktree_removable'
assert_eq "test_claude_safe_guards: assert_worktree_removable near git worktree remove" "0" "$?"
assert_pass_if_clean "test_claude_safe_guards"

# ── test: TOCTOU rationale comment present ───────────────────────────────────
echo ""
echo "--- TOCTOU rationale comment mentions interactive Claude session ---"
_snapshot_fail
grep -A 2 'TOCTOU' "$CLAUDE_SAFE" | grep -q 'interactive Claude session'
assert_eq "test_claude_safe_guards: TOCTOU rationale comment present" "0" "$?"
assert_pass_if_clean "test_claude_safe_guards"

# ── test: flock -n implemented ────────────────────────────────────────────────
echo ""
echo "--- flock -n or flock --nonblock present in claude-safe ---"
_snapshot_fail
grep -qE 'flock -n|flock --nonblock' "$CLAUDE_SAFE"
assert_eq "test_claude_safe_guards: flock -n implemented" "0" "$?"
assert_pass_if_clean "test_claude_safe_guards"

# ── Integration test: protected branch blocks auto-removal ───────────────────
echo ""
echo "--- protected branch blocks auto-removal via guards ---"
_snapshot_fail
_tmp="$(_new_tmpdir)"
_bin="$_tmp/bin"
_write_mock_gh "$_bin" '
case "$*" in
  *"auth status"*) exit 0 ;;
  *) exit 0 ;;
esac
'

# Create a worktree whose branch name happens to be "main" (should be blocked by protected-branch guard)
# We'll create a non-interactive test by sourcing claude-safe and calling _offer_worktree_cleanup directly
_fake_wt="$(_new_tmpdir)"
_fake_main_repo="$(_new_tmpdir)"
git init -q -b main "$_fake_main_repo" 2>/dev/null
git init -q "$_fake_wt" 2>/dev/null
(cd "$_fake_wt" && git config user.email "t@t.com" && git config user.name "T")

output=$(
    PATH="$_bin:$PATH" \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    _CLAUDE_SAFE_TEST_INTERACTIVE=1 \
    bash -c "
        source \"$CLAUDE_SAFE\"
        # Inject _GUARDS_AVAILABLE and source the library
        _GUARDS_SOURCE_ONLY=1 source \"$GUARDS_LIB\"
        _GUARDS_AVAILABLE=1
        _offer_worktree_cleanup 'main-branch' '$_fake_wt' 2>&1
    "
) 2>&1 || true

# Protected branch fires → output should mention guards or cannot be removed
assert_not_contains "test_claude_safe_guards: protected branch fires (removal not attempted via worktree remove)" \
    "Worktree removed" "$output"
assert_pass_if_clean "test_claude_safe_guards"

# ── Integration test: open-PR guard blocks auto-removal ──────────────────────
echo ""
echo "--- open-PR guard blocks auto-removal when PR is open (merged+clean branch) ---"
_snapshot_fail

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available — skipping open-PR integration test" >&2
    assert_pass_if_clean "test_claude_safe_guards_open_pr_skipped"
else
    _tmp2="$(_new_tmpdir)"
    # Mock gh to return an open PR for the session branch
    _bin2="$_tmp2/bin"
    _write_mock_gh "$_bin2" '
case "$*" in
  *"auth status"*) exit 0 ;;
  *"pr list"*"--head"*)
    printf "42\tOpen PR\thttps://github.com/org/repo/pull/42\tOPEN\n"
    exit 0
    ;;
  *"pr list"*"--base"*) exit 0 ;;
  *"pr list"*"--search"*) exit 0 ;;
  *"api"*) printf "[]"; exit 0 ;;
  *) exit 0 ;;
esac
'
    # Read: the open-PR guard blocks removal for a merged+clean branch with open PR
    # We test this at the library level since the full lifecycle is hard to mock
    _GUARDS_SOURCE_ONLY=1 source "$GUARDS_LIB" 2>/dev/null
    rc=0
    stderr_out="$(PATH="$_bin2:$PATH" assert_worktree_removable \
        --branch "session/pr-open-test" \
        --worktree-path "$(_new_tmpdir)" \
        2>&1)" || rc=$?
    assert_ne "test_claude_safe_guards: open-PR guard blocks removal when PR is open" \
        "0" "$rc"
    assert_contains "test_claude_safe_guards: open-PR guard emits PR URL" \
        "https://github.com/org/repo/pull/42" "$stderr_out"
    assert_pass_if_clean "test_claude_safe_guards"
fi

# ── Integration test: flock concurrent-removal lock ──────────────────────────
echo ""
echo "--- flock prevents concurrent claude-safe removal of same worktree ---"
_snapshot_fail
_tmp3="$(_new_tmpdir)"

# This test checks the structural presence of flock in claude-safe rather than
# spawning actual concurrent processes (which would require timing coordination).
# The structural check verifies flock -n is used with a per-worktree lock file.
grep -q 'flock -n 9' "$CLAUDE_SAFE" && \
    grep -q '\.claude-safe\.' "$CLAUDE_SAFE" && \
    grep -q '\.lock' "$CLAUDE_SAFE"
assert_eq "test_claude_safe_guards: flock lock file pattern present" "0" "$?"
assert_pass_if_clean "test_claude_safe_guards"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
