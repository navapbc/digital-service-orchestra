#!/usr/bin/env bash
set -euo pipefail
# tests/hooks/test-record-test-status-part3.sh
# Tests for hooks/record-test-status.sh — Part 3 of 4 (tests 18–25)
# Covers: marker_not_found_falls_back_to_blocking, red_zone_bash_test_file,
#   hyphenated_test_name_red_zone, integration_red_marker_end_to_end,
#   timeout_file_appears_in_tested_files, stale_red_marker_exit_zero,
#   stale_red_marker_partial_pass, red_tolerance_preserved_when_all_red_fail

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
# test_marker_not_found_falls_back_to_blocking
# When [marker_name] in .test-index does not match any function
# in the test file, record-test-status.sh warns to stderr and
# exits 1 (blocking, not silent tolerance).
# RED: feature not implemented; unknown markers are ignored →
# failing tests block as normal (exit 1), but no warning about
# unrecognized marker is emitted.
# ============================================================
echo ""
echo "=== test_marker_not_found_falls_back_to_blocking ==="
_snapshot_fail

TEST_REPO_NOMATCH=$(create_test_repo)
ARTIFACTS_NOMATCH=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_NOMATCH" "$ARTIFACTS_NOMATCH"' EXIT

mkdir -p "$TEST_REPO_NOMATCH/src" "$TEST_REPO_NOMATCH/tests"
cat > "$TEST_REPO_NOMATCH/src/nomatch.py" << 'PYEOF'
def nomatch():
    return "nomatch"
PYEOF

cat > "$TEST_REPO_NOMATCH/tests/test_nomatch.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_existing_function: FAIL (no marker match)"
exit 1
SHEOF
chmod +x "$TEST_REPO_NOMATCH/tests/test_nomatch.sh"

# .test-index entry with [nonexistent_marker] that won't match any test function
cat > "$TEST_REPO_NOMATCH/.test-index" << 'IDXEOF'
src/nomatch.py: tests/test_nomatch.sh [nonexistent_marker_xyz]
IDXEOF

git -C "$TEST_REPO_NOMATCH" add -A
git -C "$TEST_REPO_NOMATCH" commit -m "add nomatch with unknown marker" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_NOMATCH/src/nomatch.py"
git -C "$TEST_REPO_NOMATCH" add -A

MOCK_NOMATCH_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-nomatch-runner-XXXXXX")
chmod +x "$MOCK_NOMATCH_RUNNER"
cat > "$MOCK_NOMATCH_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_existing_function: FAIL"
exit 1
MOCKEOF

OUTPUT_NOMATCH=$(
    cd "$TEST_REPO_NOMATCH"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_NOMATCH" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_NOMATCH_RUNNER" \
    bash "$HOOK" 2>&1 || true
)
EXIT_CODE_NOMATCH=$(
    cd "$TEST_REPO_NOMATCH"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_NOMATCH" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_NOMATCH_RUNNER" \
    run_hook_exit
)

# EXPECTED (after implementation): unrecognized marker → warn on stderr, exit 1 (blocking).
# Part 1: exit code must be 1 (blocking — this will pass even pre-implementation)
assert_eq "test_marker_not_found_falls_back_to_blocking: exits 1 (unrecognized marker blocks)" "1" "$EXIT_CODE_NOMATCH"
# Part 2: stderr must warn about unrecognized marker — this is the RED assertion.
# Pre-implementation: no warning about marker name is emitted.
assert_contains "test_marker_not_found_falls_back_to_blocking: warns about unrecognized marker" "nonexistent_marker_xyz" "$OUTPUT_NOMATCH"

rm -f "$MOCK_NOMATCH_RUNNER"
rm -rf "$TEST_REPO_NOMATCH" "$ARTIFACTS_NOMATCH"
trap - EXIT
assert_pass_if_clean "test_marker_not_found_falls_back_to_blocking"

