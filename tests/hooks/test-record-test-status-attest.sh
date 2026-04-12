#!/usr/bin/env bash
set -uo pipefail
# tests/hooks/test-record-test-status-attest.sh
# RED tests for record-test-status.sh --attest mode.
# The --attest flag reads a source worktree's test-gate-status, validates it,
# and writes an attested status to the session artifacts directory.
#
# 7 test functions:
#   test_attest_writes_passed_status
#   test_attest_writes_current_diff_hash
#   test_attest_includes_attest_source
#   test_attest_unions_tested_files
#   test_attest_refuses_missing_source
#   test_attest_refuses_failed_source
#   test_attest_refuses_stale_source

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/record-test-status.sh"
COMPUTE_HASH_SCRIPT="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$PLUGIN_ROOT/tests/lib/git-fixtures.sh"

# Disable commit signing for test git repos
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

# Track temp dirs for cleanup
_TEST_TMPDIRS=()
_cleanup_attest_tests() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_attest_tests EXIT

# Helper: create a test repo with staged changes so compute-diff-hash works
create_attest_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test-attest-XXXXXX")
    _TEST_TMPDIRS+=("$tmpdir")
    clone_test_repo "$tmpdir/repo"
    # Create a source file and stage a change so diff hash is non-empty
    echo "content" > "$tmpdir/repo/src.py"
    git -C "$tmpdir/repo" add src.py
    git -C "$tmpdir/repo" commit -m "add src" --quiet 2>/dev/null
    echo "modified" > "$tmpdir/repo/src.py"
    git -C "$tmpdir/repo" add src.py
    echo "$tmpdir/repo"
}

# Helper: compute the diff hash for a repo
get_diff_hash() {
    local repo="$1"
    (cd "$repo" && bash "$COMPUTE_HASH_SCRIPT" 2>/dev/null)
}

# Helper: create a source worktree artifacts dir with a valid test-gate-status
create_source_artifacts() {
    local status="$1"
    local diff_hash="$2"
    local tested_files="${3:-tests/test_alpha.py,tests/test_beta.py}"
    local artifacts_dir
    artifacts_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-attest-src-artifacts-XXXXXX")
    _TEST_TMPDIRS+=("$artifacts_dir")
    cat > "$artifacts_dir/test-gate-status" <<EOF
${status}
diff_hash=${diff_hash}
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
tested_files=${tested_files}
EOF
    echo "$artifacts_dir"
}

# ============================================================
# test_attest_writes_passed_status
# Given a source test-gate-status with status=passed and valid hash,
# --attest should write status=passed to session artifacts
# ============================================================
echo ""
echo "=== test_attest_writes_passed_status ==="
_snapshot_fail

REPO_1=$(create_attest_test_repo)
HASH_1=$(get_diff_hash "$REPO_1")
SRC_ARTIFACTS_1=$(create_source_artifacts "passed" "$HASH_1")
SESSION_ARTIFACTS_1=$(mktemp -d "${TMPDIR:-/tmp}/test-attest-session-XXXXXX")
_TEST_TMPDIRS+=("$SESSION_ARTIFACTS_1")

# Run --attest pointing to the source artifacts directory
_exit_code=0
(
    cd "$REPO_1"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$SESSION_ARTIFACTS_1" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$HOOK" --attest "$SRC_ARTIFACTS_1"
) >/dev/null 2>&1 || _exit_code=$?

assert_eq "attest exits zero" "0" "$_exit_code"

# Check the output test-gate-status has status=passed
_output_status=""
if [[ -f "$SESSION_ARTIFACTS_1/test-gate-status" ]]; then
    _output_status=$(head -1 "$SESSION_ARTIFACTS_1/test-gate-status")
fi
assert_eq "output status is passed" "passed" "$_output_status"

assert_pass_if_clean "test_attest_writes_passed_status"

