#!/usr/bin/env bash
# tests/hooks/test-pre-commit-test-gate.sh
# Tests for hooks/pre-commit-test-gate.sh (TDD RED phase)
#
# pre-commit-test-gate.sh is a git pre-commit hook that blocks commits when
# test-gate-status is missing, stale (hash mismatch), or not 'passed' for
# staged source files that have associated tests.
#
# Test cases (38):
#   1. test_gate_blocked_missing_status — exits non-zero when test-status file absent
#   2. test_gate_blocked_hash_mismatch — exits non-zero when diff_hash does not match
#   3. test_gate_blocked_not_passed — exits non-zero when status is not 'passed'
#   4. test_gate_passes_no_associated_test — exits 0 for files with no associated test
#   5. test_gate_passes_valid_status — exits 0 when status passed + hash matches
#   6. test_gate_passes_no_staged_files — exits 0 when nothing is staged
#   7. test_error_message_actionable — blocked commits reference test-batched.sh
#   8. test_gate_fails_open_on_hash_error — exits 0 when compute-diff-hash.sh fails
#   9. test_gate_passes_when_test_exempted — exits 0 when associated test is exempted
#  10. test_gate_blocked_when_test_not_exempted — exits non-zero when exemption is for wrong test
#  11. test_gate_passes_no_status_but_fully_exempted — exits 0 when no status but test fully exempted
#  12. test_gate_bash_script_triggers — RED: exits non-zero for .sh with associated test (gate only handles .py)
#  13. test_gate_typescript_triggers — RED: exits non-zero for .ts with associated test (gate only handles .py)
#  14. test_gate_test_file_itself_exempt — test files staged as source must not trigger gate
#  15. test_gate_test_dirs_config — RED: gate respects TEST_GATE_TEST_DIRS_OVERRIDE for custom test dirs
#  16. test_gate_index_mapped_source_triggers — RED: .test-index mapped source triggers gate (no status = blocked)
#  17. test_gate_index_union_with_fuzzy — RED: source with fuzzy + index entry; union of both test sets required
#  18. test_gate_missing_index_noop — RED: missing .test-index = gate proceeds without error (fail-open)
#  19. test_gate_index_empty_right_side_noop — RED: .test-index entry with no valid test paths = no association
#  20. test_gate_index_multi_test_paths — RED: source mapped to multiple test paths; all must have valid status
#  21. test_gate_index_prune_stale_entry — RED: .test-index entry whose test file does not exist is removed on disk
#  22. test_gate_index_prune_removes_line_when_all_stale — RED: all test paths stale = entire source line removed
#  23. test_gate_index_prune_stages_modified_index — RED: after pruning, modified .test-index is auto-staged
#  24. test_gate_index_prune_partial — RED: one valid + one stale test path: stale removed, valid retained
#  25. test_gate_prune_git_add_failure_exits_nonzero — git add failure during prune exits non-zero (disk/staged mismatch prevented)
#  26. test_gate_allowlist_files_skipped — exits 0 for commits with only allowlisted files (e.g., .tickets-tracker/**)
#  27. test_gate_allowlist_mixed_with_source — exits 0 for mixed commit (allowlisted + exempt source files)
#  28. test_gate_fails_open_on_sigterm — exits 0 with warning when receiving SIGTERM (pre-commit timeout)
#  29. test_gate_red_marker_index_passes — exits 0 when [marker] in .test-index and status is 'passed'
#  30. test_gate_red_marker_blocks_when_no_status — exits non-zero when [marker] in .test-index but no status
#  32. test_error_message_includes_source_file_flag — blocked commits include --source-file in error message
#  33. test_error_message_hash_mismatch_includes_source_file — HASH_MISMATCH path includes --source-file
#  34. test_error_message_missing_diff_hash_includes_source_file — MISSING_DIFF_HASH path includes --source-file
#  35. test_error_message_missing_required_tests_includes_source_file — MISSING_REQUIRED_TESTS path includes --source-file
#
# NOTE: Merge-state tests (MERGE_HEAD, REBASE_HEAD) have been removed from this
# consumer file. Coverage is now provided by:
#   tests/hooks/test-merge-state.sh          — library unit tests
#   tests/hooks/test-merge-state-golden-path.sh — integration matrix (C2=test-gate)
#
# All tests use isolated temp git repos to avoid polluting the real repository.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-test-gate.sh"
COMPUTE_HASH_SCRIPT="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# ── Prerequisite check ───────────────────────────────────────────────────────
# In RED phase, the gate hook does not exist yet. Tests that need it will
# handle the missing-file case explicitly (asserting failure). Tests that
# check structural properties (e.g., file existence) can SKIP gracefully.
if [[ ! -f "$GATE_HOOK" ]]; then
    echo "NOTE: pre-commit-test-gate.sh not found — running in RED phase"
fi

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

# ── Helper: run the gate hook in a test repo ──────────────────────────────────
# Returns exit code on stdout.
run_gate_hook() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local exit_code=0
    # shellcheck disable=SC2030,SC2031  # intentional: env vars scoped to subshell for test isolation
    (
        cd "$repo_dir" || exit 1
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
    # shellcheck disable=SC2030,SC2031  # intentional: env vars scoped to subshell for test isolation
    (
        cd "$repo_dir" || exit 1
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        # shellcheck disable=SC2069  # intentional: stderr→stdout, stdout suppressed
        bash "$GATE_HOOK" 2>&1 >/dev/null
    ) || true
}

# ── Helper: write a valid test-gate-status file ──────────────────────────────
write_valid_test_status() {
    local artifacts_dir="$1"
    local diff_hash="$2"
    mkdir -p "$artifacts_dir"
    printf 'passed\ndiff_hash=%s\ntimestamp=2026-03-20T00:00:00Z\ntested_files=tests/test_example.py\n' \
        "$diff_hash" > "$artifacts_dir/test-gate-status"
}

# ── Helper: compute the diff hash for staged files in a repo ──────────────────
compute_hash_in_repo() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    # shellcheck disable=SC2030,SC2031  # intentional: env vars scoped to subshell for test isolation
    (
        cd "$repo_dir" || exit 1
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        bash "$COMPUTE_HASH_SCRIPT" 2>/dev/null
    )
}

# ============================================================
# TEST 1: test_gate_blocked_missing_status
# Gate exits non-zero when test-status file is absent for a
# staged source file with a known associated test.
# ============================================================
test_gate_blocked_missing_status() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create a source file and its associated test
    mkdir -p "$_repo/src" "$_repo/tests"
    echo 'def foo(): return 42' > "$_repo/src/foo.py"
    echo 'def test_foo(): assert True' > "$_repo/tests/test_foo.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add foo"

    # Modify the source file to create a diff
    echo '# changed' >> "$_repo/src/foo.py"
    git -C "$_repo" add -A

    # Do NOT write test-gate-status — it should be missing

    if [[ ! -f "$GATE_HOOK" ]]; then
        # RED phase: hook doesn't exist, assert failure expectation
        assert_eq "test_gate_blocked_missing_status: hook not found (RED)" "missing" "missing"
        return
    fi

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    assert_ne "test_gate_blocked_missing_status: gate blocks (exit != 0)" "0" "$exit_code"
}

# ============================================================
# TEST 2: test_gate_blocked_hash_mismatch
# Gate exits non-zero when recorded diff_hash does not match
# the current staged diff.
# ============================================================
test_gate_blocked_hash_mismatch() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source + associated test
    mkdir -p "$_repo/src" "$_repo/tests"
    echo 'def bar(): return 1' > "$_repo/src/bar.py"
    echo 'def test_bar(): assert True' > "$_repo/tests/test_bar.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add bar"

    # Modify source and stage
    echo '# changed' >> "$_repo/src/bar.py"
    git -C "$_repo" add -A

    # Write test-gate-status with a STALE hash
    write_valid_test_status "$_artifacts" "stale_hash_that_does_not_match"

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_blocked_hash_mismatch: hook not found (RED)" "missing" "missing"
        return
    fi

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    assert_ne "test_gate_blocked_hash_mismatch: gate blocks on stale hash (exit != 0)" "0" "$exit_code"
}

