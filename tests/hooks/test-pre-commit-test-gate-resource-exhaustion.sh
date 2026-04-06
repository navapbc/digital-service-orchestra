#!/usr/bin/env bash
# tests/hooks/test-pre-commit-test-gate-resource-exhaustion.sh
# Behavioral tests verifying that pre-commit-test-gate.sh treats
# "resource_exhaustion" status as non-blocking at both checkpoints.
#
# Test cases:
#   1. test_fast_path_allows_resource_exhaustion — exits 0 when status is
#      resource_exhaustion and diff_hash matches (fast-path short-circuit)
#   2. test_full_path_allows_resource_exhaustion — exits 0 (or non-1-for-status)
#      when resource_exhaustion + stale hash forces the full-path check;
#      the gate must not block on the status value itself
#   3. test_resource_exhaustion_emits_warning — stderr contains a warning
#      about resource exhaustion when status is resource_exhaustion
#   4. test_failed_status_still_blocks — exit 1 when status is "failed" +
#      matching diff_hash; confirms resource_exhaustion is not a blanket allow
#
# All tests run against the actual pre-commit-test-gate.sh binary using isolated
# temp git repos and override WORKFLOW_PLUGIN_ARTIFACTS_DIR for isolation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-test-gate.sh"
COMPUTE_HASH_SCRIPT="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

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

# ── Helper: run the gate hook, return exit code on stdout ────────────────────
run_gate_hook() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local exit_code=0
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        bash "$GATE_HOOK" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# ── Helper: capture stderr from the gate hook ─────────────────────────────────
run_gate_hook_stderr() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        bash "$GATE_HOOK" 2>&1 >/dev/null
    ) || true
}

# ── Helper: compute the diff hash for staged files in a repo ──────────────────
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

# ── Helper: write a test-gate-status file with resource_exhaustion ────────────
write_resource_exhaustion_status() {
    local artifacts_dir="$1"
    local diff_hash="$2"
    mkdir -p "$artifacts_dir"
    printf 'resource_exhaustion\ndiff_hash=%s\ntimestamp=2026-04-05T00:00:00Z\ntested_files=tests/test_example.py\n' \
        "$diff_hash" > "$artifacts_dir/test-gate-status"
}

# ── Helper: write a test-gate-status file with "failed" status ────────────────
write_failed_status() {
    local artifacts_dir="$1"
    local diff_hash="$2"
    mkdir -p "$artifacts_dir"
    printf 'failed\ndiff_hash=%s\ntimestamp=2026-04-05T00:00:00Z\ntested_files=tests/test_example.py\nfailed_tests=tests/test_example.py\n' \
        "$diff_hash" > "$artifacts_dir/test-gate-status"
}

# ── Helper: set up a repo with a source file + associated test staged ─────────
# Populates the repo with:
#   src/widget.py  (source, has associated test via fuzzy match)
#   tests/test_widget.py  (associated test file)
# Commits both, then modifies widget.py and stages the change.
# Returns nothing; modifies the repo in place.
setup_staged_source_with_test() {
    local repo_dir="$1"
    mkdir -p "$repo_dir/src" "$repo_dir/tests"
    echo 'def widget(): return 1' > "$repo_dir/src/widget.py"
    echo 'def test_widget(): assert True' > "$repo_dir/tests/test_widget.py"
    git -C "$repo_dir" add -A
    git -C "$repo_dir" commit -q -m "add widget"
    echo '# changed' >> "$repo_dir/src/widget.py"
    git -C "$repo_dir" add "$repo_dir/src/widget.py"
}

# ============================================================
# TEST 1: test_fast_path_allows_resource_exhaustion
# When test-gate-status first line is "resource_exhaustion" AND
# the diff_hash matches the current staged content, the gate must
# exit 0 (non-blocking). This exercises the fast-path check at
# line ~471 of pre-commit-test-gate.sh.
#
# RED: Currently the fast-path only allows "passed"; resource_exhaustion
# falls through to the full-path where it hits the blocking else branch
# and exits 1.
# ============================================================
test_fast_path_allows_resource_exhaustion() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    setup_staged_source_with_test "$_repo"

    # Compute the real hash for the current staged state so the fast-path
    # hash comparison succeeds.
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")

    write_resource_exhaustion_status "$_artifacts" "$diff_hash"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")

    # Gate must NOT block: resource_exhaustion is non-blocking (like timeout/partial)
    assert_eq "test_fast_path_allows_resource_exhaustion: gate exits 0" "0" "$exit_code"
}

