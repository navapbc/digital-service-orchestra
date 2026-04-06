#!/usr/bin/env bash
# tests/scripts/test-validate-background.sh
# TDD tests for --background self-daemonize mode in validate.sh.
#
# Tests:
#   test_background_exits_in_under_5s      -- validate.sh --background exits quickly (< 5s)
#   test_background_produces_output_file   -- validate.sh --background creates output file
#   test_background_exit_0                 -- validate.sh --background exits 0
#   test_background_appears_in_help        -- --background appears in --help output
#   test_background_graceful_without_bgrsh -- exits 0 with warning when bg-run.sh unavailable
#
# Usage: bash tests/scripts/test-validate-background.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

VALIDATE_SH="$DSO_PLUGIN_DIR/scripts/validate.sh"

echo "=== test-validate-background.sh ==="

# Temp dirs
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── test_background_appears_in_help ──────────────────────────────────────────
_snapshot_fail

help_output=$(bash "$VALIDATE_SH" --help 2>&1)
assert_contains "test_background_appears_in_help" "--background" "$help_output"

assert_pass_if_clean "test_background_appears_in_help"

# ── test_background_exit_0 ────────────────────────────────────────────────────
# With a mock bg-run.sh in PATH, --background should exit 0 immediately.
_snapshot_fail

MOCK_DIR_EXIT0="$TMPDIR_TEST/mock_exit0"
mkdir -p "$MOCK_DIR_EXIT0"
WORKTREE_NAME_MOCK="test-worktree-bg"
EXPECTED_OUT="/tmp/validate-${WORKTREE_NAME_MOCK}.out"
EXPECTED_EXIT="/tmp/validate-${WORKTREE_NAME_MOCK}.exit"

# Create a mock bg-run.sh that records its invocation and exits 0
cat > "$MOCK_DIR_EXIT0/bg-run.sh" << 'MOCK_BGRSH'
#!/usr/bin/env bash
# Mock bg-run.sh — record invocation args and exit 0
echo "mock-bg-run called: $*" >> /tmp/mock-bg-run-calls.txt
exit 0
MOCK_BGRSH
chmod +x "$MOCK_DIR_EXIT0/bg-run.sh"

rc=0
PATH="$MOCK_DIR_EXIT0:$PATH" bash "$VALIDATE_SH" --background 2>&1 || rc=$?
assert_eq "test_background_exit_0 exits 0" "0" "$rc"

assert_pass_if_clean "test_background_exit_0"

# ── test_background_exits_in_under_5s ─────────────────────────────────────────
# --background must return control in under 5 seconds, regardless of how long
# the actual validation would take if run synchronously.
_snapshot_fail

MOCK_DIR_TIMING="$TMPDIR_TEST/mock_timing"
mkdir -p "$MOCK_DIR_TIMING"

# Create mock bg-run.sh that sleeps to simulate a long-running validate
cat > "$MOCK_DIR_TIMING/bg-run.sh" << 'MOCK_SLOW'
#!/usr/bin/env bash
# Mock bg-run.sh that simulates a slow background run (should not block caller)
sleep 60 &
exit 0
MOCK_SLOW
chmod +x "$MOCK_DIR_TIMING/bg-run.sh"

start_ts=$(date +%s)
rc=0
PATH="$MOCK_DIR_TIMING:$PATH" bash "$VALIDATE_SH" --background 2>&1 || rc=$?
end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))

assert_eq "test_background_exits_in_under_5s exits 0" "0" "$rc"

# Must exit in under 5 seconds (not wait for background work)
if [ "$elapsed" -lt 5 ]; then
    assert_eq "test_background_exits_in_under_5s elapsed < 5s" "true" "true"
else
    assert_eq "test_background_exits_in_under_5s elapsed < 5s" "true" "false (${elapsed}s)"
fi

assert_pass_if_clean "test_background_exits_in_under_5s"

# ── test_background_produces_output_file ──────────────────────────────────────
# When --background is invoked, bg-run.sh should be called with label
# validate-<worktree> and output file /tmp/validate-<worktree>.out.
# We stub bg-run.sh to capture the arguments and verify the output path is passed.
_snapshot_fail

MOCK_DIR_OUT="$TMPDIR_TEST/mock_out"
mkdir -p "$MOCK_DIR_OUT"

# Capture file to record what bg-run.sh was called with
CAPTURE_FILE="$TMPDIR_TEST/bg-run-args.txt"
rm -f "$CAPTURE_FILE"

cat > "$MOCK_DIR_OUT/bg-run.sh" << MOCK_CAP
#!/usr/bin/env bash
# Capture args to verify output file path is passed
echo "args: \$*" > "$CAPTURE_FILE"
exit 0
MOCK_CAP
chmod +x "$MOCK_DIR_OUT/bg-run.sh"

rc=0
PATH="$MOCK_DIR_OUT:$PATH" bash "$VALIDATE_SH" --background 2>&1 || rc=$?

assert_eq "test_background_produces_output_file exits 0" "0" "$rc"

# bg-run.sh should have been called (capture file exists)
if [ -f "$CAPTURE_FILE" ]; then
    captured_args=$(cat "$CAPTURE_FILE")
    # The output file should be /tmp/validate-<something>.out
    if [[ "$captured_args" =~ /tmp/validate-.+\.out ]]; then
        assert_eq "test_background_produces_output_file output path" "true" "true"
    else
        assert_eq "test_background_produces_output_file output path contains /tmp/validate-*.out" "true" "false (args: $captured_args)"
    fi
else
    assert_eq "test_background_produces_output_file bg-run.sh was invoked" "true" "false (capture file missing)"
fi

assert_pass_if_clean "test_background_produces_output_file"

# ── test_background_graceful_without_bgrsh ────────────────────────────────────
# When bg-run.sh is not in PATH, --background must exit 0 with a warning message
# (graceful degradation, per the task spec: "If bg-run.sh unavailable, exit 0 with warning").
_snapshot_fail

# Use a temp bin directory containing NO bg-run.sh, prepended to PATH.
# We keep standard system paths (/bin, /usr/bin, etc.) so the script can still
# run normally — only bg-run.sh is absent.
NO_BGRSH_DIR="$TMPDIR_TEST/no_bgrsh_bin"
mkdir -p "$NO_BGRSH_DIR"

rc=0
output=$(PATH="$NO_BGRSH_DIR:$PATH" bash "$VALIDATE_SH" --background 2>&1) || rc=$?

assert_eq "test_background_graceful_without_bgrsh exits 0" "0" "$rc"
assert_contains "test_background_graceful_without_bgrsh warning" "warning" "$(echo "$output" | tr '[:upper:]' '[:lower:]')"

assert_pass_if_clean "test_background_graceful_without_bgrsh"

echo ""
echo "=== test-validate-background.sh complete ==="