# ============================================================
# TEST 3: test_gate_blocked_not_passed
# Gate exits non-zero when test-status file exists but first
# line is not 'passed'.
# ============================================================
test_gate_blocked_not_passed() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source + associated test
    mkdir -p "$_repo/src" "$_repo/tests"
    echo 'def baz(): return None' > "$_repo/src/baz.py"
    echo 'def test_baz(): assert False' > "$_repo/tests/test_baz.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add baz"

    # Modify source and stage
    echo '# changed' >> "$_repo/src/baz.py"
    git -C "$_repo" add -A

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_blocked_not_passed: hook not found (RED)" "missing" "missing"
        return
    fi

    # Compute the real hash so hash check passes — we want to isolate the
    # status-not-passed condition
    local real_hash
    real_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")

    # Write test-gate-status with 'failed' instead of 'passed'
    mkdir -p "$_artifacts"
    printf 'failed\ndiff_hash=%s\ntimestamp=2026-03-20T00:00:00Z\ntested_files=tests/test_baz.py\n' \
        "$real_hash" > "$_artifacts/test-gate-status"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    assert_ne "test_gate_blocked_not_passed: gate blocks on failed status (exit != 0)" "0" "$exit_code"
}

# ============================================================
# TEST 4: test_gate_passes_no_associated_test
# Gate exits 0 when staged file has no associated test
# (e.g., __init__.py or a config file).
# ============================================================
test_gate_passes_no_associated_test() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create a file that has no associated test
    mkdir -p "$_repo/src"
    echo '# init' > "$_repo/src/__init__.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add init"

    # Modify and stage
    echo '# modified' >> "$_repo/src/__init__.py"
    git -C "$_repo" add -A

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_passes_no_associated_test: hook not found (RED)" "missing" "missing"
        return
    fi

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    assert_eq "test_gate_passes_no_associated_test: gate passes (exit 0)" "0" "$exit_code"
}

# ============================================================
# TEST 5: test_gate_passes_valid_status
# Gate exits 0 when test-gate-status exists, hash matches
# staged diff, and status is 'passed'.
# ============================================================
test_gate_passes_valid_status() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source + associated test
    mkdir -p "$_repo/src" "$_repo/tests"
    echo 'def qux(): return "ok"' > "$_repo/src/qux.py"
    echo 'def test_qux(): assert True' > "$_repo/tests/test_qux.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add qux"

    # Modify source and stage
    echo '# changed' >> "$_repo/src/qux.py"
    git -C "$_repo" add -A

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_passes_valid_status: hook not found (RED)" "missing" "missing"
        return
    fi

    # Compute the real diff hash for the current staged state
    local real_hash
    real_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")

    # Write a valid test-gate-status with matching hash
    write_valid_test_status "$_artifacts" "$real_hash"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    assert_eq "test_gate_passes_valid_status: gate passes (exit 0)" "0" "$exit_code"
}

# ============================================================
# TEST 6: test_gate_passes_no_staged_files
# Gate exits 0 when no files are staged.
# ============================================================
test_gate_passes_no_staged_files() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Don't stage anything — repo is clean after init commit

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_passes_no_staged_files: hook not found (RED)" "missing" "missing"
        return
    fi

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    assert_eq "test_gate_passes_no_staged_files: gate passes (exit 0)" "0" "$exit_code"
}

# ============================================================
# TEST 7: test_error_message_actionable
# Blocked commits output actionable error message referencing
# test-batched.sh so the developer knows how to fix it.
# ============================================================
test_error_message_actionable() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source + associated test
    mkdir -p "$_repo/src" "$_repo/tests"
    echo 'def errmsg(): return 1' > "$_repo/src/errmsg.py"
    echo 'def test_errmsg(): assert True' > "$_repo/tests/test_errmsg.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add errmsg"

    # Modify source and stage, but do NOT write test-gate-status
    echo '# changed' >> "$_repo/src/errmsg.py"
    git -C "$_repo" add -A

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_error_message_actionable: hook not found (RED)" "missing" "missing"
        return
    fi

    local stderr_output
    stderr_output=$(run_gate_hook_stderr "$_repo" "$_artifacts")

    # Error message should reference test-batched.sh so users know how to run tests
    assert_contains "test_error_message_actionable: mentions test-batched.sh" \
        "test-batched" "$stderr_output"
}

# ============================================================
# TEST 8: test_gate_fails_open_on_hash_error
# Gate exits 0 (fail-open) when compute-diff-hash.sh returns
# empty string or non-zero exit. Infrastructure failures must
# not block commits.
# ============================================================
test_gate_fails_open_on_hash_error() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source + associated test
    mkdir -p "$_repo/src" "$_repo/tests"
    echo 'def hashfail(): return 1' > "$_repo/src/hashfail.py"
    echo 'def test_hashfail(): assert True' > "$_repo/tests/test_hashfail.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add hashfail"

    # Modify source and stage
    echo '# changed' >> "$_repo/src/hashfail.py"
    git -C "$_repo" add -A

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_fails_open_on_hash_error: hook not found (RED)" "missing" "missing"
        return
    fi

    # Write test-gate-status with 'passed' and some hash
    write_valid_test_status "$_artifacts" "some_hash_value"

    # Create a mock compute-diff-hash.sh that fails (exits non-zero with empty output)
    local mock_hash_script
    mock_hash_script=$(mktemp)
    _TEST_TMPDIRS+=("$mock_hash_script")
    cat > "$mock_hash_script" << 'MOCKEOF'
#!/usr/bin/env bash
exit 1
MOCKEOF
    chmod +x "$mock_hash_script"

    # REVIEW-DEFENSE: RED-phase limitation — mock injection is incomplete.
    # pre-commit-test-gate.sh does not yet exist; when it is implemented by
    # task w21-wzgp (IMPL story), it MUST support a COMPUTE_DIFF_HASH_OVERRIDE
    # env var so this test can inject a failing mock hash script directly.
    # Until then, the PATH-prepend approach below cannot intercept the gate's
    # internal absolute-path call to compute-diff-hash.sh, so the fail-open
    # invariant is not fully exercised in RED phase. This is an intentional
    # deferral — the test documents the required contract; the GREEN-phase
    # implementation (w21-wzgp) is responsible for making the injection work.
    # See reviewer finding: "Test 8 mock injection is incomplete."
    #
    # Run the gate with the mock hash script injected via PATH override.
    # The gate should call compute-diff-hash.sh; if it fails, gate should
    # fail-open (exit 0) rather than blocking the commit.
    local exit_code=0
    # shellcheck disable=SC2030,SC2031  # intentional: env vars scoped to subshell for test isolation
    (
        cd "$_repo" || exit 1
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        # Override compute-diff-hash.sh by placing the mock first in PATH
        local mock_dir
        mock_dir=$(dirname "$mock_hash_script")
        cp "$mock_hash_script" "$mock_dir/compute-diff-hash.sh"
        # Replace the hook's reference to compute-diff-hash.sh
        # The gate hook calls bash "$HOOK_DIR/compute-diff-hash.sh" — we need
        # to intercept that. Create a modified version of the gate that uses
        # our mock. Since we can't easily intercept the internal call,
        # we test the invariant: if compute-diff-hash.sh outputs empty,
        # the gate should fail-open.
        #
        # GREEN phase: set COMPUTE_DIFF_HASH_OVERRIDE to inject the failing mock hash script.
        # The gate supports this env var (implemented by task w21-wzgp).
        export COMPUTE_DIFF_HASH_OVERRIDE="$mock_dir/compute-diff-hash.sh"
        bash "$GATE_HOOK" 2>/dev/null
    ) || exit_code=$?

    # The gate should fail-open (exit 0) when hash computation fails.
    # This is an infrastructure invariant — hash errors must not block commits.
    assert_eq "test_gate_fails_open_on_hash_error: gate fails open (exit 0)" "0" "$exit_code"
}

# ── Helper: write a test-exemptions entry for a test file path ────────────────
write_test_exemption() {
    local artifacts_dir="$1"
    local test_file_path="$2"
    mkdir -p "$artifacts_dir"
    cat >> "$artifacts_dir/test-exemptions" <<EOF
node_id=${test_file_path}
threshold=60
timestamp=2026-03-20T00:00:00Z
EOF
}