# ============================================================
# test_red_zone_bash_test_file
# RED marker detection works for bash test files
# (function/marker patterns), not only Python.
# .test-index: source.sh: tests/test_source.sh [test_red_fn]
# The bash test file has test_red_fn as a function boundary.
# Failures after/at test_red_fn are tolerated; others block.
# RED: feature not implemented; bash test markers ignored.
# ============================================================
echo ""
echo "=== test_red_zone_bash_test_file ==="
_snapshot_fail

TEST_REPO_BASH_RED=$(create_test_repo)
ARTIFACTS_BASH_RED=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_BASH_RED" "$ARTIFACTS_BASH_RED"' EXIT

mkdir -p "$TEST_REPO_BASH_RED/scripts" "$TEST_REPO_BASH_RED/tests"
cat > "$TEST_REPO_BASH_RED/scripts/deploy.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "deploying"
SHEOF
chmod +x "$TEST_REPO_BASH_RED/scripts/deploy.sh"

# Bash test file that has test_red_fn as a named function boundary
cat > "$TEST_REPO_BASH_RED/tests/test-deploy.sh" << 'SHEOF'
#!/usr/bin/env bash
# test_pre_deploy_check: runs before marker
echo "test_pre_deploy_check: PASS"
# test_red_fn: this is the RED zone marker function
test_red_fn() {
    echo "test_red_fn: FAIL (intentional RED zone in bash)"
    return 1
}
test_red_fn || true
exit 1
SHEOF
chmod +x "$TEST_REPO_BASH_RED/tests/test-deploy.sh"

# .test-index maps deploy.sh → test-deploy.sh with [test_red_fn] marker
cat > "$TEST_REPO_BASH_RED/.test-index" << 'IDXEOF'
scripts/deploy.sh: tests/test-deploy.sh [test_red_fn]
IDXEOF

git -C "$TEST_REPO_BASH_RED" add -A
git -C "$TEST_REPO_BASH_RED" commit -m "add deploy with bash RED marker" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_BASH_RED/scripts/deploy.sh"
git -C "$TEST_REPO_BASH_RED" add -A

# Mock runner that simulates test failure in the RED zone (after bash marker)
MOCK_BASH_RED_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-bash-red-runner-XXXXXX")
chmod +x "$MOCK_BASH_RED_RUNNER"
cat > "$MOCK_BASH_RED_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
# Simulate: test_pre_deploy_check passes, then test_red_fn fails (RED zone)
echo "test_pre_deploy_check: PASS"
echo "test_red_fn: FAIL (RED zone)"
exit 1
MOCKEOF

EXIT_CODE_BASH_RED=$(
    cd "$TEST_REPO_BASH_RED"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_BASH_RED" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_BASH_RED_RUNNER" \
    run_hook_exit
)

STATUS_FILE_BASH_RED="$ARTIFACTS_BASH_RED/test-gate-status"

# EXPECTED (after implementation): failure is in RED zone (at/after bash marker) →
# tolerated → exits 0, writes 'passed'.
# RED phase: hook ignores markers → exits 1 (blocking), writes 'failed'.
assert_eq "test_red_zone_bash_test_file: exits 0 (bash RED zone tolerated)" "0" "$EXIT_CODE_BASH_RED"
if [[ -f "$STATUS_FILE_BASH_RED" ]]; then
    FIRST_LINE_BASH_RED=$(head -1 "$STATUS_FILE_BASH_RED")
    assert_eq "test_red_zone_bash_test_file: writes passed" "passed" "$FIRST_LINE_BASH_RED"
else
    assert_eq "test_red_zone_bash_test_file: status file exists" "exists" "missing"
fi

rm -f "$MOCK_BASH_RED_RUNNER"
rm -rf "$TEST_REPO_BASH_RED" "$ARTIFACTS_BASH_RED"
trap - EXIT
assert_pass_if_clean "test_red_zone_bash_test_file"

# ============================================================
# test_hyphenated_test_name_red_zone
# Verifies that hyphenated test names (e.g. 'test-foo') work
# correctly with RED zone logic. The word-boundary pattern must
# treat '-' as an identifier character so that:
#   - Searching for 'test-foo' finds the correct line
#   - Searching for 'test' does NOT match 'test-foo'
# ============================================================
echo ""
echo "=== test_hyphenated_test_name_red_zone ==="
_snapshot_fail

