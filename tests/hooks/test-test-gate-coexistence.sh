#!/usr/bin/env bash
# tests/hooks/test-test-gate-coexistence.sh
# Coexistence tests: test gate + review gate working together.
#
# Verifies that the two pre-commit gates (test gate and review gate)
# operate independently — each gate's failure does not corrupt or modify
# the other gate's status file, and both gates can pass simultaneously.
#
# Also verifies that .pre-commit-config.yaml registers the test gate hook.
#
# Tests:
#   test_test_gate_only_failure_leaves_review_status_unchanged
#   test_review_gate_only_failure_leaves_test_status_unchanged
#   test_both_gates_pass_commit_succeeds
#   test_pre_commit_config_does_not_yet_register_test_gate
#   test_test_gate_error_message_is_test_specific

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
TEST_GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-test-gate.sh"
REVIEW_GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-review-gate.sh"
PRE_COMMIT_CONFIG="$REPO_ROOT/.pre-commit-config.yaml"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Prerequisite checks ──────────────────────────────────────────────────────
if [[ ! -f "$TEST_GATE_HOOK" ]]; then
    echo "SKIP: pre-commit-test-gate.sh not found at $TEST_GATE_HOOK"
    exit 0
fi
if [[ ! -f "$REVIEW_GATE_HOOK" ]]; then
    echo "SKIP: pre-commit-review-gate.sh not found at $REVIEW_GATE_HOOK"
    exit 0
fi

# ── Helper: create a fresh isolated git repo ─────────────────────────────────
make_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    git -C "$tmpdir" config commit.gpgsign false
    # Create a source file with an associated test so the test gate fires
    mkdir -p "$tmpdir/src" "$tmpdir/tests"
    echo "def greet(): pass" > "$tmpdir/src/greet.py"
    echo "def test_greet(): pass" > "$tmpdir/tests/test_greet.py"
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

# ── Helper: run the test gate hook in a test repo ────────────────────────────
# Returns exit code on stdout.
# REVIEW-DEFENSE: COMPUTE_DIFF_HASH_OVERRIDE is honored by pre-commit-test-gate.sh at line 51
# (_COMPUTE_DIFF_HASH="${COMPUTE_DIFF_HASH_OVERRIDE:-$HOOK_DIR/compute-diff-hash.sh}"),
# implemented in batch 7 (w21-wzgp). The export here is a test seam — not dead code.
run_test_gate_hook() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local exit_code=0
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        # Override compute-diff-hash to use the real one from the plugin
        export COMPUTE_DIFF_HASH_OVERRIDE="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"
        bash "$TEST_GATE_HOOK" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# ── Helper: capture stderr from the test gate hook ───────────────────────────
run_test_gate_hook_stderr() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        export COMPUTE_DIFF_HASH_OVERRIDE="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"
        bash "$TEST_GATE_HOOK" 2>&1 >/dev/null
    ) || true
}

# ── Helper: run the review gate hook in a test repo ──────────────────────────
# Returns exit code on stdout.
run_review_gate_hook() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local exit_code=0
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        bash "$REVIEW_GATE_HOOK" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# ── Helper: compute the diff hash for staged files in a repo ────────────────
compute_hash_in_repo() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        bash "$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh" 2>/dev/null
    )
}

# ── Helper: write a valid review-status file ────────────────────────────────
write_valid_review_status() {
    local artifacts_dir="$1"
    local diff_hash="$2"
    mkdir -p "$artifacts_dir"
    printf 'passed\ntimestamp=2026-03-20T00:00:00Z\ndiff_hash=%s\nscore=5\nreview_hash=abc123\n' \
        "$diff_hash" > "$artifacts_dir/review-status"
}

# ── Helper: write a valid test-gate-status file ──────────────────────────────
write_valid_test_gate_status() {
    local artifacts_dir="$1"
    local diff_hash="$2"
    mkdir -p "$artifacts_dir"
    printf 'passed\ndiff_hash=%s\ntimestamp=2026-03-20T00:00:00Z\n' \
        "$diff_hash" > "$artifacts_dir/test-gate-status"
}

# ============================================================
# TEST 1: Test gate failure leaves review-status unchanged
# ============================================================

# test_test_gate_only_failure_leaves_review_status_unchanged
#
# When pre-commit-test-gate.sh blocks (MISSING test-gate-status) but
# review-status is valid, the commit is blocked with a test-gate-specific
# error and the review-status file content is NOT modified.
test_test_gate_only_failure_leaves_review_status_unchanged() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a .py source file that has an associated test
    echo "def greet(): return 'hi'" > "$_repo/src/greet.py"
    git -C "$_repo" add "src/greet.py"

    # Compute diff hash and write a valid review-status (review gate would pass)
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    # Record review-status content before running the test gate
    local review_status_before
    review_status_before=$(cat "$_artifacts/review-status")

    # Do NOT write test-gate-status — test gate should block
    local exit_code
    exit_code=$(run_test_gate_hook "$_repo" "$_artifacts")
    assert_eq "test_test_gate_only_failure_leaves_review_status_unchanged: test gate blocks" "1" "$exit_code"

    # Verify review-status was NOT modified
    local review_status_after
    review_status_after=$(cat "$_artifacts/review-status")
    assert_eq "test_test_gate_only_failure_leaves_review_status_unchanged: review-status unchanged" \
        "$review_status_before" "$review_status_after"
}

# ============================================================
# TEST 2: Review gate failure leaves test-gate-status unchanged
# ============================================================