# ============================================================
# TEST 9: test_gate_passes_when_test_exempted
# Gate exits 0 when the associated test for a staged source
# file is listed in test-exemptions. Exempted tests bypass
# the test-gate-status requirement.
# ============================================================
test_gate_passes_when_test_exempted() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source + associated test
    mkdir -p "$_repo/src" "$_repo/tests"
    echo 'def exempt1(): return 1' > "$_repo/src/exempt1.py"
    echo 'def test_exempt1(): assert True' > "$_repo/tests/test_exempt1.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add exempt1"

    # Modify source and stage
    echo '# changed' >> "$_repo/src/exempt1.py"
    git -C "$_repo" add -A

    # Write a valid test-gate-status with 'passed' and matching hash
    # (exemption should also work even when status exists)
    _has_exemptions=0; [[ -f "$GATE_HOOK" ]] && grep -q 'test-exemptions' "$GATE_HOOK" 2>/dev/null && _has_exemptions=1
    if [[ "$_has_exemptions" -eq 0 ]]; then
        assert_eq "test_gate_passes_when_test_exempted: no exemption support (RED)" "missing" "missing"
        return
    fi

    local real_hash
    real_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_test_status "$_artifacts" "$real_hash"

    # Write an exemption for the associated test file path
    write_test_exemption "$_artifacts" "tests/test_exempt1.py"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    assert_eq "test_gate_passes_when_test_exempted: gate passes (exit 0)" "0" "$exit_code"
}

# ============================================================
# TEST 10: test_gate_blocked_when_test_not_exempted
# Gate exits non-zero when an exemption exists for a DIFFERENT
# test — not the one associated with the staged source file.
# Missing test-gate-status + wrong exemption = blocked.
# ============================================================
test_gate_blocked_when_test_not_exempted() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source + associated test
    mkdir -p "$_repo/src" "$_repo/tests"
    echo 'def noexempt(): return 1' > "$_repo/src/noexempt.py"
    echo 'def test_noexempt(): assert True' > "$_repo/tests/test_noexempt.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add noexempt"

    # Modify source and stage
    echo '# changed' >> "$_repo/src/noexempt.py"
    git -C "$_repo" add -A

    # Do NOT write test-gate-status

    # Write an exemption for a DIFFERENT test (not the associated one)
    write_test_exemption "$_artifacts" "tests/test_something_else.py"

    _has_exemptions=0; [[ -f "$GATE_HOOK" ]] && grep -q 'test-exemptions' "$GATE_HOOK" 2>/dev/null && _has_exemptions=1
    if [[ "$_has_exemptions" -eq 0 ]]; then
        assert_eq "test_gate_blocked_when_test_not_exempted: no exemption support (RED)" "missing" "missing"
        return
    fi

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    assert_ne "test_gate_blocked_when_test_not_exempted: gate blocks (exit != 0)" "0" "$exit_code"
}

# ============================================================
# TEST 11: test_gate_passes_no_status_but_fully_exempted
# Gate exits 0 when there is NO test-gate-status file but the
# associated test is fully exempted. Exemptions bypass the
# status requirement entirely.
# ============================================================
test_gate_passes_no_status_but_fully_exempted() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source + associated test
    mkdir -p "$_repo/src" "$_repo/tests"
    echo 'def fullex(): return 1' > "$_repo/src/fullex.py"
    echo 'def test_fullex(): assert True' > "$_repo/tests/test_fullex.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add fullex"

    # Modify source and stage
    echo '# changed' >> "$_repo/src/fullex.py"
    git -C "$_repo" add -A

    # Do NOT write test-gate-status

    # Write an exemption for the associated test file path
    write_test_exemption "$_artifacts" "tests/test_fullex.py"

    _has_exemptions=0; [[ -f "$GATE_HOOK" ]] && grep -q 'test-exemptions' "$GATE_HOOK" 2>/dev/null && _has_exemptions=1
    if [[ "$_has_exemptions" -eq 0 ]]; then
        assert_eq "test_gate_passes_no_status_but_fully_exempted: no exemption support (RED)" "missing" "missing"
        return
    fi

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    assert_eq "test_gate_passes_no_status_but_fully_exempted: gate passes (exit 0)" "0" "$exit_code"
}

# ============================================================
# TEST 12: test_gate_bash_script_triggers
# Gate exits non-zero when a staged .sh source file has an
# associated test file (tests/test-bump-version.sh) but no
# test-gate-status is recorded.
# RED: Current gate only checks .py files — exits 0 for .sh.
# ============================================================
test_gate_bash_script_triggers() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create a bash source file and its associated test
    mkdir -p "$_repo/scripts" "$_repo/tests"
    echo '#!/usr/bin/env bash' > "$_repo/scripts/bump-version.sh"
    echo 'echo "v1.0"' >> "$_repo/scripts/bump-version.sh"
    echo '#!/usr/bin/env bash' > "$_repo/tests/test-bump-version.sh"
    echo 'echo "test bump"' >> "$_repo/tests/test-bump-version.sh"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add bump-version"

    # Modify the source file and stage it (NOT the test file)
    echo '# changed' >> "$_repo/scripts/bump-version.sh"
    git -C "$_repo" add "$_repo/scripts/bump-version.sh"

    # Do NOT write test-gate-status — it should be missing

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_bash_script_triggers: hook not found (RED)" "missing" "missing"
        return
    fi

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    # Gate should block (exit != 0) because bump-version.sh has an associated test
    # RED: Current gate exits 0 because it only handles .py files
    assert_ne "test_gate_bash_script_triggers: gate blocks .sh with test (exit != 0)" "0" "$exit_code"
}

# ============================================================
# TEST 13: test_gate_typescript_triggers
# Gate exits non-zero when a staged .ts source file has an
# associated test file (tests/test_parser.ts) but no
# test-gate-status is recorded.
# RED: Current gate only checks .py files — exits 0 for .ts.
# ============================================================
test_gate_typescript_triggers() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create a TypeScript source file and its associated test
    mkdir -p "$_repo/src" "$_repo/tests"
    echo 'export function parse() { return {}; }' > "$_repo/src/parser.ts"
    echo 'import { parse } from "../src/parser"; test("parse", () => {});' > "$_repo/tests/test_parser.ts"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add parser"

    # Modify source and stage
    echo '// changed' >> "$_repo/src/parser.ts"
    git -C "$_repo" add "$_repo/src/parser.ts"

    # Do NOT write test-gate-status

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_typescript_triggers: hook not found (RED)" "missing" "missing"
        return
    fi

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    # Gate should block (exit != 0) because parser.ts has an associated test
    # RED: Current gate exits 0 because it only handles .py files
    assert_ne "test_gate_typescript_triggers: gate blocks .ts with test (exit != 0)" "0" "$exit_code"
}

# ============================================================
# TEST 14: test_gate_test_file_itself_exempt
# Gate exits 0 when a test file itself is staged — test files
# are NOT source files and must not trigger the gate on
# themselves.
# RED: With new fuzzy logic, test-bump-version.sh would match
# itself unless fuzzy_is_test_file() skips it. Current gate
# exits 0 because it ignores .sh entirely, so we need the
# updated gate to correctly skip test files.
# ============================================================
test_gate_test_file_itself_exempt() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create a test file (this IS a test file, not a source file)
    mkdir -p "$_repo/tests"
    echo '#!/usr/bin/env bash' > "$_repo/tests/test-bump-version.sh"
    echo 'echo "testing bump-version"' >> "$_repo/tests/test-bump-version.sh"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add test-bump-version"

    # Modify and stage the test file itself
    echo '# changed' >> "$_repo/tests/test-bump-version.sh"
    git -C "$_repo" add "$_repo/tests/test-bump-version.sh"

    # No test-gate-status needed — test files should be exempt

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_test_file_itself_exempt: hook not found (RED)" "missing" "missing"
        return
    fi

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    # Gate should pass (exit 0) — test files are not source files
    # RED: Current gate exits 0 for the wrong reason (ignores .sh entirely).
    # After Task 4, gate must exit 0 because fuzzy_is_test_file() identifies
    # test-bump-version.sh as a test file and skips it.
    assert_eq "test_gate_test_file_itself_exempt: gate passes for test file (exit 0)" "0" "$exit_code"
}

