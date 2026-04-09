#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-version-bump.sh
# Behavioral tests for _phase_version_bump in merge-to-main.sh.
#
# TDD RED phase — ALL tests must FAIL against unmodified merge-to-main.sh
# (because _phase_version_bump does not yet exist).
#
# Tests:
#   1. test_version_bump_phase_calls_bump_version_patch_default
#   2. test_version_bump_phase_calls_bump_version_minor
#   3. test_version_bump_phase_skips_silently_when_no_version_file_path
#   4. test_version_bump_phase_marks_state_complete
#   5. test_version_bump_phase_exits_nonzero_on_bump_failure
#   6. test_merge_to_main_help_includes_bump_flag
#   7. test_version_bump_phase_idempotent_on_resume
#
# Usage: bash tests/scripts/test-merge-to-main-version-bump.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# =============================================================================
# Helper: extract a function body from merge-to-main.sh by name
# =============================================================================
_extract_fn() {
    local fn_name="$1"
    awk "/^${fn_name}\\(\\)/{found=1} found{print; if(/^\\}$/){exit}}" "$MERGE_SCRIPT"
}

# =============================================================================
# Helper: create a minimal git repo with state infrastructure sourced
# Sets globals: _TEST_BASE, _WORK_DIR, _STATE_FILE, BRANCH
# =============================================================================
_setup_test_repo() {
    _TEST_BASE=$(mktemp -d)
    _WORK_DIR="$_TEST_BASE/work"
    mkdir -p "$_WORK_DIR"
    (
        cd "$_WORK_DIR"
        git init -b main --quiet
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > README.md
        git add README.md
        git commit -m "initial" --quiet
    ) 2>/dev/null
    BRANCH="test-version-bump-$$"
    export BRANCH
}

# =============================================================================
# Helper: create a mock bump-version.sh that records its arguments to a file
# Returns the path to the mock directory (prepend to PATH)
# =============================================================================
_setup_mock_bump_version() {
    local mock_dir="$1"
    local call_log="$2"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/bump-version.sh" << MOCK_EOF
#!/usr/bin/env bash
# Mock bump-version.sh — records invocation args to call log
echo "\$@" >> "$call_log"
exit 0
MOCK_EOF
    chmod +x "$mock_dir/bump-version.sh"
}

# =============================================================================
# Helper: source state management functions from merge-to-main.sh
# =============================================================================
_source_state_functions() {
    eval "$(_extract_fn "_state_file_path")" 2>/dev/null || true
    eval "$(_extract_fn "_state_is_fresh")" 2>/dev/null || true
    eval "$(_extract_fn "_state_init")" 2>/dev/null || true
    eval "$(_extract_fn "_state_write_phase")" 2>/dev/null || true
    eval "$(_extract_fn "_state_mark_complete")" 2>/dev/null || true
    eval "$(_extract_fn "_set_phase_status")" 2>/dev/null || true
}

# =============================================================================
# Structural guard: _phase_version_bump must exist in merge-to-main.sh
# This test drives Task 2 (implementation). Must FAIL in RED phase.
# =============================================================================
HAS_PHASE_FN=$(grep -c '^_phase_version_bump()' "$MERGE_SCRIPT" 2>/dev/null || echo "0")
assert_eq "test_phase_version_bump_function_exists_in_script" "1" "$HAS_PHASE_FN"

# =============================================================================
# Test 6 (structural — runs fast before integration tests):
# test_merge_to_main_help_includes_bump_flag
# --help output must include '--bump'.
# MUST FAIL (RED): --help currently does not mention --bump.
# =============================================================================
echo ""
echo "--- test_merge_to_main_help_includes_bump_flag ---"
_snapshot_fail

_T6_OUTPUT=$(bash "$MERGE_SCRIPT" --help 2>&1)
assert_contains "test_merge_to_main_help_includes_bump_flag" "--bump" "$_T6_OUTPUT"

assert_pass_if_clean "test_merge_to_main_help_includes_bump_flag"

# =============================================================================
# Integration tests — extract and eval _phase_version_bump with mocks
# =============================================================================
echo ""
echo "=== Integration tests (behavioral: mock bump-version.sh) ==="

# Source state functions once for all integration tests
_source_state_functions

