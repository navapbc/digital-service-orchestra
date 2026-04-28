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

(
    cd "$REPO_HIGH" || exit
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_HIGH" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_HIGH" \
    bash "$HOOK" 2>/dev/null || true
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

(
    cd "$REPO_LOW" || exit
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_LOW" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_LOW" \
    bash "$HOOK" 2>/dev/null || true
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
# Capture bash path before PATH manipulation so the hook runs with the correct
# interpreter even if the directory containing `sg` also contains `bash`.
_BASH_PATH=$(command -v bash)
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

# Preserve essential binaries from sg-containing PATH dirs (EXCEPT sg itself).
# On Ubuntu, shadow-utils sg lives in /usr/bin/ alongside coreutils like
# dirname, cat, grep, sed — stripping that directory entirely would break
# the hook (which sources libs via dirname "${BASH_SOURCE[0]}"). We also
# preserve bash 4+ so env bash doesn't resolve to /bin/bash (3.2) which
# lacks declare -A support needed by record-test-status.sh.
_BASH_PRESERVE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bash-preserve-XXXXXX")
_TEST_TMPDIRS+=("$_BASH_PRESERVE_DIR")
_orig_IFS="$IFS"
IFS=':'
for _path_dir in $PATH; do
    IFS="$_orig_IFS"
    [[ -d "$_path_dir" && -x "$_path_dir/sg" ]] || { IFS=':'; continue; }
    for _bin in "$_path_dir"/*; do
        [[ -e "$_bin" ]] || continue
        _bname=${_bin##*/}
        [[ "$_bname" == "sg" ]] && continue
        [[ -e "$_BASH_PRESERVE_DIR/$_bname" ]] && continue
        ln -sf "$_bin" "$_BASH_PRESERVE_DIR/$_bname" 2>/dev/null || true
    done
    IFS=':'
done
IFS="$_orig_IFS"
_CURRENT_BASH=$(command -v bash)
if [[ -n "$_CURRENT_BASH" && ! -e "$_BASH_PRESERVE_DIR/bash" ]]; then
    ln -sf "$_CURRENT_BASH" "$_BASH_PRESERVE_DIR/bash"
fi
_NO_SG_PATH="${_BASH_PRESERVE_DIR}:${_NO_SG_PATH}"

MOCK_PASS_NOSG=$(create_mock_pass_runner)

STDERR_NOSG=$(
    cd "$REPO_NOSG" || exit
    PATH="$_NO_SG_PATH" \
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_NOSG" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_NOSG" \
    "$_BASH_PATH" "$HOOK" 2>&1 1>/dev/null || true
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
    cd "$REPO_FMT" || exit
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
    cd "$REPO_FAIL" || exit
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
    cd "$REPO_TIMEOUT" || exit
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

# ============================================================
# test_config_pattern_used_for_centrality
#
# When test_gate.import_pattern.bash is configured with a custom
# pattern (e.g., "require $MODULE") and 9+ files use that pattern,
# the hook should count them as importers and trigger the full suite.
#
# RED condition: count_centrality() ignores config patterns and uses
# only hardcoded patterns. Files using "require module_name" are NOT
# matched by hardcoded patterns, so centrality = 0, full suite is
# NOT triggered. After implementation the configured pattern is used,
# centrality = 9, full suite IS triggered.
#
# Observable: tested_files in test-gate-status contains the full-suite
# sentinel test (only present when full suite runs).
# ============================================================
echo ""
echo "=== test_config_pattern_used_for_centrality ==="
_snapshot_fail

REPO_CFG=$(create_test_repo)
ARTIFACTS_CFG=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-cfg-pattern-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_CFG")

mkdir -p "$REPO_CFG/src" "$REPO_CFG/tests"
cat > "$REPO_CFG/src/auth_helper.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "auth helper"
SHEOF
chmod +x "$REPO_CFG/src/auth_helper.sh"

cat > "$REPO_CFG/tests/test-auth-helper.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "associated test passed"
exit 0
SHEOF
chmod +x "$REPO_CFG/tests/test-auth-helper.sh"

cat > "$REPO_CFG/tests/test-full-suite-cfg-sentinel.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "full suite sentinel"
exit 0
SHEOF
chmod +x "$REPO_CFG/tests/test-full-suite-cfg-sentinel.sh"

# Configure a CUSTOM bash import pattern that the hardcoded defaults do NOT match.
# "require auth_helper" is NOT matched by the hardcoded grep pattern:
#   (import\s+auth_helper|from\s+auth_helper\s|source\s+(.*/)?auth_helper)
mkdir -p "$REPO_CFG/.claude"
cat > "$REPO_CFG/.claude/dso-config.conf" << 'CONF'
test_gate.test_dirs=tests/
test_gate.import_pattern.bash=require $MODULE
CONF

git -C "$REPO_CFG" add -A
git -C "$REPO_CFG" commit -m "add auth_helper" --quiet 2>/dev/null

# Create 9 files using "require auth_helper" — NOT matched by hardcoded patterns
mkdir -p "$REPO_CFG/src/consumers"
for i in $(seq 1 9); do
    cat > "$REPO_CFG/src/consumers/consumer_${i}.sh" << SHEOF
#!/usr/bin/env bash
require auth_helper
SHEOF
done
git -C "$REPO_CFG" add -A
git -C "$REPO_CFG" commit -m "add require-style consumers" --quiet 2>/dev/null

# Stage a change to the source module
echo "# changed" >> "$REPO_CFG/src/auth_helper.sh"
git -C "$REPO_CFG" add -A

MOCK_PASS_CFG=$(create_mock_pass_runner)

(
    cd "$REPO_CFG" || exit
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_CFG" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_CFG" \
    bash "$HOOK" 2>/dev/null || true
)

STATUS_FILE_CFG="$ARTIFACTS_CFG/test-gate-status"
TESTED_LINE_CFG=""
if [[ -f "$STATUS_FILE_CFG" ]]; then
    TESTED_LINE_CFG=$(grep '^tested_files=' "$STATUS_FILE_CFG" | head -1 | cut -d= -f2-)
fi

# After implementation, configured "require $MODULE" pattern matches 9 consumers,
# centrality > 8, full suite is triggered. Full-suite sentinel appears in tested_files.
# Currently (RED): hardcoded patterns don't match "require auth_helper", centrality=0,
# full suite is NOT triggered, sentinel is absent — this assertion FAILS.
assert_contains \
    "test_config_pattern_used_for_centrality: full-suite sentinel in tested_files when custom pattern matches 9 files" \
    "test-full-suite-cfg-sentinel.sh" \
    "$TESTED_LINE_CFG"

assert_pass_if_clean "test_config_pattern_used_for_centrality"

# ============================================================
# test_missing_config_patterns_falls_back_to_defaults
#
# When NO test_gate.import_pattern.* keys are present in config,
# the existing hardcoded grep patterns must still count centrality
# correctly (regression guard for fallback behavior).
#
# Observable: with 9+ files using standard "source module_name" and
# no config import_pattern keys, centrality > 8 triggers the full
# suite. tested_files contains the full-suite sentinel.
# ============================================================
echo ""
echo "=== test_missing_config_patterns_falls_back_to_defaults ==="
_snapshot_fail

REPO_NOKEY=$(create_test_repo)
ARTIFACTS_NOKEY=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-nokey-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_NOKEY")

mkdir -p "$REPO_NOKEY/src" "$REPO_NOKEY/tests"
cat > "$REPO_NOKEY/src/shared_lib.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "shared library"
SHEOF
chmod +x "$REPO_NOKEY/src/shared_lib.sh"

cat > "$REPO_NOKEY/tests/test-shared-lib.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "associated test passed"
exit 0
SHEOF
chmod +x "$REPO_NOKEY/tests/test-shared-lib.sh"

cat > "$REPO_NOKEY/tests/test-full-suite-nokey-sentinel.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "full suite sentinel"
exit 0
SHEOF
chmod +x "$REPO_NOKEY/tests/test-full-suite-nokey-sentinel.sh"

# Config has NO test_gate.import_pattern.* keys — only test dirs
mkdir -p "$REPO_NOKEY/.claude"
cat > "$REPO_NOKEY/.claude/dso-config.conf" << 'CONF'
test_gate.test_dirs=tests/
CONF

git -C "$REPO_NOKEY" add -A
git -C "$REPO_NOKEY" commit -m "add shared_lib" --quiet 2>/dev/null

# Create 9 files using the hardcoded "source module_name" pattern
create_importing_files "$REPO_NOKEY" "shared_lib" 9

# Re-stage the source change
echo "# changed" >> "$REPO_NOKEY/src/shared_lib.sh"
git -C "$REPO_NOKEY" add -A

MOCK_PASS_NOKEY=$(create_mock_pass_runner)

(
    cd "$REPO_NOKEY" || exit
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_NOKEY" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_NOKEY" \
    bash "$HOOK" 2>/dev/null || true
)

STATUS_FILE_NOKEY="$ARTIFACTS_NOKEY/test-gate-status"
TESTED_LINE_NOKEY=""
if [[ -f "$STATUS_FILE_NOKEY" ]]; then
    TESTED_LINE_NOKEY=$(grep '^tested_files=' "$STATUS_FILE_NOKEY" | head -1 | cut -d= -f2-)
fi

# Hardcoded "source shared_lib" pattern must still fire (fallback behavior).
# Full-suite sentinel appears in tested_files when centrality > 8.
assert_contains \
    "test_missing_config_patterns_falls_back_to_defaults: full-suite sentinel in tested_files via hardcoded fallback" \
    "test-full-suite-nokey-sentinel.sh" \
    "$TESTED_LINE_NOKEY"

assert_pass_if_clean "test_missing_config_patterns_falls_back_to_defaults"

# ============================================================
# test_cross_language_isolation
#
# When test_gate.import_pattern.python is configured, centrality
# scoring for a Python module counts Python importers.
# Files using a TypeScript-style "import { Foo } from 'module'"
# syntax that the hardcoded pattern does NOT match are used to
# demonstrate that the configured Python pattern is what drives
# centrality, not the file language of the staged file.
#
# Design: configure only test_gate.import_pattern.python=import $MODULE
# Stage a Python source file. Create 9+ Python files using
# "import data_processor" (standard Python import). Verify full suite.
#
# RED condition: count_centrality() ignores config patterns entirely
# and uses its own hardcoded combined pattern. Since the hardcoded
# pattern already matches "import data_processor", this test will
# PASS today via the hardcoded path — BUT it will fail RED only if
# we stage a file whose centrality depends EXCLUSIVELY on the
# configured Python pattern for a non-default file extension.
#
# To create a true RED: configure ONLY a Ruby pattern for .rb files.
# Stage a .sh file that has 9+ Ruby files importing it via "require".
# Hardcoded patterns don't scan for Ruby-style "require 'module'".
# After implementation, the Ruby pattern fires for the .rb importers.
#
# Observable: tested_files contains full-suite sentinel when
# configured Ruby pattern recognizes 9+ Ruby importers.
# ============================================================
echo ""
echo "=== test_cross_language_isolation ==="
_snapshot_fail

REPO_XLANG=$(create_test_repo)
ARTIFACTS_XLANG=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-xlang-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_XLANG")

mkdir -p "$REPO_XLANG/src" "$REPO_XLANG/tests" "$REPO_XLANG/src/ruby_consumers"
cat > "$REPO_XLANG/src/payment_core.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "payment core"
SHEOF
chmod +x "$REPO_XLANG/src/payment_core.sh"

cat > "$REPO_XLANG/tests/test-payment-core.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "associated test passed"
exit 0
SHEOF
chmod +x "$REPO_XLANG/tests/test-payment-core.sh"

cat > "$REPO_XLANG/tests/test-full-suite-xlang-sentinel.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "full suite sentinel"
exit 0
SHEOF
chmod +x "$REPO_XLANG/tests/test-full-suite-xlang-sentinel.sh"

# Configure a Ruby-language import pattern ONLY — no bash/python pattern configured.
# The hardcoded pattern does NOT include Ruby "require 'module'" syntax.
mkdir -p "$REPO_XLANG/.claude"
cat > "$REPO_XLANG/.claude/dso-config.conf" << 'CONF'
test_gate.test_dirs=tests/
test_gate.import_pattern.ruby=require '$MODULE'
CONF

git -C "$REPO_XLANG" add -A
git -C "$REPO_XLANG" commit -m "add payment_core" --quiet 2>/dev/null

# Create 9 Ruby files using "require 'payment_core'" — NOT matched by hardcoded patterns.
# Hardcoded pattern: (import\s+payment_core|from\s+payment_core\s|source\s+(.*/)?payment_core)
# with --include='*.rb'. Ruby "require 'payment_core'" does NOT match this pattern.
for i in $(seq 1 9); do
    cat > "$REPO_XLANG/src/ruby_consumers/consumer_${i}.rb" << SHEOF
require 'payment_core'
SHEOF
done
git -C "$REPO_XLANG" add -A
git -C "$REPO_XLANG" commit -m "add ruby consumers" --quiet 2>/dev/null

# Stage the bash source file
echo "# changed" >> "$REPO_XLANG/src/payment_core.sh"
git -C "$REPO_XLANG" add -A

MOCK_PASS_XLANG=$(create_mock_pass_runner)

(
    cd "$REPO_XLANG" || exit
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_XLANG" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_XLANG" \
    bash "$HOOK" 2>/dev/null || true
)

STATUS_FILE_XLANG="$ARTIFACTS_XLANG/test-gate-status"
TESTED_LINE_XLANG=""
if [[ -f "$STATUS_FILE_XLANG" ]]; then
    TESTED_LINE_XLANG=$(grep '^tested_files=' "$STATUS_FILE_XLANG" | head -1 | cut -d= -f2-)
fi

# After implementation: configured Ruby pattern "require '$MODULE'" matches 9 Ruby files,
# centrality = 9 > 8, full suite triggered, sentinel appears in tested_files.
# Currently (RED): hardcoded pattern doesn't match Ruby "require 'payment_core'",
# centrality = 0, full suite NOT triggered, sentinel absent — assertion FAILS.
assert_contains \
    "test_cross_language_isolation: full-suite sentinel in tested_files when configured Ruby pattern matches 9 importers" \
    "test-full-suite-xlang-sentinel.sh" \
    "$TESTED_LINE_XLANG"

assert_pass_if_clean "test_cross_language_isolation"

# ============================================================
# test_empty_config_pattern_falls_back
#
# When test_gate.import_pattern.bash is set to an empty value,
# the hook must fall back to hardcoded default patterns rather
# than using the empty pattern (which would match nothing).
#
# Observable: with 9+ files using standard "source module_name"
# and an empty bash import_pattern configured, centrality still
# reaches > 8 and the full suite is triggered.
# tested_files contains the full-suite sentinel.
# ============================================================
echo ""
echo "=== test_empty_config_pattern_falls_back ==="
_snapshot_fail

REPO_EMPTY=$(create_test_repo)
ARTIFACTS_EMPTY=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-empty-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_EMPTY")

mkdir -p "$REPO_EMPTY/src" "$REPO_EMPTY/tests"
cat > "$REPO_EMPTY/src/cache_layer.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "cache layer"
SHEOF
chmod +x "$REPO_EMPTY/src/cache_layer.sh"

cat > "$REPO_EMPTY/tests/test-cache-layer.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "associated test passed"
exit 0
SHEOF
chmod +x "$REPO_EMPTY/tests/test-cache-layer.sh"

cat > "$REPO_EMPTY/tests/test-full-suite-empty-sentinel.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "full suite sentinel"
exit 0
SHEOF
chmod +x "$REPO_EMPTY/tests/test-full-suite-empty-sentinel.sh"

# Configure test_gate.import_pattern.bash with an EMPTY value.
# After implementation, the hook must detect empty and fall back to hardcoded defaults.
mkdir -p "$REPO_EMPTY/.claude"
cat > "$REPO_EMPTY/.claude/dso-config.conf" << 'CONF'
test_gate.test_dirs=tests/
test_gate.import_pattern.bash=
CONF

git -C "$REPO_EMPTY" add -A
git -C "$REPO_EMPTY" commit -m "add cache_layer" --quiet 2>/dev/null

# Create 9 files using standard "source cache_layer" — matched by hardcoded patterns
create_importing_files "$REPO_EMPTY" "cache_layer" 9

# Re-stage the source change
echo "# changed" >> "$REPO_EMPTY/src/cache_layer.sh"
git -C "$REPO_EMPTY" add -A

MOCK_PASS_EMPTY=$(create_mock_pass_runner)

(
    cd "$REPO_EMPTY" || exit
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_EMPTY" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_EMPTY" \
    bash "$HOOK" 2>/dev/null || true
)

STATUS_FILE_EMPTY="$ARTIFACTS_EMPTY/test-gate-status"
TESTED_LINE_EMPTY=""
if [[ -f "$STATUS_FILE_EMPTY" ]]; then
    TESTED_LINE_EMPTY=$(grep '^tested_files=' "$STATUS_FILE_EMPTY" | head -1 | cut -d= -f2-)
fi

# Fallback to hardcoded patterns must fire: centrality = 9 > 8,
# full suite is triggered, sentinel appears in tested_files.
assert_contains \
    "test_empty_config_pattern_falls_back: full-suite sentinel in tested_files when empty pattern falls back to hardcoded defaults" \
    "test-full-suite-empty-sentinel.sh" \
    "$TESTED_LINE_EMPTY"

assert_pass_if_clean "test_empty_config_pattern_falls_back"

# ============================================================
# test_centrality_cached_per_diff_hash
#
# When the hook runs twice with the same staged files (same diff
# hash), the second run should use a cached centrality score.
# Observable: a cache file exists under
# $ARTIFACTS_DIR/centrality-cache-${DIFF_HASH}/ after the first run.
# When staged files change (different diff hash), the old cache
# directory is absent for the new hash.
#
# RED condition: no caching is implemented; the cache directory
# never appears. The assertion that it exists fails.
# ============================================================
echo ""
echo "=== test_centrality_cached_per_diff_hash ==="
_snapshot_fail

REPO_CACHE=$(create_test_repo)
ARTIFACTS_CACHE=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-cache-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_CACHE")

mkdir -p "$REPO_CACHE/src" "$REPO_CACHE/tests"
cat > "$REPO_CACHE/src/cache_module.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "cache module"
SHEOF
chmod +x "$REPO_CACHE/src/cache_module.sh"

cat > "$REPO_CACHE/tests/test-cache-module.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "associated test passed"
exit 0
SHEOF
chmod +x "$REPO_CACHE/tests/test-cache-module.sh"

mkdir -p "$REPO_CACHE/.claude"
printf 'test_gate.test_dirs=tests/\n' > "$REPO_CACHE/.claude/dso-config.conf"

git -C "$REPO_CACHE" add -A
git -C "$REPO_CACHE" commit -m "add cache_module" --quiet 2>/dev/null

echo "# changed" >> "$REPO_CACHE/src/cache_module.sh"
git -C "$REPO_CACHE" add -A

MOCK_PASS_CACHE=$(create_mock_pass_runner)

# First run
(
    cd "$REPO_CACHE" || exit
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_CACHE" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_CACHE" \
    bash "$HOOK" 2>/dev/null || true
)

# After first run: a centrality cache directory should exist for the current diff hash.
# The diff hash is captured from test-gate-status (computed by the hook itself).
DIFF_HASH_CACHE=""
if [[ -f "$ARTIFACTS_CACHE/test-gate-status" ]]; then
    DIFF_HASH_CACHE=$(grep '^diff_hash=' "$ARTIFACTS_CACHE/test-gate-status" | head -1 | cut -d= -f2-)
fi

CACHE_DIR_EXISTS="no"
if [[ -n "$DIFF_HASH_CACHE" ]] && [[ -d "$ARTIFACTS_CACHE/centrality-cache-${DIFF_HASH_CACHE}" ]]; then
    CACHE_DIR_EXISTS="yes"
fi

assert_eq \
    "test_centrality_cached_per_diff_hash: cache directory exists after first run" \
    "yes" \
    "$CACHE_DIR_EXISTS"

# Now change staged files to produce a different diff hash.
echo "# second change" >> "$REPO_CACHE/src/cache_module.sh"
git -C "$REPO_CACHE" add -A

# Second run (different hash)
(
    cd "$REPO_CACHE" || exit
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_CACHE" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_CACHE" \
    bash "$HOOK" 2>/dev/null || true
)

# The new hash should differ from the old one; old cache should be absent.
DIFF_HASH_CACHE2=""
if [[ -f "$ARTIFACTS_CACHE/test-gate-status" ]]; then
    DIFF_HASH_CACHE2=$(grep '^diff_hash=' "$ARTIFACTS_CACHE/test-gate-status" | head -1 | cut -d= -f2-)
fi

OLD_CACHE_ABSENT="yes"
if [[ -n "$DIFF_HASH_CACHE" ]] && [[ -d "$ARTIFACTS_CACHE/centrality-cache-${DIFF_HASH_CACHE}" ]]; then
    OLD_CACHE_ABSENT="no"
fi

assert_eq \
    "test_centrality_cached_per_diff_hash: old cache directory absent after hash change" \
    "yes" \
    "$OLD_CACHE_ABSENT"

assert_pass_if_clean "test_centrality_cached_per_diff_hash"

# ============================================================
# test_file_count_threshold_skips_centrality
#
# When more than test_gate.file_count_threshold (default 50) files
# are staged, the hook skips per-file centrality computation and
# runs the full test suite directly.
#
# Observable: $ARTIFACTS_DIR/centrality-log.jsonl contains a
# decision entry with "skipped_file_count".
#
# RED condition: no file count threshold logic is implemented;
# centrality-log.jsonl does not exist or lacks "skipped_file_count".
# ============================================================
echo ""
echo "=== test_file_count_threshold_skips_centrality ==="
_snapshot_fail

REPO_BIG=$(create_test_repo)
ARTIFACTS_BIG=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-bigset-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_BIG")

mkdir -p "$REPO_BIG/src" "$REPO_BIG/tests"

# Create the associated test
cat > "$REPO_BIG/tests/test-big-module.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "big module test passed"
exit 0
SHEOF
chmod +x "$REPO_BIG/tests/test-big-module.sh"

# Full-suite sentinel (only run when full suite is triggered)
cat > "$REPO_BIG/tests/test-big-sentinel.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "big sentinel passed"
exit 0
SHEOF
chmod +x "$REPO_BIG/tests/test-big-sentinel.sh"

mkdir -p "$REPO_BIG/.claude"
printf 'test_gate.test_dirs=tests/\n' > "$REPO_BIG/.claude/dso-config.conf"

git -C "$REPO_BIG" add -A
git -C "$REPO_BIG" commit -m "initial" --quiet 2>/dev/null

# Stage 51 source files (exceeds default threshold of 50)
mkdir -p "$REPO_BIG/src"
for i in $(seq 1 51); do
    printf '#!/usr/bin/env bash\necho "file %s"\n' "$i" > "$REPO_BIG/src/file_${i}.sh"
done
git -C "$REPO_BIG" add -A

MOCK_PASS_BIG=$(create_mock_pass_runner)

(
    cd "$REPO_BIG" || exit
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_BIG" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_BIG" \
    bash "$HOOK" 2>/dev/null || true
)

# centrality-log.jsonl must exist and contain "skipped_file_count"
CENTRALITY_LOG_BIG="$ARTIFACTS_BIG/centrality-log.jsonl"
LOG_CONTENT_BIG=""
if [[ -f "$CENTRALITY_LOG_BIG" ]]; then
    LOG_CONTENT_BIG=$(cat "$CENTRALITY_LOG_BIG")
fi

assert_contains \
    "test_file_count_threshold_skips_centrality: centrality-log.jsonl contains skipped_file_count decision" \
    "skipped_file_count" \
    "$LOG_CONTENT_BIG"

# Full suite must have run (sentinel in tested_files)
TESTED_LINE_BIG=""
if [[ -f "$ARTIFACTS_BIG/test-gate-status" ]]; then
    TESTED_LINE_BIG=$(grep '^tested_files=' "$ARTIFACTS_BIG/test-gate-status" | head -1 | cut -d= -f2-)
fi

assert_contains \
    "test_file_count_threshold_skips_centrality: full suite runs (sentinel in tested_files)" \
    "test-big-sentinel.sh" \
    "$TESTED_LINE_BIG"

assert_pass_if_clean "test_file_count_threshold_skips_centrality"

# ============================================================
# test_file_count_threshold_configurable
#
# test_gate.file_count_threshold is configurable. When set to 5:
#   - 6 staged files: centrality is skipped (full suite triggered)
#   - 4 staged files: centrality is computed normally
#
# Observable (above threshold): centrality-log.jsonl contains
# "skipped_file_count". (below threshold): centrality-log.jsonl
# does NOT contain "skipped_file_count" (or file is absent).
#
# RED condition: threshold config key is not read; both sub-cases
# fail because the threshold is always 50 (hardcoded default).
# ============================================================
echo ""
echo "=== test_file_count_threshold_configurable ==="
_snapshot_fail

# Sub-case A: 6 files staged, threshold=5 → skip centrality
REPO_THRESH_A=$(create_test_repo)
ARTIFACTS_THRESH_A=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-thresh-a-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_THRESH_A")

mkdir -p "$REPO_THRESH_A/src" "$REPO_THRESH_A/tests"
cat > "$REPO_THRESH_A/tests/test-thresh-sentinel.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "thresh sentinel passed"
exit 0
SHEOF
chmod +x "$REPO_THRESH_A/tests/test-thresh-sentinel.sh"

mkdir -p "$REPO_THRESH_A/.claude"
printf 'test_gate.test_dirs=tests/\ntest_gate.file_count_threshold=5\n' > "$REPO_THRESH_A/.claude/dso-config.conf"

git -C "$REPO_THRESH_A" add -A
git -C "$REPO_THRESH_A" commit -m "initial" --quiet 2>/dev/null

# Stage 6 files (above threshold of 5)
mkdir -p "$REPO_THRESH_A/src"
for i in $(seq 1 6); do
    printf '#!/usr/bin/env bash\necho "file %s"\n' "$i" > "$REPO_THRESH_A/src/tfile_${i}.sh"
done
git -C "$REPO_THRESH_A" add -A

MOCK_PASS_THRESH=$(create_mock_pass_runner)

(
    cd "$REPO_THRESH_A" || exit
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_THRESH_A" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_THRESH" \
    bash "$HOOK" 2>/dev/null || true
)

LOG_THRESH_A="$ARTIFACTS_THRESH_A/centrality-log.jsonl"
LOG_CONTENT_THRESH_A=""
if [[ -f "$LOG_THRESH_A" ]]; then
    LOG_CONTENT_THRESH_A=$(cat "$LOG_THRESH_A")
fi

assert_contains \
    "test_file_count_threshold_configurable: 6 files with threshold=5 logs skipped_file_count" \
    "skipped_file_count" \
    "$LOG_CONTENT_THRESH_A"

# Sub-case B: 4 files staged, threshold=5 → centrality computed (no skip)
REPO_THRESH_B=$(create_test_repo)
ARTIFACTS_THRESH_B=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-thresh-b-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_THRESH_B")

mkdir -p "$REPO_THRESH_B/src" "$REPO_THRESH_B/tests"
cat > "$REPO_THRESH_B/tests/test-thresh-b-sentinel.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "thresh b sentinel passed"
exit 0
SHEOF
chmod +x "$REPO_THRESH_B/tests/test-thresh-b-sentinel.sh"

mkdir -p "$REPO_THRESH_B/.claude"
printf 'test_gate.test_dirs=tests/\ntest_gate.file_count_threshold=5\n' > "$REPO_THRESH_B/.claude/dso-config.conf"

git -C "$REPO_THRESH_B" add -A
git -C "$REPO_THRESH_B" commit -m "initial" --quiet 2>/dev/null

# Stage 4 files (below threshold of 5)
mkdir -p "$REPO_THRESH_B/src"
for i in $(seq 1 4); do
    printf '#!/usr/bin/env bash\necho "file %s"\n' "$i" > "$REPO_THRESH_B/src/bfile_${i}.sh"
done
git -C "$REPO_THRESH_B" add -A

MOCK_PASS_THRESH_B=$(create_mock_pass_runner)

(
    cd "$REPO_THRESH_B" || exit
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_THRESH_B" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_THRESH_B" \
    bash "$HOOK" 2>/dev/null || true
)

LOG_THRESH_B="$ARTIFACTS_THRESH_B/centrality-log.jsonl"
LOG_CONTENT_THRESH_B=""
if [[ -f "$LOG_THRESH_B" ]]; then
    LOG_CONTENT_THRESH_B=$(cat "$LOG_THRESH_B")
fi

# With 4 files (below threshold), centrality is computed normally — no skip logged
if [[ "$LOG_CONTENT_THRESH_B" == *"skipped_file_count"* ]]; then
    (( ++FAIL ))
    printf "FAIL: test_file_count_threshold_configurable: 4 files with threshold=5 should NOT log skipped_file_count\n  actual log: %s\n" "$LOG_CONTENT_THRESH_B" >&2
else
    (( ++PASS ))
fi

assert_pass_if_clean "test_file_count_threshold_configurable"

# ============================================================
# test_centrality_cache_cleanup_on_hash_change
#
# When a cache entry exists for diff hash H1 and the staged files
# change (new diff hash H2), the hook must remove cache entries
# for H1 and create them for H2.
#
# Observable: after running with H2, $ARTIFACTS_DIR/centrality-cache-H1/
# directory no longer exists, and centrality-cache-H2/ does exist.
#
# RED condition: no cache cleanup logic exists; the old H1 directory
# persists after the H2 run.
# ============================================================
echo ""
echo "=== test_centrality_cache_cleanup_on_hash_change ==="
_snapshot_fail

REPO_CLEAN=$(create_test_repo)
ARTIFACTS_CLEAN=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-clean-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_CLEAN")

mkdir -p "$REPO_CLEAN/src" "$REPO_CLEAN/tests"
cat > "$REPO_CLEAN/src/cleanup_module.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "cleanup module"
SHEOF
chmod +x "$REPO_CLEAN/src/cleanup_module.sh"

cat > "$REPO_CLEAN/tests/test-cleanup-module.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "associated test passed"
exit 0
SHEOF
chmod +x "$REPO_CLEAN/tests/test-cleanup-module.sh"

mkdir -p "$REPO_CLEAN/.claude"
printf 'test_gate.test_dirs=tests/\n' > "$REPO_CLEAN/.claude/dso-config.conf"

git -C "$REPO_CLEAN" add -A
git -C "$REPO_CLEAN" commit -m "add cleanup_module" --quiet 2>/dev/null

# First staged change → diff hash H1
echo "# first change" >> "$REPO_CLEAN/src/cleanup_module.sh"
git -C "$REPO_CLEAN" add -A

MOCK_PASS_CLEAN=$(create_mock_pass_runner)

# First run → creates cache for H1
(
    cd "$REPO_CLEAN" || exit
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_CLEAN" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_CLEAN" \
    bash "$HOOK" 2>/dev/null || true
)

HASH_H1=""
if [[ -f "$ARTIFACTS_CLEAN/test-gate-status" ]]; then
    HASH_H1=$(grep '^diff_hash=' "$ARTIFACTS_CLEAN/test-gate-status" | head -1 | cut -d= -f2-)
fi

# Manually create the H1 cache dir (simulates it persisting from first run)
# so the test doesn't depend on caching being implemented to set up state.
if [[ -n "$HASH_H1" ]]; then
    mkdir -p "$ARTIFACTS_CLEAN/centrality-cache-${HASH_H1}"
    printf '{"file":"src/cleanup_module.sh","score":0,"hash":"%s"}\n' "$HASH_H1" \
        > "$ARTIFACTS_CLEAN/centrality-cache-${HASH_H1}/cleanup_module.sh.json"
fi

# Second staged change → produces diff hash H2 (different from H1)
echo "# second change" >> "$REPO_CLEAN/src/cleanup_module.sh"
git -C "$REPO_CLEAN" add -A

# Second run → should clean up H1 cache and create H2 cache
(
    cd "$REPO_CLEAN" || exit
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_CLEAN" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_CLEAN" \
    bash "$HOOK" 2>/dev/null || true
)

HASH_H2=""
if [[ -f "$ARTIFACTS_CLEAN/test-gate-status" ]]; then
    HASH_H2=$(grep '^diff_hash=' "$ARTIFACTS_CLEAN/test-gate-status" | head -1 | cut -d= -f2-)
fi

# Old H1 cache directory must no longer exist
H1_CACHE_GONE="yes"
if [[ -n "$HASH_H1" ]] && [[ -d "$ARTIFACTS_CLEAN/centrality-cache-${HASH_H1}" ]]; then
    H1_CACHE_GONE="no"
fi

assert_eq \
    "test_centrality_cache_cleanup_on_hash_change: old H1 cache directory removed after H2 run" \
    "yes" \
    "$H1_CACHE_GONE"

# New H2 cache directory must exist
H2_CACHE_EXISTS="no"
if [[ -n "$HASH_H2" ]] && [[ -d "$ARTIFACTS_CLEAN/centrality-cache-${HASH_H2}" ]]; then
    H2_CACHE_EXISTS="yes"
fi

assert_eq \
    "test_centrality_cache_cleanup_on_hash_change: new H2 cache directory created after H2 run" \
    "yes" \
    "$H2_CACHE_EXISTS"

assert_pass_if_clean "test_centrality_cache_cleanup_on_hash_change"

# ============================================================
# test_shadow_sg_rejected_by_discriminator
#
# When shadow-utils' sg (switch-group, not ast-grep) is in PATH,
# _is_astgrep_sg must reject it and the hook must fall back to
# grep-based centrality with a warning — same behavior as when
# sg is absent entirely. Bug 8282-6e7a.
#
# Observable: stderr warns centrality scoring is disabled (contains
# "sg" and "centrality"), and the status file is written (graceful
# degradation).
# ============================================================
echo ""
echo "=== test_shadow_sg_rejected_by_discriminator ==="
_snapshot_fail

REPO_SHADOW=$(create_test_repo)
ARTIFACTS_SHADOW=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-centrality-artifacts-XXXXXX")
_TEST_TMPDIRS+=("$ARTIFACTS_SHADOW")

# Create a fake sg binary that mimics shadow-utils' sg (switch-group):
# - Exists in PATH so `command -v sg` returns 0
# - Does NOT produce a version line matching "^(sg|ast-grep) [0-9]"
#   (shadow-utils sg exits non-zero with no version output, causing
#   _is_astgrep_sg's grep to fail and the function to return 1)
SHADOW_SG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/shadow-sg-XXXXXX")
_TEST_TMPDIRS+=("$SHADOW_SG_DIR")
cat > "$SHADOW_SG_DIR/sg" << 'SHEOF'
#!/usr/bin/env bash
# Simulates shadow-utils sg (switch-group) — not ast-grep.
# Produces no stdout output matching "^(sg|ast-grep) [0-9]".
echo "Usage: sg [-] [group [-c] command]" >&2
exit 1
SHEOF
chmod +x "$SHADOW_SG_DIR/sg"

mkdir -p "$REPO_SHADOW/src" "$REPO_SHADOW/tests"
cat > "$REPO_SHADOW/src/shadow_mod.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "shadow mod"
SHEOF
chmod +x "$REPO_SHADOW/src/shadow_mod.sh"
cat > "$REPO_SHADOW/tests/test-shadow-mod.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "passed"
exit 0
SHEOF
chmod +x "$REPO_SHADOW/tests/test-shadow-mod.sh"

mkdir -p "$REPO_SHADOW/.claude"
printf 'test_gate.test_dirs=tests/\n' > "$REPO_SHADOW/.claude/dso-config.conf"

git -C "$REPO_SHADOW" add -A
git -C "$REPO_SHADOW" commit -m "add shadow_mod" --quiet 2>/dev/null
echo "# changed" >> "$REPO_SHADOW/src/shadow_mod.sh"
git -C "$REPO_SHADOW" add -A

MOCK_PASS_SHADOW=$(create_mock_pass_runner)

# Prepend the shadow-utils sg dir so it wins `command -v sg` over real ast-grep sg.
STDERR_SHADOW=$(
    cd "$REPO_SHADOW" || exit
    PATH="$SHADOW_SG_DIR:$PATH" \
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_SHADOW" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_SHADOW" \
    "$_BASH_PATH" "$HOOK" 2>&1 1>/dev/null || true
)

STATUS_FILE_SHADOW="$ARTIFACTS_SHADOW/test-gate-status"

# _is_astgrep_sg must have rejected the shadow-utils sg: same warning as absent sg.
assert_contains \
    "test_shadow_sg_rejected_by_discriminator: stderr warns sg not available for centrality" \
    "sg" \
    "$STDERR_SHADOW"

assert_contains \
    "test_shadow_sg_rejected_by_discriminator: stderr mentions centrality scoring disabled" \
    "centrality" \
    "$STDERR_SHADOW"

# Graceful degradation: status file must still be written.
STATUS_FIRST_LINE_SHADOW=""
if [[ -f "$STATUS_FILE_SHADOW" ]]; then
    STATUS_FIRST_LINE_SHADOW=$(head -1 "$STATUS_FILE_SHADOW")
fi
assert_eq \
    "test_shadow_sg_rejected_by_discriminator: status file written with passed status" \
    "passed" \
    "$STATUS_FIRST_LINE_SHADOW"

assert_pass_if_clean "test_shadow_sg_rejected_by_discriminator"

print_summary