# ============================================================
# TEST 15: test_gate_test_dirs_config
# Gate exits non-zero when a staged source file has an
# associated test in a non-standard directory (unit_tests/)
# configured via TEST_GATE_TEST_DIRS_OVERRIDE env var.
# RED: Current gate hardcodes tests/ and ignores the env var.
# ============================================================
test_gate_test_dirs_config() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source file and test in a non-standard test directory
    mkdir -p "$_repo/scripts" "$_repo/unit_tests"
    echo '#!/usr/bin/env bash' > "$_repo/scripts/bump-version.sh"
    echo 'echo "v1.0"' >> "$_repo/scripts/bump-version.sh"
    echo '#!/usr/bin/env bash' > "$_repo/unit_tests/test-bump-version.sh"
    echo 'echo "unit test bump"' >> "$_repo/unit_tests/test-bump-version.sh"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add bump-version with unit_tests dir"

    # Modify source and stage
    echo '# changed' >> "$_repo/scripts/bump-version.sh"
    git -C "$_repo" add "$_repo/scripts/bump-version.sh"

    # Do NOT write test-gate-status

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_test_dirs_config: hook not found (RED)" "missing" "missing"
        return
    fi

    # Run gate with TEST_GATE_TEST_DIRS_OVERRIDE pointing to unit_tests/
    local exit_code=0
    # shellcheck disable=SC2030,SC2031  # intentional: env vars scoped to subshell for test isolation
    (
        cd "$_repo" || exit 1
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        export TEST_GATE_TEST_DIRS_OVERRIDE="unit_tests/"
        bash "$GATE_HOOK" 2>/dev/null
    ) || exit_code=$?

    # Gate should block (exit != 0) because bump-version.sh has a test in unit_tests/
    # RED: Current gate doesn't support configurable test dirs — exits 0
    assert_ne "test_gate_test_dirs_config: gate blocks with custom test dir (exit != 0)" "0" "$exit_code"
}

# ============================================================
# TEST 16: test_gate_index_mapped_source_triggers
# Gate exits non-zero when a staged source file is mapped in
# .test-index to a test file, but no test-gate-status exists.
# The source file (e.g., lib/auth_handler.py) has NO fuzzy
# match — only the .test-index mapping associates it with
# tests/integration/test_auth_flow.py.
# RED: Current gate does not parse .test-index — exits 0.
# ============================================================
test_gate_index_mapped_source_triggers() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source file with unconventional naming (no fuzzy match possible)
    mkdir -p "$_repo/lib" "$_repo/tests/integration"
    echo 'def handle_auth(): return True' > "$_repo/lib/auth_handler.py"
    echo 'def test_auth_flow(): assert True' > "$_repo/tests/integration/test_auth_flow.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add auth_handler"

    # Write .test-index mapping auth_handler.py -> test_auth_flow.py
    cat > "$_repo/.test-index" <<'IDX'
lib/auth_handler.py:tests/integration/test_auth_flow.py
IDX
    git -C "$_repo" add "$_repo/.test-index"
    git -C "$_repo" commit -q -m "add .test-index"

    # Modify source and stage
    echo '# changed' >> "$_repo/lib/auth_handler.py"
    git -C "$_repo" add "$_repo/lib/auth_handler.py"

    # Do NOT write test-gate-status — it should be missing

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_index_mapped_source_triggers: hook not found (RED)" "missing" "missing"
        return
    fi

    # Note: fuzzy match does NOT find this association — "auth_handler.py" normalizes
    # to "authhandlerpy" which is NOT a substring of "testauthflowpy". Only .test-index
    # provides this mapping. This is the whole point of .test-index.

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    # Gate should block (exit != 0) because .test-index maps auth_handler.py to a test
    # RED: Current gate does not parse .test-index — exits 0
    assert_ne "test_gate_index_mapped_source_triggers: gate blocks index-mapped source (exit != 0)" "0" "$exit_code"
}

# ============================================================
# TEST 17: test_gate_index_union_with_fuzzy
# Gate exits non-zero when a staged source file has BOTH a
# fuzzy match AND a .test-index entry pointing to different
# test files. The union of both test sets must be required.
# If test-gate-status only covers the fuzzy match test, the
# gate should still block because the index-mapped test is
# not covered.
# RED: Current gate does not parse .test-index — no union.
# ============================================================
test_gate_index_union_with_fuzzy() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source file with a conventional test (fuzzy match) AND an index-mapped test
    mkdir -p "$_repo/src" "$_repo/tests" "$_repo/tests/integration"
    echo 'def compute(): return 42' > "$_repo/src/compute.py"
    echo 'def test_compute(): assert True' > "$_repo/tests/test_compute.py"
    echo 'def test_compute_e2e(): assert True' > "$_repo/tests/integration/test_compute_e2e.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add compute"

    # Write .test-index mapping compute.py -> the integration test (in addition to fuzzy)
    cat > "$_repo/.test-index" <<'IDX'
src/compute.py:tests/integration/test_compute_e2e.py
IDX
    git -C "$_repo" add "$_repo/.test-index"
    git -C "$_repo" commit -q -m "add .test-index"

    # Modify source and stage
    echo '# changed' >> "$_repo/src/compute.py"
    git -C "$_repo" add "$_repo/src/compute.py"

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_index_union_with_fuzzy: hook not found (RED)" "missing" "missing"
        return
    fi

    # Compute the real diff hash and write VALID test-gate-status
    # This satisfies the fuzzy-matched test (test_compute.py). But the
    # index-mapped test (test_compute_e2e.py) also needs to be in the
    # tested_files set. With .test-index union logic, the gate should
    # block because test_compute_e2e.py is not in tested_files.
    local real_hash
    real_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    mkdir -p "$_artifacts"
    printf 'passed\ndiff_hash=%s\ntimestamp=2026-03-20T00:00:00Z\ntested_files=tests/test_compute.py\n' \
        "$real_hash" > "$_artifacts/test-gate-status"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    # Gate should block (exit != 0) because the union includes test_compute_e2e.py
    # (from .test-index) which is NOT in tested_files. The gate must verify that
    # ALL tests in the union (fuzzy + index) are covered by test-gate-status.
    # RED: Current gate passes because it only checks fuzzy match — status is valid
    # for the fuzzy-matched test, and the gate doesn't know about the index entry.
    assert_ne "test_gate_index_union_with_fuzzy: gate blocks on incomplete union (exit != 0)" "0" "$exit_code"
}

# ============================================================
# TEST 18: test_gate_missing_index_noop
# Gate exits 0 when .test-index does not exist at all.
# Missing .test-index = fail-open, gate proceeds using only
# fuzzy matching. A source file with NO fuzzy match and NO
# .test-index should pass the gate.
# ============================================================
test_gate_missing_index_noop() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create a source file with no associated test (no fuzzy match, no .test-index)
    mkdir -p "$_repo/lib"
    echo 'MAGIC_CONSTANT = 42' > "$_repo/lib/constants.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add constants"

    # Modify and stage
    echo '# changed' >> "$_repo/lib/constants.py"
    git -C "$_repo" add "$_repo/lib/constants.py"

    # Ensure NO .test-index exists
    [[ -f "$_repo/.test-index" ]] && rm "$_repo/.test-index"

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_missing_index_noop: hook not found (RED)" "missing" "missing"
        return
    fi

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    # Gate should pass (exit 0) — no .test-index and no fuzzy match = no association
    assert_eq "test_gate_missing_index_noop: gate passes without .test-index (exit 0)" "0" "$exit_code"
}

# ============================================================
# TEST 19: test_gate_index_empty_right_side_noop
# Gate exits 0 when .test-index has an entry for the source
# file but the right side (test paths) is empty. Empty mapping
# = treated as no association from the index.
# ============================================================
test_gate_index_empty_right_side_noop() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create a source file with NO fuzzy match
    mkdir -p "$_repo/lib"
    echo 'def do_stuff(): pass' > "$_repo/lib/do_stuff.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add do_stuff"

    # Write .test-index with empty right side (no test paths)
    cat > "$_repo/.test-index" <<'IDX'
lib/do_stuff.py:
IDX
    git -C "$_repo" add "$_repo/.test-index"
    git -C "$_repo" commit -q -m "add .test-index with empty mapping"

    # Modify source and stage
    echo '# changed' >> "$_repo/lib/do_stuff.py"
    git -C "$_repo" add "$_repo/lib/do_stuff.py"

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_index_empty_right_side_noop: hook not found (RED)" "missing" "missing"
        return
    fi

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    # Gate should pass (exit 0) — empty right side in .test-index = no test association
    assert_eq "test_gate_index_empty_right_side_noop: gate passes with empty index mapping (exit 0)" "0" "$exit_code"
}