# =============================================================================
# Test 1: test_version_bump_phase_calls_bump_version_patch_default
# When BUMP_TYPE=patch, _phase_version_bump must invoke bump-version.sh --patch.
# MUST FAIL (RED): _phase_version_bump does not exist.
# =============================================================================
echo ""
echo "--- test_version_bump_phase_calls_bump_version_patch_default ---"
_snapshot_fail

_setup_test_repo
_T1_MOCK_DIR="$_TEST_BASE/mock-bin"
_T1_CALL_LOG="$_TEST_BASE/bump-calls.txt"
_setup_mock_bump_version "$_T1_MOCK_DIR" "$_T1_CALL_LOG"

# Extract _phase_version_bump and eval it in a subshell with mock on PATH
_PHASE_FN_BODY=$(_extract_fn "_phase_version_bump" 2>/dev/null || echo "")

_T1_RC=0
_T1_OUTPUT=$(
    cd "$_WORK_DIR"
    # Inject mock on PATH
    export PATH="$_T1_MOCK_DIR:$PATH"
    export BUMP_TYPE="patch"
    export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
    export MAIN_REPO="$_WORK_DIR"
    # Initialize state file
    _state_init 2>/dev/null || true
    # Eval and run the phase function
    if [[ -n "$_PHASE_FN_BODY" ]]; then
        eval "$_PHASE_FN_BODY"
        _phase_version_bump 2>&1
    else
        echo "FUNCTION_NOT_FOUND"
        exit 1
    fi
) || _T1_RC=$?

# Must have called mock with --patch
if [[ -f "$_T1_CALL_LOG" ]]; then
    _T1_CALL_ARGS=$(cat "$_T1_CALL_LOG")
else
    _T1_CALL_ARGS=""
fi
assert_contains "test_version_bump_phase_calls_bump_version_patch_default" "--patch" "$_T1_CALL_ARGS"
assert_eq "test_version_bump_patch_exits_0" "0" "$_T1_RC"

assert_pass_if_clean "test_version_bump_phase_calls_bump_version_patch_default"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 2: test_version_bump_phase_calls_bump_version_minor
# When BUMP_TYPE=minor, _phase_version_bump must invoke bump-version.sh --minor.
# MUST FAIL (RED): _phase_version_bump does not exist.
# =============================================================================
echo ""
echo "--- test_version_bump_phase_calls_bump_version_minor ---"
_snapshot_fail

_setup_test_repo
_T2_MOCK_DIR="$_TEST_BASE/mock-bin"
_T2_CALL_LOG="$_TEST_BASE/bump-calls.txt"
_setup_mock_bump_version "$_T2_MOCK_DIR" "$_T2_CALL_LOG"

_PHASE_FN_BODY=$(_extract_fn "_phase_version_bump" 2>/dev/null || echo "")

_T2_RC=0
_T2_OUTPUT=$(
    cd "$_WORK_DIR"
    export PATH="$_T2_MOCK_DIR:$PATH"
    export BUMP_TYPE="minor"
    export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
    export MAIN_REPO="$_WORK_DIR"
    _state_init 2>/dev/null || true
    if [[ -n "$_PHASE_FN_BODY" ]]; then
        eval "$_PHASE_FN_BODY"
        _phase_version_bump 2>&1
    else
        echo "FUNCTION_NOT_FOUND"
        exit 1
    fi
) || _T2_RC=$?

if [[ -f "$_T2_CALL_LOG" ]]; then
    _T2_CALL_ARGS=$(cat "$_T2_CALL_LOG")
else
    _T2_CALL_ARGS=""
fi
assert_contains "test_version_bump_phase_calls_bump_version_minor" "--minor" "$_T2_CALL_ARGS"
assert_eq "test_version_bump_minor_exits_0" "0" "$_T2_RC"

assert_pass_if_clean "test_version_bump_phase_calls_bump_version_minor"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 3: test_version_bump_phase_skips_silently_when_no_version_file_path
# When VERSION_FILE_PATH is empty, _phase_version_bump must exit 0 and NOT
# invoke mock bump-version.sh.
# MUST FAIL (RED): _phase_version_bump does not exist.
# =============================================================================
echo ""
echo "--- test_version_bump_phase_skips_silently_when_no_version_file_path ---"
_snapshot_fail

_setup_test_repo
_T3_MOCK_DIR="$_TEST_BASE/mock-bin"
_T3_CALL_LOG="$_TEST_BASE/bump-calls.txt"
_setup_mock_bump_version "$_T3_MOCK_DIR" "$_T3_CALL_LOG"