TEST_REPO_HYPH=$(create_test_repo)
ARTIFACTS_HYPH=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_HYPH" "$ARTIFACTS_HYPH"' EXIT

mkdir -p "$TEST_REPO_HYPH/src" "$TEST_REPO_HYPH/tests"
cat > "$TEST_REPO_HYPH/src/hyph.py" << 'PYEOF'
def hyph():
    return "hyph"
PYEOF

# Test file: test-pre-check passes (BEFORE the RED marker),
# test-red-zone is the RED marker function, test-red-zone fails (in RED zone — tolerated).
cat > "$TEST_REPO_HYPH/tests/test-hyph.sh" << 'SHEOF'
#!/usr/bin/env bash
# test-pre-check: runs before RED marker, must not be confused with test-red-zone
echo "test-pre-check: PASS"
# test-red-zone: this is the RED zone marker
test-red-zone() {
    echo "test-red-zone: FAIL (RED zone)"
    return 1
}
test-red-zone || true
exit 1
SHEOF
chmod +x "$TEST_REPO_HYPH/tests/test-hyph.sh"

# .test-index maps hyph.py -> test-hyph.sh with [test-red-zone] RED marker
cat > "$TEST_REPO_HYPH/.test-index" << 'IDXEOF'
src/hyph.py: tests/test-hyph.sh [test-red-zone]
IDXEOF

git -C "$TEST_REPO_HYPH" add -A
git -C "$TEST_REPO_HYPH" commit -m "add hyph with hyphenated RED marker" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_HYPH/src/hyph.py"
git -C "$TEST_REPO_HYPH" add -A

# Mock runner: test-pre-check passes, test-red-zone fails (RED zone failure)
MOCK_HYPH_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-hyph-runner-XXXXXX")
chmod +x "$MOCK_HYPH_RUNNER"
cat > "$MOCK_HYPH_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
# Simulate: test-pre-check passes, then test-red-zone fails (RED zone)
echo "test-pre-check: PASS"
echo "test-red-zone: FAIL (RED zone)"
exit 1
MOCKEOF

EXIT_CODE_HYPH=$(
    cd "$TEST_REPO_HYPH"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_HYPH" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_HYPH_RUNNER" \
    run_hook_exit
)

STATUS_FILE_HYPH="$ARTIFACTS_HYPH/test-gate-status"

# EXPECTED: failure is in RED zone (at/after hyphenated marker test-red-zone) →
# tolerated → exits 0, writes 'passed'.
# Word-boundary fix required: [^a-zA-Z0-9_-] must treat '-' as identifier char
# so 'test-red-zone' marker locates the correct line and 'test-pre-check' (before marker)
# is not confused with 'test-red-zone'.
assert_eq "test_hyphenated_test_name_red_zone: exits 0 (hyphenated RED zone tolerated)" "0" "$EXIT_CODE_HYPH"
if [[ -f "$STATUS_FILE_HYPH" ]]; then
    FIRST_LINE_HYPH=$(head -1 "$STATUS_FILE_HYPH")
    assert_eq "test_hyphenated_test_name_red_zone: writes passed" "passed" "$FIRST_LINE_HYPH"
else
    assert_eq "test_hyphenated_test_name_red_zone: status file exists" "exists" "missing"
fi

rm -f "$MOCK_HYPH_RUNNER"
rm -rf "$TEST_REPO_HYPH" "$ARTIFACTS_HYPH"
trap - EXIT
assert_pass_if_clean "test_hyphenated_test_name_red_zone"