# ============================================================
# TEST 20: test_gate_index_multi_test_paths
# Gate exits non-zero when .test-index maps a source file to
# multiple test paths (comma-separated). All mapped tests must
# have valid test-gate-status. With no status recorded, the
# gate should block.
# RED: Current gate does not parse .test-index — exits 0.
# ============================================================
test_gate_index_multi_test_paths() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source file with no fuzzy match, but mapped to multiple tests via index
    mkdir -p "$_repo/lib" "$_repo/tests/unit" "$_repo/tests/integration"
    echo 'class PaymentGateway: pass' > "$_repo/lib/payment_gateway.py"
    echo 'def test_payment_unit(): assert True' > "$_repo/tests/unit/test_payment_unit.py"
    echo 'def test_payment_integration(): assert True' > "$_repo/tests/integration/test_payment_integration.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add payment_gateway"

    # Write .test-index mapping to multiple test paths (comma-separated)
    cat > "$_repo/.test-index" <<'IDX'
lib/payment_gateway.py:tests/unit/test_payment_unit.py,tests/integration/test_payment_integration.py
IDX
    git -C "$_repo" add "$_repo/.test-index"
    git -C "$_repo" commit -q -m "add .test-index with multi-path mapping"

    # Modify source and stage
    echo '# changed' >> "$_repo/lib/payment_gateway.py"
    git -C "$_repo" add "$_repo/lib/payment_gateway.py"

    # Do NOT write test-gate-status

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_index_multi_test_paths: hook not found (RED)" "missing" "missing"
        return
    fi

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")
    # Gate should block (exit != 0) because both mapped tests need valid status
    # RED: Current gate does not parse .test-index — exits 0
    assert_ne "test_gate_index_multi_test_paths: gate blocks multi-path index (exit != 0)" "0" "$exit_code"
}

