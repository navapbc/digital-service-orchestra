#!/usr/bin/env bash
# tests/hooks/test-test-gate-fast-path.sh
# RED tests for bug 38a0-e706: pre-commit-test-gate.sh fast-path optimization.
#
# TEST 1: fast_path_exits_quickly_with_valid_status
#   When test-gate-status exists with "passed" and a matching diff hash, the hook
#   must complete in under 2 seconds. Currently FAILS because the hook performs
#   fuzzy matching per-file BEFORE checking the status file.
#
# TEST 2: wrapper_exits_zero_when_sentinel_present
#   When the hook exits 124 (timeout) but a sentinel file with a valid nonce exists,
#   the wrapper must exit 0. Currently FAILS because the wrapper has no sentinel logic
#   and unconditionally exits 124 on timeout.
#
# Usage: bash tests/hooks/test-test-gate-fast-path.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-test-gate.sh"
COMPUTE_HASH_SCRIPT="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"
WRAPPER="$DSO_PLUGIN_DIR/scripts/pre-commit-wrapper.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Helper: create a fresh isolated git repo ─────────────────────────────────
make_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    git -C "$tmpdir" config commit.gpgsign false
    echo "initial" > "$tmpdir/README.md"
    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -q -m "init"
    echo "$tmpdir"
}

# ── Helper: create a fresh artifacts directory ────────────────────────────────
make_artifacts_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    echo "$tmpdir"
}

# ── Helper: compute the diff hash for staged files in a repo ─────────────────
compute_hash_in_repo() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        bash "$COMPUTE_HASH_SCRIPT" 2>/dev/null
    )
}

echo "=== test-test-gate-fast-path.sh (RED phase: bug 38a0-e706) ==="
echo ""

# ============================================================
# TEST 1: fast_path_exits_quickly_with_valid_status
#
# Arrange: an isolated repo with many staged source files (to amplify fuzzy
# matching cost), each with an associated test file on disk, plus a valid
# test-gate-status file whose diff_hash matches the staged content.
#
# Act: time the gate hook execution.
#
# Assert: the hook completes in under 2 seconds and exits 0.
#
# RED: currently FAILS because the hook does fuzzy_find_associated_tests for
# every staged file before reading test-gate-status. Each fuzzy match call
# walks the test directory tree (~0.3-0.5s on large repos), so 20 staged
# files takes 6-10 seconds before the status check even begins.
# ============================================================
echo "--- TEST 1: fast_path_exits_quickly_with_valid_status ---"

_repo=$(make_test_repo)
_artifacts=$(make_artifacts_dir)

# Create 20 source files and their paired test files.
# The fuzzy match algorithm pairs "src/worker_NN.py" -> "tests/test_worker_NN.py"
# because the normalized source name is a substring of the normalized test name.
# With 20 source files the un-optimized hook spends 6-22s on matching; the
# optimized fast-path should skip all of this when status is already valid.
mkdir -p "$_repo/src" "$_repo/tests"
for i in $(seq 1 20); do
    printf 'def worker_%02d(): return %d\n' "$i" "$i" > "$_repo/src/worker_$(printf '%02d' $i).py"
    printf 'def test_worker_%02d(): assert True\n' "$i" > "$_repo/tests/test_worker_$(printf '%02d' $i).py"
done

# Commit all files so there is a clean HEAD
git -C "$_repo" add -A
git -C "$_repo" commit -q -m "add workers"

# Stage a small edit to one source file to produce a non-empty staged diff
printf '# updated\n' >> "$_repo/src/worker_01.py"
git -C "$_repo" add src/worker_01.py

# Compute the hash of the current staged content so we can write a matching status
_diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
if [[ -z "$_diff_hash" ]]; then
    echo "SKIP: compute-diff-hash.sh unavailable — cannot set up valid hash" >&2
    assert_eq "fast_path: hash computation available" "non-empty" "empty"
else
    # Write a valid test-gate-status with the matching hash
    mkdir -p "$_artifacts"
    printf 'passed\ndiff_hash=%s\ntimestamp=2026-03-31T00:00:00Z\ntested_files=tests/test_worker_01.py\n' \
        "$_diff_hash" > "$_artifacts/test-gate-status"

    # Time the hook execution.
    # We use the COMPUTE_DIFF_HASH_OVERRIDE to inject the real script so hash
    # comparison works, and WORKFLOW_PLUGIN_ARTIFACTS_DIR to point at our status file.
    _start=$(date +%s)
    _exit_code=0
    (
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export COMPUTE_DIFF_HASH_OVERRIDE="$COMPUTE_HASH_SCRIPT"
        bash "$GATE_HOOK" 2>/dev/null
    ) || _exit_code=$?
    _end=$(date +%s)
    _elapsed=$((_end - _start))

    # The hook must exit 0 (valid status, matching hash)
    assert_eq "fast_path: hook exits 0 with valid status" "0" "$_exit_code"

    # The hook must complete in under 2 seconds.
    # This is the RED assertion: currently FAILS because per-file fuzzy matching
    # happens before the status check. After the fix, the status check happens
    # first and exits immediately, taking <1 second.
    _elapsed_ok="no"
    if [[ "$_elapsed" -lt 2 ]]; then
        _elapsed_ok="yes"
    fi
    assert_eq "fast_path: hook completes in under 2 seconds (elapsed: ${_elapsed}s)" "yes" "$_elapsed_ok"
fi

echo ""

echo ""
print_summary
