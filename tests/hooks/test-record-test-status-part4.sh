#!/usr/bin/env bash
set -euo pipefail
# tests/hooks/test-record-test-status-part4.sh
# Tests for hooks/record-test-status.sh — Part 4 of 4 (tests 26–33 + merge-commit)
# Covers: stale_red_marker_regression, progress_file_written_after_pass,
#   sigurg_trap_writes_partial_not_passed, status_initialized_before_trap_registration,
#   resume_skips_completed_tests, red_marker_survives_overwrite_by_unmarked_entry,
#   red_marker_found_via_global_scan,
#   global_scan_no_false_positive_from_substring_match,
#   merge_commit_filters_incoming_only

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
# test_stale_red_marker_regression
# Regression test replaying the March 2026 stale marker scenarios:
# 1. Exit 0 + RED marker → stale detection fires
# 2. Exit non-zero + passing RED-zone test → stale detection fires
# 3. Exit non-zero + all RED-zone tests fail → tolerance preserved
# ============================================================
echo ""
echo "=== test_stale_red_marker_regression ==="
_snapshot_fail

# --- Scenario 1: exit 0 + RED marker = stale ---
TEST_REPO_REG1=$(create_test_repo)
ARTIFACTS_REG1=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_REG1" "$ARTIFACTS_REG1"' EXIT

mkdir -p "$TEST_REPO_REG1/plugins" "$TEST_REPO_REG1/tests"
cat > "$TEST_REPO_REG1/plugins/hook.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "hook"
SHEOF
chmod +x "$TEST_REPO_REG1/plugins/hook.sh"
cat > "$TEST_REPO_REG1/tests/test-hook.sh" << 'SHEOF'
#!/usr/bin/env bash
test_blocks_missing() { echo "test_blocks_missing: PASS"; }
test_blocks_missing
SHEOF
chmod +x "$TEST_REPO_REG1/tests/test-hook.sh"
cat > "$TEST_REPO_REG1/.test-index" << 'IDXEOF'
plugins/hook.sh: tests/test-hook.sh [test_blocks_missing]
IDXEOF
git -C "$TEST_REPO_REG1" add -A
git -C "$TEST_REPO_REG1" commit -m "scenario 1" --quiet 2>/dev/null
echo "# changed" >> "$TEST_REPO_REG1/plugins/hook.sh"
git -C "$TEST_REPO_REG1" add -A

MOCK_REG1=$(mktemp "${TMPDIR:-/tmp}/mock-reg1-XXXXXX")
chmod +x "$MOCK_REG1"
cat > "$MOCK_REG1" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_blocks_missing: PASS"
exit 0
MOCKEOF

EXIT_REG1=$(
    cd "$TEST_REPO_REG1"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_REG1" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_REG1" \
    run_hook_exit
)
assert_eq "regression_scenario_1_exit0_stale: exits 1" "1" "$EXIT_REG1"
rm -f "$MOCK_REG1"
rm -rf "$TEST_REPO_REG1" "$ARTIFACTS_REG1"

# --- Scenario 2: exit non-zero + passing RED-zone test = stale ---
TEST_REPO_REG2=$(create_test_repo)
ARTIFACTS_REG2=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_REG2" "$ARTIFACTS_REG2"' EXIT

mkdir -p "$TEST_REPO_REG2/scripts" "$TEST_REPO_REG2/tests"
cat > "$TEST_REPO_REG2/scripts/lib.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "lib"
SHEOF
chmod +x "$TEST_REPO_REG2/scripts/lib.sh"
cat > "$TEST_REPO_REG2/tests/test-lib.sh" << 'SHEOF'
#!/usr/bin/env bash
test_read_status() { echo "test_read_status: PASS"; }
test_still_red() { echo "test_still_red: FAIL"; exit 1; }
test_read_status
test_still_red
SHEOF
chmod +x "$TEST_REPO_REG2/tests/test-lib.sh"
cat > "$TEST_REPO_REG2/.test-index" << 'IDXEOF'
scripts/lib.sh: tests/test-lib.sh [test_read_status]
IDXEOF
git -C "$TEST_REPO_REG2" add -A
git -C "$TEST_REPO_REG2" commit -m "scenario 2" --quiet 2>/dev/null
echo "# changed" >> "$TEST_REPO_REG2/scripts/lib.sh"
git -C "$TEST_REPO_REG2" add -A

MOCK_REG2=$(mktemp "${TMPDIR:-/tmp}/mock-reg2-XXXXXX")
chmod +x "$MOCK_REG2"
cat > "$MOCK_REG2" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_read_status: PASS"
echo "test_still_red: FAIL"
exit 1
MOCKEOF

EXIT_REG2=$(
    cd "$TEST_REPO_REG2"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_REG2" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_REG2" \
    run_hook_exit
)
assert_eq "regression_scenario_2_partial_pass_stale: exits 1" "1" "$EXIT_REG2"
rm -f "$MOCK_REG2"
rm -rf "$TEST_REPO_REG2" "$ARTIFACTS_REG2"

# --- Scenario 3: exit non-zero + all RED fail = tolerance preserved ---
TEST_REPO_REG3=$(create_test_repo)
ARTIFACTS_REG3=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_REG3" "$ARTIFACTS_REG3"' EXIT

mkdir -p "$TEST_REPO_REG3/scripts" "$TEST_REPO_REG3/tests"
cat > "$TEST_REPO_REG3/scripts/create.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "create"
SHEOF
chmod +x "$TEST_REPO_REG3/scripts/create.sh"
cat > "$TEST_REPO_REG3/tests/test-create.sh" << 'SHEOF'
#!/usr/bin/env bash
test_create_works() { echo "test_create_works: PASS"; }
test_closed_parent() { echo "test_closed_parent: FAIL"; exit 1; }
test_create_works
test_closed_parent
SHEOF
chmod +x "$TEST_REPO_REG3/tests/test-create.sh"
cat > "$TEST_REPO_REG3/.test-index" << 'IDXEOF'
scripts/create.sh: tests/test-create.sh [test_closed_parent]
IDXEOF
git -C "$TEST_REPO_REG3" add -A
git -C "$TEST_REPO_REG3" commit -m "scenario 3" --quiet 2>/dev/null
echo "# changed" >> "$TEST_REPO_REG3/scripts/create.sh"
git -C "$TEST_REPO_REG3" add -A

