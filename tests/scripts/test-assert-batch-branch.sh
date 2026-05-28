#!/usr/bin/env bash
# tests/scripts/test-assert-batch-branch.sh
# Behavioral tests for plugins/dso/scripts/assert-batch-branch.sh
#
# Refuses to allow debug-everything Phase F/G to open a sub-branch PR when in
# ci-pr mode without a properly created and pushed bug-batch sub-branch.
#
# Usage: bash tests/scripts/test-assert-batch-branch.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/assert-batch-branch.sh"

# shellcheck source=tests/lib/run_test.sh
source "$SCRIPT_DIR/../lib/run_test.sh"

_CLEANUP_DIRS=()
_CLEANUP_FILES=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done
    for f in "${_CLEANUP_FILES[@]}"; do rm -f "$f"; done
}
trap _cleanup EXIT

echo "=== test-assert-batch-branch.sh ==="

# Helper: write a dso-config.conf with a single dso.workflow=<value> line.
_make_config() {
    local workflow="$1"
    local cfg
    cfg=$(mktemp "${TMPDIR:-/tmp}/test-assert-batch-cfg.XXXXXX")
    _CLEANUP_FILES+=("$cfg")
    printf 'dso.workflow=%s\n' "$workflow" >"$cfg"
    echo "$cfg"
}

# Helper: initialize a git repo with a bare "origin" remote and one commit.
_make_repo_with_remote() {
    local repo bare
    repo=$(mktemp -d)
    bare=$(mktemp -d)
    _CLEANUP_DIRS+=("$repo" "$bare")
    git init -b main "$repo" >/dev/null 2>&1
    git init --bare "$bare" >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" commit --allow-empty -m "init" >/dev/null 2>&1
    git -C "$repo" remote add origin "$bare" >/dev/null 2>&1
    git -C "$repo" push -u origin main >/dev/null 2>&1
    echo "$repo"
}

# ── Test 1: Script exists and is executable ──────────────────────────────────
echo "Test 1: script is executable at plugin location"
if [ -x "$SCRIPT" ]; then
    echo "  PASS"
    PASS=$((PASS+1))
else
    echo "  FAIL: script missing or not executable at $SCRIPT" >&2
    FAIL=$((FAIL+1))
fi

# ── Test 2: local mode is a no-op (exit 0) regardless of args ────────────────
echo "Test 2: local mode no-op (exit 0) with no arg"
test_local_mode_is_noop() {
    local cfg repo exit_code=0
    cfg=$(_make_config local)
    repo=$(_make_repo_with_remote)
    (
        cd "$repo" || return
        WORKFLOW_CONFIG_FILE="$cfg" bash "$SCRIPT" >/dev/null 2>&1
    ) || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: expected exit 0 in local mode, got $exit_code" >&2
        FAIL=$((FAIL+1))
    fi
}
test_local_mode_is_noop

# ── Test 3: ci-pr mode + missing arg → exit 1 with remediation ───────────────
echo "Test 3: ci-pr mode with missing arg fails with remediation message"
test_ci_pr_missing_arg_fails() {
    local cfg repo exit_code=0 stderr_output
    cfg=$(_make_config ci-pr)
    repo=$(_make_repo_with_remote)
    stderr_output=$(
        cd "$repo" || return
        WORKFLOW_CONFIG_FILE="$cfg" bash "$SCRIPT" 2>&1
    ) || exit_code=$?
    if [ "$exit_code" -ne 0 ] && echo "$stderr_output" | grep -qE "git checkout -b .*bug-batch"; then
        echo "  PASS: exit $exit_code, stderr mentions bug-batch remediation"
        PASS=$((PASS+1))
    else
        echo "  FAIL: expected exit non-zero + remediation, got exit $exit_code" >&2
        echo "  stderr: $stderr_output" >&2
        FAIL=$((FAIL+1))
    fi
}
test_ci_pr_missing_arg_fails

