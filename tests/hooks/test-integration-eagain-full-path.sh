#!/usr/bin/env bash
# tests/hooks/test-integration-eagain-full-path.sh
# Integration test verifying the full EAGAIN retry -> reclassification -> non-blocking gate path.
#
# This test chains three components:
#   1. suite-engine.sh EAGAIN retry (exit 254 + EAGAIN pattern -> retry with MAX_PARALLEL=1)
#   2. record-test-status.sh EAGAIN reclassification (exit 254 + pattern -> "resource_exhaustion")
#   3. pre-commit-test-gate.sh non-blocking gate (resource_exhaustion -> exit 0, fail-open)
#
# Tests:
#   test_suite_engine_retries_on_eagain
#   test_record_test_status_reclassifies_eagain
#   test_gate_allows_resource_exhaustion
#   test_full_chain_with_intermediate_assertions
#   test_no_retry_without_eagain_stderr
#   test_no_reclassify_without_exit_254
#
# Usage: bash tests/hooks/test-integration-eagain-full-path.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
LIB_DIR="$PLUGIN_ROOT/tests/lib"

RECORD_HOOK="$DSO_PLUGIN_DIR/hooks/record-test-status.sh"
GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-test-gate.sh"
COMPUTE_HASH_SCRIPT="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"

source "$LIB_DIR/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# Disable commit signing for test git repos
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_all() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap '_cleanup_all' EXIT

_make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Shared git repos (created once, reused across tests) ─────────────────────
# Creating a git repo (init + config + commits + staged change) takes ~0.6-1s
# per repo. The tests need 3 rts repos and 2 gate repos per full run, which
# compounds under CI load and causes intermittent timeout failures. By creating
# one repo of each type up-front and reusing it, we cut git overhead by ~60%.
# record-test-status.sh and the gate hook are read-only against the git repo
# (they read staged state, diff hash, etc. but do not commit or modify files),
# so sharing is safe as long as each test uses its own fresh artifacts dir.
_RTS_REPO=""
_GATE_REPO=""

_init_shared_rts_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    git -C "$tmpdir" init --quiet 2>/dev/null
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"

    mkdir -p "$tmpdir/src" "$tmpdir/tests"

    cat > "$tmpdir/src/widget.sh" <<'SRCEOF'
#!/usr/bin/env bash
echo "widget"
SRCEOF

    cat > "$tmpdir/tests/test-widget.sh" <<'TESTEOF'
#!/usr/bin/env bash
echo "PASSED: 1  FAILED: 0"
exit 0
TESTEOF
    chmod +x "$tmpdir/tests/test-widget.sh"

    cat > "$tmpdir/.test-index" <<'IDXEOF'
src/widget.sh: tests/test-widget.sh
IDXEOF

    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -m "add widget" --quiet 2>/dev/null

    echo "# changed" >> "$tmpdir/src/widget.sh"
    git -C "$tmpdir" add "$tmpdir/src/widget.sh"

    _RTS_REPO="$tmpdir"
}

_init_shared_gate_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    git -C "$tmpdir" init -q 2>/dev/null
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    git -C "$tmpdir" config commit.gpgsign false

    mkdir -p "$tmpdir/src" "$tmpdir/tests"
    echo 'def widget(): return 1' > "$tmpdir/src/widget.py"
    echo 'def test_widget(): assert True' > "$tmpdir/tests/test_widget.py"
    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -q -m "add widget" 2>/dev/null

    echo '# changed' >> "$tmpdir/src/widget.py"
    git -C "$tmpdir" add "$tmpdir/src/widget.py"

    _GATE_REPO="$tmpdir"
}

# Initialize shared repos once before running any tests.
_init_shared_rts_repo
_init_shared_gate_repo

# ── Helper: compute diff hash for a gate repo ───────────────────────────────
_compute_hash_in_repo() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    # shellcheck disable=SC2030,SC2031  # exports are intentionally scoped to the subshell
    (
        cd "$repo_dir" || exit 1
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        bash "$COMPUTE_HASH_SCRIPT" 2>/dev/null
    )
}