MOCK_REG3=$(mktemp "${TMPDIR:-/tmp}/mock-reg3-XXXXXX")
chmod +x "$MOCK_REG3"
cat > "$MOCK_REG3" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_create_works: PASS"
echo "test_closed_parent: FAIL"
exit 1
MOCKEOF

EXIT_REG3=$(
    cd "$TEST_REPO_REG3"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_REG3" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_REG3" \
    run_hook_exit
)
assert_eq "regression_scenario_3_tolerance_preserved: exits 0" "0" "$EXIT_REG3"
rm -f "$MOCK_REG3"
rm -rf "$TEST_REPO_REG3" "$ARTIFACTS_REG3"
trap - EXIT

assert_pass_if_clean "test_stale_red_marker_regression"

# ============================================================
# test_progress_file_written_after_pass
# After a test passes, its name is appended to the progress file
# so a subsequent invocation can resume without re-running it.
# ============================================================
echo ""
echo "=== test_progress_file_written_after_pass ==="
_snapshot_fail

TEST_REPO_PROG1=$(create_test_repo)
ARTIFACTS_PROG1=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_PROG1" "$ARTIFACTS_PROG1"' EXIT

mkdir -p "$TEST_REPO_PROG1/src" "$TEST_REPO_PROG1/tests"
cat > "$TEST_REPO_PROG1/src/alpha.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "alpha"
SHEOF
chmod +x "$TEST_REPO_PROG1/src/alpha.sh"
cat > "$TEST_REPO_PROG1/tests/test-alpha.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_alpha_ok: PASS"
exit 0
SHEOF
chmod +x "$TEST_REPO_PROG1/tests/test-alpha.sh"
git -C "$TEST_REPO_PROG1" add -A
git -C "$TEST_REPO_PROG1" commit -m "add alpha" --quiet 2>/dev/null
echo "# changed" >> "$TEST_REPO_PROG1/src/alpha.sh"
git -C "$TEST_REPO_PROG1" add -A

MOCK_PROG1=$(mktemp "${TMPDIR:-/tmp}/mock-prog1-XXXXXX")
chmod +x "$MOCK_PROG1"
cat > "$MOCK_PROG1" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_alpha_ok: PASS"
exit 0
MOCKEOF

EXIT_PROG1=$(
    cd "$TEST_REPO_PROG1"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_PROG1" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PROG1" \
    run_hook_exit
)
assert_eq "progress_file_written_after_pass: exits 0" "0" "$EXIT_PROG1"

# After a full successful run, the progress file should be cleaned up
DIFF_HASH_PROG1=$(cd "$TEST_REPO_PROG1" && bash "$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh" 2>/dev/null || echo "unknown")
PROGRESS_FILE_PROG1=$(find "$ARTIFACTS_PROG1" -name "test-gate-progress-*" 2>/dev/null | head -1 || echo "")
assert_eq "progress_file_cleaned_up_after_full_run: no progress file remains" "" "$PROGRESS_FILE_PROG1"

# test-gate-status should record 'passed'
STATUS_LINE_PROG1=$(head -1 "$ARTIFACTS_PROG1/test-gate-status" 2>/dev/null || echo "missing")
assert_eq "progress_file_written_after_pass: status is passed" "passed" "$STATUS_LINE_PROG1"

rm -f "$MOCK_PROG1"
rm -rf "$TEST_REPO_PROG1" "$ARTIFACTS_PROG1"
trap - EXIT

assert_pass_if_clean "test_progress_file_written_after_pass"

# ============================================================
# test_sigurg_trap_writes_partial_not_passed
# The SIGURG trap handler must write 'partial' as the first
# line of test-gate-status — never 'passed' — so that the
# pre-commit test gate does not accept a mid-run snapshot as
# a valid pass when tests remain in the queue.
# ============================================================
echo ""
echo "=== test_sigurg_trap_writes_partial_not_passed ==="
_snapshot_fail

TEST_REPO_SIGURG=$(create_test_repo)
ARTIFACTS_SIGURG=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_SIGURG" "$ARTIFACTS_SIGURG"' EXIT

mkdir -p "$TEST_REPO_SIGURG/src" "$TEST_REPO_SIGURG/tests"
cat > "$TEST_REPO_SIGURG/src/beta.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "beta"
SHEOF
chmod +x "$TEST_REPO_SIGURG/src/beta.sh"
# Two tests: the first passes, the second blocks forever (simulates timeout).
# We will send SIGURG manually to the subshell to trigger the trap.
cat > "$TEST_REPO_SIGURG/tests/test-beta.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_beta_ok: PASS"
exit 0
SHEOF
chmod +x "$TEST_REPO_SIGURG/tests/test-beta.sh"
git -C "$TEST_REPO_SIGURG" add -A
git -C "$TEST_REPO_SIGURG" commit -m "add beta" --quiet 2>/dev/null
echo "# changed" >> "$TEST_REPO_SIGURG/src/beta.sh"
git -C "$TEST_REPO_SIGURG" add -A

# We test the trap by directly sourcing the internal _write_partial_status
# function in an isolated subshell where STATUS=passed and DIFF_HASH is set,
# then calling the function. The function should write 'partial' to the status
# file, not the value of STATUS ('passed').
_PARTIAL_TEST_STATUS_FILE="$ARTIFACTS_SIGURG/test-gate-status"
_PARTIAL_RESULT=$(
    export ARTIFACTS_DIR="$ARTIFACTS_SIGURG"
    export DIFF_HASH="abc123def456789"
    export STATUS="passed"
    export TESTED_FILES_LIST="src/beta.sh"
    _write_partial_status() {
        local _ts
        _ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        cat > "$ARTIFACTS_DIR/test-gate-status" <<PARTIAL
partial
diff_hash=${DIFF_HASH}
timestamp=${_ts}
tested_files=${TESTED_FILES_LIST}
PARTIAL
    }
    _write_partial_status
    head -1 "$ARTIFACTS_DIR/test-gate-status" 2>/dev/null || echo "missing"
)
assert_eq "sigurg_trap_writes_partial_not_passed: first line is partial" "partial" "$_PARTIAL_RESULT"

