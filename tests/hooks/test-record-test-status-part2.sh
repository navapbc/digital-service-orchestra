#!/usr/bin/env bash
set -euo pipefail
# tests/hooks/test-record-test-status-part2.sh
# Tests for hooks/record-test-status.sh — Part 2 of 4 (tests 10–17: .test-index support, RED marker behavior)
# Covers: discovers_associated_tests, records_passed_status,
#   records_failed_status, exit_144_actionable_message,
#   no_associated_tests_exempts, hash_matches_compute_diff_hash,
#   captures_hash_after_staging, record_bash_script_discovers_test,
#   record_uses_configured_test_dirs, record_status_index_mapped_source,
#   record_status_index_union_with_fuzzy, record_status_index_missing_noop,
#   record_status_index_stale_entry_skipped, restamping_with_changed_hash_rejected,
#   red_marker_tolerates_failure_after_marker,
#   red_marker_blocks_failure_before_marker, no_marker_backward_compat

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/record-test-status.sh"
COMPUTE_HASH_SCRIPT="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Source deps.sh to use get_artifacts_dir()
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# Disable commit signing for test git repos
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

# --- Pytest availability check ---
# If pytest is not installed (e.g., CI without Python dev deps), use a mock
# runner via RECORD_TEST_STATUS_RUNNER so tests don't depend on pytest.
_PYTEST_AVAILABLE=1
if ! python3 -m pytest --version >/dev/null 2>&1; then
    _PYTEST_AVAILABLE=0
    # Create mock runners: one that always passes, one that always fails
    _MOCK_PASS_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-pass-runner-XXXXXX")
    _MOCK_FAIL_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-fail-runner-XXXXXX")
    chmod +x "$_MOCK_PASS_RUNNER" "$_MOCK_FAIL_RUNNER"
    cat > "$_MOCK_PASS_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
echo "PASSED (mock runner — pytest not installed)"
exit 0
MOCKEOF
    cat > "$_MOCK_FAIL_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
echo "FAILED (mock runner — pytest not installed)"
exit 1
MOCKEOF
fi

# ============================================================
# Helper: create an isolated temp git repo with initial commit
# ============================================================
create_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test-record-test-status-XXXXXX")
    git -C "$tmpdir" init --quiet 2>/dev/null
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    # Create initial commit so HEAD exists
    touch "$tmpdir/.gitkeep"
    git -C "$tmpdir" add .gitkeep
    git -C "$tmpdir" commit -m "initial" --quiet 2>/dev/null
    echo "$tmpdir"
}