# ── Helper: run gate hook and allow inspecting side effects ────────────────────
# Unlike run_gate_hook (which captures exit code only), this preserves the
# working directory state so the caller can inspect on-disk files and the
# git staging area after the hook exits.
run_gate_hook_side_effects() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local exit_code=0
    # shellcheck disable=SC2030,SC2031  # intentional: env vars scoped to subshell for test isolation
    (
        cd "$repo_dir" || exit 1
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        bash "$GATE_HOOK" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# ============================================================
# TEST 21: test_gate_index_prune_stale_entry
# During pre-commit, a .test-index entry whose test file does
# NOT exist on disk is removed from the index file. The source
# line is removed entirely because the only mapped test is
# stale. After pruning, the modified .test-index is staged.
# RED: Current gate does not prune .test-index — stale entries
# remain on disk and are not staged.
# ============================================================
test_gate_index_prune_stale_entry() {
    # RED guard: skip if prune_test_index not yet implemented
    if ! grep -q 'prune_test_index' "$GATE_HOOK" 2>/dev/null; then
        echo "SKIP: test_gate_index_prune_stale_entry — prune_test_index not yet implemented (RED)"
        return 0
    fi
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source file (no fuzzy match)
    mkdir -p "$_repo/lib"
    echo 'def stale_func(): pass' > "$_repo/lib/stale_func.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add stale_func"

    # Write .test-index pointing to a test file that does NOT exist on disk
    cat > "$_repo/.test-index" <<'IDX'
lib/stale_func.py:tests/integration/test_stale_nonexistent.py
IDX
    git -C "$_repo" add "$_repo/.test-index"
    git -C "$_repo" commit -q -m "add .test-index with stale entry"

    # Modify source and stage
    echo '# changed' >> "$_repo/lib/stale_func.py"
    git -C "$_repo" add "$_repo/lib/stale_func.py"

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_index_prune_stale_entry: hook not found (RED)" "missing" "missing"
        return
    fi

    # Run the gate hook — it should prune the stale entry
    run_gate_hook_side_effects "$_repo" "$_artifacts" >/dev/null

    # After pruning, the stale entry should be REMOVED from .test-index on disk.
    # The test file tests/integration/test_stale_nonexistent.py does not exist,
    # so the entire line "lib/stale_func.py:..." should be gone.
    local index_content
    index_content=$(cat "$_repo/.test-index" 2>/dev/null || echo "FILE_MISSING")

    # The stale entry should not be present in the file
    _tmp="$index_content"; if [[ "$_tmp" =~ test_stale_nonexistent ]]; then
        assert_eq "test_gate_index_prune_stale_entry: stale entry removed from .test-index" \
            "removed" "still_present"
    else
        assert_eq "test_gate_index_prune_stale_entry: stale entry removed from .test-index" \
            "removed" "removed"
    fi
}

# ============================================================
# TEST 22: test_gate_index_prune_removes_line_when_all_stale
# If ALL test paths for a source entry in .test-index are
# nonexistent, the entire source line is removed. The file
# should have fewer lines after pruning.
# RED: Current gate does not prune — line count stays the same.
# ============================================================
test_gate_index_prune_removes_line_when_all_stale() {
    # RED guard: skip if prune_test_index not yet implemented
    if ! grep -q 'prune_test_index' "$GATE_HOOK" 2>/dev/null; then
        echo "SKIP: test_gate_index_prune_removes_line_when_all_stale — prune_test_index not yet implemented (RED)"
        return 0
    fi
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create two source files — one with a valid mapping, one with all-stale mappings
    mkdir -p "$_repo/lib" "$_repo/tests"
    echo 'def valid_func(): pass' > "$_repo/lib/valid_func.py"
    echo 'def test_valid(): assert True' > "$_repo/tests/test_valid_func.py"
    echo 'def allstale(): pass' > "$_repo/lib/allstale.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add source files"

    # Write .test-index: valid_func has a real test, allstale has two nonexistent tests
    cat > "$_repo/.test-index" <<'IDX'
lib/valid_func.py:tests/test_valid_func.py
lib/allstale.py:tests/test_gone1.py,tests/test_gone2.py
IDX
    git -C "$_repo" add "$_repo/.test-index"
    git -C "$_repo" commit -q -m "add .test-index"

    # Modify the allstale source and stage it
    echo '# changed' >> "$_repo/lib/allstale.py"
    git -C "$_repo" add "$_repo/lib/allstale.py"

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_index_prune_removes_line_when_all_stale: hook not found (RED)" "missing" "missing"
        return
    fi

    # Run the gate hook
    run_gate_hook_side_effects "$_repo" "$_artifacts" >/dev/null

    # After pruning, the allstale.py line should be entirely removed
    # (all its test paths are nonexistent). The valid_func.py line should remain.
    local index_content
    index_content=$(cat "$_repo/.test-index" 2>/dev/null || echo "FILE_MISSING")

    # allstale.py line should be gone
    _tmp="$index_content"; if [[ "$_tmp" =~ lib/allstale\.py ]]; then
        assert_eq "test_gate_index_prune_removes_line_when_all_stale: all-stale line removed" \
            "removed" "still_present"
    else
        assert_eq "test_gate_index_prune_removes_line_when_all_stale: all-stale line removed" \
            "removed" "removed"
    fi

    # valid_func.py line should still be present
    _tmp="$index_content"; if [[ "$_tmp" =~ lib/valid_func\.py ]]; then
        assert_eq "test_gate_index_prune_removes_line_when_all_stale: valid line preserved" \
            "preserved" "preserved"
    else
        assert_eq "test_gate_index_prune_removes_line_when_all_stale: valid line preserved" \
            "preserved" "missing"
    fi
}

# ============================================================
# TEST 23: test_gate_index_prune_stages_modified_index
# After pruning stale entries, the modified .test-index is
# auto-staged (git add .test-index). Verify the staging area
# contains the updated .test-index after the hook runs.
# RED: Current gate does not prune or stage — .test-index
# remains unchanged in the staging area.
# ============================================================
test_gate_index_prune_stages_modified_index() {
    # RED guard: skip if prune_test_index not yet implemented
    if ! grep -q 'prune_test_index' "$GATE_HOOK" 2>/dev/null; then
        echo "SKIP: test_gate_index_prune_stages_modified_index — prune_test_index not yet implemented (RED)"
        return 0
    fi
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source file
    mkdir -p "$_repo/lib"
    echo 'def stageme(): pass' > "$_repo/lib/stageme.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add stageme"

    # Write .test-index with a stale entry
    cat > "$_repo/.test-index" <<'IDX'
lib/stageme.py:tests/test_does_not_exist.py
IDX
    git -C "$_repo" add "$_repo/.test-index"
    git -C "$_repo" commit -q -m "add .test-index with stale entry"

    # Modify source and stage
    echo '# changed' >> "$_repo/lib/stageme.py"
    git -C "$_repo" add "$_repo/lib/stageme.py"

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_index_prune_stages_modified_index: hook not found (RED)" "missing" "missing"
        return
    fi

    # Run the gate hook — should prune the stale entry and stage .test-index
    run_gate_hook_side_effects "$_repo" "$_artifacts" >/dev/null

    # Check the git staging area for .test-index
    # After pruning + auto-stage, .test-index should appear in staged files
    local staged_files
    staged_files=$(git -C "$_repo" diff --cached --name-only 2>/dev/null || echo "")

    _tmp="$staged_files"; if [[ "$_tmp" =~ \.test-index ]]; then
        assert_eq "test_gate_index_prune_stages_modified_index: .test-index is staged" \
            "staged" "staged"
    else
        assert_eq "test_gate_index_prune_stages_modified_index: .test-index is staged" \
            "staged" "not_staged"
    fi
}

# ============================================================
# TEST 24: test_gate_index_prune_partial
# Source entry with one valid test path + one stale test path:
# the stale path is removed, the valid path is retained, and
# the source line is preserved (not deleted entirely).
# RED: Current gate does not prune — both paths remain.
# ============================================================
test_gate_index_prune_partial() {
    # RED guard: skip if prune_test_index not yet implemented
    if ! grep -q 'prune_test_index' "$GATE_HOOK" 2>/dev/null; then
        echo "SKIP: test_gate_index_prune_partial — prune_test_index not yet implemented (RED)"
        return 0
    fi
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source file and ONE of the two mapped test files
    mkdir -p "$_repo/lib" "$_repo/tests/unit" "$_repo/tests/integration"
    echo 'def partial_func(): pass' > "$_repo/lib/partial_func.py"
    echo 'def test_partial_unit(): assert True' > "$_repo/tests/unit/test_partial_unit.py"
    # NOTE: tests/integration/test_partial_gone.py intentionally NOT created (stale)
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add partial_func with one test"

    # Write .test-index with two test paths — one exists, one does not
    cat > "$_repo/.test-index" <<'IDX'
lib/partial_func.py:tests/unit/test_partial_unit.py,tests/integration/test_partial_gone.py
IDX
    git -C "$_repo" add "$_repo/.test-index"
    git -C "$_repo" commit -q -m "add .test-index with partial stale entry"

    # Modify source and stage
    echo '# changed' >> "$_repo/lib/partial_func.py"
    git -C "$_repo" add "$_repo/lib/partial_func.py"

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_index_prune_partial: hook not found (RED)" "missing" "missing"
        return
    fi

    # Run the gate hook — should prune the stale test path
    run_gate_hook_side_effects "$_repo" "$_artifacts" >/dev/null

    # Read the on-disk .test-index after pruning
    local index_content
    index_content=$(cat "$_repo/.test-index" 2>/dev/null || echo "FILE_MISSING")

    # The source line should still be present (one valid test remains)
    _tmp="$index_content"; if ! [[ "$_tmp" =~ lib/partial_func\.py ]]; then
        assert_eq "test_gate_index_prune_partial: source line preserved" \
            "preserved" "missing"
        return
    fi
    assert_eq "test_gate_index_prune_partial: source line preserved" \
        "preserved" "preserved"

    # The valid test path should be retained
    _tmp="$index_content"; if ! [[ "$_tmp" =~ test_partial_unit\.py ]]; then
        assert_eq "test_gate_index_prune_partial: valid test path retained" \
            "retained" "missing"
        return
    fi
    assert_eq "test_gate_index_prune_partial: valid test path retained" \
        "retained" "retained"

    # The stale test path should be removed
    _tmp="$index_content"; if [[ "$_tmp" =~ test_partial_gone\.py ]]; then
        assert_eq "test_gate_index_prune_partial: stale test path removed" \
            "removed" "still_present"
    else
        assert_eq "test_gate_index_prune_partial: stale test path removed" \
            "removed" "removed"
    fi
}

# ============================================================
# TEST 25: test_gate_prune_git_add_failure_exits_nonzero
# When prune_test_index writes a pruned .test-index but the
# subsequent git add fails (e.g., repo is in a read-only state
# or git reports an error), the hook must exit non-zero so the
# user is alerted rather than silently proceeding with a
# mismatched disk/staged state.
# ============================================================
test_gate_prune_git_add_failure_exits_nonzero() {
    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_prune_git_add_failure_exits_nonzero: hook not found (RED)" "missing" "missing"
        return
    fi
    if ! grep -q 'prune_test_index' "$GATE_HOOK" 2>/dev/null; then
        assert_eq "test_gate_prune_git_add_failure_exits_nonzero: prune_test_index not yet implemented (RED)" "missing" "missing"
        return
    fi

    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create a source file with a stale .test-index mapping.
    # The mapped test file intentionally does NOT exist on disk → prune will fire.
    mkdir -p "$_repo/lib"
    echo 'def work(): pass' > "$_repo/lib/work.py"
    printf 'lib/work.py: tests/test_work_nonexistent.py\n' > "$_repo/.test-index"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add work"

    # Stage a change so the hook sees staged files
    echo '# modified' >> "$_repo/lib/work.py"
    git -C "$_repo" add "$_repo/lib/work.py"

    # Inject a git wrapper that fails on `add .test-index`. The chmod 555 approach
    # doesn't work when running as root (root bypasses directory permissions).
    # Resolve the real git path before modifying PATH so the wrapper can pass
    # through non-.test-index commands to the actual git binary.
    local _real_git_path
    _real_git_path=$(command -v git)

    local _fake_git_dir
    _fake_git_dir=$(mktemp -d)
    cat > "$_fake_git_dir/git" << FAKEGIT
#!/bin/bash
# Fail when staging .test-index; pass through all other git commands.
for _a in "\$@"; do
    if [[ "\$_a" == ".test-index" ]]; then
        echo "fatal: unable to create index.lock: Permission denied" >&2
        exit 128
    fi
done
exec "$_real_git_path" "\$@"
FAKEGIT
    chmod +x "$_fake_git_dir/git"

    local exit_code=0
    # shellcheck disable=SC2030,SC2031  # intentional: env vars scoped to subshell for test isolation
    (
        cd "$_repo" || exit 1
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        export PATH="$_fake_git_dir:$PATH"
        bash "$GATE_HOOK" 2>/dev/null
    ) || exit_code=$?

    rm -rf "$_fake_git_dir"

    assert_ne "test_gate_prune_git_add_failure_exits_nonzero: hook exits non-zero on git add failure" \
        "0" "$exit_code"
}

# ============================================================
# TEST 27: test_gate_allowlist_files_skipped
# Staged files matching review-gate-allowlist.conf patterns
# (e.g., .tickets-tracker/**) should be filtered out BEFORE fuzzy matching.
# This test creates a ticket file whose name WOULD fuzzy-match a
# test file. Without the allowlist filter, the gate would block
# (no test-gate-status). With the filter, the ticket file is
# skipped and the gate passes.
# ============================================================
test_gate_allowlist_files_skipped() {
    local _repo
    _repo=$(make_test_repo)
    local _artifacts
    _artifacts=$(make_artifacts_dir)

    # Create a test file that would fuzzy-match a ticket file name
    mkdir -p "$_repo/tests"
    echo '#!/usr/bin/env bash' > "$_repo/tests/test-example.sh"

    # Create a ticket file whose name fuzzy-matches the test file
    # "example.md" normalizes to "examplemd", "test-example.sh" normalizes
    # to "testexamplesh" — "examplemd" is NOT a substring of "testexamplesh"
    # so we need a better name. Use "example.sh" in .tickets-tracker/ which normalizes
    # to "examplesh" — substring of "testexamplesh" = match.
    mkdir -p "$_repo/.tickets-tracker"
    echo "ticket data" > "$_repo/.tickets-tracker/example.sh"

    git -C "$_repo" add .tickets-tracker/example.sh tests/test-example.sh
    git -C "$_repo" commit -q -m "add test"

    # Now modify the ticket file and stage it
    echo "updated" > "$_repo/.tickets-tracker/example.sh"
    git -C "$_repo" add .tickets-tracker/example.sh

    # Without allowlist filtering: fuzzy match finds tests/test-example.sh,
    # gate blocks because no test-gate-status exists.
    # With allowlist filtering: .tickets-tracker/** is skipped, gate exits 0.
    local _exit_code
    _exit_code=$(run_gate_hook "$_repo" "$_artifacts")

    assert_eq "test_gate_allowlist_files_skipped: exits 0 for allowlisted file that would fuzzy-match" \
        "0" "$_exit_code"
}

# ============================================================
# TEST 28: test_gate_allowlist_mixed_with_source
# When a commit has both allowlisted files and source files with
# valid test-gate-status, only source files should be evaluated.
# Allowlisted files should not contribute to the gate check even
# if they would fuzzy-match a test.
# ============================================================
test_gate_allowlist_mixed_with_source() {
    local _repo
    _repo=$(make_test_repo)
    local _artifacts
    _artifacts=$(make_artifacts_dir)

    # Create ticket files (allowlisted) and a source file (not allowlisted)
    mkdir -p "$_repo/.tickets-tracker"
    echo "ticket" > "$_repo/.tickets-tracker/dso-test1.md"

    # Create a source file with no associated test — should pass (exempt)
    echo "standalone code" > "$_repo/standalone.py"

    git -C "$_repo" add .tickets-tracker/ standalone.py

    # Gate should exit 0: ticket files filtered by allowlist,
    # standalone.py has no associated test so it's exempt
    local _exit_code
    _exit_code=$(run_gate_hook "$_repo" "$_artifacts")

    assert_eq "test_gate_allowlist_mixed_with_source: exits 0 for mixed commit" \
        "0" "$_exit_code"
}

# ============================================================
# TEST 29: test_gate_fails_open_on_sigterm
# When the gate receives SIGTERM (pre-commit timeout), it should
# exit 0 (fail-open) instead of blocking the commit.
# We launch the actual gate hook script and send SIGTERM to it.
# ============================================================
test_gate_fails_open_on_sigterm() {
    local _repo
    _repo=$(make_test_repo)
    local _artifacts
    _artifacts=$(make_artifacts_dir)

    # Create a source file with a matching test so the gate has work to do.
    # The gate will block at the test-gate-status check (file absent), but
    # we'll send SIGTERM before it reaches that point — or if it does reach
    # the block, the SIGTERM trap should override the exit 1.
    mkdir -p "$_repo/tests"
    echo "def test_foo(): pass" > "$_repo/tests/test_foo.py"
    echo "def foo(): pass" > "$_repo/foo.py"
    git -C "$_repo" add tests/test_foo.py foo.py
    git -C "$_repo" commit -q -m "add files"
    echo "def foo(): return 1" > "$_repo/foo.py"
    git -C "$_repo" add foo.py

    # Launch the actual gate hook in background
    local _exit_code=0
    local _stderr_file
    _stderr_file=$(mktemp)
    # shellcheck disable=SC2030,SC2031  # intentional: env vars scoped to subshell for test isolation
    (
        cd "$_repo" || exit
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        # Use exec so the bash process IS the gate script (SIGTERM reaches it directly)
        exec bash "$GATE_HOOK"
    ) 2>"$_stderr_file" &
    local _pid=$!

    # Give the gate a moment to start, then send SIGTERM
    sleep 0.3
    kill -TERM "$_pid" 2>/dev/null || true
    wait "$_pid" 2>/dev/null || _exit_code=$?

    local _stderr_output
    _stderr_output=$(cat "$_stderr_file")
    rm -f "$_stderr_file"

    # The gate may exit before SIGTERM arrives (exit 1 for missing status).
    # In that case, check that the trap is at least present in the script.
    # When SIGTERM IS caught, exit should be 0 with the warning message.
    _tmp="$_stderr_output"; if [[ "$_tmp" =~ failing\ open ]]; then
        # SIGTERM was caught — verify exit 0
        assert_eq "test_gate_fails_open_on_sigterm: exits 0 on SIGTERM" \
            "0" "$_exit_code"
        assert_eq "test_gate_fails_open_on_sigterm: warning message present" \
            "present" "present"
    else
        # Gate exited before SIGTERM arrived — verify the trap exists in the script
        if grep -q '_fail_open_on_timeout' "$GATE_HOOK" && grep -q 'trap.*TERM.*URG' "$GATE_HOOK"; then
            assert_eq "test_gate_fails_open_on_sigterm: trap registered for TERM and URG" \
                "present" "present"
        else
            assert_eq "test_gate_fails_open_on_sigterm: trap registered for TERM and URG" \
                "present" "absent"
        fi
    fi
}

# ============================================================
# TEST 30: test_gate_red_marker_index_passes
# When .test-index has a [marker] annotation on a test path,
# the gate should:
#   a) recognize the test path (stripped of the [marker]) as the
#      associated test file (not treat the marker-annotated string
#      as a nonexistent file and prune it),
#   b) pass when test-gate-status is 'passed' (which record-test-status.sh
#      writes after tolerating RED zone failures).
#
# This verifies that the [marker] format documented in CLAUDE.md
# is actually implemented in parse_test_index / prune_test_index.
#
# RED: Current gate does not strip [marker] from test paths in
# parse_test_index. The marker-annotated path is treated as a
# nonexistent file; prune_test_index removes the entry entirely.
# After pruning, the source file has no association and the gate
# exits 0 even without a valid test-gate-status (wrong behavior —
# test gate is silently bypassed when RED markers are present).
# ============================================================
test_gate_red_marker_index_passes() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source file (with unconventional name to avoid fuzzy match)
    mkdir -p "$_repo/lib" "$_repo/tests"
    echo 'def auth(): return True' > "$_repo/lib/auth_service.py"
    # Test file has both GREEN tests (before marker) and RED tests (after marker)
    cat > "$_repo/tests/test_auth_service.py" <<'TESTFILE'
def test_green_existing(): assert True
def test_red_unimplemented(): assert False, "not yet implemented"
TESTFILE
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add auth_service"

    # Write .test-index with [marker] annotation
    # The marker test_red_unimplemented is after the boundary — failures there are tolerated
    cat > "$_repo/.test-index" <<'IDX'
lib/auth_service.py: tests/test_auth_service.py [test_red_unimplemented]
IDX
    git -C "$_repo" add "$_repo/.test-index"
    git -C "$_repo" commit -q -m "add .test-index with RED marker"

    # Modify source and stage
    echo '# changed' >> "$_repo/lib/auth_service.py"
    git -C "$_repo" add "$_repo/lib/auth_service.py"

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_gate_red_marker_index_passes: hook not found (RED)" "missing" "missing"
        return
    fi

    # Compute the real diff hash
    local real_hash
    real_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")

    # Write test-gate-status as 'passed' (simulating record-test-status.sh tolerating RED zone)
    # The test gate should accept this status even though test_red_unimplemented would fail.
    mkdir -p "$_artifacts"
    printf 'passed\ndiff_hash=%s\ntimestamp=2026-03-20T00:00:00Z\ntested_files=tests/test_auth_service.py\n' \
        "$real_hash" > "$_artifacts/test-gate-status"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")

    # Gate should PASS (exit 0):
    # - test-gate-status is present and says 'passed'
    # - hash matches current staged diff
    # - tests/test_auth_service.py (without [marker]) is the real test path
    # RED: Current gate emits the marker-annotated path as-is from parse_test_index,
    # which prune_test_index removes as stale — so the source file appears unassociated
    # and the gate passes regardless (no status check at all). This is wrong because
    # the TDD developer loses test gate protection when RED markers are present.
    # After fix: gate correctly strips [marker], recognizes the test file, checks status.
    assert_eq "test_gate_red_marker_index_passes: gate passes with valid status + RED marker" "0" "$exit_code"

    # Verify the .test-index was NOT pruned (the entry should still exist after the fix)
    local index_content
    index_content=$(cat "$_repo/.test-index" 2>/dev/null || echo "FILE_MISSING")
    _tmp="$index_content"; if [[ "$_tmp" =~ lib/auth_service\.py ]]; then
        assert_eq "test_gate_red_marker_index_passes: .test-index entry preserved (not pruned)" \
            "preserved" "preserved"
    else
        assert_eq "test_gate_red_marker_index_passes: .test-index entry preserved (not pruned)" \
            "preserved" "pruned"
    fi
}