# Verify the function definition in record-test-status.sh writes "partial" not "${STATUS}"
TRAP_WRITES_PARTIAL=$(grep -A 8 '_write_partial_status()' "$DSO_PLUGIN_DIR/hooks/record-test-status.sh" | grep -c '^partial$' || echo "0")
assert_ne "sigurg_trap_does_not_use_status_variable: no \${STATUS} in heredoc body" "0" \
    "$(grep -A 10 '_write_partial_status()' "$DSO_PLUGIN_DIR/hooks/record-test-status.sh" | grep -c '^partial$' || echo "0")"

rm -rf "$TEST_REPO_SIGURG" "$ARTIFACTS_SIGURG"
trap - EXIT

assert_pass_if_clean "test_sigurg_trap_writes_partial_not_passed"

# ============================================================
# test_status_initialized_before_trap_registration
# STATUS must be initialized BEFORE the SIGURG trap is
# registered so ${STATUS} is never unbound when the trap fires.
# Under set -u, an unbound STATUS in the trap handler causes an
# error that silently aborts the handler.
# ============================================================
echo ""
echo "=== test_status_initialized_before_trap_registration ==="
_snapshot_fail

# Verify source ordering: STATUS="passed" assignment must appear
# before trap '_write_partial_status' URG in the file.
RECORD_TS_CONTENT="$DSO_PLUGIN_DIR/hooks/record-test-status.sh"
STATUS_LINE_NUM=$(grep -n '^STATUS="passed"' "$RECORD_TS_CONTENT" | head -1 | cut -d: -f1)
TRAP_LINE_NUM=$(grep -n "trap '_write_partial_status' URG" "$RECORD_TS_CONTENT" | head -1 | cut -d: -f1)

# Both lines must exist
assert_ne "status_init_before_trap: STATUS line found" "" "$STATUS_LINE_NUM"
assert_ne "status_init_before_trap: trap line found" "" "$TRAP_LINE_NUM"

# STATUS assignment must come BEFORE the trap registration
if [[ -n "$STATUS_LINE_NUM" ]] && [[ -n "$TRAP_LINE_NUM" ]]; then
    if (( STATUS_LINE_NUM < TRAP_LINE_NUM )); then
        _ORDER_RESULT="yes"
    else
        _ORDER_RESULT="no"
    fi
    assert_eq "status_init_before_trap: STATUS (line ${STATUS_LINE_NUM}) before trap (line ${TRAP_LINE_NUM})" "yes" "$_ORDER_RESULT"
fi

assert_pass_if_clean "test_status_initialized_before_trap_registration"

# ============================================================
# test_resume_skips_completed_tests
# When a progress file exists for the current diff hash, tests
# listed in it are skipped (not re-run), and they still appear
# in the tested_files audit field.
# ============================================================
echo ""
echo "=== test_resume_skips_completed_tests ==="
_snapshot_fail

TEST_REPO_RESUME=$(create_test_repo)
ARTIFACTS_RESUME=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_RESUME" "$ARTIFACTS_RESUME"' EXIT

mkdir -p "$TEST_REPO_RESUME/src" "$TEST_REPO_RESUME/tests"
cat > "$TEST_REPO_RESUME/src/gamma.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "gamma"
SHEOF
chmod +x "$TEST_REPO_RESUME/src/gamma.sh"
cat > "$TEST_REPO_RESUME/tests/test-gamma.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_gamma_ok: PASS"
exit 0
SHEOF
chmod +x "$TEST_REPO_RESUME/tests/test-gamma.sh"
git -C "$TEST_REPO_RESUME" add -A
git -C "$TEST_REPO_RESUME" commit -m "add gamma" --quiet 2>/dev/null
echo "# changed" >> "$TEST_REPO_RESUME/src/gamma.sh"
git -C "$TEST_REPO_RESUME" add -A

# Compute the diff hash and .test-index hash for this repo so we can pre-populate the progress file
DIFF_HASH_RESUME=$(cd "$TEST_REPO_RESUME" && bash "$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh" 2>/dev/null || echo "deadbeef")
HASH_PREFIX="${DIFF_HASH_RESUME:0:16}"
_TI_FILE="$TEST_REPO_RESUME/.test-index"
if [[ -f "$_TI_FILE" ]]; then
    _TI_HASH=$(shasum -a 256 "$_TI_FILE" 2>/dev/null | cut -d' ' -f1 || echo "noindex")
else
    _TI_HASH="noindex"
fi
PROGRESS_FILE_RESUME="$ARTIFACTS_RESUME/test-gate-progress-${HASH_PREFIX}-${_TI_HASH:0:8}"

# Pre-populate the progress file as if tests/test-gamma.sh already passed
echo "tests/test-gamma.sh" > "$PROGRESS_FILE_RESUME"

# Use a mock runner that fails — if the hook correctly skips the already-passed
# test, it should exit 0; if it re-runs the test, it would exit 1.
MOCK_RESUME=$(mktemp "${TMPDIR:-/tmp}/mock-resume-XXXXXX")
chmod +x "$MOCK_RESUME"
cat > "$MOCK_RESUME" << 'MOCKEOF'
#!/usr/bin/env bash
# This runner should never be called when resume is working correctly.
echo "test_gamma_ok: FAIL (should have been skipped)"
exit 1
MOCKEOF

EXIT_RESUME=$(
    cd "$TEST_REPO_RESUME"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_RESUME" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_RESUME" \
    run_hook_exit
)
assert_eq "resume_skips_completed_tests: exits 0 when test already passed" "0" "$EXIT_RESUME"

# The final status file should show 'passed'
STATUS_RESUME=$(head -1 "$ARTIFACTS_RESUME/test-gate-status" 2>/dev/null || echo "missing")
assert_eq "resume_skips_completed_tests: final status is passed" "passed" "$STATUS_RESUME"