# ============================================================
# test_attest_writes_current_diff_hash
# The output diff_hash should match compute-diff-hash.sh for the session repo
# ============================================================
echo ""
echo "=== test_attest_writes_current_diff_hash ==="
_snapshot_fail

REPO_2=$(create_attest_test_repo)
HASH_2=$(get_diff_hash "$REPO_2")
SRC_ARTIFACTS_2=$(create_source_artifacts "passed" "$HASH_2")
SESSION_ARTIFACTS_2=$(mktemp -d "${TMPDIR:-/tmp}/test-attest-session-XXXXXX")
_TEST_TMPDIRS+=("$SESSION_ARTIFACTS_2")

_exit_code=0
(
    cd "$REPO_2"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$SESSION_ARTIFACTS_2" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$HOOK" --attest "$SRC_ARTIFACTS_2"
) >/dev/null 2>&1 || _exit_code=$?

_output_hash=""
if [[ -f "$SESSION_ARTIFACTS_2/test-gate-status" ]]; then
    _output_hash=$(grep '^diff_hash=' "$SESSION_ARTIFACTS_2/test-gate-status" 2>/dev/null | head -1 | cut -d= -f2)
fi

# The output hash should match the session repo's current diff hash
_expected_hash=$(get_diff_hash "$REPO_2")
assert_eq "output diff_hash matches current" "$_expected_hash" "$_output_hash"

assert_pass_if_clean "test_attest_writes_current_diff_hash"

# ============================================================
# test_attest_includes_attest_source
# The output should include an attest_source field identifying the source worktree
# ============================================================
echo ""
echo "=== test_attest_includes_attest_source ==="
_snapshot_fail

REPO_3=$(create_attest_test_repo)
HASH_3=$(get_diff_hash "$REPO_3")
SRC_ARTIFACTS_3=$(create_source_artifacts "passed" "$HASH_3")
SESSION_ARTIFACTS_3=$(mktemp -d "${TMPDIR:-/tmp}/test-attest-session-XXXXXX")
_TEST_TMPDIRS+=("$SESSION_ARTIFACTS_3")

_exit_code=0
(
    cd "$REPO_3"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$SESSION_ARTIFACTS_3" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$HOOK" --attest "$SRC_ARTIFACTS_3"
) >/dev/null 2>&1 || _exit_code=$?

_attest_source=""
if [[ -f "$SESSION_ARTIFACTS_3/test-gate-status" ]]; then
    _attest_source=$(grep '^attest_source=' "$SESSION_ARTIFACTS_3/test-gate-status" 2>/dev/null | head -1 | cut -d= -f2)
fi

# attest_source should be non-empty and reference the source artifacts path
assert_ne "attest_source is present" "" "$_attest_source"

assert_pass_if_clean "test_attest_includes_attest_source"

# ============================================================
# test_attest_unions_tested_files
# tested_files in output should be union of source tested_files and any
# session-local test files
# ============================================================
echo ""
echo "=== test_attest_unions_tested_files ==="
_snapshot_fail

REPO_4=$(create_attest_test_repo)
HASH_4=$(get_diff_hash "$REPO_4")
# Source has alpha and beta tests
SRC_ARTIFACTS_4=$(create_source_artifacts "passed" "$HASH_4" "tests/test_alpha.py,tests/test_beta.py")
SESSION_ARTIFACTS_4=$(mktemp -d "${TMPDIR:-/tmp}/test-attest-session-XXXXXX")
_TEST_TMPDIRS+=("$SESSION_ARTIFACTS_4")

# Create a .test-index mapping in the session repo that maps src.py to a local test
mkdir -p "$REPO_4/tests"
cat > "$REPO_4/tests/test_src.py" <<'PYEOF'
def test_src():
    assert True
PYEOF
git -C "$REPO_4" add tests/test_src.py
# Also create a .test-index so the hook can find the local association
echo "src.py: tests/test_src.py" > "$REPO_4/.test-index"
git -C "$REPO_4" add .test-index

