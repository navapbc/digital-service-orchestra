#!/usr/bin/env bash
set -euo pipefail
# tests/hooks/test-record-test-status-part1.sh
# Tests for hooks/record-test-status.sh — Part 1 of 4 (tests 1–9: discovery, pass/fail recording, hash matching)
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
# test_discovers_associated_tests
# Given a source file foo.py with an associated test_foo.py,
# the script discovers and runs test_foo.py
# ============================================================
echo ""
echo "=== test_discovers_associated_tests ==="

TEST_REPO_1=$(create_test_repo)
ARTIFACTS_1=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_1" "$ARTIFACTS_1"' EXIT

# Create source file and associated test file
mkdir -p "$TEST_REPO_1/src" "$TEST_REPO_1/tests"
cat > "$TEST_REPO_1/src/foo.py" << 'PYEOF'
def foo():
    return 42
PYEOF
cat > "$TEST_REPO_1/tests/test_foo.py" << 'PYEOF'
def test_foo():
    assert True
PYEOF
git -C "$TEST_REPO_1" add -A
git -C "$TEST_REPO_1" commit -m "add foo" --quiet 2>/dev/null

# Modify foo.py to create a diff
echo "# changed" >> "$TEST_REPO_1/src/foo.py"
git -C "$TEST_REPO_1" add -A

EXIT_CODE=$(
    cd "$TEST_REPO_1"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_1" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    run_hook_exit_pass
)

# The script should either exit 0 (tests passed) or produce a status file.
# Since record-test-status.sh doesn't exist yet, this should fail (exit != 0).
# In RED phase, we verify the test infrastructure works by checking it fails.
if [[ -f "$HOOK" ]]; then
    # When implementation exists: verify test_foo.py was discovered
    # Check that test-gate-status records test_foo.py in the tested_files field
    FOUND_TEST="no"
    if grep -q "tested_files=.*test_foo" "$ARTIFACTS_1/test-gate-status" 2>/dev/null; then
        FOUND_TEST="yes"
    fi
    assert_eq "test_discovers_associated_tests: test_foo.py discovered" "yes" "$FOUND_TEST"
else
    # RED phase: script doesn't exist, test correctly fails
    assert_ne "test_discovers_associated_tests: script not found (RED)" "0" "$EXIT_CODE"
fi

rm -rf "$TEST_REPO_1" "$ARTIFACTS_1"
trap - EXIT

# ============================================================
# test_records_passed_status
# When associated tests pass, writes 'passed' and diff_hash
# to test-gate-status file
# ============================================================
echo ""
echo "=== test_records_passed_status ==="

TEST_REPO_2=$(create_test_repo)
ARTIFACTS_2=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_2" "$ARTIFACTS_2"' EXIT

# Create a source file and a passing test
mkdir -p "$TEST_REPO_2/src" "$TEST_REPO_2/tests"
cat > "$TEST_REPO_2/src/bar.py" << 'PYEOF'
def bar():
    return "hello"
PYEOF
cat > "$TEST_REPO_2/tests/test_bar.py" << 'PYEOF'
def test_bar():
    assert True
PYEOF
git -C "$TEST_REPO_2" add -A
git -C "$TEST_REPO_2" commit -m "add bar" --quiet 2>/dev/null

# Create a diff by modifying bar.py
echo "# changed" >> "$TEST_REPO_2/src/bar.py"
git -C "$TEST_REPO_2" add -A

EXIT_CODE=$(
    cd "$TEST_REPO_2"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_2" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    run_hook_exit_pass
)

STATUS_FILE="$ARTIFACTS_2/test-gate-status"
if [[ -f "$HOOK" ]]; then
    # When implementation exists: verify passed status and diff_hash
    assert_eq "test_records_passed_status: exit 0" "0" "$EXIT_CODE"
    if [[ -f "$STATUS_FILE" ]]; then
        FIRST_LINE=$(head -1 "$STATUS_FILE")
        assert_eq "test_records_passed_status: first line is passed" "passed" "$FIRST_LINE"
        HASH_LINE=$(grep '^diff_hash=' "$STATUS_FILE" || echo "")
        assert_ne "test_records_passed_status: diff_hash present" "" "$HASH_LINE"
    else
        assert_eq "test_records_passed_status: status file exists" "exists" "missing"
    fi