# ============================================================
# test_integration_red_marker_end_to_end
# End-to-end integration test for the RED marker commit flow.
# Exercises the full stack: .test-index parsing, RED zone line
# detection, test runner execution, and test-gate-status writing.
#
# Scenario A: GREEN tests pass before marker, RED tests fail
#   after marker — record-test-status.sh exits 0, writes 'passed'.
# Scenario B: A GREEN test BEFORE the marker fails — exits 1,
#   writes 'failed'.
#
# This test is exempt from TDD RED-first order per the Integration
# Test Task Rule (criterion 1): the external boundary (test runner
# execution + file system) is already established by existing tests.
# ============================================================
echo ""
echo "=== test_integration_red_marker_end_to_end ==="
_snapshot_fail

# ── Scenario A: RED zone failures tolerated ──────────────────

TEST_REPO_ITEG_A=$(create_test_repo)
ARTIFACTS_ITEG_A=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_ITEG_A" "$ARTIFACTS_ITEG_A"' EXIT

mkdir -p "$TEST_REPO_ITEG_A/src" "$TEST_REPO_ITEG_A/tests"

# Source file under test
cat > "$TEST_REPO_ITEG_A/src/feature.py" << 'PYEOF'
def feature():
    return "feature"
PYEOF

# Bash test file: GREEN tests before marker pass, RED tests at/after marker fail
cat > "$TEST_REPO_ITEG_A/tests/test-feature.sh" << 'SHEOF'
#!/usr/bin/env bash
# test_green_before_marker: passing test BEFORE the RED zone
echo "test_green_before_marker: PASS"
# test_red_start: first test in RED zone (the marker)
test_red_start() {
    echo "test_red_start: FAIL (intentional RED zone failure)"
    return 1
}
test_red_start || true
exit 1
SHEOF
chmod +x "$TEST_REPO_ITEG_A/tests/test-feature.sh"

# .test-index maps feature.py -> test-feature.sh with [test_red_start] RED marker
cat > "$TEST_REPO_ITEG_A/.test-index" << 'IDXEOF'
src/feature.py: tests/test-feature.sh [test_red_start]
IDXEOF

git -C "$TEST_REPO_ITEG_A" add -A
git -C "$TEST_REPO_ITEG_A" commit -m "add feature with RED marker" --quiet 2>/dev/null

# Stage a change to the source file
echo "# changed" >> "$TEST_REPO_ITEG_A/src/feature.py"
git -C "$TEST_REPO_ITEG_A" add -A

# Run record-test-status.sh (no mock runner — full integration)
EXIT_CODE_ITEG_A=$(
    cd "$TEST_REPO_ITEG_A"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_ITEG_A" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    run_hook_exit
)

STATUS_FILE_ITEG_A="$ARTIFACTS_ITEG_A/test-gate-status"

# EXPECTED: RED zone failure tolerated → exits 0, writes 'passed'
assert_eq "test_integration_red_marker_end_to_end (scenario A): exits 0" "0" "$EXIT_CODE_ITEG_A"
if [[ -f "$STATUS_FILE_ITEG_A" ]]; then
    FIRST_LINE_ITEG_A=$(head -1 "$STATUS_FILE_ITEG_A")
    assert_eq "test_integration_red_marker_end_to_end (scenario A): writes passed" "passed" "$FIRST_LINE_ITEG_A"
else
    assert_eq "test_integration_red_marker_end_to_end (scenario A): status file exists" "exists" "missing"
fi

rm -rf "$TEST_REPO_ITEG_A" "$ARTIFACTS_ITEG_A"
trap - EXIT

# ── Scenario B: GREEN failure before marker blocks commit ────

TEST_REPO_ITEG_B=$(create_test_repo)
ARTIFACTS_ITEG_B=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_ITEG_B" "$ARTIFACTS_ITEG_B"' EXIT

mkdir -p "$TEST_REPO_ITEG_B/src" "$TEST_REPO_ITEG_B/tests"

# Source file under test
cat > "$TEST_REPO_ITEG_B/src/feature2.py" << 'PYEOF'
def feature2():
    return "feature2"
PYEOF

