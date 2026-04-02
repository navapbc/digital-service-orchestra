#!/usr/bin/env bash
set -uo pipefail
# tests/hooks/test-record-test-status-centrality.sh
# Tests for centrality scoring in hooks/record-test-status.sh
#
# Centrality logic:
#   - Uses grep pattern matching to count fan-in (direct references) for staged files
#   - Centrality > threshold (default 8): run the full test suite
#   - Centrality <= threshold: run only associated tests
#   - sg not installed: centrality defaults to 0, stderr warning, run associated only

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/record-test-status.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# Disable commit signing for test git repos
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

# ============================================================
# Helper: create an isolated temp git repo with initial commit
# ============================================================
_TEST_TMPDIRS=()

create_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-centrality-XXXXXX")
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init --quiet 2>/dev/null
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    touch "$tmpdir/.gitkeep"
    git -C "$tmpdir" add .gitkeep
    git -C "$tmpdir" commit -m "initial" --quiet 2>/dev/null
    echo "$tmpdir"
}

cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

# Helper: create N files that import/source the target module to control fan-in count.
# Args: $1 = repo dir, $2 = module name (without extension), $3 = fan-in count
create_importing_files() {
    local repo_dir="$1"
    local module_name="$2"
    local fan_in_count="$3"
    mkdir -p "$repo_dir/src/importers"
    for i in $(seq 1 "$fan_in_count"); do
        cat > "$repo_dir/src/importers/consumer_${i}.sh" << IMPEOF
#!/usr/bin/env bash
source ${module_name}
IMPEOF
    done
    # Stage the importing files so they're in the repo for grep to find
    git -C "$repo_dir" add -A
    git -C "$repo_dir" commit -m "add importing files" --quiet 2>/dev/null
}

# Helper: create a mock passing test runner
create_mock_pass_runner() {
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/mock-pass-XXXXXX")
    _TEST_TMPDIRS+=("$tmpfile")
    cat > "$tmpfile" << 'MOCKEOF'
#!/usr/bin/env bash
echo "PASSED (mock)"
exit 0
MOCKEOF
    chmod +x "$tmpfile"
    echo "$tmpfile"
}

# ============================================================
# test_high_centrality_triggers_full_suite
#
# When a staged file has fan-in > 8 (9 importing files), the
# script should run the full test suite, not just the associated
# test. Observable: tested_files in test-gate-status contains
# the full-suite sentinel test (not just the associated test).
# ============================================================
echo ""
echo "=== test_high_centrality_triggers_full_suite ==="
_snapshot_fail

REPO_HIGH=$(create_test_repo)
ARTIFACTS_HIGH=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-centrality-artifacts-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_HIGH")

# Create a source file with an associated test
mkdir -p "$REPO_HIGH/src" "$REPO_HIGH/tests"
cat > "$REPO_HIGH/src/central_module.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "central module"
SHEOF
chmod +x "$REPO_HIGH/src/central_module.sh"

# Associated test (the one found by fuzzy match)
cat > "$REPO_HIGH/tests/test-central-module.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "associated test passed"
exit 0
SHEOF
chmod +x "$REPO_HIGH/tests/test-central-module.sh"

# Full suite test (only run when centrality is high)
cat > "$REPO_HIGH/tests/test-full-suite-sentinel.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "full suite sentinel passed"
exit 0
SHEOF
chmod +x "$REPO_HIGH/tests/test-full-suite-sentinel.sh"

git -C "$REPO_HIGH" add -A
git -C "$REPO_HIGH" commit -m "add central_module" --quiet 2>/dev/null

echo "# changed" >> "$REPO_HIGH/src/central_module.sh"
git -C "$REPO_HIGH" add -A

# Configure test dirs to include both tests
mkdir -p "$REPO_HIGH/.claude"
printf 'test_gate.test_dirs=tests/\n' > "$REPO_HIGH/.claude/dso-config.conf"

