#!/usr/bin/env bash
# shellcheck disable=SC2164,SC2030,SC2031,SC2016  # cd/subshell patterns and grep regex in test setup
# tests/scripts/test-merge-to-main-resume-cwd.sh
# Behavioral tests for the CWD-correctness invariant in merge-to-main.sh:
#   Bug 34cc-526c: --resume skips _phase_sync, so cd "$MAIN_REPO" (inside
#                  _phase_sync) never runs → _phase_merge and _phase_push
#                  execute from the worktree dir → push fails non-fast-forward.
#   Bug 687d-b448: same root — _phase_version_bump runs in worktree context,
#                  amend targets worktree HEAD (not MAIN_REPO HEAD) → MAIN_REPO
#                  commit unchanged; state file records version_bump=complete.
#
# Both bugs share the same fix: _phase_merge must cd into MAIN_REPO at its
# start, making CWD-correctness self-contained rather than inheriting from
# _phase_sync. These tests verify that invariant.
#
# Correctness gap (reviewer finding): when --resume skips _phase_merge entirely
# (because merge is already complete) and resumes from _phase_version_bump,
# _phase_validate, or _phase_push, no cd "$MAIN_REPO" would execute. These
# phases therefore each carry their own explicit cd "$MAIN_REPO" guard.
#
# Tests:
#   1. test_phase_merge_begins_with_cd_main_repo
#      _phase_merge() must contain an explicit cd "$MAIN_REPO" as its first
#      git-context operation (after state bookkeeping). RED: absent before fix.
#
#   2. test_phase_merge_cd_main_repo_precedes_git_merge
#      The cd "$MAIN_REPO" line must appear BEFORE any 'git merge' call inside
#      the same function body. RED: cd absent before fix, so this also fails.
#
#   3. test_phase_version_bump_has_standalone_cd_main_repo
#      _phase_version_bump must contain its own standalone cd "$MAIN_REPO" so
#      that --resume-from-version_bump (skipping _phase_merge) runs in the
#      correct directory. Each downstream phase is self-contained.
#
#   4. test_phase_validate_has_standalone_cd_main_repo
#      _phase_validate must contain its own standalone cd "$MAIN_REPO" for the
#      same reason: --resume can skip _phase_merge entirely.
#
#   5. test_phase_push_has_standalone_cd_main_repo
#      _phase_push must contain its own standalone cd "$MAIN_REPO" to protect
#      bare git push from running in the worktree on resume.
#
# Usage: bash tests/scripts/test-merge-to-main-resume-cwd.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"
MERGE_HELPERS_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-to-main-resume-cwd.sh ==="
echo ""

# ---------------------------------------------------------------------------
# Helper: extract a named function body from merge-to-main.sh
# ---------------------------------------------------------------------------
_extract_fn() {
    local fn_name="$1"
    local _body
    _body=$(awk "/^${fn_name}\\(\\)/{found=1} found{print; if(/^\\}$/){exit}}" "$MERGE_SCRIPT")
    if [[ -z "$_body" ]] && [[ -f "${MERGE_HELPERS_LIB:-}" ]]; then
        _body=$(awk "/^${fn_name}\\(\\)/{found=1} found{print; if(/^\\}$/){exit}}" "$MERGE_HELPERS_LIB")
    fi
    echo "$_body"
}

# ---------------------------------------------------------------------------
# Precondition: merge-to-main.sh must exist
# ---------------------------------------------------------------------------
if [[ ! -f "$MERGE_SCRIPT" ]]; then
    echo "SKIP: merge-to-main.sh not found at $MERGE_SCRIPT" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# test_phase_merge_begins_with_cd_main_repo
#
# _phase_merge() must contain 'cd "$MAIN_REPO"' to ensure it always runs
# from the main repo regardless of whether --resume skipped _phase_sync.
# Before the fix: _phase_merge has NO such cd → test FAILS (RED).
# After the fix:  _phase_merge starts with cd "$MAIN_REPO" → test PASSES.
# ---------------------------------------------------------------------------
echo "--- test_phase_merge_begins_with_cd_main_repo ---"

_MERGE_BODY=$(_extract_fn "_phase_merge" 2>/dev/null || echo "")
_HAS_CD_MAIN_REPO="no"
if grep -qE 'cd[[:space:]]+"?\$MAIN_REPO"?' <<< "$_MERGE_BODY"; then
    _HAS_CD_MAIN_REPO="yes"
fi
assert_eq "test_phase_merge_begins_with_cd_main_repo" "yes" "$_HAS_CD_MAIN_REPO"