# Bash test file: GREEN test BEFORE the marker fails (blocking)
cat > "$TEST_REPO_ITEG_B/tests/test-feature2.sh" << 'SHEOF'
#!/usr/bin/env bash
# test_green_fails_before_marker: GREEN test that fails — BEFORE the RED zone
echo "test_green_fails_before_marker: FAIL (pre-marker failure)"
# test_red_start2: the RED zone marker (never reached due to earlier failure)
test_red_start2() {
    echo "test_red_start2: PASS"
}
exit 1
SHEOF
chmod +x "$TEST_REPO_ITEG_B/tests/test-feature2.sh"

# .test-index maps feature2.py -> test-feature2.sh with [test_red_start2] RED marker
cat > "$TEST_REPO_ITEG_B/.test-index" << 'IDXEOF'
src/feature2.py: tests/test-feature2.sh [test_red_start2]
IDXEOF

git -C "$TEST_REPO_ITEG_B" add -A
git -C "$TEST_REPO_ITEG_B" commit -m "add feature2 with RED marker (GREEN fails)" --quiet 2>/dev/null

# Stage a change to the source file
echo "# changed" >> "$TEST_REPO_ITEG_B/src/feature2.py"
git -C "$TEST_REPO_ITEG_B" add -A

# Run record-test-status.sh (no mock runner — full integration)
EXIT_CODE_ITEG_B=$(
    cd "$TEST_REPO_ITEG_B"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_ITEG_B" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    run_hook_exit
)

STATUS_FILE_ITEG_B="$ARTIFACTS_ITEG_B/test-gate-status"

# EXPECTED: pre-marker failure blocks → exits 1, writes 'failed'
assert_eq "test_integration_red_marker_end_to_end (scenario B): exits 1" "1" "$EXIT_CODE_ITEG_B"
if [[ -f "$STATUS_FILE_ITEG_B" ]]; then
    FIRST_LINE_ITEG_B=$(head -1 "$STATUS_FILE_ITEG_B")
    assert_eq "test_integration_red_marker_end_to_end (scenario B): writes failed" "failed" "$FIRST_LINE_ITEG_B"
else
    assert_eq "test_integration_red_marker_end_to_end (scenario B): status file exists" "exists" "missing"
fi

rm -rf "$TEST_REPO_ITEG_B" "$ARTIFACTS_ITEG_B"
trap - EXIT
assert_pass_if_clean "test_integration_red_marker_end_to_end"

# Clean up mock runners if created
if (( ! _PYTEST_AVAILABLE )); then
    rm -f "$_MOCK_PASS_RUNNER" "$_MOCK_FAIL_RUNNER" 2>/dev/null || true
fi

# ============================================================
# test_timeout_file_appears_in_tested_files
# When a test runner exits 144 (SIGURG timeout), the timed-out
# test file is still recorded in the tested_files field of
# test-gate-status. This verifies that TESTED_FILES_LIST is
# appended BEFORE the test runs (intentional ordering), so
# even tests that never complete are reflected in the audit
# record for observability.
# ============================================================
echo ""
echo "=== test_timeout_file_appears_in_tested_files ==="

TEST_REPO_TIMEOUT=$(create_test_repo)
ARTIFACTS_TIMEOUT=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_TIMEOUT" "$ARTIFACTS_TIMEOUT"' EXIT

mkdir -p "$TEST_REPO_TIMEOUT/src" "$TEST_REPO_TIMEOUT/tests"
cat > "$TEST_REPO_TIMEOUT/src/slow.py" << 'PYEOF'
def slow():
    pass
PYEOF
cat > "$TEST_REPO_TIMEOUT/tests/test_slow.py" << 'PYEOF'
def test_slow():
    assert True
PYEOF
git -C "$TEST_REPO_TIMEOUT" add -A
git -C "$TEST_REPO_TIMEOUT" commit -m "add slow" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_TIMEOUT/src/slow.py"
git -C "$TEST_REPO_TIMEOUT" add -A

MOCK_TIMEOUT_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-timeout-runner-XXXXXX")
chmod +x "$MOCK_TIMEOUT_RUNNER"
cat > "$MOCK_TIMEOUT_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
exit 144
MOCKEOF