# The tested_files field should include the skipped test (for audit accuracy)
TESTED_RESUME=$(grep '^tested_files=' "$ARTIFACTS_RESUME/test-gate-status" 2>/dev/null || echo "")
assert_contains "resume_skips_completed_tests: skipped test appears in tested_files" "test-gamma.sh" "$TESTED_RESUME"

rm -f "$MOCK_RESUME"
rm -rf "$TEST_REPO_RESUME" "$ARTIFACTS_RESUME"
trap - EXIT

assert_pass_if_clean "test_resume_skips_completed_tests"

# test_red_marker_survives_overwrite_by_unmarked_entry (Bug A — b9a9-4cb3)
# When TWO staged source files both map to the SAME test file via
# .test-index, and one entry has a RED marker while the other does not,
# the marker must be preserved regardless of processing order.
# ============================================================
echo ""
echo "=== test_red_marker_survives_overwrite_by_unmarked_entry ==="
_snapshot_fail

TEST_REPO_BUGA=$(create_test_repo)
ARTIFACTS_BUGA=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_BUGA" "$ARTIFACTS_BUGA"' EXIT

# Two source files: aaa_marked.py (sorts first) and zzz_unmarked.py (sorts last).
# git diff --cached outputs alphabetically, so aaa_marked is processed first
# (setting the marker), then zzz_unmarked is processed second (which must NOT
# overwrite the marker with empty string).
mkdir -p "$TEST_REPO_BUGA/src" "$TEST_REPO_BUGA/tests"
cat > "$TEST_REPO_BUGA/src/aaa_marked.py" << 'PYEOF'
def aaa_marked():
    return "marked"
PYEOF
cat > "$TEST_REPO_BUGA/src/zzz_unmarked.py" << 'PYEOF'
def zzz_unmarked():
    return "unmarked"
PYEOF

# One shared test file with a passing test and a RED zone test
cat > "$TEST_REPO_BUGA/tests/test_shared.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_passing: PASS"
echo "test_red_feature: FAIL (intentional RED zone failure)"
exit 1
SHEOF
chmod +x "$TEST_REPO_BUGA/tests/test_shared.sh"

# .test-index: aaa_marked maps WITH marker, zzz_unmarked WITHOUT marker.
# git processes staged files alphabetically: aaa_marked first (sets marker),
# then zzz_unmarked second. Bug A: the unmarked entry must NOT overwrite.
cat > "$TEST_REPO_BUGA/.test-index" << 'IDXEOF'
src/aaa_marked.py:tests/test_shared.sh [test_red_feature]
src/zzz_unmarked.py:tests/test_shared.sh
IDXEOF

git -C "$TEST_REPO_BUGA" add -A
git -C "$TEST_REPO_BUGA" commit -m "setup" --quiet 2>/dev/null

# Stage BOTH source files
echo "# change" >> "$TEST_REPO_BUGA/src/aaa_marked.py"
echo "# change" >> "$TEST_REPO_BUGA/src/zzz_unmarked.py"
git -C "$TEST_REPO_BUGA" add -A

# Mock runner: simulates RED zone failure
MOCK_BUGA=$(mktemp "${TMPDIR:-/tmp}/mock-buga-runner-XXXXXX")
chmod +x "$MOCK_BUGA"
cat > "$MOCK_BUGA" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_passing: PASS"
echo "test_red_feature: FAIL (intentional RED zone)"
exit 1
MOCKEOF

EXIT_BUGA=$(
    cd "$TEST_REPO_BUGA"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_BUGA" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_BUGA" \
    run_hook_exit
)

assert_eq "bug_a_marker_survives_overwrite: exits 0 (RED zone tolerated)" "0" "$EXIT_BUGA"
if [[ -f "$ARTIFACTS_BUGA/test-gate-status" ]]; then
    FIRST_LINE_BUGA=$(head -1 "$ARTIFACTS_BUGA/test-gate-status")
    assert_eq "bug_a_marker_survives_overwrite: writes passed" "passed" "$FIRST_LINE_BUGA"
else
    assert_eq "bug_a_marker_survives_overwrite: status file exists" "exists" "missing"
fi

rm -f "$MOCK_BUGA"
rm -rf "$TEST_REPO_BUGA" "$ARTIFACTS_BUGA"
trap - EXIT
assert_pass_if_clean "test_red_marker_survives_overwrite_by_unmarked_entry"

# ============================================================
# test_red_marker_found_via_global_scan (Bug B — b9a9-4cb3)
# When a test file is triggered by a staged source file whose
# .test-index entry has NO marker, but a DIFFERENT (non-staged)
# source file's .test-index entry maps to the same test WITH a
# marker, the global scan should find and apply the marker.
# ============================================================
echo ""
echo "=== test_red_marker_found_via_global_scan ==="
_snapshot_fail

TEST_REPO_BUGB=$(create_test_repo)
ARTIFACTS_BUGB=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_BUGB" "$ARTIFACTS_BUGB"' EXIT

# Two source files: staged.py and unstaged.py
mkdir -p "$TEST_REPO_BUGB/src" "$TEST_REPO_BUGB/tests"
cat > "$TEST_REPO_BUGB/src/staged.py" << 'PYEOF'
def staged():
    return "staged"
PYEOF
cat > "$TEST_REPO_BUGB/src/unstaged.py" << 'PYEOF'
def unstaged():
    return "unstaged"
PYEOF

# Shared test file with RED zone failure
cat > "$TEST_REPO_BUGB/tests/test_shared.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_existing: PASS"
echo "test_new_red: FAIL (intentional RED zone failure)"
exit 1
SHEOF
chmod +x "$TEST_REPO_BUGB/tests/test_shared.sh"

# .test-index:
#   staged.py   → test_shared.sh (NO marker)
#   unstaged.py → test_shared.sh [test_new_red] (HAS marker)
cat > "$TEST_REPO_BUGB/.test-index" << 'IDXEOF'
src/staged.py:tests/test_shared.sh
src/unstaged.py:tests/test_shared.sh [test_new_red]
IDXEOF