echo ""

# ---------------------------------------------------------------------------
# test_phase_merge_cd_main_repo_precedes_git_merge
#
# The cd "$MAIN_REPO" must appear BEFORE the 'git merge --no-ff' call so that
# git merge runs against the main repo HEAD, not the worktree HEAD.
# Both lines must be present AND in the correct order.
# Before the fix: cd absent → test FAILS (RED).
# After the fix:  cd appears before git merge → test PASSES.
# ---------------------------------------------------------------------------
echo "--- test_phase_merge_cd_main_repo_precedes_git_merge ---"

_CD_LINE=$(echo "$_MERGE_BODY" | grep -nE 'cd[[:space:]]+"?\$MAIN_REPO"?' | head -1 | cut -d: -f1)
_GIT_MERGE_LINE=$(echo "$_MERGE_BODY" | grep -nE 'git merge --no-ff' | head -1 | cut -d: -f1)

_ORDER_CORRECT="no"
if [[ -n "$_CD_LINE" && -n "$_GIT_MERGE_LINE" ]]; then
    if [[ "$_CD_LINE" -lt "$_GIT_MERGE_LINE" ]]; then
        _ORDER_CORRECT="yes"
    fi
fi
assert_eq "test_phase_merge_cd_main_repo_precedes_git_merge" "yes" "$_ORDER_CORRECT"

echo ""

# ---------------------------------------------------------------------------
# test_phase_version_bump_has_standalone_cd_main_repo
#
# _phase_version_bump must contain its own standalone cd "$MAIN_REPO" so that
# --resume-from-version_bump (which skips _phase_merge entirely when merge is
# already complete) still runs git operations from the main repo, not the
# worktree. Each phase that uses bare git commands must be self-contained.
# RED: absent before reviewer fix; GREEN after adding the cd guard.
# ---------------------------------------------------------------------------
echo "--- test_phase_version_bump_has_standalone_cd_main_repo ---"
_snapshot_fail

_BUMP_BODY=$(_extract_fn "_phase_version_bump" 2>/dev/null || echo "")
# Check for standalone 'cd "$MAIN_REPO"' lines (not inside subshells like (cd ...))
_BUMP_HAS_STANDALONE_CD="no"
if grep -qE '^[[:space:]]*cd[[:space:]]+"?\$MAIN_REPO"?' <<< "$_BUMP_BODY" 2>/dev/null; then
    _BUMP_HAS_STANDALONE_CD="yes"
fi
assert_eq "test_phase_version_bump_has_standalone_cd_main_repo" "yes" "$_BUMP_HAS_STANDALONE_CD"

assert_pass_if_clean "test_phase_version_bump_has_standalone_cd_main_repo"
echo ""

# ---------------------------------------------------------------------------
# test_phase_version_bump_executes_bump_from_main_repo_cwd
#
# Behavioral: when _phase_version_bump is invoked with CWD ≠ MAIN_REPO
# (simulating a resume from a worktree directory), bump-version.sh must
# execute from MAIN_REPO, not from the caller's directory.
# The mock bump-version.sh records $(pwd) to a log file.
# RED: before the cd "$MAIN_REPO" guard, bump ran from the worktree dir.
# GREEN: the cd guard redirects CWD to MAIN_REPO before bump is called.
# ---------------------------------------------------------------------------
echo "--- test_phase_version_bump_executes_bump_from_main_repo_cwd ---"
_snapshot_fail

_CWD_TEST_BASE=$(mktemp -d)
_CWD_MAIN_REPO="$_CWD_TEST_BASE/main-repo"
_CWD_WORKTREE="$_CWD_TEST_BASE/worktree"
_CWD_PWD_LOG="$_CWD_TEST_BASE/pwd.log"
_CWD_MOCK_BIN="$_CWD_TEST_BASE/mock-bin"
mkdir -p "$_CWD_MAIN_REPO" "$_CWD_WORKTREE" "$_CWD_MOCK_BIN"

# Mock bump-version.sh records its CWD via $(pwd)
cat > "$_CWD_MOCK_BIN/bump-version.sh" << 'CWD_MOCK_EOF'
#!/usr/bin/env bash
pwd >> "$_CWD_PWD_LOG"
exit 0
CWD_MOCK_EOF
chmod +x "$_CWD_MOCK_BIN/bump-version.sh"

export _CWD_PWD_LOG