(
    cd "$TEST_REPO_TIMEOUT"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_TIMEOUT" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_TIMEOUT_RUNNER" \
    bash "$HOOK" 2>/dev/null || true
)

STATUS_FILE_TIMEOUT="$ARTIFACTS_TIMEOUT/test-gate-status"
if [[ -f "$STATUS_FILE_TIMEOUT" ]]; then
    TESTED_LINE_TIMEOUT=$(grep '^tested_files=' "$STATUS_FILE_TIMEOUT" | head -1 | cut -d= -f2)
    assert_contains "test_timeout_file_appears_in_tested_files: timed-out file in tested_files" "test_slow.py" "$TESTED_LINE_TIMEOUT"
    FIRST_LINE_TIMEOUT=$(head -1 "$STATUS_FILE_TIMEOUT")
    assert_eq "test_timeout_file_appears_in_tested_files: status is timeout" "timeout" "$FIRST_LINE_TIMEOUT"
else
    assert_eq "test_timeout_file_appears_in_tested_files: status file exists" "exists" "missing"
fi

rm -f "$MOCK_TIMEOUT_RUNNER"
rm -rf "$TEST_REPO_TIMEOUT" "$ARTIFACTS_TIMEOUT"
trap - EXIT

# ============================================================
# test_stale_red_marker_exit_zero
# When a test file has a RED marker but exits 0 (all tests pass),
# the marker is stale — record-test-status.sh must record "failed"
# with a STALE RED MARKER message.
# ============================================================
echo ""
echo "=== test_stale_red_marker_exit_zero ==="
_snapshot_fail

TEST_REPO_STALE0=$(create_test_repo)
ARTIFACTS_STALE0=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_STALE0" "$ARTIFACTS_STALE0"' EXIT

mkdir -p "$TEST_REPO_STALE0/src" "$TEST_REPO_STALE0/tests"
cat > "$TEST_REPO_STALE0/src/feature.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "feature"
SHEOF
chmod +x "$TEST_REPO_STALE0/src/feature.sh"

cat > "$TEST_REPO_STALE0/tests/test-feature.sh" << 'SHEOF'
#!/usr/bin/env bash
test_green() { echo "test_green: PASS"; }
test_was_red() { echo "test_was_red: PASS"; }
test_green
test_was_red
SHEOF
chmod +x "$TEST_REPO_STALE0/tests/test-feature.sh"

# .test-index with RED marker — but the test now passes (stale marker)
cat > "$TEST_REPO_STALE0/.test-index" << 'IDXEOF'
src/feature.sh: tests/test-feature.sh [test_was_red]
IDXEOF

git -C "$TEST_REPO_STALE0" add -A
git -C "$TEST_REPO_STALE0" commit -m "add feature with stale red marker" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_STALE0/src/feature.sh"
git -C "$TEST_REPO_STALE0" add -A

# Mock runner that exits 0 (all tests pass — including the "RED" test)
MOCK_STALE0_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-stale0-runner-XXXXXX")
chmod +x "$MOCK_STALE0_RUNNER"
cat > "$MOCK_STALE0_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_green: PASS"
echo "test_was_red: PASS"
exit 0
MOCKEOF

HOOK_OUTPUT_STALE0=$(mktemp "${TMPDIR:-/tmp}/test-rts-stale0-output-XXXXXX")
EXIT_CODE_STALE0=$(
    cd "$TEST_REPO_STALE0"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_STALE0" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_STALE0_RUNNER" \
    bash "$HOOK" 2>"$HOOK_OUTPUT_STALE0" || echo $?
)
EXIT_CODE_STALE0="${EXIT_CODE_STALE0:-0}"

STATUS_FILE_STALE0="$ARTIFACTS_STALE0/test-gate-status"

# EXPECTED: exit non-zero, status=failed, stderr contains STALE RED MARKER
assert_eq "test_stale_red_marker_exit_zero: exits non-zero" "1" "$EXIT_CODE_STALE0"