else
    assert_ne "test_records_passed_status: script not found (RED)" "0" "$EXIT_CODE"
fi

rm -rf "$TEST_REPO_2" "$ARTIFACTS_2"
trap - EXIT

# ============================================================
# test_records_failed_status
# When associated tests fail, writes 'failed' to test-gate-status
# ============================================================
echo ""
echo "=== test_records_failed_status ==="

TEST_REPO_3=$(create_test_repo)
ARTIFACTS_3=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_3" "$ARTIFACTS_3"' EXIT

# Create a source file and a FAILING test
mkdir -p "$TEST_REPO_3/src" "$TEST_REPO_3/tests"
cat > "$TEST_REPO_3/src/baz.py" << 'PYEOF'
def baz():
    return None
PYEOF
cat > "$TEST_REPO_3/tests/test_baz.py" << 'PYEOF'
def test_baz():
    assert False, "intentional failure"
PYEOF
git -C "$TEST_REPO_3" add -A
git -C "$TEST_REPO_3" commit -m "add baz" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_3/src/baz.py"
git -C "$TEST_REPO_3" add -A

EXIT_CODE=$(
    cd "$TEST_REPO_3"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_3" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    run_hook_exit_fail
)

STATUS_FILE="$ARTIFACTS_3/test-gate-status"
if [[ -f "$HOOK" ]]; then
    # When implementation exists: verify failed status
    if [[ -f "$STATUS_FILE" ]]; then
        FIRST_LINE=$(head -1 "$STATUS_FILE")
        assert_eq "test_records_failed_status: first line is failed" "failed" "$FIRST_LINE"
    else
        assert_eq "test_records_failed_status: status file exists" "exists" "missing"
    fi
else
    assert_ne "test_records_failed_status: script not found (RED)" "0" "$EXIT_CODE"
fi

rm -rf "$TEST_REPO_3" "$ARTIFACTS_3"
trap - EXIT

# ============================================================
# test_exit_144_actionable_message
# When test runner exits 144 (SIGURG timeout), error message
# includes test-batched.sh command with --timeout flag and
# resume instructions
# ============================================================
echo ""
echo "=== test_exit_144_actionable_message ==="

TEST_REPO_4=$(create_test_repo)
ARTIFACTS_4=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_4" "$ARTIFACTS_4"' EXIT

# Create source and test, with a mock test runner that exits 144
mkdir -p "$TEST_REPO_4/src" "$TEST_REPO_4/tests"
cat > "$TEST_REPO_4/src/slow.py" << 'PYEOF'
def slow():
    pass
PYEOF
cat > "$TEST_REPO_4/tests/test_slow.py" << 'PYEOF'
def test_slow():
    assert True
PYEOF
git -C "$TEST_REPO_4" add -A
git -C "$TEST_REPO_4" commit -m "add slow" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_4/src/slow.py"
git -C "$TEST_REPO_4" add -A

# Create a mock test runner that exits 144 (simulating SIGURG timeout)
MOCK_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-test-runner-XXXXXX")
chmod +x "$MOCK_RUNNER"
cat > "$MOCK_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
exit 144
MOCKEOF

OUTPUT=$(
    cd "$TEST_REPO_4"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_4" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_RUNNER" \
    bash "$HOOK" 2>&1 || true
)

if [[ -f "$HOOK" ]]; then
    # When implementation exists: verify actionable message mentions test-batched.sh
    assert_contains "test_exit_144_actionable_message: mentions test-batched.sh" "test-batched" "$OUTPUT"
    assert_contains "test_exit_144_actionable_message: mentions --timeout" "--timeout" "$OUTPUT"
else
    # RED phase: script doesn't exist
    assert_contains "test_exit_144_actionable_message: script not found (RED)" "No such file" "$OUTPUT"
fi

rm -f "$MOCK_RUNNER"
rm -rf "$TEST_REPO_4" "$ARTIFACTS_4"
trap - EXIT

# ============================================================
# test_no_associated_tests_exempts
# Source file with no associated test writes an exempt marker
# or exits 0 cleanly
# ============================================================
echo ""
echo "=== test_no_associated_tests_exempts ==="