# ── Test 4: ci-pr mode + wrong-prefix arg → exit 1 ───────────────────────────
echo "Test 4: ci-pr mode + non-bug-batch prefix → exit 1 with prefix remediation"
test_ci_pr_wrong_prefix_fails() {
    local cfg repo exit_code=0 stderr_output
    cfg=$(_make_config ci-pr)
    repo=$(_make_repo_with_remote)
    git -C "$repo" checkout -b "story/some-epic/some-story" >/dev/null 2>&1
    stderr_output=$(
        cd "$repo" || return
        WORKFLOW_CONFIG_FILE="$cfg" bash "$SCRIPT" "story/some-epic/some-story" 2>&1
    ) || exit_code=$?
    if [ "$exit_code" -ne 0 ] && echo "$stderr_output" | grep -qiE "bug-batch.*prefix|prefix"; then
        echo "  PASS: exit $exit_code, stderr mentions prefix requirement"
        PASS=$((PASS+1))
    else
        echo "  FAIL: expected non-zero exit with prefix remediation, got exit $exit_code" >&2
        echo "  stderr: $stderr_output" >&2
        FAIL=$((FAIL+1))
    fi
}
test_ci_pr_wrong_prefix_fails

# ── Test 5: ci-pr mode + branch doesn't exist locally → exit 1 ───────────────
echo "Test 5: ci-pr mode + branch does not exist locally → exit 1"
test_ci_pr_branch_not_exists_fails() {
    local cfg repo exit_code=0
    cfg=$(_make_config ci-pr)
    repo=$(_make_repo_with_remote)
    (
        cd "$repo" || return
        WORKFLOW_CONFIG_FILE="$cfg" \
            bash "$SCRIPT" "bug-batch/nonexistent-session/tier-3-batch-1" >/dev/null 2>&1
    ) || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo "  PASS: exit $exit_code"
        PASS=$((PASS+1))
    else
        echo "  FAIL: expected non-zero, got 0" >&2
        FAIL=$((FAIL+1))
    fi
}
test_ci_pr_branch_not_exists_fails

# ── Test 6: ci-pr mode + branch exists locally but not pushed → exit 1 ───────
echo "Test 6: ci-pr mode + branch local but not pushed → exit 1 with push remediation"
test_ci_pr_branch_not_pushed_fails() {
    local cfg repo exit_code=0 stderr_output
    cfg=$(_make_config ci-pr)
    repo=$(_make_repo_with_remote)
    git -C "$repo" checkout -b "bug-batch/sess-abc/tier-3-batch-1" >/dev/null 2>&1
    stderr_output=$(
        cd "$repo" || return
        WORKFLOW_CONFIG_FILE="$cfg" \
            bash "$SCRIPT" "bug-batch/sess-abc/tier-3-batch-1" 2>&1
    ) || exit_code=$?
    if [ "$exit_code" -ne 0 ] && echo "$stderr_output" | grep -qiE "push|origin"; then
        echo "  PASS: exit $exit_code, stderr mentions push/origin"
        PASS=$((PASS+1))
    else
        echo "  FAIL: expected non-zero exit with push remediation, got exit $exit_code" >&2
        echo "  stderr: $stderr_output" >&2
        FAIL=$((FAIL+1))
    fi
}
test_ci_pr_branch_not_pushed_fails

# ── Test 7: ci-pr mode + branch exists and is pushed → exit 0 ────────────────
echo "Test 7: ci-pr mode + branch exists locally AND pushed to origin → exit 0"
test_ci_pr_branch_pushed_passes() {
    local cfg repo exit_code=0
    cfg=$(_make_config ci-pr)
    repo=$(_make_repo_with_remote)
    git -C "$repo" checkout -b "bug-batch/sess-abc/tier-3-batch-1" >/dev/null 2>&1
    git -C "$repo" push -u origin "bug-batch/sess-abc/tier-3-batch-1" >/dev/null 2>&1
    (
        cd "$repo" || return
        WORKFLOW_CONFIG_FILE="$cfg" \
            bash "$SCRIPT" "bug-batch/sess-abc/tier-3-batch-1" >/dev/null 2>&1
    ) || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: expected exit 0 with pushed batch branch, got $exit_code" >&2
        FAIL=$((FAIL+1))
    fi
}
test_ci_pr_branch_pushed_passes

print_results