if [[ -f "$STATUS_FILE_STALE0" ]]; then
    FIRST_LINE_STALE0=$(head -1 "$STATUS_FILE_STALE0")
    assert_eq "test_stale_red_marker_exit_zero: status is failed" "failed" "$FIRST_LINE_STALE0"
else
    assert_eq "test_stale_red_marker_exit_zero: status file exists" "exists" "missing"
fi

assert_contains "test_stale_red_marker_exit_zero: stderr has STALE RED MARKER" "STALE RED MARKER" "$(cat "$HOOK_OUTPUT_STALE0")"

rm -f "$MOCK_STALE0_RUNNER" "$HOOK_OUTPUT_STALE0"
rm -rf "$TEST_REPO_STALE0" "$ARTIFACTS_STALE0"
trap - EXIT
assert_pass_if_clean "test_stale_red_marker_exit_zero"

# ============================================================
# test_stale_red_marker_partial_pass
# When a test file exits non-zero (some tests fail) but a RED-zone
# test passes, that RED test is stale. record-test-status.sh must
# detect the passing RED-zone test and record "failed".
# ============================================================
echo ""
echo "=== test_stale_red_marker_partial_pass ==="
_snapshot_fail

TEST_REPO_STALEP=$(create_test_repo)
ARTIFACTS_STALEP=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_STALEP" "$ARTIFACTS_STALEP"' EXIT

mkdir -p "$TEST_REPO_STALEP/src" "$TEST_REPO_STALEP/tests"
cat > "$TEST_REPO_STALEP/src/widget.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "widget"
SHEOF
chmod +x "$TEST_REPO_STALEP/src/widget.sh"

# Test file: test_green passes, test_red_a passes (stale!), test_red_b fails (still RED)
cat > "$TEST_REPO_STALEP/tests/test-widget.sh" << 'SHEOF'
#!/usr/bin/env bash
test_green() { echo "test_green: PASS"; }
test_red_a() { echo "test_red_a: PASS"; }
test_red_b() { echo "test_red_b: FAIL"; exit 1; }
test_green
test_red_a
test_red_b
SHEOF
chmod +x "$TEST_REPO_STALEP/tests/test-widget.sh"

# RED marker at test_red_a — both test_red_a and test_red_b are in RED zone
cat > "$TEST_REPO_STALEP/.test-index" << 'IDXEOF'
src/widget.sh: tests/test-widget.sh [test_red_a]
IDXEOF

git -C "$TEST_REPO_STALEP" add -A
git -C "$TEST_REPO_STALEP" commit -m "add widget with partial stale red" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_STALEP/src/widget.sh"
git -C "$TEST_REPO_STALEP" add -A

# Mock runner: exits non-zero, test_red_b fails (RED zone), but test_red_a passes (stale!)
MOCK_STALEP_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-stalep-runner-XXXXXX")
chmod +x "$MOCK_STALEP_RUNNER"
cat > "$MOCK_STALEP_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_green: PASS"
echo "test_red_a: PASS"
echo "test_red_b: FAIL"
exit 1
MOCKEOF

HOOK_OUTPUT_STALEP=$(mktemp "${TMPDIR:-/tmp}/test-rts-stalep-output-XXXXXX")
EXIT_CODE_STALEP=$(
    cd "$TEST_REPO_STALEP"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_STALEP" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_STALEP_RUNNER" \
    bash "$HOOK" 2>"$HOOK_OUTPUT_STALEP" || echo $?
)
EXIT_CODE_STALEP="${EXIT_CODE_STALEP:-0}"

STATUS_FILE_STALEP="$ARTIFACTS_STALEP/test-gate-status"

# EXPECTED: exit non-zero, status=failed, stderr mentions stale RED marker for test_red_a
assert_eq "test_stale_red_marker_partial_pass: exits non-zero" "1" "$EXIT_CODE_STALEP"

if [[ -f "$STATUS_FILE_STALEP" ]]; then
    FIRST_LINE_STALEP=$(head -1 "$STATUS_FILE_STALEP")
    assert_eq "test_stale_red_marker_partial_pass: status is failed" "failed" "$FIRST_LINE_STALEP"
