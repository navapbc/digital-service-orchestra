#!/usr/bin/env bash
# shellcheck disable=SC2164,SC2030,SC2031  # cd/subshell patterns in test setup
# tests/scripts/test-merge-to-main-resume-cwd.sh
# Behavioral tests for the CWD-correctness invariant in merge-to-main.sh:
#   Bug 34cc-526c: --resume skips _phase_sync, so cd "$MAIN_REPO" (inside
#                  _phase_sync) never runs → _phase_merge and _phase_push
#                  execute from the worktree dir → push fails non-fast-forward.
#   Bug 687d-b448: same root — _phase_version_bump runs in worktree context,
#                  amend targets worktree HEAD (not MAIN_REPO HEAD) → MAIN_REPO
#                  commit unchanged; state file records version_bump=complete.
#
# Both bugs share the same fix: each phase must cd into MAIN_REPO at its
# start, making CWD-correctness self-contained rather than inheriting from
# _phase_sync.
#
# Tests:
#   1. test_phase_merge_executes_in_main_repo_cwd
#      When _phase_merge is invoked from a wrong CWD (worktree dir), it must
#      perform the merge against MAIN_REPO's HEAD, not the worktree's HEAD.
#      Observable: MAIN_REPO's HEAD advances after merge.
#
#   2. test_phase_version_bump_executes_bump_from_main_repo_cwd (behavioral)
#      When _phase_version_bump is invoked from wrong CWD, bump-version.sh
#      runs from MAIN_REPO (recorded via mock pwd log).
#
#   3. test_phase_validate_executes_in_main_repo_cwd
#      When _phase_validate is invoked from wrong CWD (worktree dir), it
#      produces correct output (succeeds with post-merge validation).
#
#   4. test_phase_push_executes_in_main_repo_cwd
#      When _phase_push is invoked from wrong CWD (worktree dir), _check_push_needed
#      correctly determines push status based on MAIN_REPO's HEAD.
#
# Usage: bash tests/scripts/test-merge-to-main-resume-cwd.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-direct.sh"
MERGE_HELPERS_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-to-main-resume-cwd.sh ==="
echo ""

# ---------------------------------------------------------------------------
# Helper: extract a named function body from merge-to-main.sh
# Used by integration tests that eval phase functions in isolation.
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
# test_phase_merge_executes_in_main_repo_cwd
#
# Behavioral: when _phase_merge is invoked from a wrong CWD (a different
# directory), the merge must be performed against MAIN_REPO, not the caller's
# directory. Observable: MAIN_REPO's HEAD advances after the merge.
# Before the fix (34cc-526c): cd "$MAIN_REPO" was absent → merge ran from
# the worktree and pushed the wrong SHA to main.
# After the fix: cd "$MAIN_REPO" at the start of _phase_merge → correct.
# ---------------------------------------------------------------------------
echo "--- test_phase_merge_executes_in_main_repo_cwd ---"
_snapshot_fail

# Set up a git pair: bare origin + main clone + worktree branch
_MERGE_TEST_BASE=$(mktemp -d)
_MERGE_ORIGIN="$_MERGE_TEST_BASE/origin.git"
_MERGE_MAIN="$_MERGE_TEST_BASE/main"
_MERGE_WT="$_MERGE_TEST_BASE/worktree"
_MERGE_WRONG_CWD="$_MERGE_TEST_BASE/wrong-cwd"
mkdir -p "$_MERGE_WRONG_CWD"

git init --bare "$_MERGE_ORIGIN" -b main --quiet 2>/dev/null
git clone "$_MERGE_ORIGIN" "$_MERGE_MAIN" --quiet 2>/dev/null
(
    cd "$_MERGE_MAIN" || return
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit -m "initial" --quiet
    git push origin main --quiet 2>/dev/null
) 2>/dev/null

# Create a feature branch worktree with a commit to merge
git -C "$_MERGE_MAIN" branch feature-cwd-test 2>/dev/null || true
git -C "$_MERGE_MAIN" worktree add -q "$_MERGE_WT" feature-cwd-test 2>/dev/null
(
    cd "$_MERGE_WT" || exit 1
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "feature content" > feature.txt
    git add feature.txt
    git commit -m "feat: add feature" --quiet
) 2>/dev/null || exit 1