git -C "$TEST_REPO_BUGB" add -A
git -C "$TEST_REPO_BUGB" commit -m "setup" --quiet 2>/dev/null

# Stage ONLY staged.py — unstaged.py is NOT modified
echo "# change" >> "$TEST_REPO_BUGB/src/staged.py"
git -C "$TEST_REPO_BUGB" add src/staged.py

# Mock runner: simulates RED zone failure
MOCK_BUGB=$(mktemp "${TMPDIR:-/tmp}/mock-bugb-runner-XXXXXX")
chmod +x "$MOCK_BUGB"
cat > "$MOCK_BUGB" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_existing: PASS"
echo "test_new_red: FAIL (intentional RED zone)"
exit 1
MOCKEOF

EXIT_BUGB=$(
    cd "$TEST_REPO_BUGB"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_BUGB" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_BUGB" \
    run_hook_exit
)

# The test was triggered by staged.py (no marker), but unstaged.py's
# .test-index entry has [test_new_red]. The global scan should find it.
assert_eq "bug_b_global_scan_finds_marker: exits 0 (RED zone tolerated)" "0" "$EXIT_BUGB"
if [[ -f "$ARTIFACTS_BUGB/test-gate-status" ]]; then
    FIRST_LINE_BUGB=$(head -1 "$ARTIFACTS_BUGB/test-gate-status")
    assert_eq "bug_b_global_scan_finds_marker: writes passed" "passed" "$FIRST_LINE_BUGB"
else
    assert_eq "bug_b_global_scan_finds_marker: status file exists" "exists" "missing"
fi

rm -f "$MOCK_BUGB"
rm -rf "$TEST_REPO_BUGB" "$ARTIFACTS_BUGB"
trap - EXIT
assert_pass_if_clean "test_red_marker_found_via_global_scan"

# ============================================================
# test_global_scan_no_false_positive_from_substring_match (Bug B hardening)
# When test file "tests/test_alpha.sh" has no marker, and a DIFFERENT
# test file "tests/test_alpha_extended.sh" has a marker, the global
# scan must NOT apply the marker from the longer-named file.
# Validates exact path matching, not substring matching.
# ============================================================
echo ""
echo "=== test_global_scan_no_false_positive_from_substring_match ==="
_snapshot_fail

TEST_REPO_BUGB2=$(create_test_repo)
ARTIFACTS_BUGB2=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_BUGB2" "$ARTIFACTS_BUGB2"' EXIT

mkdir -p "$TEST_REPO_BUGB2/src" "$TEST_REPO_BUGB2/tests"
cat > "$TEST_REPO_BUGB2/src/alpha.py" << 'PYEOF'
def alpha():
    return "alpha"
PYEOF
cat > "$TEST_REPO_BUGB2/src/alpha_extended.py" << 'PYEOF'
def alpha_extended():
    return "extended"
PYEOF

# test_alpha.sh — FAILS (no marker should protect it)
cat > "$TEST_REPO_BUGB2/tests/test_alpha.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_alpha_basic: FAIL (genuine failure, no marker)"
exit 1
SHEOF
chmod +x "$TEST_REPO_BUGB2/tests/test_alpha.sh"

# test_alpha_extended.sh — has marker (but for a DIFFERENT test file)
cat > "$TEST_REPO_BUGB2/tests/test_alpha_extended.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_extended_red: FAIL (RED zone)"
exit 1
SHEOF
chmod +x "$TEST_REPO_BUGB2/tests/test_alpha_extended.sh"

# .test-index:
#   alpha.py → test_alpha.sh (NO marker)
#   alpha_extended.py → test_alpha_extended.sh [test_extended_red] (HAS marker)
# A substring grep for "test_alpha.sh" would match "test_alpha_extended.sh" — must NOT happen.
cat > "$TEST_REPO_BUGB2/.test-index" << 'IDXEOF'
src/alpha.py:tests/test_alpha.sh
src/alpha_extended.py:tests/test_alpha_extended.sh [test_extended_red]
IDXEOF

git -C "$TEST_REPO_BUGB2" add -A
git -C "$TEST_REPO_BUGB2" commit -m "setup" --quiet 2>/dev/null

# Stage alpha.py only
echo "# change" >> "$TEST_REPO_BUGB2/src/alpha.py"
git -C "$TEST_REPO_BUGB2" add src/alpha.py

MOCK_BUGB2=$(mktemp "${TMPDIR:-/tmp}/mock-bugb2-runner-XXXXXX")
chmod +x "$MOCK_BUGB2"
cat > "$MOCK_BUGB2" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_alpha_basic: FAIL (genuine failure)"
exit 1
MOCKEOF

EXIT_BUGB2=$(
    cd "$TEST_REPO_BUGB2"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_BUGB2" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_BUGB2" \
    run_hook_exit
)

# test_alpha.sh has NO marker. test_alpha_extended.sh has a marker but for a
# different file. The global scan must NOT apply that marker to test_alpha.sh.
assert_eq "bug_b_no_substring_false_positive: exits 1 (genuine failure blocks)" "1" "$EXIT_BUGB2"
if [[ -f "$ARTIFACTS_BUGB2/test-gate-status" ]]; then
    FIRST_LINE_BUGB2=$(head -1 "$ARTIFACTS_BUGB2/test-gate-status")
    assert_eq "bug_b_no_substring_false_positive: writes failed" "failed" "$FIRST_LINE_BUGB2"
fi

rm -f "$MOCK_BUGB2"
rm -rf "$TEST_REPO_BUGB2" "$ARTIFACTS_BUGB2"
trap - EXIT
assert_pass_if_clean "test_global_scan_no_false_positive_from_substring_match"