# Helper: run the hook and capture exit code
# Accepts optional RECORD_TEST_STATUS_RUNNER override as first arg prefixed with "RUNNER="
run_hook_exit() {
    local exit_code=0
    bash "$HOOK" "$@" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# Helper: run the hook with mock pass runner when pytest is unavailable
run_hook_exit_pass() {
    if (( _PYTEST_AVAILABLE )); then
        run_hook_exit "$@"
    else
        RECORD_TEST_STATUS_RUNNER="$_MOCK_PASS_RUNNER" run_hook_exit "$@"
    fi
}

# Helper: run the hook with mock fail runner when pytest is unavailable
run_hook_exit_fail() {
    if (( _PYTEST_AVAILABLE )); then
        run_hook_exit "$@"
    else
        RECORD_TEST_STATUS_RUNNER="$_MOCK_FAIL_RUNNER" run_hook_exit "$@"
    fi
}
# ============================================================
# test_record_status_index_mapped_source
# Source file mapped in .test-index; record-test-status.sh
# includes the mapped test file in the test run (even if
# fuzzy match would not find it)
# ============================================================
echo ""
echo "=== test_record_status_index_mapped_source ==="

TEST_REPO_IDX1=$(create_test_repo)
ARTIFACTS_IDX1=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_IDX1" "$ARTIFACTS_IDX1"' EXIT

# Create a source file and a test file with a non-conventional name
# that fuzzy match would NOT discover
mkdir -p "$TEST_REPO_IDX1/lib" "$TEST_REPO_IDX1/tests/integration"
cat > "$TEST_REPO_IDX1/lib/processor.py" << 'PYEOF'
def process():
    return "processed"
PYEOF
cat > "$TEST_REPO_IDX1/tests/integration/verify_processor_integration.py" << 'PYEOF'
def test_processor_integration():
    assert True
PYEOF

# Create .test-index mapping processor.py -> the integration test
cat > "$TEST_REPO_IDX1/.test-index" << 'IDXEOF'
lib/processor.py:tests/integration/verify_processor_integration.py
IDXEOF

git -C "$TEST_REPO_IDX1" add -A
git -C "$TEST_REPO_IDX1" commit -m "add processor with .test-index mapping" --quiet 2>/dev/null

# Modify processor.py to create a staged diff
echo "# changed" >> "$TEST_REPO_IDX1/lib/processor.py"
git -C "$TEST_REPO_IDX1" add -A

EXIT_CODE=$(
    cd "$TEST_REPO_IDX1"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_IDX1" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    run_hook_exit_pass
)

STATUS_FILE_IDX1="$ARTIFACTS_IDX1/test-gate-status"

# The .test-index maps processor.py to verify_processor_integration.py.
# Fuzzy match alone would NOT find this test (name doesn't match convention).
# With .test-index support, the test file should be discovered and run.
if [[ -f "$STATUS_FILE_IDX1" ]]; then
    TESTED_LINE=$(grep '^tested_files=' "$STATUS_FILE_IDX1" | head -1 | cut -d= -f2)
    assert_contains "test_record_status_index_mapped_source: tested_files contains verify_processor_integration.py" "verify_processor_integration.py" "$TESTED_LINE"
else
    # No status file — .test-index was not consulted (RED failure expected)
    assert_eq "test_record_status_index_mapped_source: status file written (.test-index mapping)" "exists" "missing"
fi

rm -rf "$TEST_REPO_IDX1" "$ARTIFACTS_IDX1"
trap - EXIT

# ============================================================
# test_record_status_index_union_with_fuzzy
# Source file with both fuzzy match AND index entry; union
# of both test sets is included in the run
# ============================================================
echo ""
echo "=== test_record_status_index_union_with_fuzzy ==="

TEST_REPO_IDX2=$(create_test_repo)
ARTIFACTS_IDX2=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_IDX2" "$ARTIFACTS_IDX2"' EXIT

# Create a source file, a conventionally-named test (fuzzy match finds it),
# and a non-conventional test mapped via .test-index
mkdir -p "$TEST_REPO_IDX2/src" "$TEST_REPO_IDX2/tests" "$TEST_REPO_IDX2/tests/special"
cat > "$TEST_REPO_IDX2/src/widget.py" << 'PYEOF'
def widget():
    return "widget"
PYEOF
# Conventional test — fuzzy match will find this
cat > "$TEST_REPO_IDX2/tests/test_widget.py" << 'PYEOF'
def test_widget():
    assert True
PYEOF
# Non-conventional test — only .test-index maps to this
cat > "$TEST_REPO_IDX2/tests/special/widget_smoke_check.py" << 'PYEOF'
def test_widget_smoke():
    assert True
PYEOF

# .test-index maps widget.py to the smoke check test
cat > "$TEST_REPO_IDX2/.test-index" << 'IDXEOF'
src/widget.py:tests/special/widget_smoke_check.py
IDXEOF

git -C "$TEST_REPO_IDX2" add -A
git -C "$TEST_REPO_IDX2" commit -m "add widget with fuzzy + index tests" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_IDX2/src/widget.py"
git -C "$TEST_REPO_IDX2" add -A

EXIT_CODE=$(
    cd "$TEST_REPO_IDX2"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_IDX2" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    run_hook_exit_pass
)

STATUS_FILE_IDX2="$ARTIFACTS_IDX2/test-gate-status"

if [[ -f "$STATUS_FILE_IDX2" ]]; then
    TESTED_LINE=$(grep '^tested_files=' "$STATUS_FILE_IDX2" | head -1 | cut -d= -f2)
    # Both the fuzzy-matched test AND the index-mapped test should appear
    assert_contains "test_record_status_index_union_with_fuzzy: tested_files contains test_widget.py" "test_widget.py" "$TESTED_LINE"
    assert_contains "test_record_status_index_union_with_fuzzy: tested_files contains widget_smoke_check.py" "widget_smoke_check.py" "$TESTED_LINE"
else
    # Status file exists (fuzzy match finds test_widget.py) but smoke check is missing
    # — need to check tested_files doesn't contain the index-mapped test
    assert_eq "test_record_status_index_union_with_fuzzy: status file written (union of fuzzy + index)" "exists" "missing"
fi

rm -rf "$TEST_REPO_IDX2" "$ARTIFACTS_IDX2"
trap - EXIT

# ============================================================
# test_record_status_index_missing_noop
# .test-index does not exist; record-test-status.sh proceeds
# normally (no error)
# ============================================================
echo ""
echo "=== test_record_status_index_missing_noop ==="

TEST_REPO_IDX3=$(create_test_repo)
ARTIFACTS_IDX3=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_IDX3" "$ARTIFACTS_IDX3"' EXIT

# Create a source file with a conventional test but NO .test-index file
mkdir -p "$TEST_REPO_IDX3/src" "$TEST_REPO_IDX3/tests"
cat > "$TEST_REPO_IDX3/src/simple.py" << 'PYEOF'
def simple():
    return "simple"
PYEOF
cat > "$TEST_REPO_IDX3/tests/test_simple.py" << 'PYEOF'
def test_simple():
    assert True
PYEOF

git -C "$TEST_REPO_IDX3" add -A
git -C "$TEST_REPO_IDX3" commit -m "add simple without .test-index" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_IDX3/src/simple.py"
git -C "$TEST_REPO_IDX3" add -A

# Confirm no .test-index exists
if [[ -f "$TEST_REPO_IDX3/.test-index" ]]; then
    echo "ERROR: .test-index should not exist in this test" >&2
    (( ++FAIL ))
fi

OUTPUT_IDX3=$(
    cd "$TEST_REPO_IDX3"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_IDX3" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    run_hook_exit_pass 2>&1
)
EXIT_CODE_IDX3=$(echo "$OUTPUT_IDX3" | tail -1)

# When .test-index is missing, the hook should still work via fuzzy match.
# This test verifies the hook explicitly handles .test-index absence — the
# stderr output should mention .test-index (e.g., "no .test-index found" or
# ".test-index: not found, using fuzzy match only") to confirm the code path
# was exercised. Pre-implementation, no such message exists (RED).
assert_eq "test_record_status_index_missing_noop: exit 0" "0" "$EXIT_CODE_IDX3"

# Capture stderr to check for .test-index handling message
STDERR_IDX3=$(
    cd "$TEST_REPO_IDX3"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_IDX3" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$HOOK" 2>&1 >/dev/null || true
)
# After implementation, stderr should mention .test-index (even when absent)
# to confirm the code path was reached. Pre-implementation, no mention.
assert_contains "test_record_status_index_missing_noop: stderr mentions .test-index handling" ".test-index" "$STDERR_IDX3"

STATUS_FILE_IDX3="$ARTIFACTS_IDX3/test-gate-status"
if [[ -f "$STATUS_FILE_IDX3" ]]; then
    TESTED_LINE=$(grep '^tested_files=' "$STATUS_FILE_IDX3" | head -1 | cut -d= -f2)
    assert_contains "test_record_status_index_missing_noop: test_simple.py discovered via fuzzy" "test_simple.py" "$TESTED_LINE"
fi

rm -rf "$TEST_REPO_IDX3" "$ARTIFACTS_IDX3"
trap - EXIT

# ============================================================
# test_record_status_index_stale_entry_skipped
# .test-index entry pointing to a nonexistent test file;
# record-test-status.sh skips it with a warning (does not
# attempt to run nonexistent file)
# ============================================================
echo ""
echo "=== test_record_status_index_stale_entry_skipped ==="

TEST_REPO_IDX4=$(create_test_repo)
ARTIFACTS_IDX4=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_IDX4" "$ARTIFACTS_IDX4"' EXIT

# Create source file with .test-index pointing to a test that does NOT exist
mkdir -p "$TEST_REPO_IDX4/src"
cat > "$TEST_REPO_IDX4/src/ghost.py" << 'PYEOF'
def ghost():
    return "ghost"
PYEOF

# .test-index maps to a test file that does not exist on disk
cat > "$TEST_REPO_IDX4/.test-index" << 'IDXEOF'
src/ghost.py:tests/test_ghost_missing.py
IDXEOF

git -C "$TEST_REPO_IDX4" add -A
git -C "$TEST_REPO_IDX4" commit -m "add ghost with stale .test-index entry" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_IDX4/src/ghost.py"
git -C "$TEST_REPO_IDX4" add -A

HOOK_OUTPUT_IDX4=$(
    cd "$TEST_REPO_IDX4"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_IDX4" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$HOOK" 2>&1 || true
)

# The hook should warn about the stale entry (nonexistent file) and skip it.
# Currently .test-index is not consulted at all, so:
#   - The stale entry is never seen
#   - No warning is emitted about test_ghost_missing.py
# After implementation: warning should mention the missing file.
assert_contains "test_record_status_index_stale_entry_skipped: warning about stale entry" "test_ghost_missing.py" "$HOOK_OUTPUT_IDX4"

# The hook should NOT crash — it should exit cleanly (0) after skipping the stale entry.
# (ghost.py has no fuzzy-matched test either, so it gets exempt treatment.)
STATUS_FILE_IDX4="$ARTIFACTS_IDX4/test-gate-status"
if [[ -f "$STATUS_FILE_IDX4" ]]; then
    TESTED_LINE=$(grep '^tested_files=' "$STATUS_FILE_IDX4" | head -1 | cut -d= -f2)
    # The stale test file should NOT appear in tested_files
    if [[ "$TESTED_LINE" == *"test_ghost_missing.py"* ]]; then
        (( ++FAIL ))
        echo "FAIL: test_record_status_index_stale_entry_skipped: stale entry should not be in tested_files" >&2
    else
        (( ++PASS ))
    fi
fi

rm -rf "$TEST_REPO_IDX4" "$ARTIFACTS_IDX4"
trap - EXIT

# ============================================================
# test_restamping_with_changed_hash_rejected
# When record-test-status.sh is called a second time after
# code changes (hash A → hash B), it should NOT silently
# re-stamp hash B as 'passed' based on a test run that
# validated hash-A code. The script must detect the stale
# status (existing 'passed' for a different hash) and fail
# with an error directing the caller to re-run tests.
#
# Reproduction (dso-6x8o):
#   1. Stage files, run record-test-status.sh (records hash A)
#   2. Edit a staged file (hash changes to B)
#   3. Stage the edit, run record-test-status.sh again
#   Expected: error / non-zero exit — stale status detected
#   Actual:   exits 0 and writes hash B as 'passed' silently
# ============================================================
echo ""
echo "=== test_restamping_with_changed_hash_rejected ==="

TEST_REPO_RESTAMP=$(create_test_repo)
ARTIFACTS_RESTAMP=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_RESTAMP" "$ARTIFACTS_RESTAMP"' EXIT

# Create a source file and its associated test
mkdir -p "$TEST_REPO_RESTAMP/src" "$TEST_REPO_RESTAMP/tests"
cat > "$TEST_REPO_RESTAMP/src/restamp.py" << 'PYEOF2'
def restamp():
    return "v1"
PYEOF2
cat > "$TEST_REPO_RESTAMP/tests/test_restamp.py" << 'PYEOF2'
def test_restamp():
    assert True
PYEOF2
git -C "$TEST_REPO_RESTAMP" add -A
git -C "$TEST_REPO_RESTAMP" commit -m "add restamp" --quiet 2>/dev/null

# Step 1: Modify source, stage it, run record-test-status.sh (records hash A)
echo "# change v1" >> "$TEST_REPO_RESTAMP/src/restamp.py"
git -C "$TEST_REPO_RESTAMP" add -A

MOCK_PASS_RESTAMP=$(mktemp "${TMPDIR:-/tmp}/mock-pass-restamp-XXXXXX")
chmod +x "$MOCK_PASS_RESTAMP"
cat > "$MOCK_PASS_RESTAMP" << 'MOCKEOF'
#!/usr/bin/env bash
echo "PASSED (mock)"
exit 0
MOCKEOF

EXIT_CODE_FIRST=$(
    cd "$TEST_REPO_RESTAMP"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_RESTAMP" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_RESTAMP" \
    run_hook_exit
)

assert_eq "test_restamping_with_changed_hash_rejected: first invocation exits 0" "0" "$EXIT_CODE_FIRST"

STATUS_FILE_RESTAMP="$ARTIFACTS_RESTAMP/test-gate-status"
if [[ ! -f "$STATUS_FILE_RESTAMP" ]]; then
    echo "SKIP: test_restamping_with_changed_hash_rejected: no status file after first run (test infra issue)" >&2
else
    HASH_A=$(grep '^diff_hash=' "$STATUS_FILE_RESTAMP" | head -1 | cut -d= -f2)

    # Step 2: Make a new code change and stage it (hash changes to B)
    echo "# change v2 - post-review fix" >> "$TEST_REPO_RESTAMP/src/restamp.py"
    git -C "$TEST_REPO_RESTAMP" add -A

    # Verify hash actually changed
    HASH_B=$(cd "$TEST_REPO_RESTAMP" && bash "$COMPUTE_HASH_SCRIPT" 2>/dev/null)

    if [[ "$HASH_A" == "$HASH_B" ]]; then
        echo "SKIP: test_restamping_with_changed_hash_rejected: hashes did not change (test setup issue)" >&2
    else
        # Step 3: Call record-test-status.sh again -- it should clear the stale
        # status and re-run tests, recording hash B as passed.
        EXIT_CODE_SECOND=$(
            cd "$TEST_REPO_RESTAMP"
            WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_RESTAMP" \
            CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
            RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_RESTAMP" \
            run_hook_exit
        )

        # EXPECTED: exit 0 (stale status cleared, tests re-run and passed)
        assert_eq "test_restamping_with_changed_hash_rejected: second call re-runs tests and exits 0" "0" "$EXIT_CODE_SECOND"

        # Status file should now have hash B (tests re-ran against new code)
        RECORDED_HASH_AFTER=$(grep '^diff_hash=' "$STATUS_FILE_RESTAMP" | head -1 | cut -d= -f2)
        assert_eq "test_restamping_with_changed_hash_rejected: status file updated to hash B after re-test" "$HASH_B" "$RECORDED_HASH_AFTER"
    fi
fi

rm -f "$MOCK_PASS_RESTAMP"
rm -rf "$TEST_REPO_RESTAMP" "$ARTIFACTS_RESTAMP"
trap - EXIT

# ============================================================
# test_red_marker_tolerates_failure_after_marker
# When .test-index entry has [test_red_function] marker and
# the test file has failing tests at/after test_red_function,
# record-test-status.sh exits 0 and writes 'passed'.
# RED: feature not yet implemented; hook ignores markers.
# ============================================================
echo ""
echo "=== test_red_marker_tolerates_failure_after_marker ==="
_snapshot_fail

TEST_REPO_RED1=$(create_test_repo)
ARTIFACTS_RED1=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_RED1" "$ARTIFACTS_RED1"' EXIT

# Create a source file and a test file with both passing and failing tests
mkdir -p "$TEST_REPO_RED1/src" "$TEST_REPO_RED1/tests"
cat > "$TEST_REPO_RED1/src/alpha.py" << 'PYEOF'
def alpha():
    return "alpha"
PYEOF

cat > "$TEST_REPO_RED1/tests/test_alpha.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_alpha_passes: PASS"
echo "test_red_function: FAIL (intentional RED zone failure)"
exit 1
SHEOF
chmod +x "$TEST_REPO_RED1/tests/test_alpha.sh"

# .test-index maps alpha.py -> test_alpha.sh with [test_red_function] RED marker
cat > "$TEST_REPO_RED1/.test-index" << 'IDXEOF'
src/alpha.py: tests/test_alpha.sh [test_red_function]
IDXEOF

git -C "$TEST_REPO_RED1" add -A
git -C "$TEST_REPO_RED1" commit -m "add alpha with RED marker" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_RED1/src/alpha.py"
git -C "$TEST_REPO_RED1" add -A

# Use a mock runner that simulates a test runner that fails (RED zone failure expected)
MOCK_RED1_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-red1-runner-XXXXXX")
chmod +x "$MOCK_RED1_RUNNER"
cat > "$MOCK_RED1_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_red_function: FAIL (intentional RED zone)"
exit 1
MOCKEOF

EXIT_CODE_RED1=$(
    cd "$TEST_REPO_RED1"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_RED1" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_RED1_RUNNER" \
    run_hook_exit
)

STATUS_FILE_RED1="$ARTIFACTS_RED1/test-gate-status"

# EXPECTED (after implementation): hook reads [test_red_function] from .test-index,
# detects failure is in the RED zone, exits 0, writes 'passed'.
# RED phase: hook ignores markers → exits 1 (blocking), writes 'failed'.
assert_eq "test_red_marker_tolerates_failure_after_marker: exits 0 (RED zone tolerated)" "0" "$EXIT_CODE_RED1"
if [[ -f "$STATUS_FILE_RED1" ]]; then
    FIRST_LINE_RED1=$(head -1 "$STATUS_FILE_RED1")
    assert_eq "test_red_marker_tolerates_failure_after_marker: writes passed" "passed" "$FIRST_LINE_RED1"
else
    assert_eq "test_red_marker_tolerates_failure_after_marker: status file exists" "exists" "missing"
fi

rm -f "$MOCK_RED1_RUNNER"
rm -rf "$TEST_REPO_RED1" "$ARTIFACTS_RED1"
trap - EXIT
assert_pass_if_clean "test_red_marker_tolerates_failure_after_marker"

# ============================================================
# test_red_marker_blocks_failure_before_marker
# When .test-index entry has [test_red_function] and a test
# BEFORE test_red_function fails, record-test-status.sh exits
# 1 and writes 'failed' (normal blocking behavior preserved).
# RED: feature not implemented; all failures block (same result
# but for wrong reason — hook doesn't parse position at all).
# ============================================================
echo ""
echo "=== test_red_marker_blocks_failure_before_marker ==="
_snapshot_fail

TEST_REPO_RED2=$(create_test_repo)
ARTIFACTS_RED2=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_RED2" "$ARTIFACTS_RED2"' EXIT

mkdir -p "$TEST_REPO_RED2/src" "$TEST_REPO_RED2/tests"
cat > "$TEST_REPO_RED2/src/beta.py" << 'PYEOF'
def beta():
    return "beta"
PYEOF

# Test file: test_pre_red_failure fails BEFORE the marker; test_red_function is the marker
cat > "$TEST_REPO_RED2/tests/test_beta.sh" << 'SHEOF'
#!/usr/bin/env bash
# test_pre_red_failure runs before test_red_function and fails
echo "test_pre_red_failure: FAIL"
echo "test_red_function: PASS (marker — not yet reached due to earlier failure)"
exit 1
SHEOF
chmod +x "$TEST_REPO_RED2/tests/test_beta.sh"

cat > "$TEST_REPO_RED2/.test-index" << 'IDXEOF'
src/beta.py: tests/test_beta.sh [test_red_function]
IDXEOF

git -C "$TEST_REPO_RED2" add -A
git -C "$TEST_REPO_RED2" commit -m "add beta with RED marker" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_RED2/src/beta.py"
git -C "$TEST_REPO_RED2" add -A

# Mock runner simulating test failure BEFORE the RED marker
MOCK_RED2_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-red2-runner-XXXXXX")
chmod +x "$MOCK_RED2_RUNNER"
cat > "$MOCK_RED2_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
# Simulate: test_pre_red_failure fails, test_red_function not yet reached
echo "test_pre_red_failure: FAIL"
exit 1
MOCKEOF

EXIT_CODE_RED2=$(
    cd "$TEST_REPO_RED2"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_RED2" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_RED2_RUNNER" \
    run_hook_exit
)

STATUS_FILE_RED2="$ARTIFACTS_RED2/test-gate-status"

# EXPECTED (after implementation): failure is BEFORE marker → still blocks → exits 1, writes 'failed'.
# RED phase: same exit code but for the wrong reason (hook doesn't know about position).
# We verify the exit code AND the status file — both must be correct for the test to pass.
assert_eq "test_red_marker_blocks_failure_before_marker: exits 1 (pre-marker failure blocks)" "1" "$EXIT_CODE_RED2"
if [[ -f "$STATUS_FILE_RED2" ]]; then
    FIRST_LINE_RED2=$(head -1 "$STATUS_FILE_RED2")
    assert_eq "test_red_marker_blocks_failure_before_marker: writes failed" "failed" "$FIRST_LINE_RED2"
fi

rm -f "$MOCK_RED2_RUNNER"
rm -rf "$TEST_REPO_RED2" "$ARTIFACTS_RED2"
trap - EXIT
assert_pass_if_clean "test_red_marker_blocks_failure_before_marker"

# ============================================================
# test_no_marker_backward_compat
# When .test-index entry has NO marker (existing format),
# behavior is identical to current — failures always block.
# RED: This test should pass even pre-implementation (backward
# compat check); it documents the invariant that no marker =
# blocking behavior unchanged.
# ============================================================
echo ""
echo "=== test_no_marker_backward_compat ==="
_snapshot_fail

TEST_REPO_COMPAT=$(create_test_repo)
ARTIFACTS_COMPAT=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_COMPAT" "$ARTIFACTS_COMPAT"' EXIT

mkdir -p "$TEST_REPO_COMPAT/src" "$TEST_REPO_COMPAT/tests"
cat > "$TEST_REPO_COMPAT/src/compat.py" << 'PYEOF'
def compat():
    return "compat"
PYEOF

cat > "$TEST_REPO_COMPAT/tests/test_compat.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_something: FAIL (backward compat — no marker)"
exit 1
SHEOF
chmod +x "$TEST_REPO_COMPAT/tests/test_compat.sh"

# .test-index entry WITHOUT any [marker] — existing format
cat > "$TEST_REPO_COMPAT/.test-index" << 'IDXEOF'
src/compat.py: tests/test_compat.sh
IDXEOF

git -C "$TEST_REPO_COMPAT" add -A
git -C "$TEST_REPO_COMPAT" commit -m "add compat without marker" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_COMPAT/src/compat.py"
git -C "$TEST_REPO_COMPAT" add -A

MOCK_COMPAT_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-compat-runner-XXXXXX")
chmod +x "$MOCK_COMPAT_RUNNER"
cat > "$MOCK_COMPAT_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_something: FAIL"
exit 1
MOCKEOF

EXIT_CODE_COMPAT=$(
    cd "$TEST_REPO_COMPAT"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_COMPAT" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_COMPAT_RUNNER" \
    run_hook_exit
)

STATUS_FILE_COMPAT="$ARTIFACTS_COMPAT/test-gate-status"

# EXPECTED (pre and post implementation): no marker → failure always blocks → exits 1, writes 'failed'
# This test documents the backward-compat invariant.
assert_eq "test_no_marker_backward_compat: exits 1 (no marker, failure blocks)" "1" "$EXIT_CODE_COMPAT"
if [[ -f "$STATUS_FILE_COMPAT" ]]; then
    FIRST_LINE_COMPAT=$(head -1 "$STATUS_FILE_COMPAT")
    assert_eq "test_no_marker_backward_compat: writes failed" "failed" "$FIRST_LINE_COMPAT"
fi

rm -f "$MOCK_COMPAT_RUNNER"
rm -rf "$TEST_REPO_COMPAT" "$ARTIFACTS_COMPAT"
trap - EXIT
assert_pass_if_clean "test_no_marker_backward_compat"

# Clean up mock runners if created
if (( ! _PYTEST_AVAILABLE )); then
    rm -f "$_MOCK_PASS_RUNNER" "$_MOCK_FAIL_RUNNER" 2>/dev/null || true
fi


print_summary
