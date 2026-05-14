#!/usr/bin/env bash
# check-session-merge-only.sh
# Pre-commit hook: when .sprint-active or .debug-active is present, only accept merge commits.
# Rejects direct non-merge commits to the session/debug worktree during active-mode state.
#
# Exit codes:
#   0 — commit accepted (no active markers, is a merge commit, or all escape hatches cleared)
#   1 — rejected (non-merge commit with at least one active marker still set)
#
# Escape hatches (independent):
#   DSO_SPRINT_ACTIVE=0  — clears sprint-active enforcement; writes sprint-merge-only-bypass-*.log
#   DSO_DEBUG_ACTIVE=0   — clears debug-active enforcement; writes debug-merge-only-bypass-*.log
# AND semantics: when both .sprint-active and .debug-active present, BOTH vars must be 0 to permit commit.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SPRINT_ACTIVE_MARKER="$REPO_ROOT/.sprint-active"
DEBUG_ACTIVE_MARKER="$REPO_ROOT/.debug-active"

_sprint_active=0
_debug_active=0
[[ -f "$SPRINT_ACTIVE_MARKER" ]] && _sprint_active=1
[[ -f "$DEBUG_ACTIVE_MARKER" ]] && _debug_active=1

# No markers — hook inactive
if [[ $_sprint_active -eq 0 && $_debug_active -eq 0 ]]; then
    exit 0
fi

_artifacts_dir="${DSO_ARTIFACTS_DIR:-$REPO_ROOT/.claude/artifacts}"

# Sprint escape hatch (independent — only clears _sprint_active)
if [[ $_sprint_active -eq 1 && "${DSO_SPRINT_ACTIVE:-}" == "0" ]]; then
    mkdir -p "$_artifacts_dir"
    _log_file="$_artifacts_dir/sprint-merge-only-bypass-$(date +%Y%m%d-%H%M%S).log"
    echo "DSO_SPRINT_ACTIVE=0 bypass: $(date -u +%Y-%m-%dT%H:%M:%SZ) PID=$$" > "$_log_file"
    _sprint_active=0
fi

# Debug escape hatch (independent — only clears _debug_active)
if [[ $_debug_active -eq 1 && "${DSO_DEBUG_ACTIVE:-}" == "0" ]]; then
    mkdir -p "$_artifacts_dir"
    _log_file="$_artifacts_dir/debug-merge-only-bypass-$(date +%Y%m%d-%H%M%S).log"
    echo "DSO_DEBUG_ACTIVE=0 bypass: $(date -u +%Y-%m-%dT%H:%M:%SZ) PID=$$" > "$_log_file"
    _debug_active=0
fi

# Both cleared by escape hatches — allow
if [[ $_sprint_active -eq 0 && $_debug_active -eq 0 ]]; then
    exit 0
fi

# Merge commit detection: MERGE_HEAD file exists in git dir
GIT_DIR="$(git rev-parse --git-dir)"
if [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
    exit 0
fi

# Build active modes string for error message
_active_modes=""
[[ $_sprint_active -eq 1 ]] && _active_modes="sprint-active"
[[ $_debug_active -eq 1 ]] && { [[ -n "$_active_modes" ]] && _active_modes="$_active_modes + debug-active" || _active_modes="debug-active"; }

echo "ERROR: Direct commit to session worktree rejected (${_active_modes} mode)." >&2
echo "Commits must go through a story worktree and be merged into the session branch." >&2
[[ $_sprint_active -eq 1 ]] && echo "To bypass sprint enforcement: set DSO_SPRINT_ACTIVE=0" >&2
[[ $_debug_active -eq 1 ]] && echo "To bypass debug enforcement: set DSO_DEBUG_ACTIVE=0" >&2
exit 1