# Capture MAIN_REPO HEAD before merge
_PRE_MERGE_SHA=$(git -C "$_MERGE_MAIN" rev-parse HEAD)

# Source the script in library mode and run _phase_merge from WRONG_CWD
_MERGE_CWD_WRAPPER=$(mktemp "${TMPDIR:-/tmp}/merge-cwd.XXXXXX".sh)
cat > "$_MERGE_CWD_WRAPPER" << WRAPPER_EOF
#!/usr/bin/env bash
export MERGE_TO_MAIN_DIRECT_LIB=1
export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
export BRANCH="feature-cwd-test"
export MAIN_REPO="$_MERGE_MAIN"
export MSG_EXCLUSION_PATTERN=""
export PRE_MERGE_SHA=""
export VISUAL_BASELINE_PATH=""
# shellcheck source=/dev/null
source "$MERGE_SCRIPT"
_state_init 2>/dev/null || true
# Start from WRONG CWD — not MAIN_REPO
cd "$_MERGE_WRONG_CWD"
_phase_merge 2>&1
WRAPPER_EOF

_MERGE_CWD_RC=0
_MERGE_CWD_OUTPUT=$(bash "$_MERGE_CWD_WRAPPER" 2>&1) || _MERGE_CWD_RC=$?
rm -f "$_MERGE_CWD_WRAPPER"

# After merge, MAIN_REPO HEAD should have advanced (new merge commit)
_POST_MERGE_SHA=$(git -C "$_MERGE_MAIN" rev-parse HEAD 2>/dev/null || echo "MISSING")
_MERGE_ADVANCED="false"
if [[ "$_POST_MERGE_SHA" != "$_PRE_MERGE_SHA" ]]; then
    _MERGE_ADVANCED="true"
fi
assert_eq "test_phase_merge_executes_in_main_repo_cwd" "true" "$_MERGE_ADVANCED"
assert_eq "test_phase_merge_cwd_exits_0" "0" "$_MERGE_CWD_RC"

assert_pass_if_clean "test_phase_merge_executes_in_main_repo_cwd"
git -C "$_MERGE_MAIN" worktree remove --force "$_MERGE_WT" 2>/dev/null || true
rm -rf "$_MERGE_TEST_BASE"
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
    cd "$_CWD_MAIN_REPO" || return
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
    cd "$_CWD_WORKTREE" || return
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
# test_phase_validate_executes_in_main_repo_cwd
#
# Behavioral: when _phase_validate is invoked from a wrong CWD (not MAIN_REPO),
# it must succeed — meaning its git operations ran from MAIN_REPO, not the
# caller's directory.
# Observable: _phase_validate exits 0 and emits "OK: Post-merge validation passed"
# (or the no-app-dir skip, depending on config). Either way it must not fail
# with "not a git repository" from the wrong CWD.
# ---------------------------------------------------------------------------
echo "--- test_phase_validate_executes_in_main_repo_cwd ---"
_snapshot_fail

_VAL_TEST_BASE=$(mktemp -d)
_VAL_MAIN_REPO="$_VAL_TEST_BASE/main"
_VAL_WRONG_CWD="$_VAL_TEST_BASE/wrong-cwd"
_VAL_EMPTY_CONFIG="$_VAL_TEST_BASE/empty.conf"
mkdir -p "$_VAL_MAIN_REPO" "$_VAL_WRONG_CWD"
touch "$_VAL_EMPTY_CONFIG"

(
    cd "$_VAL_MAIN_REPO" || return
    git init -b main --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit -m "initial" --quiet
) 2>/dev/null

