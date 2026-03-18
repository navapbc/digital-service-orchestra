#!/usr/bin/env bash
# tests/scripts/test-nohup-launch.sh
# Tests for scripts/nohup-launch.sh
#
# Usage: bash tests/scripts/test-nohup-launch.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

LAUNCH_SCRIPT="$DSO_PLUGIN_DIR/scripts/nohup-launch.sh"

echo "=== test-nohup-launch.sh ==="

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── Test: script exists and is executable ────────────────────────────────────
echo ""
echo "--- existence and permissions ---"
_snapshot_fail

if [[ -x "$LAUNCH_SCRIPT" ]]; then
    (( ++PASS ))
    echo "script is executable ... PASS"
else
    (( ++FAIL ))
    echo "FAIL: $LAUNCH_SCRIPT is not executable"
fi

assert_pass_if_clean "script exists and is executable"

# ── Test: entry format documentation ─────────────────────────────────────────
echo ""
echo "--- entry format documentation ---"
_snapshot_fail

doc_check=$(grep -c 'Entry Format' "$LAUNCH_SCRIPT" 2>/dev/null || true)
assert_ne "contains Entry Format header" "0" "$doc_check"

assert_pass_if_clean "entry format documented"

# ── Test: NOHUP_PROCESS_BUDGET reference ─────────────────────────────────────
echo ""
echo "--- process budget variable ---"
_snapshot_fail

budget_check=$(grep -c 'NOHUP_PROCESS_BUDGET' "$LAUNCH_SCRIPT" 2>/dev/null || true)
assert_ne "references NOHUP_PROCESS_BUDGET" "0" "$budget_check"

assert_pass_if_clean "NOHUP_PROCESS_BUDGET referenced"

# ── Test: PID registry directory reference ───────────────────────────────────
echo ""
echo "--- PID registry ---"
_snapshot_fail

registry_check=$(grep -c 'workflow-nohup-pids' "$LAUNCH_SCRIPT" 2>/dev/null || true)
assert_ne "references workflow-nohup-pids" "0" "$registry_check"

assert_pass_if_clean "PID registry referenced"

# ── Test: refuses to launch when budget exceeded ─────────────────────────────
echo ""
echo "--- budget exceeded ---"
_snapshot_fail

# Set an impossibly low budget so we always exceed it
OUTPUT_FILE="$TMPDIR_TEST/budget-exceeded-output.txt"
NOHUP_PROCESS_BUDGET=1 \
NOHUP_PID_DIR="$TMPDIR_TEST/pids-budget" \
    bash "$LAUNCH_SCRIPT" "$OUTPUT_FILE" -- echo hello 2>"$TMPDIR_TEST/budget-stderr.txt"
exit_code=$?

assert_eq "exits non-zero when budget exceeded" "1" "$exit_code"

stderr_content=$(cat "$TMPDIR_TEST/budget-stderr.txt")
assert_contains "stderr mentions budget" "budget" "$stderr_content"

# Should NOT have created an output file or entry
if [[ -d "$TMPDIR_TEST/pids-budget" ]] && ls "$TMPDIR_TEST/pids-budget"/*.entry >/dev/null 2>&1; then
    (( ++FAIL ))
    echo "FAIL: entry file should not be created when budget exceeded"
else
    (( ++PASS ))
fi

assert_pass_if_clean "budget exceeded blocks launch"

# ── Test: successful launch with high budget ─────────────────────────────────
echo ""
echo "--- successful launch ---"
_snapshot_fail

OUTPUT_FILE="$TMPDIR_TEST/success-output.txt"
NOHUP_PROCESS_BUDGET=99999 \
NOHUP_PID_DIR="$TMPDIR_TEST/pids-success" \
    bash "$LAUNCH_SCRIPT" "$OUTPUT_FILE" -- echo "test-output-marker" 2>"$TMPDIR_TEST/launch-stderr.txt"
launch_exit=$?

assert_eq "exits zero on successful launch" "0" "$launch_exit"

# Wait briefly for background task to complete
sleep 1

# Check that output file was created (nohup redirects there)
if [[ -f "$OUTPUT_FILE" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: output file not created at $OUTPUT_FILE"
fi

# Verify output file contains only the expected command output (not file paths)
if [[ -f "$OUTPUT_FILE" ]]; then
    output_content=$(cat "$OUTPUT_FILE")
    assert_contains "output contains command output" "test-output-marker" "$output_content"
    # Ensure output/exit-code file paths were NOT prepended to the command
    exitcode_file="${OUTPUT_FILE}.exitcode"
    if echo "$output_content" | grep -qF "$exitcode_file"; then
        (( ++FAIL ))
        echo "FAIL: output contains exit-code file path (bash -c positional arg bug)"
    else
        (( ++PASS ))
    fi
fi

# Check PID entry file was created
entry_count=$(ls "$TMPDIR_TEST/pids-success"/*.entry 2>/dev/null | wc -l | tr -d ' ')
assert_ne "at least one entry file created" "0" "$entry_count"

# Verify entry contains expected fields
if [[ "$entry_count" != "0" ]]; then
    entry_file=$(ls "$TMPDIR_TEST/pids-success"/*.entry 2>/dev/null | head -1)
    entry_content=$(cat "$entry_file")
    assert_contains "entry contains command" "echo" "$entry_content"
    assert_contains "entry contains output path" "$OUTPUT_FILE" "$entry_content"
fi

assert_pass_if_clean "successful launch"

# ── Test: no arguments shows usage ──────────────────────────────────────────
echo ""
echo "--- usage message ---"
_snapshot_fail

usage_output=$(bash "$LAUNCH_SCRIPT" 2>&1 || true)
assert_contains "shows usage on no args" "usage" "$(echo "$usage_output" | tr '[:upper:]' '[:lower:]')"

assert_pass_if_clean "usage message"

# ── Test: piped command produces non-empty output ────────────────────────────
echo ""
echo "--- piped command output ---"
_snapshot_fail

PIPE_OUTPUT_FILE="$TMPDIR_TEST/pipe-output.txt"
NOHUP_PROCESS_BUDGET=99999 \
NOHUP_PID_DIR="$TMPDIR_TEST/pids-pipe" \
    bash "$LAUNCH_SCRIPT" "$PIPE_OUTPUT_FILE" -- "echo pipe-marker | cat" 2>"$TMPDIR_TEST/pipe-stderr.txt"
pipe_launch_exit=$?

assert_eq "piped command launches successfully" "0" "$pipe_launch_exit"

# Wait briefly for background task to complete
sleep 2

# Output file must exist
if [[ -f "$PIPE_OUTPUT_FILE" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: output file not created for piped command at $PIPE_OUTPUT_FILE" >&2
fi

# Output file must contain exactly the marker — not an error about "command not found".
# The bug (line 85 in nohup-launch.sh) causes "${@:5}" to treat the piped command
# string as a literal executable name, producing a "command not found" error instead
# of running the pipeline. Verify the actual marker text appears without any error.
if [[ -f "$PIPE_OUTPUT_FILE" ]]; then
    pipe_output_content=$(cat "$PIPE_OUTPUT_FILE")
    # Must contain the expected output
    assert_contains "piped command output contains marker" "pipe-marker" "$pipe_output_content"
    # Must NOT contain a "command not found" error (which would be the bug symptom)
    if echo "$pipe_output_content" | grep -q "command not found"; then
        (( ++FAIL ))
        printf "FAIL: piped command output contains 'command not found' error (pipe not interpreted)\n  output: %s\n" "$pipe_output_content" >&2
    else
        (( ++PASS ))
    fi
fi

assert_pass_if_clean "piped command produces non-empty output"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
