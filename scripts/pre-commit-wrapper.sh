#!/usr/bin/env bash
set -uo pipefail
# lockpick-workflow/scripts/pre-commit-wrapper.sh — Generic pre-commit timeout wrapper
#
# Runs a command string with timeout detection and logging.
# This is a plugin-level generic script with no project-specific assumptions.
#
# Usage: pre-commit-wrapper.sh <hook_name> <timeout_secs> <command_string>
#
# Arguments:
#   hook_name       — descriptive name for the hook (used in logs)
#   timeout_secs    — threshold in seconds; if the command takes longer, it is logged as slow
#   command_string  — the full command to run via bash -c
#
# Example:
#   pre-commit-wrapper.sh format-check 30 "ruff check src/"
#
# Timeout detection:
#   - If command exceeds timeout_secs, logs to <artifacts_dir>/precommit-timeouts.log
#
# Config keys read from workflow-config.conf via read-config.sh:
#   session.artifact_prefix    — prefix for /tmp artifact dirs (fallback: <repo-name>-test-artifacts)
#
# Exit codes:
#   Passes through the command's exit code, with special handling:
#   124 — timeout (command killed by timeout)
#   143 — SIGTERM (128 + 15)
#   137 — SIGKILL (128 + 9)

set -uo pipefail

# ── Argument validation ──────────────────────────────────────────────────────
if [[ $# -lt 3 ]]; then
    echo "Usage: pre-commit-wrapper.sh <hook_name> <timeout_secs> <command_string>" >&2
    exit 1
fi

HOOK_NAME="$1"
TIMEOUT_SECS="$2"
COMMAND_STRING="$3"

# ── Numeric validation for TIMEOUT_SECS ─────────────────────────────────────
# TIMEOUT_SECS must be a positive integer. Non-numeric values (e.g. "abc",
# "3.14", "") or non-positive integers cause unpredictable bash arithmetic
# behaviour, so we reject them early with a clear error.
if [[ ! "$TIMEOUT_SECS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SECS" -le 0 ]]; then
    echo "ERROR: TIMEOUT_SECS must be a positive integer, got: '$TIMEOUT_SECS'" >&2
    exit 1
fi

# ── Plugin scripts resolution ────────────────────────────────────────────────
PLUGIN_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Config helper ────────────────────────────────────────────────────────────
_read_cfg() {
    local key="$1"
    bash "$PLUGIN_SCRIPTS/read-config.sh" "$key" 2>/dev/null || true
}

# ── Artifact directory setup ─────────────────────────────────────────────────
# Read artifact prefix from config; fall back to repo-basename + -test-artifacts
_artifact_prefix=$(_read_cfg session.artifact_prefix)
if [[ -z "$_artifact_prefix" ]]; then
    _repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "unknown")
    _artifact_prefix="$(basename "$_repo_root")-test-artifacts"
fi

WORKTREE_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "default")")
ARTIFACTS_DIR="/tmp/${_artifact_prefix}-${WORKTREE_NAME}"
mkdir -p "$ARTIFACTS_DIR"
TIMEOUT_LOG="$ARTIFACTS_DIR/precommit-timeouts.log"

# ── Run the command ──────────────────────────────────────────────────────────
START_TIME=$(date +%s)

bash -c "$COMMAND_STRING"
EXIT_CODE=$?

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# ── Timeout detection: slow but completed ────────────────────────────────────
if [[ "$DURATION" -gt "$TIMEOUT_SECS" ]]; then
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$TIMESTAMP | SLOW | $HOOK_NAME | ${DURATION}s (limit: ${TIMEOUT_SECS}s) | command: $COMMAND_STRING" >> "$TIMEOUT_LOG"
    echo "WARNING: $HOOK_NAME took ${DURATION}s (limit: ${TIMEOUT_SECS}s)"

# ── Timeout detection: killed by signal ──────────────────────────────────────
elif [[ $EXIT_CODE -eq 124 ]] || [[ $EXIT_CODE -eq 143 ]] || [[ $EXIT_CODE -eq 137 ]]; then
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$TIMESTAMP | KILLED | $HOOK_NAME | timeout at ${TIMEOUT_SECS}s | command: $COMMAND_STRING" >> "$TIMEOUT_LOG"
    echo "TIMEOUT: $HOOK_NAME was killed after ${TIMEOUT_SECS}s"
    exit 124
fi

exit $EXIT_CODE