_PHASE_FN_BODY=$(_extract_fn "_phase_version_bump" 2>/dev/null || echo "")

_T3_RC=0
_T3_OUTPUT=$(
    cd "$_WORK_DIR"
    export PATH="$_T3_MOCK_DIR:$PATH"
    export BUMP_TYPE="patch"
    export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
    export MAIN_REPO="$_WORK_DIR"
    # Explicitly clear VERSION_FILE_PATH to simulate unconfigured state
    export VERSION_FILE_PATH=""
    _state_init 2>/dev/null || true
    if [[ -n "$_PHASE_FN_BODY" ]]; then
        eval "$_PHASE_FN_BODY"
        _phase_version_bump 2>&1
    else
        echo "FUNCTION_NOT_FOUND"
        exit 1
    fi
) || _T3_RC=$?

# Mock must NOT have been called
if [[ -f "$_T3_CALL_LOG" ]]; then
    _T3_CALLS=$(wc -l < "$_T3_CALL_LOG" | tr -d ' ')
else
    _T3_CALLS="0"
fi
assert_eq "test_version_bump_skip_exits_0" "0" "$_T3_RC"
assert_eq "test_version_bump_skip_no_mock_call" "0" "$_T3_CALLS"

assert_pass_if_clean "test_version_bump_phase_skips_silently_when_no_version_file_path"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 4: test_version_bump_phase_marks_state_complete
# After a successful bump, the state file must contain 'version_bump'
# in completed_phases.
# MUST FAIL (RED): _phase_version_bump does not exist.
# =============================================================================
echo ""
echo "--- test_version_bump_phase_marks_state_complete ---"
_snapshot_fail

_setup_test_repo
_T4_MOCK_DIR="$_TEST_BASE/mock-bin"
_T4_CALL_LOG="$_TEST_BASE/bump-calls.txt"
_setup_mock_bump_version "$_T4_MOCK_DIR" "$_T4_CALL_LOG"

_PHASE_FN_BODY=$(_extract_fn "_phase_version_bump" 2>/dev/null || echo "")

(
    cd "$_WORK_DIR"
    export PATH="$_T4_MOCK_DIR:$PATH"
    export BUMP_TYPE="patch"
    export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
    export MAIN_REPO="$_WORK_DIR"
    _state_init 2>/dev/null || true
    if [[ -n "$_PHASE_FN_BODY" ]]; then
        eval "$_PHASE_FN_BODY"
        _phase_version_bump 2>&1
    fi
) 2>/dev/null || true

