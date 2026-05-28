#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-pr-bump-before-push.sh
#
# Behavioral guards for the architectural fix to bugs
# b6e3-e771-d37b-436c + bbba-123d-659e-4cee.
#
# In PR merge strategy, the version bump must be committed on the SOURCE
# (session) branch BEFORE the push, so the bump lands on main as part of the
# PR's squash-merge commit. The prior implementation committed the bump
# directly to main AFTER the PR merged, which (1) diverged main from the PR's
# merged content (b6e3) and (2) was rejected by the always-run pre-commit
# compliance verifier because no compliance artifacts existed for the
# out-of-band post-merge commit (bbba).
#
# The observable behavior (bump commit lands on origin/<branch> before the
# merge to main) is verified end-to-end by t_pr_version_bump_pushed_to_origin
# in tests/scripts/test-merge-to-main-pr.sh — that test sets up a real fixture,
# runs the script, and asserts on origin refs. This file only covers the
# IDEMPOTENCY invariants that cannot be observed at the same end-to-end level
# without a much heavier multi-run fixture:
#   - _phase_source_branch_version_bump is a no-op when HEAD is already a bump
#     commit (resume safety; without this, --resume would cascade the version
#     1.0.5 → 1.0.6 → 1.0.7 …).
#   - _phase_version_bump (in direct.sh) is a no-op when HEAD is already a
#     bump commit — defensive guard for the unlikely case that it runs
#     post-merge via a stale state-file resume path.
#
# Per behavioral testing standard rule 3, we DO NOT grep the source files to
# assert that specific function calls or call orderings exist. Earlier
# revisions of this test included source-grepping assertions; they were
# removed during code review and replaced with this header pointer to the
# behavioral end-to-end coverage.
#
# Usage: bash tests/scripts/test-merge-to-main-pr-bump-before-push.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"
DIRECT_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-direct.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-merge-to-main-pr-bump-before-push.sh ==="

# Both temp dirs are tracked in this array and cleaned on EXIT (covers both
# normal exit and abnormal exit from assert failures with set -uo pipefail).
_TMPDIRS=()
_cleanup_tmpdirs() {
    local _d
    for _d in "${_TMPDIRS[@]:-}"; do
        [[ -n "${_d:-}" ]] && rm -rf "$_d"
    done
}
trap _cleanup_tmpdirs EXIT

_real_git="$(command -v git)"

# -----------------------------------------------------------------------------
# Test 1: _phase_source_branch_version_bump is idempotent on resume.
# Behavioral: source the function in PR_LIB_MODE=1, set up a worktree whose
# HEAD is already a `chore: bump version to v...` commit, invoke the function,
# and assert that no new commit is created (commit count unchanged) AND the
# function returns success (exit 0).
# -----------------------------------------------------------------------------
echo "--- test_source_branch_bump_idempotent_when_head_is_bump_commit ---"
_T="$(mktemp -d "${TMPDIR:-/tmp}/dso-bump-idempotent.XXXXXX")"
_TMPDIRS+=("$_T")

"$_real_git" init -q -b main "$_T/repo" >/dev/null 2>&1
(
    cd "$_T/repo" || exit 1
    "$_real_git" config user.email "test@test.local"
    "$_real_git" config user.name "test"
    echo "1.0.4" > VERSION
    "$_real_git" add VERSION
    "$_real_git" commit -q -m "feat: initial" >/dev/null
    echo "1.0.5" > VERSION
    "$_real_git" add VERSION
    "$_real_git" commit -q -m "chore: bump version to v1.0.5

DSO-Story: prior-story-xyz" >/dev/null
)

cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
version.file_path=$_T/repo/VERSION
dso.workflow=ci-pr
EOF

_pre_count=$("$_real_git" -C "$_T/repo" rev-list --count HEAD 2>/dev/null || echo 0)

# Invoke the function. It must detect the bump-commit HEAD and skip — and
# return exit 0. Capture the exit code so a refactor that renames the function
# or breaks the source path produces a visible failure rather than silently
# passing the commit-count invariant.
_ec=0
(
    cd "$_T/repo" || exit 1
    WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    MERGE_STRATEGY="pr" \
    PR_LIB_MODE="1" \
    BRANCH="main" \
    VERSION_FILE_PATH="$_T/repo/VERSION" \
    bash -c '
        source "$0"
        _phase_source_branch_version_bump "test-story-idempotent"
    ' "$PR_SCRIPT"
) || _ec=$?

_post_count=$("$_real_git" -C "$_T/repo" rev-list --count HEAD 2>/dev/null || echo 0)
assert_eq "test_source_branch_bump_idempotent_when_head_is_bump_commit:commit_count_unchanged" "$_pre_count" "$_post_count"
assert_eq "test_source_branch_bump_idempotent_when_head_is_bump_commit:exit_zero" "0" "$_ec"

# -----------------------------------------------------------------------------
# Test 2: _phase_version_bump (direct.sh) is a no-op when HEAD is already a
# bump commit. Defensive guard against accidental double-bump on resume paths.
# Captures the exit code so a future regression that breaks the guard becomes
# visible (rather than passing on coincidence).
# -----------------------------------------------------------------------------
echo "--- test_phase_version_bump_no_op_when_head_is_bump_commit ---"
_T2="$(mktemp -d "${TMPDIR:-/tmp}/dso-bump-version-noop.XXXXXX")"
_TMPDIRS+=("$_T2")

"$_real_git" init -q -b main "$_T2/repo" >/dev/null 2>&1
(
    cd "$_T2/repo" || exit 1
    "$_real_git" config user.email "test@test.local"
    "$_real_git" config user.name "test"
    echo "2.0.0" > VERSION
    "$_real_git" add VERSION
    "$_real_git" commit -q -m "chore: seed" >/dev/null
    echo "2.0.1" > VERSION
    "$_real_git" add VERSION
    "$_real_git" commit -q -m "chore: bump version to v2.0.1

DSO-Story: prior" >/dev/null
)

cat > "$_T2/dso-config.conf" <<EOF
version=1.1.0
version.file_path=$_T2/repo/VERSION
dso.workflow=ci-pr
EOF

_pre_count2=$("$_real_git" -C "$_T2/repo" rev-list --count HEAD 2>/dev/null || echo 0)

_ec2=0
(
    cd "$_T2/repo" || exit 1
    WORKFLOW_CONFIG_FILE="$_T2/dso-config.conf" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    MERGE_STRATEGY="direct" \
    MERGE_TO_MAIN_DIRECT_LIB="1" \
    BRANCH="main" \
    MAIN_REPO="$_T2/repo" \
    VERSION_FILE_PATH="$_T2/repo/VERSION" \
    BUMP_TYPE="patch" \
    DSO_WORKFLOW="local" \
    bash -c '
        source "$0"
        # Minimal state stubs so the function does not require a state file.
        _state_write_phase()   { return 0; }
        _state_mark_complete() { return 0; }
        _state_file_path()     { echo ""; }
        _phase_version_bump
    ' "$DIRECT_SCRIPT"
) || _ec2=$?

_post_count2=$("$_real_git" -C "$_T2/repo" rev-list --count HEAD 2>/dev/null || echo 0)
assert_eq "test_phase_version_bump_no_op_when_head_is_bump_commit:commit_count_unchanged" "$_pre_count2" "$_post_count2"
assert_eq "test_phase_version_bump_no_op_when_head_is_bump_commit:exit_zero" "0" "$_ec2"

print_summary