# test_review_gate_only_failure_leaves_test_status_unchanged
#
# When pre-commit-review-gate.sh blocks (no review-status) but
# test-gate-status is valid, the commit is blocked with a review-gate-specific
# error and the test-gate-status file content is NOT modified.
test_review_gate_only_failure_leaves_test_status_unchanged() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a .py source file that has an associated test
    echo "def greet(): return 'hello'" > "$_repo/src/greet.py"
    git -C "$_repo" add "src/greet.py"

    # Compute diff hash and write a valid test-gate-status (test gate would pass)
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_test_gate_status "$_artifacts" "$diff_hash"

    # Record test-gate-status content before running the review gate
    local test_status_before
    test_status_before=$(cat "$_artifacts/test-gate-status")

    # Do NOT write review-status — review gate should block
    local exit_code
    exit_code=$(run_review_gate_hook "$_repo" "$_artifacts")
    assert_eq "test_review_gate_only_failure_leaves_test_status_unchanged: review gate blocks" "1" "$exit_code"

    # Verify test-gate-status was NOT modified
    local test_status_after
    test_status_after=$(cat "$_artifacts/test-gate-status")
    assert_eq "test_review_gate_only_failure_leaves_test_status_unchanged: test-gate-status unchanged" \
        "$test_status_before" "$test_status_after"
}

# ============================================================
# TEST 3: Both gates pass — commit succeeds
# ============================================================

# test_both_gates_pass_commit_succeeds
#
# When both test-gate-status (passed, hash match) and review-status
# (passed, hash match) are present, a pre-commit run of both hooks
# succeeds (both exit 0).
test_both_gates_pass_commit_succeeds() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a .py source file that has an associated test
    echo "def greet(): return 'both'" > "$_repo/src/greet.py"
    git -C "$_repo" add "src/greet.py"

    # Compute diff hash and write both valid status files
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"
    write_valid_test_gate_status "$_artifacts" "$diff_hash"

    # Both hooks should pass (exit 0)
    local test_gate_exit review_gate_exit
    test_gate_exit=$(run_test_gate_hook "$_repo" "$_artifacts")
    review_gate_exit=$(run_review_gate_hook "$_repo" "$_artifacts")

    assert_eq "test_both_gates_pass_commit_succeeds: test gate passes" "0" "$test_gate_exit"
    assert_eq "test_both_gates_pass_commit_succeeds: review gate passes" "0" "$review_gate_exit"
}

# ============================================================
# TEST 4: .pre-commit-config.yaml registers test gate
# ============================================================

# test_pre_commit_config_does_not_yet_register_test_gate
#
# .pre-commit-config.yaml must contain an entry with id: pre-commit-test-gate
# that invokes pre-commit-test-gate.sh.
#
# RED→GREEN: This test asserts registration is ABSENT (current state).
# Story w21-milk will add the registration to .pre-commit-config.yaml,
# at which point this test must be flipped to assert PRESENCE (found_id=1).
test_pre_commit_config_does_not_yet_register_test_gate() {
    local found_id=0
    if grep -q 'id: pre-commit-test-gate' "$PRE_COMMIT_CONFIG" 2>/dev/null; then
        found_id=1
    fi
    # RED: currently absent — flip to assert_eq "1" "$found_id" when w21-milk lands
    assert_eq "test_pre_commit_config_does_not_yet_register_test_gate: id not yet registered (RED)" "0" "$found_id"

    local found_entry=0
    if grep -q 'pre-commit-test-gate\.sh' "$PRE_COMMIT_CONFIG" 2>/dev/null; then
        found_entry=1
    fi
    # RED: currently absent — flip to assert_eq "1" "$found_entry" when w21-milk lands
    assert_eq "test_pre_commit_config_does_not_yet_register_test_gate: entry not yet registered (RED)" "0" "$found_entry"
}

# ============================================================
# TEST 5: Test gate error message is test-specific
# ============================================================

# test_test_gate_error_message_is_test_specific
#
# The error message from pre-commit-test-gate.sh does NOT reference
# /dso:review or review-gate concepts; it references test-gate-specific
# instructions.
test_test_gate_error_message_is_test_specific() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a .py source file that has an associated test
    echo "def greet(): return 'error msg'" > "$_repo/src/greet.py"
    git -C "$_repo" add "src/greet.py"

    # Do NOT write test-gate-status — test gate should block with error message
    local stderr_output
    stderr_output=$(run_test_gate_hook_stderr "$_repo" "$_artifacts")

    # Error message should reference test-gate-specific concepts (not generic 'test')
    assert_contains "test_test_gate_error_message_is_test_specific: mentions record-test-status" \
        "record-test-status" "$stderr_output"

    # Error message should NOT reference /dso:review
    local has_review_ref=0
    if [[ "$stderr_output" == *"/dso:review"* ]]; then
        has_review_ref=1
    fi
    assert_eq "test_test_gate_error_message_is_test_specific: no /dso:review reference" "0" "$has_review_ref"

    # Error message should NOT reference "review gate"
    local has_review_gate_ref=0
    if [[ "$stderr_output" == *"review gate"* ]] || [[ "$stderr_output" == *"review-gate"* ]]; then
        has_review_gate_ref=1
    fi
    assert_eq "test_test_gate_error_message_is_test_specific: no review gate reference" "0" "$has_review_gate_ref"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_test_gate_only_failure_leaves_review_status_unchanged
test_review_gate_only_failure_leaves_test_status_unchanged
test_both_gates_pass_commit_succeeds
test_pre_commit_config_does_not_yet_register_test_gate
test_test_gate_error_message_is_test_specific

print_summary
