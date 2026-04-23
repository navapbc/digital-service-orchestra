#!/usr/bin/env bash
# hooks/lib/pre-all-functions.sh
# Sourceable function definitions for the PreToolUse empty-matcher (pre-all) hooks.
#
# Each function follows the hook contract:
#   Input:  JSON string passed as $1
#   Return 0: allow — continue to next hook
#   Return 2: block/deny — dispatcher stops, outputs permissionDecision
#   stderr: warnings (always allowed; passed through by dispatcher)
#   stdout: permissionDecision message (only consumed when return 2)
#
# Functions defined:
#   hook_checkpoint_rollback — unwind a pre-compact checkpoint commit at HEAD
#
# Usage:
#   source hooks/lib/pre-all-functions.sh
#   hook_checkpoint_rollback "$INPUT_JSON"

# Guard: only load once
[[ "${_PRE_ALL_FUNCTIONS_LOADED:-}" == "1" ]] && return 0
_PRE_ALL_FUNCTIONS_LOADED=1

# Source shared dependency library (idempotent via its own guard)
_PRE_ALL_FUNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_PRE_ALL_FUNC_DIR/deps.sh"

# ---------------------------------------------------------------------------
# hook_checkpoint_rollback
# ---------------------------------------------------------------------------
# PreToolUse hook: unwind a pre-compact checkpoint commit when the rollback
# marker file is present.
#
# The pre-compact hook (pre-compact-checkpoint.sh) creates a checkpoint commit
# and writes a marker file (default: .checkpoint-pending-rollback) containing
# the checkpoint commit SHA. This hook detects that marker on the next tool
# call and rolls back the checkpoint via git reset --soft HEAD~1, preserving
# all files as staged. The marker is then removed.
#
# Fast path: if no marker file exists, returns immediately (zero overhead).
#
# Fail-open: any error logs to dso-hook-errors.jsonl and returns 0.
hook_checkpoint_rollback() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"checkpoint-rollback\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    # Resolve repo root
    local REPO_ROOT
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$REPO_ROOT" ]]; then
        return 0
    fi

    # Read marker filename from config (with fallback default)
    local MARKER_FILE=".checkpoint-pending-rollback"
    local _READ_CONFIG=""
    if [[ -f "$CLAUDE_PLUGIN_ROOT/scripts/read-config.sh" ]]; then
        _READ_CONFIG="$CLAUDE_PLUGIN_ROOT/scripts/read-config.sh"
    fi
    if [[ -n "$_READ_CONFIG" ]]; then
        local _MARKER
        _MARKER=$("$_READ_CONFIG" checkpoint.marker_file 2>/dev/null || echo '')
        [[ -n "$_MARKER" ]] && MARKER_FILE="$_MARKER"
    fi

    # Fast path: no marker file → no rollback needed
    if [[ ! -f "$REPO_ROOT/$MARKER_FILE" ]]; then
        return 0
    fi

    # Read checkpoint label from config (with fallback default)
    local CHECKPOINT_LABEL="checkpoint: pre-compaction auto-save"
    if [[ -n "$_READ_CONFIG" ]]; then
        local _LABEL
        _LABEL=$("$_READ_CONFIG" checkpoint.commit_label 2>/dev/null || echo '')
        [[ -n "$_LABEL" ]] && CHECKPOINT_LABEL="$_LABEL"
    fi

    # Verify HEAD commit message matches the checkpoint label
    local HEAD_MSG
    HEAD_MSG=$(git -C "$REPO_ROOT" log -1 --format=%s 2>/dev/null || echo "")

    if [[ "$HEAD_MSG" != *"$CHECKPOINT_LABEL"* ]]; then
        # Stale marker: HEAD is not a checkpoint commit.
        # Remove the marker and log a warning.
        rm -f "$REPO_ROOT/$MARKER_FILE"
        echo "WARNING [checkpoint-rollback]: Stale marker removed — HEAD message does not match checkpoint label." >&2
        return 0
    fi

    # Roll back the checkpoint commit, preserving staged files
    git -C "$REPO_ROOT" reset --soft HEAD~1 2>/dev/null || {
        echo "WARNING [checkpoint-rollback]: git reset --soft HEAD~1 failed." >&2
        return 0
    }

    # Remove the marker file
    rm -f "$REPO_ROOT/$MARKER_FILE"

    return 0
}