# Set up MAIN_REPO as a minimal git repo
(
    cd "$_CWD_MAIN_REPO"
    git init -b main --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "1.0.0" > VERSION
    git add VERSION
    git commit -m "initial" --quiet
) 2>/dev/null

_CWD_BUMP_BODY=$(_extract_fn "_phase_version_bump" 2>/dev/null || echo "")

_CWD_TEST_RC=0
(
    # Start from WORKTREE dir (not MAIN_REPO) — simulates the resume scenario
    cd "$_CWD_WORKTREE"
    export PATH="$_CWD_MOCK_BIN:$PATH"
    export BUMP_TYPE="patch"
    export VERSION_FILE_PATH="$_CWD_MAIN_REPO/VERSION"
    export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
    export MAIN_REPO="$_CWD_MAIN_REPO"
    export BRANCH="test-cwd-$$"
    export _CWD_PWD_LOG

    # Eval state management functions needed by _phase_version_bump
    eval "$(_extract_fn "_state_file_path" 2>/dev/null || echo "")" 2>/dev/null || true
    eval "$(_extract_fn "_state_is_fresh" 2>/dev/null || echo "")" 2>/dev/null || true
    eval "$(_extract_fn "_state_init" 2>/dev/null || echo "")" 2>/dev/null || true
    eval "$(_extract_fn "_state_write_phase" 2>/dev/null || echo "")" 2>/dev/null || true
    eval "$(_extract_fn "_state_mark_complete" 2>/dev/null || echo "")" 2>/dev/null || true
    eval "$(_extract_fn "_set_phase_status" 2>/dev/null || echo "")" 2>/dev/null || true
    _state_init 2>/dev/null || true

    if [[ -n "$_CWD_BUMP_BODY" ]]; then
        eval "$_CWD_BUMP_BODY"
        _phase_version_bump 2>/dev/null
    else
        echo "FUNCTION_NOT_FOUND" >&2
        exit 1
    fi
) || _CWD_TEST_RC=$?

_BUMP_CWD=$(cat "$_CWD_PWD_LOG" 2>/dev/null | head -1 || echo "NO_LOG")
assert_eq "test_phase_version_bump_executes_bump_from_main_repo_cwd" \
    "$_CWD_MAIN_REPO" "$_BUMP_CWD"
assert_eq "test_phase_version_bump_cwd_test_exits_0" "0" "$_CWD_TEST_RC"

assert_pass_if_clean "test_phase_version_bump_executes_bump_from_main_repo_cwd"
rm -rf "$_CWD_TEST_BASE"
echo ""

# ---------------------------------------------------------------------------
# test_phase_validate_has_standalone_cd_main_repo
#
# _phase_validate must contain its own standalone cd "$MAIN_REPO" so that
# --resume-from-validate (skipping _phase_merge) runs from the main repo.
# Bare git operations in this phase (git add .gitignore, git diff --cached,
# git commit --amend) require CWD to be MAIN_REPO.
# ---------------------------------------------------------------------------
echo "--- test_phase_validate_has_standalone_cd_main_repo ---"

_VALIDATE_BODY=$(_extract_fn "_phase_validate" 2>/dev/null || echo "")
_VALIDATE_HAS_STANDALONE_CD="no"
if grep -qE '^[[:space:]]*cd[[:space:]]+"?\$MAIN_REPO"?' <<< "$_VALIDATE_BODY" 2>/dev/null; then
    _VALIDATE_HAS_STANDALONE_CD="yes"
fi
assert_eq "test_phase_validate_has_standalone_cd_main_repo" "yes" "$_VALIDATE_HAS_STANDALONE_CD"

echo ""

# ---------------------------------------------------------------------------
# test_phase_push_has_standalone_cd_main_repo
#
# _phase_push must contain its own standalone cd "$MAIN_REPO" so that
# --resume-from-push (skipping _phase_merge) runs bare git push from the
# main repo, not the worktree.
# ---------------------------------------------------------------------------
echo "--- test_phase_push_has_standalone_cd_main_repo ---"

_PUSH_BODY=$(_extract_fn "_phase_push" 2>/dev/null || echo "")
_PUSH_HAS_STANDALONE_CD="no"
if grep -qE '^[[:space:]]*cd[[:space:]]+"?\$MAIN_REPO"?' <<< "$_PUSH_BODY" 2>/dev/null; then
    _PUSH_HAS_STANDALONE_CD="yes"
fi
assert_eq "test_phase_push_has_standalone_cd_main_repo" "yes" "$_PUSH_HAS_STANDALONE_CD"

echo ""

print_summary