_exit_code=0
(
    cd "$REPO_4"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$SESSION_ARTIFACTS_4" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$HOOK" --attest "$SRC_ARTIFACTS_4"
) >/dev/null 2>&1 || _exit_code=$?

_tested_files=""
if [[ -f "$SESSION_ARTIFACTS_4/test-gate-status" ]]; then
    _tested_files=$(grep '^tested_files=' "$SESSION_ARTIFACTS_4/test-gate-status" 2>/dev/null | head -1 | cut -d= -f2)
fi

# Should contain files from both source and session
assert_contains "contains source test_alpha" "test_alpha" "$_tested_files"
assert_contains "contains source test_beta" "test_beta" "$_tested_files"

assert_pass_if_clean "test_attest_unions_tested_files"

# ============================================================
# test_attest_refuses_missing_source
# When source test-gate-status does not exist, --attest should exit non-zero
# ============================================================
echo ""
echo "=== test_attest_refuses_missing_source ==="
_snapshot_fail

REPO_5=$(create_attest_test_repo)
EMPTY_ARTIFACTS_5=$(mktemp -d "${TMPDIR:-/tmp}/test-attest-empty-XXXXXX")
_TEST_TMPDIRS+=("$EMPTY_ARTIFACTS_5")
# No test-gate-status file in source artifacts dir
SESSION_ARTIFACTS_5=$(mktemp -d "${TMPDIR:-/tmp}/test-attest-session-XXXXXX")
_TEST_TMPDIRS+=("$SESSION_ARTIFACTS_5")

_exit_code=0
(
    cd "$REPO_5"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$SESSION_ARTIFACTS_5" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$HOOK" --attest "$EMPTY_ARTIFACTS_5"
) >/dev/null 2>&1 || _exit_code=$?

assert_ne "exits non-zero for missing source" "0" "$_exit_code"

assert_pass_if_clean "test_attest_refuses_missing_source"

# ============================================================
# test_attest_refuses_failed_source
# When source status is "failed", --attest should exit non-zero
# ============================================================
echo ""
echo "=== test_attest_refuses_failed_source ==="
_snapshot_fail

REPO_6=$(create_attest_test_repo)
HASH_6=$(get_diff_hash "$REPO_6")
SRC_ARTIFACTS_6=$(create_source_artifacts "failed" "$HASH_6")
SESSION_ARTIFACTS_6=$(mktemp -d "${TMPDIR:-/tmp}/test-attest-session-XXXXXX")
_TEST_TMPDIRS+=("$SESSION_ARTIFACTS_6")

_exit_code=0
(
    cd "$REPO_6"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$SESSION_ARTIFACTS_6" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$HOOK" --attest "$SRC_ARTIFACTS_6"
) >/dev/null 2>&1 || _exit_code=$?

assert_ne "exits non-zero for failed source" "0" "$_exit_code"

assert_pass_if_clean "test_attest_refuses_failed_source"

# ============================================================
# test_attest_refuses_stale_source
# When source diff_hash doesn't match current worktree content, exit non-zero
# ============================================================
echo ""
echo "=== test_attest_refuses_stale_source ==="
_snapshot_fail

REPO_7=$(create_attest_test_repo)
# Create source artifacts with a stale (non-matching) diff hash
SRC_ARTIFACTS_7=$(create_source_artifacts "passed" "stale_hash_that_does_not_match_anything")
SESSION_ARTIFACTS_7=$(mktemp -d "${TMPDIR:-/tmp}/test-attest-session-XXXXXX")
_TEST_TMPDIRS+=("$SESSION_ARTIFACTS_7")

_exit_code=0
(
    cd "$REPO_7"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$SESSION_ARTIFACTS_7" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$HOOK" --attest "$SRC_ARTIFACTS_7"
) >/dev/null 2>&1 || _exit_code=$?

assert_ne "exits non-zero for stale hash" "0" "$_exit_code"

assert_pass_if_clean "test_attest_refuses_stale_source"

# ============================================================
print_summary