# ── Helper: run gate hook, return exit code ──────────────────────────────────
_run_gate_hook() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local exit_code=0
    # shellcheck disable=SC2030,SC2031  # exports are intentionally scoped to the subshell
    (
        cd "$repo_dir" || exit 1
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        bash "$GATE_HOOK" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# ── Helper: read line 1 of test-gate-status ──────────────────────────────────
_status_line1() {
    local artifacts_dir="$1"
    local status_file="$artifacts_dir/test-gate-status"
    if [[ -f "$status_file" ]]; then
        head -1 "$status_file"
    else
        echo "FILE_NOT_FOUND"
    fi
}

# ── Helper: make a mock runner script ────────────────────────────────────────
_make_mock_runner() {
    local exit_code="$1"
    local stderr_msg="${2:-}"
    local runner
    local runner_dir
    runner_dir=$(mktemp -d)
    _TEST_TMPDIRS+=("$runner_dir")
    runner="$runner_dir/runner.sh"
    if [[ -n "$stderr_msg" ]]; then
        cat > "$runner" <<RUNEOF
#!/usr/bin/env bash
echo "${stderr_msg}" >&2
exit ${exit_code}
RUNEOF
    else
        cat > "$runner" <<RUNEOF
#!/usr/bin/env bash
exit ${exit_code}
RUNEOF
    fi
    chmod +x "$runner"
    echo "$runner"
}

# ============================================================
# TEST 1: test_suite_engine_retries_on_eagain
#
# Mock runner exits 254 + "fork: Resource temporarily unavailable" on
# first call, passes (exit 0) on second call (retry). Verify
# suite-engine retries with MAX_PARALLEL=1 exported. Verify the
# retry succeeds.
# ============================================================
test_suite_engine_retries_on_eagain() {
    local mock_dir
    mock_dir=$(_make_tmpdir)
    local state_file="$mock_dir/call_count"
    local parallel_log="$mock_dir/parallel_values"
    echo "0" > "$state_file"

    cat > "$mock_dir/test-eagain-mock.sh" <<'MOCK'
#!/usr/bin/env bash
STATE_FILE="__STATE_FILE__"
PARALLEL_LOG="__PARALLEL_LOG__"
count=$(cat "$STATE_FILE")
count=$(( count + 1 ))
echo "$count" > "$STATE_FILE"
echo "${MAX_PARALLEL:-unset}" >> "$PARALLEL_LOG"
if [ "$count" -eq 1 ]; then
    echo "fork: Resource temporarily unavailable" >&2
    echo "PASSED: 0  FAILED: 1"
    exit 254
fi
echo "PASSED: 1  FAILED: 0"
exit 0
MOCK
    sed -i.bak "s|__STATE_FILE__|$state_file|g" "$mock_dir/test-eagain-mock.sh"
    sed -i.bak "s|__PARALLEL_LOG__|$parallel_log|g" "$mock_dir/test-eagain-mock.sh"
    chmod +x "$mock_dir/test-eagain-mock.sh"

    local suite_output suite_exit=0
    suite_output=$(
        MAX_PARALLEL=4 TEST_TIMEOUT=15 MAX_CONSECUTIVE_FAILS=10 \
        bash "$LIB_DIR/suite-engine.sh" "$mock_dir/test-eagain-mock.sh" 2>&1
    ) || suite_exit=$?

    # Mock should have been called twice (retry occurred)
    local final_count
    final_count=$(cat "$state_file")
    assert_eq "suite_retries: mock called twice" "2" "$final_count"

    # Suite output should report PASS
    assert_contains "suite_retries: suite reports PASS" "test-eagain-mock.sh ... PASS" "$suite_output"

    # MAX_PARALLEL during the retry call (second invocation) should be 1
    local parallel_on_retry
    parallel_on_retry=$(sed -n '2p' "$parallel_log")
    assert_eq "suite_retries: MAX_PARALLEL=1 during retry" "1" "$parallel_on_retry"
}

# ============================================================
# TEST 2: test_record_test_status_reclassifies_eagain
#
# Mock runner exits 254 + EAGAIN pattern. Invoke record-test-status.sh
# with --source-file. Verify test-gate-status line 1 = "resource_exhaustion".
# ============================================================
test_record_test_status_reclassifies_eagain() {
    local artifacts runner
    artifacts=$(_make_tmpdir)
    runner=$(_make_mock_runner 254 "fork: Resource temporarily unavailable")

    (
        cd "$_RTS_REPO"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        RECORD_TEST_STATUS_RUNNER="$runner" \
        bash "$RECORD_HOOK" --source-file "src/widget.sh" 2>/dev/null
    ) || true

    local status
    status=$(_status_line1 "$artifacts")
    assert_eq "reclassifies: status is resource_exhaustion" \
        "resource_exhaustion" "$status"
}

# ============================================================
# TEST 3: test_gate_allows_resource_exhaustion
#
# Set up temp git repo with staged files and test-gate-status containing
# "resource_exhaustion" + valid diff_hash. Invoke pre-commit-test-gate.sh.
# Verify non-blocking exit (exit 0).
# ============================================================
test_gate_allows_resource_exhaustion() {
    local artifacts
    artifacts=$(_make_tmpdir)

    local diff_hash
    diff_hash=$(_compute_hash_in_repo "$_GATE_REPO" "$artifacts")

    mkdir -p "$artifacts"
    printf 'resource_exhaustion\ndiff_hash=%s\ntimestamp=2026-04-05T00:00:00Z\ntested_files=tests/test_widget.py\n' \
        "$diff_hash" > "$artifacts/test-gate-status"

    local exit_code
    exit_code=$(_run_gate_hook "$_GATE_REPO" "$artifacts")

    assert_eq "gate_allows: gate exits 0 for resource_exhaustion" "0" "$exit_code"
}

# ============================================================
# TEST 4: test_full_chain_with_intermediate_assertions
#
# Chain all 3 components with intermediate assertions:
#   Step A: Run suite-engine with mock runner -> assert retry succeeded
#   Step B: Run record-test-status -> assert test-gate-status = "resource_exhaustion"
#   Step C: Run gate check -> assert exit 0 (non-blocking)
#
# Uses BlockingIOError pattern to exercise both EAGAIN patterns across
# the chain.
# ============================================================
test_full_chain_with_intermediate_assertions() {
    # --- Step A: suite-engine retry ---
    local mock_dir
    mock_dir=$(_make_tmpdir)
    local state_file="$mock_dir/call_count"
    echo "0" > "$state_file"

    # Mock: first call exits 254 + BlockingIOError, second call passes
    cat > "$mock_dir/test-chain-mock.sh" <<'MOCK'
#!/usr/bin/env bash
STATE_FILE="__STATE_FILE__"
count=$(cat "$STATE_FILE")
count=$(( count + 1 ))
echo "$count" > "$STATE_FILE"
if [ "$count" -eq 1 ]; then
    echo "BlockingIOError: [Errno 35] Resource temporarily unavailable" >&2
    echo "PASSED: 0  FAILED: 1"
    exit 254
fi
echo "PASSED: 1  FAILED: 0"
exit 0
MOCK
    sed -i.bak "s|__STATE_FILE__|$state_file|g" "$mock_dir/test-chain-mock.sh"
    chmod +x "$mock_dir/test-chain-mock.sh"

    local suite_output
    suite_output=$(
        MAX_PARALLEL=4 TEST_TIMEOUT=15 MAX_CONSECUTIVE_FAILS=10 \
        bash "$LIB_DIR/suite-engine.sh" "$mock_dir/test-chain-mock.sh" 2>&1
    ) || true

    local final_count
    final_count=$(cat "$state_file")
    assert_eq "chain_A: suite-engine retried (called twice)" "2" "$final_count"
    assert_contains "chain_A: suite reports PASS after retry" "test-chain-mock.sh ... PASS" "$suite_output"

    # --- Step B: record-test-status reclassification (reuse shared rts repo) ---
    local artifacts runner
    artifacts=$(_make_tmpdir)
    runner=$(_make_mock_runner 254 "BlockingIOError: [Errno 35] Resource temporarily unavailable")

    (
        cd "$_RTS_REPO"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        RECORD_TEST_STATUS_RUNNER="$runner" \
        bash "$RECORD_HOOK" --source-file "src/widget.sh" 2>/dev/null
    ) || true

    local status
    status=$(_status_line1 "$artifacts")
    assert_eq "chain_B: record-test-status wrote resource_exhaustion" \
        "resource_exhaustion" "$status"

    # --- Step C: gate non-blocking (reuse shared gate repo) ---
    local gate_artifacts
    gate_artifacts=$(_make_tmpdir)

    local diff_hash
    diff_hash=$(_compute_hash_in_repo "$_GATE_REPO" "$gate_artifacts")

    mkdir -p "$gate_artifacts"
    printf 'resource_exhaustion\ndiff_hash=%s\ntimestamp=2026-04-05T00:00:00Z\ntested_files=tests/test_widget.py\n' \
        "$diff_hash" > "$gate_artifacts/test-gate-status"

    local gate_exit
    gate_exit=$(_run_gate_hook "$_GATE_REPO" "$gate_artifacts")

    assert_eq "chain_C: gate allows resource_exhaustion (exit 0)" "0" "$gate_exit"
}

# ============================================================
# TEST 5: test_no_retry_without_eagain_stderr
#
# Mock exits 254, no EAGAIN pattern in output. Verify NO retry occurs
# (dual-condition: exit code alone insufficient).
# ============================================================
test_no_retry_without_eagain_stderr() {
    local mock_dir
    mock_dir=$(_make_tmpdir)
    local state_file="$mock_dir/call_count"
    echo "0" > "$state_file"

    cat > "$mock_dir/test-no-eagain-mock.sh" <<'MOCK'
#!/usr/bin/env bash
STATE_FILE="__STATE_FILE__"
count=$(cat "$STATE_FILE")
count=$(( count + 1 ))
echo "$count" > "$STATE_FILE"
# Exit 254 but no EAGAIN pattern -- should NOT trigger retry
echo "some unrelated error message" >&2
echo "PASSED: 0  FAILED: 1"
exit 254
MOCK
    sed -i.bak "s|__STATE_FILE__|$state_file|g" "$mock_dir/test-no-eagain-mock.sh"
    chmod +x "$mock_dir/test-no-eagain-mock.sh"

    local suite_output
    suite_output=$(
        MAX_PARALLEL=4 TEST_TIMEOUT=15 MAX_CONSECUTIVE_FAILS=10 \
        bash "$LIB_DIR/suite-engine.sh" "$mock_dir/test-no-eagain-mock.sh" 2>&1
    ) || true

    # Mock should have been called exactly once (no retry)
    local final_count
    final_count=$(cat "$state_file")
    assert_eq "no_retry_no_pattern: mock called once" "1" "$final_count"

    # Suite should report FAIL
    assert_contains "no_retry_no_pattern: suite reports FAIL" "test-no-eagain-mock.sh ... FAIL" "$suite_output"
}

# ============================================================
# TEST 6: test_no_reclassify_without_exit_254
#
# Mock exits 1, outputs EAGAIN pattern. Verify status = "failed"
# (dual-condition: EAGAIN pattern alone insufficient without exit 254).
# ============================================================
test_no_reclassify_without_exit_254() {
    local artifacts runner
    artifacts=$(_make_tmpdir)
    runner=$(_make_mock_runner 1 "fork: Resource temporarily unavailable")

    (
        cd "$_RTS_REPO"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        RECORD_TEST_STATUS_RUNNER="$runner" \
        bash "$RECORD_HOOK" --source-file "src/widget.sh" 2>/dev/null
    ) || true

    local status
    status=$(_status_line1 "$artifacts")
    assert_eq "no_reclassify_wrong_exit: status is failed (not resource_exhaustion)" \
        "failed" "$status"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_suite_engine_retries_on_eagain
test_record_test_status_reclassifies_eagain
test_gate_allows_resource_exhaustion
test_full_chain_with_intermediate_assertions
test_no_retry_without_eagain_stderr
test_no_reclassify_without_exit_254

print_summary