# Read state file
_T4_STATE_FILE=$(_state_file_path 2>/dev/null || echo "")
if [[ -n "$_T4_STATE_FILE" && -f "$_T4_STATE_FILE" ]]; then
    _T4_COMPLETED=$(python3 -c "
import json
with open('$_T4_STATE_FILE') as f:
    d = json.load(f)
phases = d.get('completed_phases', [])
print('version_bump' if 'version_bump' in phases else 'missing')
" 2>/dev/null || echo "missing")
else
    _T4_COMPLETED="no_state_file"
fi
assert_eq "test_version_bump_marks_state_complete" "version_bump" "$_T4_COMPLETED"

assert_pass_if_clean "test_version_bump_phase_marks_state_complete"
rm -f "$_T4_STATE_FILE" 2>/dev/null || true
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 5: test_version_bump_phase_exits_nonzero_on_bump_failure
# When mock bump-version.sh exits 1, _phase_version_bump must exit non-zero.
# The function must also EXIST (not just fail because it is undefined).
# MUST FAIL (RED): _phase_version_bump does not exist.
# We assert: (a) the function body is non-empty, AND (b) exit code is non-zero.
# In RED phase both (a) and (b) independently fail to be satisfied together.
# =============================================================================
echo ""
echo "--- test_version_bump_phase_exits_nonzero_on_bump_failure ---"
_snapshot_fail

_setup_test_repo
_T5_MOCK_DIR="$_TEST_BASE/mock-bin"
mkdir -p "$_T5_MOCK_DIR"
# Failing mock
cat > "$_T5_MOCK_DIR/bump-version.sh" << 'FAIL_MOCK_EOF'
#!/usr/bin/env bash
echo "ERROR: mock bump-version.sh failure" >&2
exit 1
FAIL_MOCK_EOF
chmod +x "$_T5_MOCK_DIR/bump-version.sh"

_T5_PHASE_FN_BODY=$(_extract_fn "_phase_version_bump" 2>/dev/null || echo "")

# Structural gate: function must exist (RED: this fails because fn not defined)
if [[ -n "$_T5_PHASE_FN_BODY" ]]; then
    _T5_FN_EXISTS="yes"
else
    _T5_FN_EXISTS="no"
fi
assert_eq "test_version_bump_failure_fn_exists" "yes" "$_T5_FN_EXISTS"

_T5_RC=0
(
    cd "$_WORK_DIR"
    export PATH="$_T5_MOCK_DIR:$PATH"
    export BUMP_TYPE="patch"
    export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
    export MAIN_REPO="$_WORK_DIR"
    _state_init 2>/dev/null || true
    if [[ -n "$_T5_PHASE_FN_BODY" ]]; then
        eval "$_T5_PHASE_FN_BODY"
        _phase_version_bump 2>/dev/null
    else
        exit 1
    fi
) || _T5_RC=$?

assert_ne "test_version_bump_exits_nonzero_on_failure" "0" "$_T5_RC"

assert_pass_if_clean "test_version_bump_phase_exits_nonzero_on_bump_failure"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 7: test_version_bump_phase_idempotent_on_resume
# Simulate resume scenario: 'version_bump' already in completed_phases.
# _phase_version_bump must exit 0 and NOT call mock bump-version.sh again.
# MUST FAIL (RED): _phase_version_bump does not exist.
# =============================================================================
echo ""
echo "--- test_version_bump_phase_idempotent_on_resume ---"
_snapshot_fail

_setup_test_repo
_T7_MOCK_DIR="$_TEST_BASE/mock-bin"
_T7_CALL_LOG="$_TEST_BASE/bump-calls-resume.txt"
_setup_mock_bump_version "$_T7_MOCK_DIR" "$_T7_CALL_LOG"

_PHASE_FN_BODY=$(_extract_fn "_phase_version_bump" 2>/dev/null || echo "")

# Pre-populate state file with version_bump already completed
_state_init 2>/dev/null || true
_T7_STATE_FILE=$(_state_file_path 2>/dev/null || echo "")
if [[ -n "$_T7_STATE_FILE" && -f "$_T7_STATE_FILE" ]]; then
    python3 -c "
import json
with open('$_T7_STATE_FILE') as f:
    d = json.load(f)
d.setdefault('completed_phases', []).append('version_bump')
d.setdefault('phases', {})['version_bump'] = {'status': 'complete'}
with open('$_T7_STATE_FILE', 'w') as f:
    json.dump(d, f)
" 2>/dev/null || true
fi

_T7_RC=0
_T7_OUTPUT=$(
    cd "$_WORK_DIR"
    export PATH="$_T7_MOCK_DIR:$PATH"
    export BUMP_TYPE="patch"
    export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
    export MAIN_REPO="$_WORK_DIR"
    if [[ -n "$_PHASE_FN_BODY" ]]; then
        eval "$_PHASE_FN_BODY"
        _phase_version_bump 2>&1
    else
        echo "FUNCTION_NOT_FOUND"
        exit 1
    fi
) || _T7_RC=$?

# Mock must NOT have been called on resume
if [[ -f "$_T7_CALL_LOG" ]]; then
    _T7_CALLS=$(wc -l < "$_T7_CALL_LOG" | tr -d ' ')
else
    _T7_CALLS="0"
fi
assert_eq "test_version_bump_idempotent_exits_0" "0" "$_T7_RC"
assert_eq "test_version_bump_idempotent_no_mock_call" "0" "$_T7_CALLS"

assert_pass_if_clean "test_version_bump_phase_idempotent_on_resume"
rm -f "$_T7_STATE_FILE" 2>/dev/null || true
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 8: test_version_bump_defaults_to_patch_when_version_file_configured
# When BUMP_TYPE is EMPTY but VERSION_FILE_PATH is set (configured),
# _phase_version_bump must default to patch and invoke bump-version.sh --patch.
# This tests the fix for fb93-69da: version not bumped when --bump is not passed.
# MUST FAIL (RED): current code skips when BUMP_TYPE is empty.
# =============================================================================
echo ""
echo "--- test_version_bump_defaults_to_patch_when_version_file_configured ---"
_snapshot_fail

_setup_test_repo
_T8_MOCK_DIR="$_TEST_BASE/mock-bin"
_T8_CALL_LOG="$_TEST_BASE/bump-calls-default.txt"
_setup_mock_bump_version "$_T8_MOCK_DIR" "$_T8_CALL_LOG"

_PHASE_FN_BODY=$(_extract_fn "_phase_version_bump" 2>/dev/null || echo "")

_T8_RC=0
_T8_OUTPUT=$(
    cd "$_WORK_DIR"
    export PATH="$_T8_MOCK_DIR:$PATH"
    # KEY: BUMP_TYPE is EMPTY (no --bump passed) but VERSION_FILE_PATH is set
    export BUMP_TYPE=""
    export VERSION_FILE_PATH="plugins/dso/.claude-plugin/plugin.json"
    export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
    export MAIN_REPO="$_WORK_DIR"
    _state_init 2>/dev/null || true
    if [[ -n "$_PHASE_FN_BODY" ]]; then
        eval "$_PHASE_FN_BODY"
        _phase_version_bump 2>&1
    else
        echo "FUNCTION_NOT_FOUND"
        exit 1
    fi
) || _T8_RC=$?

# Must have called mock with --patch (defaulted)
if [[ -f "$_T8_CALL_LOG" ]]; then
    _T8_CALL_ARGS=$(cat "$_T8_CALL_LOG")
else
    _T8_CALL_ARGS=""
fi
assert_contains "test_version_bump_defaults_to_patch" "--patch" "$_T8_CALL_ARGS"
assert_eq "test_version_bump_default_exits_0" "0" "$_T8_RC"

assert_pass_if_clean "test_version_bump_defaults_to_patch_when_version_file_configured"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 9: test_version_bump_skips_when_no_bump_type_and_no_version_file
# When BUMP_TYPE is EMPTY and VERSION_FILE_PATH is also EMPTY,
# _phase_version_bump must skip (not default to patch).
# =============================================================================
echo ""
echo "--- test_version_bump_skips_when_no_bump_type_and_no_version_file ---"
_snapshot_fail

_setup_test_repo
_T9_MOCK_DIR="$_TEST_BASE/mock-bin"
_T9_CALL_LOG="$_TEST_BASE/bump-calls-skip.txt"
_setup_mock_bump_version "$_T9_MOCK_DIR" "$_T9_CALL_LOG"

_PHASE_FN_BODY=$(_extract_fn "_phase_version_bump" 2>/dev/null || echo "")

_T9_RC=0
_T9_OUTPUT=$(
    cd "$_WORK_DIR"
    export PATH="$_T9_MOCK_DIR:$PATH"
    export BUMP_TYPE=""
    # KEY: VERSION_FILE_PATH also empty — no version config
    unset VERSION_FILE_PATH
    export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
    export MAIN_REPO="$_WORK_DIR"
    _state_init 2>/dev/null || true
    if [[ -n "$_PHASE_FN_BODY" ]]; then
        eval "$_PHASE_FN_BODY"
        _phase_version_bump 2>&1
    else
        echo "FUNCTION_NOT_FOUND"
        exit 1
    fi
) || _T9_RC=$?

# Mock must NOT have been called
if [[ -f "$_T9_CALL_LOG" ]]; then
    _T9_CALLS=$(wc -l < "$_T9_CALL_LOG" | tr -d ' ')
else
    _T9_CALLS="0"
fi
assert_eq "test_version_bump_no_config_exits_0" "0" "$_T9_RC"
assert_eq "test_version_bump_no_config_no_mock_call" "0" "$_T9_CALLS"

assert_pass_if_clean "test_version_bump_skips_when_no_bump_type_and_no_version_file"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 10: test_version_bump_syncs_package_lock_json_when_version_file_is_package_json
# When VERSION_FILE_PATH ends in package.json, _phase_version_bump must run
# npm install --package-lock-only after bump-version.sh to sync package-lock.json.
# MUST FAIL (RED): current code does not run npm install --package-lock-only.
# =============================================================================
echo ""
echo "--- test_version_bump_syncs_package_lock_json_when_version_file_is_package_json ---"
_snapshot_fail

_setup_test_repo
_T10_MOCK_DIR="$_TEST_BASE/mock-bin"
_T10_CALL_LOG="$_TEST_BASE/npm-calls.txt"
mkdir -p "$_T10_MOCK_DIR"

# Create package.json with version 1.0.0 in the git repo
cat > "$_WORK_DIR/package.json" << 'PKG_EOF'
{
  "name": "test-pkg",
  "version": "1.0.0"
}
PKG_EOF

# Create package-lock.json with version 1.0.0 (simulating stale lock file)
cat > "$_WORK_DIR/package-lock.json" << 'LOCK_EOF'
{
  "name": "test-pkg",
  "version": "1.0.0",
  "lockfileVersion": 2
}
LOCK_EOF

# Commit both files to git so git diff works
(cd "$_WORK_DIR" && git add package.json package-lock.json && git commit -m "add package files" --quiet) 2>/dev/null

# Mock bump-version.sh: updates package.json version to 1.0.1
cat > "$_T10_MOCK_DIR/bump-version.sh" << 'BUMP_MOCK_EOF'
#!/usr/bin/env bash
# Find and update the package.json in cwd
PKG_FILE="$(pwd)/package.json"
if [[ -f "$PKG_FILE" ]]; then
    python3 -c "
import json, sys
with open('$PKG_FILE') as f:
    d = json.load(f)
d['version'] = '1.0.1'
with open('$PKG_FILE', 'w') as f:
    json.dump(d, f, indent=2)
"
fi
exit 0
BUMP_MOCK_EOF
chmod +x "$_T10_MOCK_DIR/bump-version.sh"

# Mock npm: when called with "install --package-lock-only", updates package-lock.json
# to reflect the new version from package.json
cat > "$_T10_MOCK_DIR/npm" << 'NPM_MOCK_EOF'
#!/usr/bin/env bash
# Record call
echo "$@" >> "$_T10_NPM_CALL_LOG"
# If called with install --package-lock-only, update package-lock.json to match package.json version
if [[ "$*" == *"--package-lock-only"* ]]; then
    PKG_FILE="$(pwd)/package.json"
    LOCK_FILE="$(pwd)/package-lock.json"
    if [[ -f "$PKG_FILE" && -f "$LOCK_FILE" ]]; then
        python3 -c "
import json
with open('$PKG_FILE') as f:
    pkg = json.load(f)
with open('$LOCK_FILE') as f:
    lock = json.load(f)
lock['version'] = pkg['version']
with open('$LOCK_FILE', 'w') as f:
    json.dump(lock, f, indent=2)
"
    fi
fi
exit 0
NPM_MOCK_EOF
chmod +x "$_T10_MOCK_DIR/npm"

export _T10_NPM_CALL_LOG="$_T10_CALL_LOG"

# Set VERSION_FILE_PATH to package.json path (relative to MAIN_REPO)
export VERSION_FILE_PATH="$_WORK_DIR/package.json"

_PHASE_FN_BODY=$(_extract_fn "_phase_version_bump" 2>/dev/null || echo "")

_T10_RC=0
_T10_OUTPUT=$(
    cd "$_WORK_DIR"
    export PATH="$_T10_MOCK_DIR:$PATH"
    export BUMP_TYPE="patch"
    export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
    export MAIN_REPO="$_WORK_DIR"
    export VERSION_FILE_PATH="$_WORK_DIR/package.json"
    export _T10_NPM_CALL_LOG="$_T10_CALL_LOG"
    _state_init 2>/dev/null || true
    if [[ -n "$_PHASE_FN_BODY" ]]; then
        eval "$_PHASE_FN_BODY"
        _phase_version_bump 2>&1
    else
        echo "FUNCTION_NOT_FOUND"
        exit 1
    fi
) || _T10_RC=$?

# Assert: npm was called with --package-lock-only
if [[ -f "$_T10_CALL_LOG" ]]; then
    _T10_NPM_ARGS=$(cat "$_T10_CALL_LOG")
else
    _T10_NPM_ARGS=""
fi
assert_contains "test_version_bump_calls_npm_package_lock_only" "--package-lock-only" "$_T10_NPM_ARGS"

# Assert: package-lock.json now has version 1.0.1
_T10_LOCK_VERSION=$(python3 -c "
import json
with open('$_WORK_DIR/package-lock.json') as f:
    d = json.load(f)
print(d.get('version', 'MISSING'))
" 2>/dev/null || echo "READ_ERROR")
assert_eq "test_version_bump_lock_version_updated" "1.0.1" "$_T10_LOCK_VERSION"

assert_eq "test_version_bump_package_lock_sync_exits_0" "0" "$_T10_RC"

assert_pass_if_clean "test_version_bump_syncs_package_lock_json_when_version_file_is_package_json"
rm -rf "$_TEST_BASE"

# =============================================================================
print_summary