else
    assert_eq "test_stale_red_marker_partial_pass: status file exists" "exists" "missing"
fi

assert_contains "test_stale_red_marker_partial_pass: stderr has STALE RED MARKER" "STALE RED MARKER" "$(cat "$HOOK_OUTPUT_STALEP")"
assert_contains "test_stale_red_marker_partial_pass: stderr names test_red_a" "test_red_a" "$(cat "$HOOK_OUTPUT_STALEP")"

rm -f "$MOCK_STALEP_RUNNER" "$HOOK_OUTPUT_STALEP"
rm -rf "$TEST_REPO_STALEP" "$ARTIFACTS_STALEP"
trap - EXIT
assert_pass_if_clean "test_stale_red_marker_partial_pass"

# ============================================================
# test_red_tolerance_preserved_when_all_red_fail
# When a test file exits non-zero and ALL RED-zone tests fail
# (none pass), existing tolerance must be preserved — status
# should be "passed" (failures tolerated).
# ============================================================
echo ""
echo "=== test_red_tolerance_preserved_when_all_red_fail ==="
_snapshot_fail

TEST_REPO_TOLERATE=$(create_test_repo)
ARTIFACTS_TOLERATE=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_TOLERATE" "$ARTIFACTS_TOLERATE"' EXIT

mkdir -p "$TEST_REPO_TOLERATE/src" "$TEST_REPO_TOLERATE/tests"
cat > "$TEST_REPO_TOLERATE/src/gadget.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "gadget"
SHEOF
chmod +x "$TEST_REPO_TOLERATE/src/gadget.sh"

cat > "$TEST_REPO_TOLERATE/tests/test-gadget.sh" << 'SHEOF'
#!/usr/bin/env bash
test_green() { echo "test_green: PASS"; }
test_red_x() { echo "test_red_x: FAIL"; exit 1; }
test_green
test_red_x
SHEOF
chmod +x "$TEST_REPO_TOLERATE/tests/test-gadget.sh"

cat > "$TEST_REPO_TOLERATE/.test-index" << 'IDXEOF'
src/gadget.sh: tests/test-gadget.sh [test_red_x]
IDXEOF

git -C "$TEST_REPO_TOLERATE" add -A
git -C "$TEST_REPO_TOLERATE" commit -m "add gadget with valid red marker" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_TOLERATE/src/gadget.sh"
git -C "$TEST_REPO_TOLERATE" add -A

# Mock runner: exits non-zero, only RED-zone test fails (expected behavior)
MOCK_TOLERATE_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-tolerate-runner-XXXXXX")
chmod +x "$MOCK_TOLERATE_RUNNER"
cat > "$MOCK_TOLERATE_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_green: PASS"
echo "test_red_x: FAIL"
exit 1
MOCKEOF

EXIT_CODE_TOLERATE=$(
    cd "$TEST_REPO_TOLERATE"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_TOLERATE" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_TOLERATE_RUNNER" \
    run_hook_exit
)

STATUS_FILE_TOLERATE="$ARTIFACTS_TOLERATE/test-gate-status"

# EXPECTED: exit 0, status=passed (RED zone failure tolerated, no stale passing tests)
assert_eq "test_red_tolerance_preserved_when_all_red_fail: exits 0" "0" "$EXIT_CODE_TOLERATE"

if [[ -f "$STATUS_FILE_TOLERATE" ]]; then
    FIRST_LINE_TOLERATE=$(head -1 "$STATUS_FILE_TOLERATE")
    assert_eq "test_red_tolerance_preserved_when_all_red_fail: status is passed" "passed" "$FIRST_LINE_TOLERATE"
else
    assert_eq "test_red_tolerance_preserved_when_all_red_fail: status file exists" "exists" "missing"
fi

rm -f "$MOCK_TOLERATE_RUNNER"
rm -rf "$TEST_REPO_TOLERATE" "$ARTIFACTS_TOLERATE"
trap - EXIT
assert_pass_if_clean "test_red_tolerance_preserved_when_all_red_fail"

print_summary