# Create 9 files that import central_module (fan-in > threshold of 8)
create_importing_files "$REPO_HIGH" "central_module" 9

# Re-stage the source change (importing files commit reset it)
echo "# changed" >> "$REPO_HIGH/src/central_module.sh"
git -C "$REPO_HIGH" add -A

MOCK_PASS_HIGH=$(create_mock_pass_runner)

OUTPUT_HIGH=$(
    cd "$REPO_HIGH"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_HIGH" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_HIGH" \
    bash "$HOOK" 2>&1 || true
)

STATUS_FILE_HIGH="$ARTIFACTS_HIGH/test-gate-status"
TESTED_LINE_HIGH=""
if [[ -f "$STATUS_FILE_HIGH" ]]; then
    TESTED_LINE_HIGH=$(grep '^tested_files=' "$STATUS_FILE_HIGH" | head -1 | cut -d= -f2-)
fi

assert_contains \
    "test_high_centrality_triggers_full_suite: full-suite sentinel test in tested_files" \
    "test-full-suite-sentinel.sh" \
    "$TESTED_LINE_HIGH"

assert_pass_if_clean "test_high_centrality_triggers_full_suite"

# ============================================================
# test_low_centrality_runs_associated_only
#
# When a staged file has fan-in <= 8 (2 importing files), the
# script should run only the associated test, NOT the full suite.
# Observable: tested_files in test-gate-status does NOT contain
# the full-suite sentinel test.
# ============================================================
echo ""
echo "=== test_low_centrality_runs_associated_only ==="
_snapshot_fail

REPO_LOW=$(create_test_repo)
ARTIFACTS_LOW=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-centrality-artifacts-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_LOW")

mkdir -p "$REPO_LOW/src" "$REPO_LOW/tests"
cat > "$REPO_LOW/src/low_central.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "low centrality module"
SHEOF
chmod +x "$REPO_LOW/src/low_central.sh"

cat > "$REPO_LOW/tests/test-low-central.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "associated test passed"
exit 0
SHEOF
chmod +x "$REPO_LOW/tests/test-low-central.sh"

# Create a full-suite sentinel — this should NOT be run for low-centrality files
cat > "$REPO_LOW/tests/test-full-suite-sentinel.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "full suite sentinel"
exit 0
SHEOF
chmod +x "$REPO_LOW/tests/test-full-suite-sentinel.sh"

# Write a .test-index so we can precisely control what the "full suite" is
mkdir -p "$REPO_LOW/.claude"
cat > "$REPO_LOW/.claude/dso-config.conf" << 'CONF'
test_gate.test_dirs=tests/
CONF

git -C "$REPO_LOW" add -A
git -C "$REPO_LOW" commit -m "add low_central" --quiet 2>/dev/null

# Create 2 files that import low_central (fan-in below threshold of 8)
create_importing_files "$REPO_LOW" "low_central" 2

# Re-stage the source change (importing files commit reset it)
echo "# changed" >> "$REPO_LOW/src/low_central.sh"
git -C "$REPO_LOW" add -A

MOCK_PASS_LOW=$(create_mock_pass_runner)

OUTPUT_LOW=$(
    cd "$REPO_LOW"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_LOW" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_LOW" \
    bash "$HOOK" 2>&1 || true
)

STATUS_FILE_LOW="$ARTIFACTS_LOW/test-gate-status"
TESTED_LINE_LOW=""
if [[ -f "$STATUS_FILE_LOW" ]]; then
    TESTED_LINE_LOW=$(grep '^tested_files=' "$STATUS_FILE_LOW" | head -1 | cut -d= -f2-)
fi

# The associated test MUST have run
assert_contains \
    "test_low_centrality_runs_associated_only: associated test was run" \
    "test-low-central.sh" \
    "$TESTED_LINE_LOW"