# ============================================================
# TEST 2: test_full_path_allows_resource_exhaustion
# When test-gate-status first line is "resource_exhaustion" AND
# the diff_hash is STALE (does not match), the fast-path falls
# through to the full enforcement path. At the full-path status
# check (~line 594), the gate must NOT exit 1 due to
# resource_exhaustion — it should treat it as non-blocking (like
# timeout/partial) and fall through to the hash mismatch check.
# The commit may still be blocked, but ONLY because of the hash
# mismatch — not because of the status value itself.
#
# RED: Currently resource_exhaustion hits the blocking else branch
# at line ~603 and exits with "tests did not pass" message.
# ============================================================
test_full_path_allows_resource_exhaustion() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    setup_staged_source_with_test "$_repo"

    # Write a STALE diff_hash — this ensures the fast-path falls through
    # and the full enforcement path runs. The full path must not block on
    # the resource_exhaustion status itself.
    write_resource_exhaustion_status "$_artifacts" "stale_hash_does_not_match_anything"

    local exit_code stderr_output
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    stderr_output=$(run_gate_hook_stderr "$_repo" "$_artifacts")

    # If the gate blocked on the status, stderr will say "tests did not pass".
    # After correct implementation it should say "code changed since tests were
    # recorded" (hash mismatch), not "tests did not pass" (status rejection).
    # We assert the status-blocked message is NOT present.
    local status_block_msg="tests did not pass"
    if [[ "$stderr_output" == *"$status_block_msg"* ]]; then
        assert_eq "test_full_path_allows_resource_exhaustion: gate must NOT block on status value" \
            "no_status_block" "blocked_on_status"
    else
        assert_eq "test_full_path_allows_resource_exhaustion: gate must NOT block on status value" \
            "no_status_block" "no_status_block"
    fi
}

# ============================================================
# TEST 3: test_resource_exhaustion_emits_warning
# When test-gate-status is resource_exhaustion and the hash
# matches (allowing the commit), the gate must emit a warning
# on stderr — similar to the timeout/partial warning pattern.
# This gives developers visibility that resource limits were hit.
#
# RED: Currently resource_exhaustion exits 1 with a "tests did
# not pass" error — no warning is emitted, and the commit is
# blocked rather than warned-and-allowed.
# ============================================================
test_resource_exhaustion_emits_warning() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    setup_staged_source_with_test "$_repo"

    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")

    write_resource_exhaustion_status "$_artifacts" "$diff_hash"

    local stderr_output
    stderr_output=$(run_gate_hook_stderr "$_repo" "$_artifacts")

    # Gate should emit a warning mentioning "resource" or "resource_exhaustion"
    # on stderr when failing open for this status.
    assert_contains "test_resource_exhaustion_emits_warning: warning on stderr" \
        "resource" "$stderr_output"
}

# ============================================================
# TEST 4: test_failed_status_still_blocks
# When test-gate-status first line is "failed" and the diff_hash
# matches the current staged content, the gate must exit 1
# (blocking). This confirms that resource_exhaustion is
# specifically non-blocking — not a blanket allow for all
# non-"passed" statuses.
#
# This test is expected to PASS even in RED phase because
# "failed" is already a blocking status in the current
# implementation. It acts as a regression guard.
# ============================================================
test_failed_status_still_blocks() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    setup_staged_source_with_test "$_repo"

    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")

    write_failed_status "$_artifacts" "$diff_hash"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")

    # Gate must BLOCK when status is "failed" — this is the expected behavior
    assert_ne "test_failed_status_still_blocks: gate blocks on failed status (exit != 0)" \
        "0" "$exit_code"
}

# ── Helper: run a test function and print PASS/FAIL per-function result ───────
run_test() {
    local _fn="$1"
    local _fail_before=$FAIL
    "$_fn"
    if [[ "$FAIL" -eq "$_fail_before" ]]; then
        echo "PASS: $_fn"
    else
        echo "FAIL: $_fn"
    fi
}

# ── Run all tests ────────────────────────────────────────────────────────────
run_test test_fast_path_allows_resource_exhaustion
run_test test_full_path_allows_resource_exhaustion
run_test test_resource_exhaustion_emits_warning
run_test test_failed_status_still_blocks

print_summary