TEST_REPO_5=$(create_test_repo)
ARTIFACTS_5=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_5" "$ARTIFACTS_5"' EXIT

# Create a source file with NO associated test
mkdir -p "$TEST_REPO_5/src"
cat > "$TEST_REPO_5/src/orphan.py" << 'PYEOF'
def orphan():
    return "no tests here"
PYEOF
git -C "$TEST_REPO_5" add -A
git -C "$TEST_REPO_5" commit -m "add orphan" --quiet 2>/dev/null

echo "# changed" >> "$TEST_REPO_5/src/orphan.py"
git -C "$TEST_REPO_5" add -A

EXIT_CODE=$(
    cd "$TEST_REPO_5"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_5" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    run_hook_exit
)

STATUS_FILE="$ARTIFACTS_5/test-gate-status"
if [[ -f "$HOOK" ]]; then
    # When implementation exists: should exit 0 and write exempt marker or skip cleanly
    assert_eq "test_no_associated_tests_exempts: exit 0" "0" "$EXIT_CODE"
    if [[ -f "$STATUS_FILE" ]]; then
        FIRST_LINE=$(head -1 "$STATUS_FILE")
        # Should be either "passed" (vacuously) or "exempt"
        VALID_STATUS="no"
        if [[ "$FIRST_LINE" == "passed" || "$FIRST_LINE" == "exempt" ]]; then
            VALID_STATUS="yes"
        fi
        assert_eq "test_no_associated_tests_exempts: status is passed or exempt" "yes" "$VALID_STATUS"
    fi
    # Either way, exit code should be 0
else
    assert_ne "test_no_associated_tests_exempts: script not found (RED)" "0" "$EXIT_CODE"
fi

rm -rf "$TEST_REPO_5" "$ARTIFACTS_5"
trap - EXIT

# ============================================================
# test_hash_matches_compute_diff_hash
# diff_hash recorded in test-gate-status must match output
# of compute-diff-hash.sh at the same git state
# ============================================================
echo ""
echo "=== test_hash_matches_compute_diff_hash ==="

TEST_REPO_6=$(create_test_repo)
ARTIFACTS_6=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_6" "$ARTIFACTS_6"' EXIT

# Create source and passing test
mkdir -p "$TEST_REPO_6/src" "$TEST_REPO_6/tests"
cat > "$TEST_REPO_6/src/hashme.py" << 'PYEOF'
def hashme():
    return "hash test"
PYEOF
cat > "$TEST_REPO_6/tests/test_hashme.py" << 'PYEOF'
def test_hashme():
    assert True
PYEOF
git -C "$TEST_REPO_6" add -A
git -C "$TEST_REPO_6" commit -m "add hashme" --quiet 2>/dev/null

echo "# changed for hash test" >> "$TEST_REPO_6/src/hashme.py"
git -C "$TEST_REPO_6" add -A

EXIT_CODE=$(
    cd "$TEST_REPO_6"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_6" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    run_hook_exit_pass
)

STATUS_FILE="$ARTIFACTS_6/test-gate-status"

if [[ -f "$HOOK" ]] && [[ -f "$STATUS_FILE" ]]; then
    RECORDED_HASH=$(grep '^diff_hash=' "$STATUS_FILE" | head -1 | cut -d= -f2)
    EXPECTED_HASH=$(cd "$TEST_REPO_6" && bash "$COMPUTE_HASH_SCRIPT" 2>/dev/null)
    assert_eq "test_hash_matches_compute_diff_hash: hashes match" "$EXPECTED_HASH" "$RECORDED_HASH"
else
    # RED phase: script doesn't exist or no status file
    assert_ne "test_hash_matches_compute_diff_hash: script not found (RED)" "0" "$EXIT_CODE"
fi

rm -rf "$TEST_REPO_6" "$ARTIFACTS_6"
trap - EXIT

# ============================================================
# test_captures_hash_after_staging
# Hash is captured AFTER git add (same point as record-review.sh)
# so it matches at verify time
# ============================================================
echo ""
echo "=== test_captures_hash_after_staging ==="

TEST_REPO_7=$(create_test_repo)
ARTIFACTS_7=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_7" "$ARTIFACTS_7"' EXIT