# The full-suite sentinel must NOT appear in tested_files (low centrality = no full suite)
if [[ "$TESTED_LINE_LOW" == *"test-full-suite-sentinel.sh"* ]]; then
    (( ++FAIL ))
    printf "FAIL: test_low_centrality_runs_associated_only: full-suite sentinel should NOT be in tested_files\n  actual: %s\n" "$TESTED_LINE_LOW" >&2
else
    (( ++PASS ))
fi

assert_pass_if_clean "test_low_centrality_runs_associated_only"

# ============================================================
# test_missing_sg_gracefully_degrades
#
# When `sg` is not installed, centrality defaults to 0 and a
# warning is emitted to stderr. The script proceeds normally
# (only associated tests run). Observable:
#   - stderr contains "sg" and "not found" or "not installed"
#   - test-gate-status is still written correctly
#   - exit code is 0 when associated tests pass
# ============================================================
echo ""
echo "=== test_missing_sg_gracefully_degrades ==="
_snapshot_fail

REPO_NOSG=$(create_test_repo)
ARTIFACTS_NOSG=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-centrality-artifacts-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_NOSG")

mkdir -p "$REPO_NOSG/src" "$REPO_NOSG/tests"
cat > "$REPO_NOSG/src/greet_lib.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "greeting library"
SHEOF
chmod +x "$REPO_NOSG/src/greet_lib.sh"

cat > "$REPO_NOSG/tests/test-greet-lib.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "associated test passed"
exit 0
SHEOF
chmod +x "$REPO_NOSG/tests/test-greet-lib.sh"

mkdir -p "$REPO_NOSG/.claude"
cat > "$REPO_NOSG/.claude/dso-config.conf" << 'CONF'
test_gate.test_dirs=tests/
CONF

git -C "$REPO_NOSG" add -A
git -C "$REPO_NOSG" commit -m "add nosg_module" --quiet 2>/dev/null

echo "# changed" >> "$REPO_NOSG/src/greet_lib.sh"
git -C "$REPO_NOSG" add -A

# Build a PATH that excludes any directory containing `sg`.
# This ensures `command -v sg` fails in the hook — simulating sg not being installed.
# All other system binaries remain accessible.
_NO_SG_PATH=""
_orig_IFS="$IFS"
IFS=':'
for _path_dir in $PATH; do
    IFS="$_orig_IFS"
    if [[ -x "$_path_dir/sg" ]]; then
        # Skip directories that contain sg
        continue
    fi
    if [[ -z "$_NO_SG_PATH" ]]; then
        _NO_SG_PATH="$_path_dir"
    else
        _NO_SG_PATH="${_NO_SG_PATH}:${_path_dir}"
    fi
    IFS=':'
done
IFS="$_orig_IFS"

MOCK_PASS_NOSG=$(create_mock_pass_runner)

STDERR_NOSG=$(
    cd "$REPO_NOSG"
    PATH="$_NO_SG_PATH" \
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_NOSG" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_NOSG" \
    bash "$HOOK" 2>&1 1>/dev/null || true
)

STATUS_FILE_NOSG="$ARTIFACTS_NOSG/test-gate-status"

# After implementation, stderr must warn that centrality scoring is unavailable
# because sg is not installed (expected phrase: "centrality" + context about sg).
assert_contains \
    "test_missing_sg_gracefully_degrades: stderr warns sg not available" \
    "sg" \
    "$STDERR_NOSG"

assert_contains \
    "test_missing_sg_gracefully_degrades: stderr mentions centrality scoring disabled" \
    "centrality" \
    "$STDERR_NOSG"

# The script must still write a valid status file (graceful degradation)
STATUS_FIRST_LINE_NOSG=""
if [[ -f "$STATUS_FILE_NOSG" ]]; then
    STATUS_FIRST_LINE_NOSG=$(head -1 "$STATUS_FILE_NOSG")
fi
assert_eq \
    "test_missing_sg_gracefully_degrades: status file written with passed status" \
    "passed" \
    "$STATUS_FIRST_LINE_NOSG"

assert_pass_if_clean "test_missing_sg_gracefully_degrades"