_VAL_WRAPPER=$(mktemp "${TMPDIR:-/tmp}/validate-cwd.XXXXXX".sh)
cat > "$_VAL_WRAPPER" << WRAPPER_EOF
#!/usr/bin/env bash
export MERGE_TO_MAIN_DIRECT_LIB=1
export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
export WORKFLOW_CONFIG_FILE="$_VAL_EMPTY_CONFIG"
export BRANCH="test-validate-cwd-\$\$"
export MAIN_REPO="$_VAL_MAIN_REPO"
# shellcheck source=/dev/null
source "$MERGE_SCRIPT"
_state_init 2>/dev/null || true
# Start from WRONG CWD — not MAIN_REPO
cd "$_VAL_WRONG_CWD"
_phase_validate 2>&1
WRAPPER_EOF

_VAL_RC=0
_VAL_OUTPUT=$(bash "$_VAL_WRAPPER" 2>&1) || _VAL_RC=$?
rm -f "$_VAL_WRAPPER"

# _phase_validate must exit 0 (CWD correction must have worked)
# If it ran from the wrong CWD, git operations would fail → non-zero exit
assert_eq "test_phase_validate_executes_in_main_repo_cwd" "0" "$_VAL_RC"

assert_pass_if_clean "test_phase_validate_executes_in_main_repo_cwd"
rm -rf "$_VAL_TEST_BASE"
echo ""

# ---------------------------------------------------------------------------
# test_phase_push_executes_in_main_repo_cwd
#
# Behavioral: when _phase_push is invoked from a wrong CWD (not MAIN_REPO),
# _check_push_needed must evaluate the push status for MAIN_REPO, not for
# the wrong directory.
# Observable: when MAIN_REPO HEAD already matches origin/main, _phase_push
# exits 0 with "Push skipped" — not a git error from the wrong CWD.
# ---------------------------------------------------------------------------
echo "--- test_phase_push_executes_in_main_repo_cwd ---"
_snapshot_fail

_PUSH_TEST_BASE=$(mktemp -d)
_PUSH_ORIGIN="$_PUSH_TEST_BASE/origin.git"
_PUSH_MAIN="$_PUSH_TEST_BASE/main"
_PUSH_WRONG_CWD="$_PUSH_TEST_BASE/wrong-cwd"
mkdir -p "$_PUSH_WRONG_CWD"

git init --bare "$_PUSH_ORIGIN" -b main --quiet 2>/dev/null
git clone "$_PUSH_ORIGIN" "$_PUSH_MAIN" --quiet 2>/dev/null
(
    cd "$_PUSH_MAIN" || return
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit -m "initial" --quiet
    git push origin main --quiet 2>/dev/null
) 2>/dev/null

_PUSH_WRAPPER=$(mktemp "${TMPDIR:-/tmp}/push-cwd.XXXXXX".sh)
cat > "$_PUSH_WRAPPER" << WRAPPER_EOF
#!/usr/bin/env bash
export MERGE_TO_MAIN_DIRECT_LIB=1
export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
export BRANCH="test-push-cwd-\$\$"
export MAIN_REPO="$_PUSH_MAIN"
# shellcheck source=/dev/null
source "$MERGE_SCRIPT"
_state_init 2>/dev/null || true
# Start from WRONG CWD — not MAIN_REPO
cd "$_PUSH_WRONG_CWD"
_phase_push 2>&1
WRAPPER_EOF

_PUSH_RC=0
_PUSH_OUTPUT=$(bash "$_PUSH_WRAPPER" 2>&1) || _PUSH_RC=$?
rm -f "$_PUSH_WRAPPER"

# MAIN_REPO HEAD matches origin/main, so _check_push_needed returns exit 1
# (push not needed). _phase_push should emit "Push skipped" and exit 0.
_PUSH_SKIP="false"
if echo "$_PUSH_OUTPUT" | grep -q "Push skipped"; then
    _PUSH_SKIP="true"
fi
assert_eq "test_phase_push_executes_in_main_repo_cwd" "true" "$_PUSH_SKIP"
assert_eq "test_phase_push_cwd_exits_0" "0" "$_PUSH_RC"

assert_pass_if_clean "test_phase_push_executes_in_main_repo_cwd"
rm -rf "$_PUSH_TEST_BASE"
echo ""

print_summary