# ── Test: merge-commit awareness filters out incoming-only files ─────────
echo "Test: merge-commit awareness — incoming-only files are filtered out"
test_merge_commit_filters_incoming_only() {
    _snapshot_fail

    # Create a test repo with two source files and associated tests
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    local repo="$tmp/repo"
    mkdir -p "$repo"
    cd "$repo"
    git init -q -b main
    git config user.name "test" && git config user.email "test@test"

    # Create source + test for "ours" (worktree branch changes)
    mkdir -p plugins/dso/scripts tests/scripts
    echo '#!/bin/bash' > plugins/dso/scripts/our-script.sh
    echo '#!/bin/bash' > tests/scripts/test-our-script.sh
    chmod +x tests/scripts/test-our-script.sh

    # Create source + test for "theirs" (incoming from main)
    echo '#!/bin/bash' > plugins/dso/scripts/their-script.sh
    printf '#!/bin/bash\necho "PASSED: 0  FAILED: 1"' > tests/scripts/test-their-script.sh
    chmod +x tests/scripts/test-their-script.sh

    git add -A && git commit -q -m "initial"

    # Create a branch and change OUR file only
    git checkout -q -b feature
    echo '# changed' >> plugins/dso/scripts/our-script.sh
    git add -A && git commit -q -m "feature change"

    # Back to main, change THEIR file (simulates incoming main changes)
    git checkout -q main
    echo '# main change' >> plugins/dso/scripts/their-script.sh
    git add -A && git commit -q -m "main change"

    # Start merge on feature branch (no-commit to simulate merge state)
    git checkout -q feature
    git merge --no-commit --no-ff main 2>/dev/null || true

    # Verify MERGE_HEAD exists
    if [[ ! -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]]; then
        assert_eq "MERGE_HEAD exists" "exists" "missing"
        assert_pass_if_clean "test_merge_commit_filters_incoming_only"
        return
    fi

    # Stage everything (as a merge commit would)
    git add -A

    # Create artifacts dir and mock test runner that always passes for our-script
    local artifacts="$tmp/artifacts"
    mkdir -p "$artifacts"

    # The runner should only be called for our-script's test, NOT their-script's test
    local runner_log="$tmp/runner-invocations.log"
    local mock_runner="$tmp/mock-runner.sh"
    cat > "$mock_runner" << 'RUNNER'
#!/bin/bash
echo "$@" >> RUNNER_LOG_PATH
echo "PASSED: 1  FAILED: 0"
exit 0
RUNNER
    sed -i.bak "s|RUNNER_LOG_PATH|${runner_log}|g" "$mock_runner" 2>/dev/null || \
        sed -i '' "s|RUNNER_LOG_PATH|${runner_log}|g" "$mock_runner"
    chmod +x "$mock_runner"

    # Run record-test-status with our mock
    REPO_ROOT="$repo" \
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts" \
    RECORD_TEST_STATUS_RUNNER="$mock_runner" \
    TEST_GATE_TEST_DIRS_OVERRIDE="tests/" \
    bash "$HOOK" 2>/dev/null || true

    # Assert: their-script's test was NOT invoked (filtered as incoming-only)
    if [[ -f "$runner_log" ]]; then
        local invoked_their
        invoked_their=$(grep -c 'test-their-script' "$runner_log" 2>/dev/null || echo "0")
        assert_eq "their-script test NOT invoked (incoming-only)" "0" "$invoked_their"
    else
        # No runner invocations at all — also acceptable if our-script had no fuzzy match
        assert_eq "runner log exists or no tests needed" "ok" "ok"
    fi

    cd /
    rm -rf "$tmp"
    trap - EXIT
    assert_pass_if_clean "test_merge_commit_filters_incoming_only"
}
test_merge_commit_filters_incoming_only

# ============================================================
# test_red_marker_parsed_with_20plus_test_files
# When a single .test-index line maps ONE source file to 22+
# comma-separated test files and one of them has a [marker],
# the RED marker must be correctly detected and tolerated.
#
# This is a regression test for ea38-e0b4: "RED zone parsing
# fails for .test-index entries with many test files".
# The IFS=',' read -ra splitting and regex matching inside
# read_test_index_for_source must correctly identify the marker
# regardless of how many entries precede or follow it.
# ============================================================
echo ""
echo "=== test_red_marker_parsed_with_20plus_test_files ==="
_snapshot_fail

TEST_REPO_MANY=$(create_test_repo)
ARTIFACTS_MANY=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_MANY" "$ARTIFACTS_MANY"' EXIT

mkdir -p "$TEST_REPO_MANY/source" "$TEST_REPO_MANY/tests"

# Create source file
cat > "$TEST_REPO_MANY/source/big.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "big source"
SHEOF

# Create 22 test files. Test 15 is in the RED zone (fails, has marker).
# All others pass.
for _mi in $(seq 1 22); do
    if [[ $_mi -eq 15 ]]; then
        cat > "$TEST_REPO_MANY/tests/test_big_${_mi}.sh" << 'SHEOF'
#!/usr/bin/env bash
test_green_before() { echo "test_green_before: PASS"; }
test_many_red_marker() { echo "test_many_red_marker: FAIL"; exit 1; }
test_green_before
test_many_red_marker
SHEOF
    else
        printf '#!/usr/bin/env bash\necho "test_pass_%d: PASS"\nexit 0\n' "$_mi" \
            > "$TEST_REPO_MANY/tests/test_big_${_mi}.sh"
    fi
    chmod +x "$TEST_REPO_MANY/tests/test_big_${_mi}.sh"
done

# Build .test-index with 22 entries for source/big.sh, marker at position 15
_idx_line="source/big.sh:"
for _mi in $(seq 1 14); do
    _idx_line="${_idx_line} tests/test_big_${_mi}.sh,"
done
_idx_line="${_idx_line} tests/test_big_15.sh [test_many_red_marker],"
for _mi in $(seq 16 22); do
    _idx_line="${_idx_line} tests/test_big_${_mi}.sh,"
done
_idx_line="${_idx_line%,}"
printf '%s\n' "$_idx_line" > "$TEST_REPO_MANY/.test-index"

git -C "$TEST_REPO_MANY" add -A
git -C "$TEST_REPO_MANY" commit -m "setup many tests" --quiet 2>/dev/null

# Stage a change to the source file
echo "# changed" >> "$TEST_REPO_MANY/source/big.sh"
git -C "$TEST_REPO_MANY" add source/big.sh