# ============================================================
# test_status_file_format_preserved_for_full_suite
#
# When centrality > 8 triggers a full suite run, the test-gate-status
# file must still conform to the 4-line format:
#   Line 1: passed | failed | timeout | partial
#   Line 2: diff_hash=<sha256>
#   Line 3: timestamp=<ISO8601>
#   Line 4: tested_files=<comma-separated>
#
# Observable: all four expected fields present in status file after
# a high-centrality full-suite run.
#
# ============================================================
echo ""
echo "=== test_status_file_format_preserved_for_full_suite ==="
_snapshot_fail

REPO_FMT=$(create_test_repo)
ARTIFACTS_FMT=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-centrality-artifacts-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_FMT")

mkdir -p "$REPO_FMT/src" "$REPO_FMT/tests"
cat > "$REPO_FMT/src/format_module.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "format test module"
SHEOF
chmod +x "$REPO_FMT/src/format_module.sh"

cat > "$REPO_FMT/tests/test-format-module.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "associated test passed"
exit 0
SHEOF
chmod +x "$REPO_FMT/tests/test-format-module.sh"

cat > "$REPO_FMT/tests/test-format-sentinel.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "full suite sentinel passed"
exit 0
SHEOF
chmod +x "$REPO_FMT/tests/test-format-sentinel.sh"

mkdir -p "$REPO_FMT/.claude"
cat > "$REPO_FMT/.claude/dso-config.conf" << 'CONF'
test_gate.test_dirs=tests/
CONF

git -C "$REPO_FMT" add -A
git -C "$REPO_FMT" commit -m "add format_module" --quiet 2>/dev/null

# Create 10 files that import format_module (well above threshold)
create_importing_files "$REPO_FMT" "format_module" 10

# Re-stage the source change (importing files commit reset it)
echo "# changed" >> "$REPO_FMT/src/format_module.sh"
git -C "$REPO_FMT" add -A

MOCK_PASS_FMT=$(create_mock_pass_runner)

(
    cd "$REPO_FMT"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_FMT" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_FMT" \
    bash "$HOOK" 2>/dev/null || true
)

STATUS_FILE_FMT="$ARTIFACTS_FMT/test-gate-status"

# Status file must exist
if [[ -f "$STATUS_FILE_FMT" ]]; then
    # Line 1: status word
    LINE1=$(sed -n '1p' "$STATUS_FILE_FMT")
    VALID_STATUS="no"
    case "$LINE1" in
        passed|failed|timeout|partial) VALID_STATUS="yes" ;;
    esac
    assert_eq \
        "test_status_file_format_preserved_for_full_suite: line1 is valid status word" \
        "yes" \
        "$VALID_STATUS"

    # Line 2: diff_hash=<value>
    LINE2=$(sed -n '2p' "$STATUS_FILE_FMT")
    HASH_PREFIX="${LINE2:0:10}"
    assert_eq \
        "test_status_file_format_preserved_for_full_suite: line2 starts with diff_hash=" \
        "diff_hash=" \
        "$HASH_PREFIX"

    # Line 3: timestamp= present
    LINE3=$(sed -n '3p' "$STATUS_FILE_FMT")
    TS_PREFIX="${LINE3:0:10}"
    assert_eq \
        "test_status_file_format_preserved_for_full_suite: line3 starts with timestamp=" \
        "timestamp=" \
        "$TS_PREFIX"

    # Line 4: tested_files= present
    LINE4=$(sed -n '4p' "$STATUS_FILE_FMT")
    TF_PREFIX="${LINE4:0:13}"
    assert_eq \
        "test_status_file_format_preserved_for_full_suite: line4 starts with tested_files=" \
        "tested_files=" \
        "$TF_PREFIX"

    # The full-suite sentinel must appear in tested_files (confirming full suite ran)
    TESTED_LINE_FMT=$(grep '^tested_files=' "$STATUS_FILE_FMT" | head -1 | cut -d= -f2-)
    assert_contains \
        "test_status_file_format_preserved_for_full_suite: full-suite sentinel in tested_files" \
        "test-format-sentinel.sh" \
        "$TESTED_LINE_FMT"