# Create source and passing test
mkdir -p "$TEST_REPO_7/src" "$TEST_REPO_7/tests"
cat > "$TEST_REPO_7/src/staged.py" << 'PYEOF'
def staged():
    return "staging test"
PYEOF
cat > "$TEST_REPO_7/tests/test_staged.py" << 'PYEOF'
def test_staged():
    assert True
PYEOF
git -C "$TEST_REPO_7" add -A
git -C "$TEST_REPO_7" commit -m "add staged" --quiet 2>/dev/null

# Create unstaged changes first
echo "# unstaged change" >> "$TEST_REPO_7/src/staged.py"

# Capture hash BEFORE staging (with unstaged change)
HASH_BEFORE_ADD=$(cd "$TEST_REPO_7" && bash "$COMPUTE_HASH_SCRIPT" 2>/dev/null || echo "compute-error")

# Stage the change
git -C "$TEST_REPO_7" add -A

# Capture hash AFTER staging
HASH_AFTER_ADD=$(cd "$TEST_REPO_7" && bash "$COMPUTE_HASH_SCRIPT" 2>/dev/null || echo "compute-error")

# Run the hook after staging
EXIT_CODE=$(
    cd "$TEST_REPO_7"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_7" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    run_hook_exit_pass
)

STATUS_FILE="$ARTIFACTS_7/test-gate-status"

if [[ -f "$HOOK" ]] && [[ -f "$STATUS_FILE" ]]; then
    RECORDED_HASH=$(grep '^diff_hash=' "$STATUS_FILE" | head -1 | cut -d= -f2)
    # The recorded hash should match the hash computed after staging,
    # which is the same point where record-review.sh captures its hash.
    # compute-diff-hash.sh is staging-invariant, so both should match.
    assert_eq "test_captures_hash_after_staging: hash matches after-add state" "$HASH_AFTER_ADD" "$RECORDED_HASH"
else
    # RED phase: script doesn't exist or no status file
    assert_ne "test_captures_hash_after_staging: script not found (RED)" "0" "$EXIT_CODE"
fi

rm -rf "$TEST_REPO_7" "$ARTIFACTS_7"
trap - EXIT

# ============================================================
# test_record_bash_script_discovers_test
# A staged bash script (scripts/bump-version.sh) should be
# matched to its associated test (tests/test-bump-version.sh)
# via fuzzy matching. RED: current recorder uses test_bumpversionsh
# pattern which won't match test-bump-version.sh.
# ============================================================
echo ""
echo "=== test_record_bash_script_discovers_test ==="

TEST_REPO_BASH=$(create_test_repo)
ARTIFACTS_BASH=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_BASH" "$ARTIFACTS_BASH"' EXIT

# Create a bash source file and its associated test file (bash naming convention)
mkdir -p "$TEST_REPO_BASH/scripts" "$TEST_REPO_BASH/tests"
cat > "$TEST_REPO_BASH/scripts/bump-version.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "bumping version"
SHEOF
chmod +x "$TEST_REPO_BASH/scripts/bump-version.sh"

cat > "$TEST_REPO_BASH/tests/test-bump-version.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test bump-version"
exit 0
SHEOF
chmod +x "$TEST_REPO_BASH/tests/test-bump-version.sh"

git -C "$TEST_REPO_BASH" add -A
git -C "$TEST_REPO_BASH" commit -m "add bump-version" --quiet 2>/dev/null

# Modify the source to create a staged diff
echo "# changed" >> "$TEST_REPO_BASH/scripts/bump-version.sh"
git -C "$TEST_REPO_BASH" add -A

# Create a mock runner that always passes
MOCK_PASS=$(mktemp "${TMPDIR:-/tmp}/mock-pass-XXXXXX")
chmod +x "$MOCK_PASS"
cat > "$MOCK_PASS" << 'MOCKEOF'
#!/usr/bin/env bash
echo "PASSED (mock)"
exit 0
MOCKEOF

EXIT_CODE=$(
    cd "$TEST_REPO_BASH"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_BASH" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS" \
    run_hook_exit
)

STATUS_FILE_BASH="$ARTIFACTS_BASH/test-gate-status"