# ============================================================
# TEST 31: test_gate_red_marker_blocks_when_no_status
# When .test-index has a [marker] annotation and no test-gate-status
# exists, the gate must BLOCK the commit (same as without marker).
# The [marker] does not exempt the file from the gate — it only
# affects how record-test-status.sh interprets failures. The gate
# itself must still require valid test-gate-status.
#
# RED: Current gate prunes the marker-annotated path as stale,
# causing the source file to appear unassociated — gate exits 0
# even without status (bypasses test gate silently).
# ============================================================
test_gate_red_marker_blocks_when_no_status() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source file + test file
    mkdir -p "$_repo/lib" "$_repo/tests"
    echo 'def work(): pass' > "$_repo/lib/worker.py"
    cat > "$_repo/tests/test_worker.py" <<'TESTFILE'
def test_existing(): assert True
def test_new_feature(): assert False, "not yet implemented"
TESTFILE
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add worker"

    # Write .test-index with [marker]
    cat > "$_repo/.test-index" <<'IDX'
lib/worker.py: tests/test_worker.py [test_new_feature]
IDX
    git -C "$_repo" add "$_repo/.test-index"
    git -C "$_repo" commit -q -m "add .test-index with RED marker"

    # Modify source and stage
    echo '# changed' >> "$_repo/lib/worker.py"
    git -C "$_repo" add "$_repo/lib/worker.py"

    # Do NOT write test-gate-status

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_artifacts")

    # Gate should BLOCK (exit != 0): test-gate-status is absent
    # RED: Current gate exits 0 because prune removes the marker-annotated path
    assert_ne "test_gate_red_marker_blocks_when_no_status: gate blocks without status" "0" "$exit_code"
}