else
    # No status file means the full suite was never triggered — RED
    assert_eq \
        "test_status_file_format_preserved_for_full_suite: status file exists after high-centrality run" \
        "exists" \
        "missing"
fi

assert_pass_if_clean "test_status_file_format_preserved_for_full_suite"

# ============================================================
# test_full_suite_failure_records_failed
#
# When full suite is triggered (high centrality) and the runner
# exits with code 1, the status file should say "failed".
# ============================================================
echo ""
echo "=== test_full_suite_failure_records_failed ==="
_snapshot_fail

REPO_FAIL=$(create_test_repo)
ARTIFACTS_FAIL=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-centrality-artifacts-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_FAIL")

mkdir -p "$REPO_FAIL/src" "$REPO_FAIL/tests"
cat > "$REPO_FAIL/src/fail_module.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "fail module"
SHEOF
chmod +x "$REPO_FAIL/src/fail_module.sh"

cat > "$REPO_FAIL/tests/test-fail-module.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "associated test"
exit 0
SHEOF
chmod +x "$REPO_FAIL/tests/test-fail-module.sh"

mkdir -p "$REPO_FAIL/.claude"
printf 'test_gate.test_dirs=tests/\n' > "$REPO_FAIL/.claude/dso-config.conf"

git -C "$REPO_FAIL" add -A
git -C "$REPO_FAIL" commit -m "add fail_module" --quiet 2>/dev/null

# Create 10 importing files for high centrality
create_importing_files "$REPO_FAIL" "fail_module" 10

echo "# changed" >> "$REPO_FAIL/src/fail_module.sh"
git -C "$REPO_FAIL" add -A

# Create a mock runner that exits 1 (failure)
MOCK_FAIL_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-fail-XXXXXX")
_TEST_TMPDIRS+=("$MOCK_FAIL_RUNNER")
cat > "$MOCK_FAIL_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
echo "FAILED (mock)"
exit 1
MOCKEOF
chmod +x "$MOCK_FAIL_RUNNER"

(
    cd "$REPO_FAIL"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_FAIL" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_FAIL_RUNNER" \
    bash "$HOOK" 2>/dev/null || true
)

STATUS_FILE_FAIL="$ARTIFACTS_FAIL/test-gate-status"
STATUS_LINE_FAIL=""
if [[ -f "$STATUS_FILE_FAIL" ]]; then
    STATUS_LINE_FAIL=$(head -1 "$STATUS_FILE_FAIL")
fi

assert_eq \
    "test_full_suite_failure_records_failed: status is 'failed'" \
    "failed" \
    "$STATUS_LINE_FAIL"

assert_pass_if_clean "test_full_suite_failure_records_failed"

# ============================================================
# test_full_suite_timeout_records_timeout
#
# When full suite is triggered (high centrality) and the runner
# exits with code 144, the status file should say "timeout".
# ============================================================
echo ""
echo "=== test_full_suite_timeout_records_timeout ==="
_snapshot_fail

REPO_TIMEOUT=$(create_test_repo)
ARTIFACTS_TIMEOUT=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-centrality-artifacts-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_TIMEOUT")

mkdir -p "$REPO_TIMEOUT/src" "$REPO_TIMEOUT/tests"
cat > "$REPO_TIMEOUT/src/timeout_module.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "timeout module"
SHEOF
chmod +x "$REPO_TIMEOUT/src/timeout_module.sh"

cat > "$REPO_TIMEOUT/tests/test-timeout-module.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "associated test"
exit 0
SHEOF
chmod +x "$REPO_TIMEOUT/tests/test-timeout-module.sh"

mkdir -p "$REPO_TIMEOUT/.claude"
printf 'test_gate.test_dirs=tests/\n' > "$REPO_TIMEOUT/.claude/dso-config.conf"

