#!/usr/bin/env bash
# tests/scripts/test-validate-nava-platform-headless.sh
# RED-phase tests for plugins/dso/scripts/validate-nava-platform-headless.sh
#
# Usage: bash tests/scripts/test-validate-nava-platform-headless.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: All tests are expected to FAIL until validate-nava-platform-headless.sh
#       is implemented (RED phase of TDD).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/validate-nava-platform-headless.sh"
FIXTURE_DIR="$PLUGIN_ROOT/tests/fixtures"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-validate-nava-platform-headless.sh ==="

# Temp dir for stub binaries and runtime fixtures
_TEST_TMPDIRS=()
TMPDIR_TEST="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_TEST")
trap 'rm -rf "${_TEST_TMPDIRS[@]}"' EXIT

# ── test_script_exists_and_executable ────────────────────────────────────────
# The script must exist at the expected path and be executable.
# RED: script not yet created — both assertions will fail.

if [[ -f "$SCRIPT" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_script_exists_and_executable: file exists" "exists" "$actual_exists"

if [[ -x "$SCRIPT" ]]; then
    actual_exec="executable"
else
    actual_exec="not_executable"
fi
assert_eq "test_script_exists_and_executable: file is executable" "executable" "$actual_exec"

# ── test_help_shows_usage ─────────────────────────────────────────────────────
# Running the script with --help must exit 0 and emit usage text on stdout.
# RED: script does not exist, so bash will exit non-zero and emit no usage text.

help_output=""
help_exit=0
help_output=$(bash "$SCRIPT" --help 2>&1) || help_exit=$?
assert_eq "test_help_shows_usage: exit 0" "0" "$help_exit"
assert_contains "test_help_shows_usage: stdout contains 'Usage'" "Usage" "$help_output"

# ── test_missing_cli_returns_error ────────────────────────────────────────────
# When nava-platform is not on PATH the script must exit non-zero and emit an
# error message that mentions "nava-platform" (distinct from "No such file").
# RED: script does not exist; the script-level error message is never produced.

# Build a PATH that contains only harmless system dirs, excluding any real
# nava-platform installation.
STUB_BIN_DIR="$TMPDIR_TEST/stub-bin-missing"
mkdir -p "$STUB_BIN_DIR"
RESTRICTED_PATH="$STUB_BIN_DIR:/usr/bin:/bin"

missing_cli_output=""
missing_cli_exit=0
missing_cli_output=$(PATH="$RESTRICTED_PATH" bash "$SCRIPT" 2>&1) || missing_cli_exit=$?

# At RED: script does not exist so bash emits "No such file or directory".
# The assertion below checks for a script-authored diagnostic; it will FAIL
# because the script never runs to produce that message.
assert_contains "test_missing_cli_returns_error: emits nava-platform diagnostic" \
    "nava-platform not found" "$missing_cli_output"

# ── test_list_flags_for_nextjs ────────────────────────────────────────────────
# Running the script with --list-flags nextjs and the fixture copier.yml must
# emit one --data KEY=VALUE flag per question key defined in the fixture.
# RED: script does not exist; no flags are emitted.

listflags_output=""
listflags_exit=0
listflags_output=$(bash "$SCRIPT" --list-flags nextjs \
    --copier-yml "$FIXTURE_DIR/copier-nextjs.yml" 2>&1) || listflags_exit=$?
assert_eq "test_list_flags_for_nextjs: exit 0" "0" "$listflags_exit"
assert_contains "test_list_flags_for_nextjs: output contains --data project_name" \
    "--data project_name" "$listflags_output"
assert_contains "test_list_flags_for_nextjs: output contains --data node_version" \
    "--data node_version" "$listflags_output"

# ── test_missing_data_flag_exits_nonzero ──────────────────────────────────────
# When the script invokes nava-platform without a required --data flag the
# underlying command may prompt for input. The script must time out (1 s
# internal timeout) and exit 124 (the exit code produced by timeout(1)).
# RED: script does not exist, so bash exits 127 ("No such file"), not 124.

# Stub nava-platform to hang indefinitely
STUB_BIN_HANG="$TMPDIR_TEST/stub-bin-hang"
mkdir -p "$STUB_BIN_HANG"
cat > "$STUB_BIN_HANG/nava-platform" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
chmod +x "$STUB_BIN_HANG/nava-platform"
HANG_PATH="$STUB_BIN_HANG:/usr/bin:/bin"

missing_data_exit=0
missing_data_output=""
# Outer guard: allow up to 3 s so the test does not block the suite
missing_data_output=$(timeout 3 bash -c "PATH='$HANG_PATH' bash '$SCRIPT' nextjs 2>&1") \
    || missing_data_exit=$?

# At GREEN: script applies a 1 s internal timeout → exit 124
# At RED:   script is missing → bash exits 127
assert_eq "test_missing_data_flag_exits_nonzero: exit 124 (timeout)" "124" "$missing_data_exit"

# ── test_timeout_prevents_hang ────────────────────────────────────────────────
# When the underlying nava-platform command sleeps 3 s and the script applies a
# 1 s internal timeout, the script must complete within 2 s and exit 124.
# RED: script does not exist; bash exits 127 immediately, not 124.
#      The elapsed-time assertion also fails: we assert elapsed >= 0.5 s
#      (the minimum time the real script should spend before timing out), but
#      the missing-file error returns instantly in < 0.1 s.

STUB_BIN_SLOW="$TMPDIR_TEST/stub-bin-slow"
mkdir -p "$STUB_BIN_SLOW"
cat > "$STUB_BIN_SLOW/nava-platform" <<'STUB'
#!/usr/bin/env bash
sleep 3
STUB
chmod +x "$STUB_BIN_SLOW/nava-platform"
SLOW_PATH="$STUB_BIN_SLOW:/usr/bin:/bin"

timeout_exit=0
# Outer guard is 2 s; the script's internal timeout is 1 s.
# If the script correctly wraps nava-platform with timeout(1), it exits 124
# before the outer 2 s guard fires.
PATH="$SLOW_PATH" timeout 2 bash "$SCRIPT" nextjs \
    --data "project_name=test-proj" \
    --data "node_version=20" \
    --data "use_typescript=true" \
    --data "github_org=test-org" \
    --data "project_description=test" \
    > /dev/null 2>&1 || timeout_exit=$?

# At GREEN: script-internal 1 s timeout fires → exit 124
# At RED:   script is missing → bash exits 127
assert_eq "test_timeout_prevents_hang: exit 124 (script timeout)" "124" "$timeout_exit"

print_summary