# RED assertion: current recorder uses test_bump-versionsh pattern which won't
# match test-bump-version.sh, so no test-gate-status file is written (exempt exit 0).
# After implementation (fuzzy match), the test file WILL be discovered and status written.
if [[ -f "$STATUS_FILE_BASH" ]]; then
    TESTED_LINE=$(grep '^tested_files=' "$STATUS_FILE_BASH" | head -1 | cut -d= -f2)
    assert_contains "test_record_bash_script_discovers_test: tested_files contains test-bump-version.sh" "test-bump-version.sh" "$TESTED_LINE"
else
    # No status file means no test was discovered — this is the RED failure
    assert_eq "test_record_bash_script_discovers_test: status file written (fuzzy match discovers test)" "exists" "missing"
fi

rm -f "$MOCK_PASS"
rm -rf "$TEST_REPO_BASH" "$ARTIFACTS_BASH"
trap - EXIT

# ============================================================
# test_record_uses_configured_test_dirs
# When TEST_GATE_TEST_DIRS_OVERRIDE is set, the recorder should
# search only those directories for test files. RED: current
# recorder ignores TEST_GATE_TEST_DIRS_OVERRIDE entirely.
# ============================================================
echo ""
echo "=== test_record_uses_configured_test_dirs ==="

TEST_REPO_DIRS=$(create_test_repo)
ARTIFACTS_DIRS=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_DIRS" "$ARTIFACTS_DIRS"' EXIT

# Create a bash source file and test in a NON-standard directory (unit_tests/)
mkdir -p "$TEST_REPO_DIRS/scripts" "$TEST_REPO_DIRS/unit_tests"
cat > "$TEST_REPO_DIRS/scripts/bump-version.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "bumping version"
SHEOF
chmod +x "$TEST_REPO_DIRS/scripts/bump-version.sh"

cat > "$TEST_REPO_DIRS/unit_tests/test-bump-version.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test bump-version from unit_tests"
exit 0
SHEOF
chmod +x "$TEST_REPO_DIRS/unit_tests/test-bump-version.sh"

git -C "$TEST_REPO_DIRS" add -A
git -C "$TEST_REPO_DIRS" commit -m "add bump-version with custom test dir" --quiet 2>/dev/null

# Modify source to create staged diff
echo "# changed" >> "$TEST_REPO_DIRS/scripts/bump-version.sh"
git -C "$TEST_REPO_DIRS" add -A

# Create a mock runner that always passes
MOCK_PASS_DIRS=$(mktemp "${TMPDIR:-/tmp}/mock-pass-dirs-XXXXXX")
chmod +x "$MOCK_PASS_DIRS"
cat > "$MOCK_PASS_DIRS" << 'MOCKEOF'
#!/usr/bin/env bash
echo "PASSED (mock)"
exit 0
MOCKEOF

EXIT_CODE=$(
    cd "$TEST_REPO_DIRS"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIRS" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_DIRS" \
    TEST_GATE_TEST_DIRS_OVERRIDE="unit_tests/" \
    run_hook_exit
)

STATUS_FILE_DIRS="$ARTIFACTS_DIRS/test-gate-status"

# RED assertion: current recorder ignores TEST_GATE_TEST_DIRS_OVERRIDE and uses
# find . with test_bump-versionsh pattern. It won't find test-bump-version.sh
# regardless of directory. After implementation, it will use fuzzy match scoped
# to unit_tests/ and find the test.
if [[ -f "$STATUS_FILE_DIRS" ]]; then
    TESTED_LINE=$(grep '^tested_files=' "$STATUS_FILE_DIRS" | head -1 | cut -d= -f2)
    assert_contains "test_record_uses_configured_test_dirs: tested_files contains test-bump-version.sh from unit_tests" "test-bump-version.sh" "$TESTED_LINE"
    # Additionally verify it found the file in unit_tests/ (not some other dir)
    assert_contains "test_record_uses_configured_test_dirs: path includes unit_tests/" "unit_tests/" "$TESTED_LINE"
else
    # No status file means no test was discovered — this is the RED failure
    assert_eq "test_record_uses_configured_test_dirs: status file written (fuzzy match with test dirs)" "exists" "missing"
fi

rm -f "$MOCK_PASS_DIRS"
rm -rf "$TEST_REPO_DIRS" "$ARTIFACTS_DIRS"
trap - EXIT


print_summary