git -C "$REPO_TIMEOUT" add -A
git -C "$REPO_TIMEOUT" commit -m "add timeout_module" --quiet 2>/dev/null

# Create 10 importing files for high centrality
create_importing_files "$REPO_TIMEOUT" "timeout_module" 10

echo "# changed" >> "$REPO_TIMEOUT/src/timeout_module.sh"
git -C "$REPO_TIMEOUT" add -A

# Create a mock runner that exits 144 (timeout)
MOCK_TIMEOUT_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-timeout-XXXXXX")
_TEST_TMPDIRS+=("$MOCK_TIMEOUT_RUNNER")
cat > "$MOCK_TIMEOUT_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
echo "TIMEOUT (mock)"
exit 144
MOCKEOF
chmod +x "$MOCK_TIMEOUT_RUNNER"

(
    cd "$REPO_TIMEOUT"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_TIMEOUT" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_TIMEOUT_RUNNER" \
    bash "$HOOK" 2>/dev/null || true
)

STATUS_FILE_TIMEOUT="$ARTIFACTS_TIMEOUT/test-gate-status"
STATUS_LINE_TIMEOUT=""
if [[ -f "$STATUS_FILE_TIMEOUT" ]]; then
    STATUS_LINE_TIMEOUT=$(head -1 "$STATUS_FILE_TIMEOUT")
fi

assert_eq \
    "test_full_suite_timeout_records_timeout: status is 'timeout'" \
    "timeout" \
    "$STATUS_LINE_TIMEOUT"

assert_pass_if_clean "test_full_suite_timeout_records_timeout"

# ============================================================
# test_full_suite_cmd_path
#
# When RECORD_TEST_STATUS_RUNNER is NOT set but commands.test
# is configured, the full suite runs via the _FULL_SUITE_CMD
# code path (array-split + direct execution).
# ============================================================
echo ""
echo "=== test_full_suite_cmd_path ==="
_snapshot_fail

REPO_CMD=$(create_test_repo)
ARTIFACTS_CMD=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-centrality-artifacts-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_CMD")

mkdir -p "$REPO_CMD/src" "$REPO_CMD/tests"
cat > "$REPO_CMD/src/core_lib.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "core library"
SHEOF
chmod +x "$REPO_CMD/src/core_lib.sh"

# Create sentinel test
cat > "$REPO_CMD/tests/test-full-suite-sentinel.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "full suite sentinel"
exit 0
SHEOF
chmod +x "$REPO_CMD/tests/test-full-suite-sentinel.sh"

# Create 10 files that reference core_lib (centrality > 8)
for i in $(seq 1 10); do
    cat > "$REPO_CMD/src/consumer_${i}.sh" << SHEOF
#!/usr/bin/env bash
source core_lib
SHEOF
done

mkdir -p "$REPO_CMD/.claude"
cat > "$REPO_CMD/.claude/dso-config.conf" << CONFEOF
test_gate.test_dirs=tests/
test_gate.centrality_threshold=8
commands.test=echo pass
CONFEOF

# Stage core_lib
(cd "$REPO_CMD" && git add src/core_lib.sh && git add -A)

# Run WITHOUT RECORD_TEST_STATUS_RUNNER — forces _FULL_SUITE_CMD path
(
    cd "$REPO_CMD" && \
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_CMD" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$HOOK" 2>/dev/null || true
)

STATUS_FILE_CMD="$ARTIFACTS_CMD/test-gate-status"
STATUS_LINE_CMD=""
if [[ -f "$STATUS_FILE_CMD" ]]; then
    STATUS_LINE_CMD=$(head -1 "$STATUS_FILE_CMD")
fi
assert_eq \
    "test_full_suite_cmd_path: status is 'passed' via commands.test" \
    "passed" \
    "$STATUS_LINE_CMD"

assert_pass_if_clean "test_full_suite_cmd_path"

print_summary
