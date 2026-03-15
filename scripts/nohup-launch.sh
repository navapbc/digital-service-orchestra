#!/usr/bin/env bash
# lockpick-workflow/scripts/nohup-launch.sh
# Launch a background task with process budget enforcement and PID registry.
#
# Replaces ad-hoc `nohup` commands across agents and skills with a managed
# launcher that tracks PIDs, enforces a process budget, and writes entry
# files for downstream cleanup (see nohup-poll.sh, orphan-cleanup).
#
# Usage:
#   nohup-launch.sh <output-file> -- <command> [args...]
#
# Environment:
#   NOHUP_PROCESS_BUDGET  Max processes allowed (default: 3500)
#   NOHUP_PID_DIR         PID registry directory (default: /tmp/workflow-nohup-pids)
#   NOHUP_SESSION_ID      Session identifier for entry metadata (default: $$)
#
# Exit codes:
#   0  Task launched successfully
#   1  Budget exceeded or invalid arguments
#
# ── Entry Format ─────────────────────────────────────────────────────────────
# Each launched task gets a file: <NOHUP_PID_DIR>/<pid>.entry
# Fields are newline-delimited KEY=VALUE pairs:
#
#   PID=<process-id>
#   COMMAND=<full command string>
#   OUTPUT_FILE=<path to stdout/stderr capture file>
#   LAUNCH_TIMESTAMP=<ISO-8601 UTC timestamp>
#   SESSION_ID=<session identifier>
#   EXIT_CODE_FILE=<path to file that receives exit code on completion>
#
# Example:
#   PID=12345
#   COMMAND=make test-unit-only
#   OUTPUT_FILE=/tmp/test-output.txt
#   LAUNCH_TIMESTAMP=2026-03-14T15:45:27Z
#   SESSION_ID=98765
#   EXIT_CODE_FILE=/tmp/test-output.txt.exitcode
#
# The EXIT_CODE_FILE is written by the wrapper when the command completes.
# nohup-poll.sh and orphan cleanup scripts use these entries to determine
# task status and detect stale/recycled PIDs (via COMMAND + LAUNCH_TIMESTAMP).
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────
if [[ $# -lt 3 ]] || [[ "$2" != "--" ]]; then
    echo "Usage: nohup-launch.sh <output-file> -- <command> [args...]" >&2
    exit 1
fi

OUTPUT_FILE="$1"
shift 2  # skip output-file and --
COMMAND_ARGS=("$@")
COMMAND_STR="${COMMAND_ARGS[*]}"

# ── Configuration ────────────────────────────────────────────────────────────
: "${NOHUP_PROCESS_BUDGET:=3500}"
: "${NOHUP_PID_DIR:=/tmp/workflow-nohup-pids}"
: "${NOHUP_SESSION_ID:=$$}"

# ── Process budget check ────────────────────────────────────────────────────
current_procs=$(ps -u "$(whoami)" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$current_procs" -ge "$NOHUP_PROCESS_BUDGET" ]]; then
    echo "nohup-launch: process budget exceeded (current=$current_procs, budget=$NOHUP_PROCESS_BUDGET)" >&2
    exit 1
fi

# ── Prepare registry directory ───────────────────────────────────────────────
mkdir -p "$NOHUP_PID_DIR"

# ── Launch background task ───────────────────────────────────────────────────
EXIT_CODE_FILE="${OUTPUT_FILE}.exitcode"
LAUNCH_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Launch via nohup: run command, capture exit code to file
nohup bash -c '"${@:3}" > "$1" 2>&1; echo $? > "$2"' _ "$OUTPUT_FILE" "$EXIT_CODE_FILE" "${COMMAND_ARGS[@]}" &
TASK_PID=$!

# ── Write entry file ────────────────────────────────────────────────────────
ENTRY_FILE="$NOHUP_PID_DIR/${TASK_PID}.entry"
cat > "$ENTRY_FILE" <<EOF
PID=$TASK_PID
COMMAND=$COMMAND_STR
OUTPUT_FILE=$OUTPUT_FILE
LAUNCH_TIMESTAMP=$LAUNCH_TIMESTAMP
SESSION_ID=$NOHUP_SESSION_ID
EXIT_CODE_FILE=$EXIT_CODE_FILE
EOF

echo "$TASK_PID"