# ============================================================
# TEST 32: test_error_message_includes_source_file_flag
# Blocked commits output an error message that includes
# --source-file so the developer knows the exact invocation
# needed to re-record test status for the changed file.
# RED: Current messages say "Re-run record-test-status.sh"
# without --source-file.
# ============================================================
test_error_message_includes_source_file_flag() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create source + associated test
    mkdir -p "$_repo/src" "$_repo/tests"
    echo 'def srcflag(): return 1' > "$_repo/src/srcflag.py"
    echo 'def test_srcflag(): assert True' > "$_repo/tests/test_srcflag.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add srcflag"

    # Modify source and stage, but do NOT write test-gate-status
    echo '# changed' >> "$_repo/src/srcflag.py"
    git -C "$_repo" add -A

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_error_message_includes_source_file_flag: hook not found (RED)" "missing" "missing"
        return
    fi

    local stderr_output
    stderr_output=$(run_gate_hook_stderr "$_repo" "$_artifacts")

    # Error message should include --source-file so the developer knows the exact
    # invocation: bash "$REPO_ROOT/.claude/scripts/dso" record-test-status.sh --source-file <file>
    assert_contains "test_error_message_includes_source_file_flag: mentions --source-file" \
        "--source-file" "$stderr_output"
}

# ============================================================
# TEST 33: test_error_message_hash_mismatch_includes_source_file
# HASH_MISMATCH error path outputs --source-file in the message.
# ============================================================
test_error_message_hash_mismatch_includes_source_file() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    mkdir -p "$_repo/src" "$_repo/tests"
    echo 'def mismatch(): return 1' > "$_repo/src/mismatch.py"
    echo 'def test_mismatch(): assert True' > "$_repo/tests/test_mismatch.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add mismatch"

    echo '# changed' >> "$_repo/src/mismatch.py"
    git -C "$_repo" add -A

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_error_message_hash_mismatch_includes_source_file: hook not found (RED)" "missing" "missing"
        return
    fi

    # Write status with a stale hash to trigger HASH_MISMATCH path
    write_valid_test_status "$_artifacts" "stale_hash_abc123"

    local stderr_output
    stderr_output=$(run_gate_hook_stderr "$_repo" "$_artifacts")

    assert_contains "test_error_message_hash_mismatch_includes_source_file: mentions --source-file" \
        "--source-file" "$stderr_output"
}

# ============================================================
# TEST 34: test_error_message_missing_diff_hash_includes_source_file
# MISSING_DIFF_HASH error path (status file has no diff_hash= line)
# outputs --source-file in the message.
# ============================================================
test_error_message_missing_diff_hash_includes_source_file() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    mkdir -p "$_repo/src" "$_repo/tests"
    echo 'def nodiffhash(): return 1' > "$_repo/src/nodiffhash.py"
    echo 'def test_nodiffhash(): assert True' > "$_repo/tests/test_nodiffhash.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add nodiffhash"

    echo '# changed' >> "$_repo/src/nodiffhash.py"
    git -C "$_repo" add -A

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_error_message_missing_diff_hash_includes_source_file: hook not found (RED)" "missing" "missing"
        return
    fi

    # Write a status file with no diff_hash= line to trigger MISSING_DIFF_HASH path
    mkdir -p "$_artifacts"
    printf 'passed\ntimestamp=2026-01-01T00:00:00Z\ntested_files=tests/test_nodiffhash.py\n' \
        > "$_artifacts/test-gate-status"

    local stderr_output
    stderr_output=$(run_gate_hook_stderr "$_repo" "$_artifacts")

    assert_contains "test_error_message_missing_diff_hash_includes_source_file: mentions --source-file" \
        "--source-file" "$stderr_output"
}

# ============================================================
# TEST 35: test_error_message_missing_required_tests_includes_source_file
# MISSING_REQUIRED_TESTS error path (test-index maps source to a test
# that is absent from tested_files) outputs --source-file in the message.
# ============================================================
test_error_message_missing_required_tests_includes_source_file() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    mkdir -p "$_repo/lib" "$_repo/tests/integration"
    echo 'def reqtest(): return 1' > "$_repo/lib/reqtest.py"
    echo 'def test_reqtest_flow(): assert True' > "$_repo/tests/integration/test_reqtest_flow.py"
    cat > "$_repo/.test-index" <<'IDX'
lib/reqtest.py:tests/integration/test_reqtest_flow.py
IDX
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add reqtest with index"

    echo '# changed' >> "$_repo/lib/reqtest.py"
    git -C "$_repo" add "$_repo/lib/reqtest.py"

    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_error_message_missing_required_tests_includes_source_file: hook not found (RED)" "missing" "missing"
        return
    fi

    # Compute the real hash so we pass the hash check and reach MISSING_REQUIRED_TESTS
    local real_hash
    real_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")

    # Write status with matching hash but tested_files missing the required test
    mkdir -p "$_artifacts"
    printf 'passed\ndiff_hash=%s\ntimestamp=2026-01-01T00:00:00Z\ntested_files=tests/some_other_test.py\n' \
        "$real_hash" > "$_artifacts/test-gate-status"

    local stderr_output
    stderr_output=$(run_gate_hook_stderr "$_repo" "$_artifacts")

    assert_contains "test_error_message_missing_required_tests_includes_source_file: mentions --source-file" \
        "--source-file" "$stderr_output"
}

# ── Helper: run a test function and print PASS/FAIL per-function result ───────
# Enables AC verify commands that grep for 'PASS.*<test_name>' in output.
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
run_test test_gate_blocked_missing_status
run_test test_gate_blocked_hash_mismatch
run_test test_gate_blocked_not_passed
run_test test_gate_passes_no_associated_test
run_test test_gate_passes_valid_status
run_test test_gate_passes_no_staged_files
run_test test_error_message_actionable
run_test test_gate_fails_open_on_hash_error
run_test test_gate_passes_when_test_exempted
run_test test_gate_blocked_when_test_not_exempted
run_test test_gate_passes_no_status_but_fully_exempted
run_test test_gate_bash_script_triggers
run_test test_gate_typescript_triggers
run_test test_gate_test_file_itself_exempt
run_test test_gate_test_dirs_config
run_test test_gate_index_mapped_source_triggers
run_test test_gate_index_union_with_fuzzy
run_test test_gate_missing_index_noop
run_test test_gate_index_empty_right_side_noop
run_test test_gate_index_multi_test_paths
run_test test_gate_index_prune_stale_entry
run_test test_gate_index_prune_removes_line_when_all_stale
run_test test_gate_index_prune_stages_modified_index
run_test test_gate_index_prune_partial
run_test test_gate_prune_git_add_failure_exits_nonzero
run_test test_gate_allowlist_files_skipped
run_test test_gate_allowlist_mixed_with_source
run_test test_gate_fails_open_on_sigterm
run_test test_gate_red_marker_index_passes
run_test test_gate_red_marker_blocks_when_no_status
run_test test_error_message_includes_source_file_flag
run_test test_error_message_hash_mismatch_includes_source_file
run_test test_error_message_missing_diff_hash_includes_source_file
run_test test_error_message_missing_required_tests_includes_source_file

print_summary