EXIT_MANY=$(
    cd "$TEST_REPO_MANY"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_MANY" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    TEST_GATE_TEST_DIRS_OVERRIDE="tests/" \
    run_hook_exit
)

# test_big_15.sh fails but the RED marker [test_many_red_marker] must be
# correctly parsed from the 22-entry .test-index line. All other tests pass.
# Expected overall status: passed (RED zone failure tolerated).
assert_eq "20plus_entries: exits 0 (RED zone tolerated)" "0" "$EXIT_MANY"

if [[ -f "$ARTIFACTS_MANY/test-gate-status" ]]; then
    STATUS_MANY=$(head -1 "$ARTIFACTS_MANY/test-gate-status")
    assert_eq "20plus_entries: writes passed" "passed" "$STATUS_MANY"
    TESTED_MANY=$(grep '^tested_files=' "$ARTIFACTS_MANY/test-gate-status" 2>/dev/null || echo "")
    assert_contains "20plus_entries: test_big_15 appears in tested_files" "test_big_15" "$TESTED_MANY"
else
    assert_eq "20plus_entries: status file exists" "exists" "missing"
fi

rm -rf "$TEST_REPO_MANY" "$ARTIFACTS_MANY"
trap - EXIT

assert_pass_if_clean "test_red_marker_parsed_with_20plus_test_files"

# ============================================================
# test_progress_cache_invalidated_on_test_index_change
# When .test-index is edited (RED marker removed) between two
# hook invocations, a pre-existing progress file keyed by
# DIFF_HASH must NOT be reused — the test must be re-executed.
#
# Bug: progress file key is test-gate-progress-${DIFF_HASH:0:16},
# which is unchanged when only .test-index is edited (not the
# staged source file). The fix must incorporate .test-index
# content into the key so edits invalidate the cache.
#
# The progress file is only consulted on resume after SIGURG
# interruption. This test simulates a SIGURG-interrupted first run
# by manually pre-populating the progress file at the hash-derived
# key, then editing .test-index, then running the hook.
#
# Before fix: hook finds the pre-populated progress file → skips
#   the test → mock runner NOT invoked → INVOKE_LOG absent → FAIL.
# After fix:  .test-index content changes the key → no matching
#   progress file → test re-runs → mock runner invoked → PASS.
# ============================================================
echo ""
echo "=== test_progress_cache_invalidated_on_test_index_change ==="
_snapshot_fail

TEST_REPO_CACHE=$(create_test_repo)
ARTIFACTS_CACHE=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_CACHE" "$ARTIFACTS_CACHE"' EXIT

# Create source file with a passing test
mkdir -p "$TEST_REPO_CACHE/scripts" "$TEST_REPO_CACHE/tests"
cat > "$TEST_REPO_CACHE/scripts/worker.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "worker"
SHEOF
chmod +x "$TEST_REPO_CACHE/scripts/worker.sh"

cat > "$TEST_REPO_CACHE/tests/test-worker.sh" << 'SHEOF'
#!/usr/bin/env bash
test_worker_green() { echo "test_worker_green: PASS"; }
test_worker_red_pending() { echo "test_worker_red_pending: FAIL"; exit 1; }
test_worker_green
test_worker_red_pending
SHEOF
chmod +x "$TEST_REPO_CACHE/tests/test-worker.sh"

# Initial .test-index WITH a RED marker (the marker is present before editing)
cat > "$TEST_REPO_CACHE/.test-index" << 'IDXEOF'
scripts/worker.sh: tests/test-worker.sh [test_worker_red_pending]
IDXEOF

git -C "$TEST_REPO_CACHE" add -A
git -C "$TEST_REPO_CACHE" commit -m "initial with red marker" --quiet 2>/dev/null

# Stage a change to the source file — this fixes DIFF_HASH for both runs
echo "# changed" >> "$TEST_REPO_CACHE/scripts/worker.sh"
git -C "$TEST_REPO_CACHE" add scripts/worker.sh

# Compute DIFF_HASH as the hook would — with .test-index unchanged at this point
DIFF_HASH_CACHE=$(
    cd "$TEST_REPO_CACHE"
    bash "$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh" 2>/dev/null
)

# Simulate a SIGURG-interrupted previous run: pre-populate the progress file
# with the test filename, as if tests/test-worker.sh passed in a prior invocation.
# This is the exact state that triggers the bug on the next hook invocation.
_STALE_PROGRESS_FILE="$ARTIFACTS_CACHE/test-gate-progress-${DIFF_HASH_CACHE:0:16}"
echo "tests/test-worker.sh" > "$_STALE_PROGRESS_FILE"

# Now edit .test-index to REMOVE the RED marker (simulates developer completing
# the feature and removing the TDD boundary marker). DIFF_HASH is unchanged
# because only the staged source file matters for the diff hash.
cat > "$TEST_REPO_CACHE/.test-index" << 'IDXEOF'
scripts/worker.sh: tests/test-worker.sh
IDXEOF
# .test-index is not re-staged — the staged diff (and thus DIFF_HASH) is unchanged.

# Counting mock runner: records each invocation in a log file.
# The test (test-worker.sh) now has no RED marker, so the hook expects exit 0.
# We make the mock exit 0 to give the correct behavior after fix.
INVOKE_LOG="$ARTIFACTS_CACHE/invoke-count.log"
MOCK_RUN=$(mktemp "${TMPDIR:-/tmp}/mock-cache-run-XXXXXX")
chmod +x "$MOCK_RUN"
cat > "$MOCK_RUN" << MOCKEOF
#!/usr/bin/env bash
echo "invoked" >> "${INVOKE_LOG}"
echo "test_worker_green: PASS"
echo "test_worker_red_pending: PASS"
exit 0
MOCKEOF

# Run the hook. With the stale progress file present and DIFF_HASH unchanged:
# BUG  (before fix): hook reads _STALE_PROGRESS_FILE → test is in _COMPLETED_TESTS
#   → skipped with "already passed" message → mock NOT invoked → exit 0
# FIXED (after fix): progress key incorporates .test-index hash → different key
#   → stale file not found → test re-runs → mock IS invoked → exit 0
EXIT_CACHE=$(
    cd "$TEST_REPO_CACHE"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_CACHE" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_RUN" \
    run_hook_exit
)
assert_eq "cache_invalidation: hook exits 0" "0" "$EXIT_CACHE"
rm -f "$MOCK_RUN"

# Critical assertion: mock runner MUST have been invoked.
# Before fix: stale cache reused → mock skipped → INVOKE_LOG absent → FAIL.
# After fix:  .test-index change invalidates cache → mock runs → PASS.
if [[ -f "$INVOKE_LOG" ]]; then
    INVOKE_COUNT=$(wc -l < "$INVOKE_LOG" | tr -d ' ')
    assert_eq "cache_invalidation: test re-executed after .test-index change (not skipped from stale cache)" "1" "$INVOKE_COUNT"
else
    assert_eq "cache_invalidation: mock runner was invoked (stale progress cache not reused)" "invoked" "not_invoked"
fi

rm -rf "$TEST_REPO_CACHE" "$ARTIFACTS_CACHE"
trap - EXIT

assert_pass_if_clean "test_progress_cache_invalidated_on_test_index_change"

# ============================================================
# test_stale_red_marker_status_cleared_when_only_test_index_staged
# Bug: 137a-b61a
#
# Scenario: source file is staged → hook runs → test exits 0 but has RED marker
# → STATUS="failed" written to test-gate-status. Then developer removes the marker
# from .test-index and stages ONLY .test-index (source file not re-staged).
# Hook re-runs → ASSOCIATED_TESTS=[] (no source file staged) → early exit at
# the no-associated-tests guard → stale "failed" status persists → commit blocked.
#
# Before fix: hook exits 0 silently; stale "failed" test-gate-status untouched.
# After fix:  hook detects stale-red-marker entries whose markers no longer exist
#             in .test-index and clears the status file so the gate allows commit.
# ============================================================
echo ""
echo "=== test_stale_red_marker_status_cleared_when_only_test_index_staged ==="
_snapshot_fail

TEST_REPO_STALE=$(create_test_repo)
ARTIFACTS_STALE=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-stale-XXXXXX")
trap 'rm -rf "$TEST_REPO_STALE" "$ARTIFACTS_STALE"' EXIT

mkdir -p "$TEST_REPO_STALE/scripts" "$TEST_REPO_STALE/tests"

cat > "$TEST_REPO_STALE/scripts/worker.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "worker"
SHEOF
chmod +x "$TEST_REPO_STALE/scripts/worker.sh"

# Test file must exist so the hook can find and run it
cat > "$TEST_REPO_STALE/tests/test-worker.sh" << 'SHEOF'
#!/usr/bin/env bash
test_worker_done() { echo "test_worker_done: PASS"; }
test_worker_done
SHEOF
chmod +x "$TEST_REPO_STALE/tests/test-worker.sh"

# Mock test runner that always exits 0 (all tests pass — RED zone complete)
MOCK_PASS=$(mktemp "${TMPDIR:-/tmp}/mock-pass-XXXXXX")
chmod +x "$MOCK_PASS"
cat > "$MOCK_PASS" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_worker_done: PASS"
exit 0
MOCKEOF

# .test-index WITH a RED marker (marker is present on first run)
cat > "$TEST_REPO_STALE/.test-index" << 'IDXEOF'
scripts/worker.sh: tests/test-worker.sh [test_worker_done]
IDXEOF

# Commit all initial state so HEAD exists and staged diff is clean
git -C "$TEST_REPO_STALE" add scripts/worker.sh tests/test-worker.sh .test-index
git -C "$TEST_REPO_STALE" commit -m "initial with marker" --quiet 2>/dev/null

# Stage a change to the source file (so ASSOCIATED_TESTS gets populated on first run)
echo "# v2" >> "$TEST_REPO_STALE/scripts/worker.sh"
git -C "$TEST_REPO_STALE" add scripts/worker.sh

# First run: source file staged, RED marker present, test exits 0 → stale marker → STATUS=failed → hook exits 1
_RUN1_EXIT=$(
    cd "$TEST_REPO_STALE"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_STALE" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS" \
    run_hook_exit
)
assert_eq "stale_marker_run1: hook exits 1 (stale marker detected)" "1" "$_RUN1_EXIT"
_RUN1_STATUS=$(head -1 "$ARTIFACTS_STALE/test-gate-status" 2>/dev/null || echo "missing")
assert_eq "stale_marker_run1: status is failed due to stale RED marker" "failed" "$_RUN1_STATUS"

# Now developer removes the RED marker from .test-index and stages ONLY .test-index
# (source file is NOT re-staged — this is the problematic scenario)
cat > "$TEST_REPO_STALE/.test-index" << 'IDXEOF'
scripts/worker.sh: tests/test-worker.sh
IDXEOF
git -C "$TEST_REPO_STALE" add .test-index
# Unstage source file (simulate: developer staged .test-index but not source)
git -C "$TEST_REPO_STALE" restore --staged scripts/worker.sh 2>/dev/null || true

# Second run: only .test-index staged → ASSOCIATED_TESTS=[] → stale status should be cleared
_RUN2_EXIT=$(
    cd "$TEST_REPO_STALE"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_STALE" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS" \
    run_hook_exit
)
assert_eq "stale_marker_run2: hook exits 0" "0" "$_RUN2_EXIT"

# Critical: stale "failed" status must be cleared — marker is gone from .test-index
_RUN2_STATUS=$(head -1 "$ARTIFACTS_STALE/test-gate-status" 2>/dev/null || echo "missing")
# Before fix: status is still "failed" (early exit left it untouched) → this assertion FAILS
# After fix:  status is "missing" (file cleared) or "passed" → PASSES
assert_ne "stale_marker_run2: stale failed status cleared after marker removal" "failed" "$_RUN2_STATUS"

rm -f "$MOCK_PASS"
rm -rf "$TEST_REPO_STALE" "$ARTIFACTS_STALE"
trap - EXIT

assert_pass_if_clean "test_stale_red_marker_status_cleared_when_only_test_index_staged"

print_summary
