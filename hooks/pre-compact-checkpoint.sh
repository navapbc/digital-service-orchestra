#!/usr/bin/env bash
# .claude/hooks/pre-compact-checkpoint.sh
# PreCompact hook: auto-save work state before context compaction.
#
# Captures mechanical state (git diff, active tasks)
# and outputs structured markdown that gets injected into post-compaction
# context for session recovery.
#
# Also auto-commits uncommitted work as a checkpoint so nothing is lost
# during compaction.

# Log unexpected errors to JSONL and exit cleanly (never surface to user)
HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"pre-compact-checkpoint.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# --- Determine repo root ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
    # Not in a git repo; nothing useful to capture
    exit 0
fi

# Read config-driven checkpoint label (with fallback default)
# Resolve read-config.sh: try HOOK_DIR/../scripts (lockpick-workflow/hooks/ path),
# then HOOK_DIR/../../lockpick-workflow/scripts (.claude/hooks/ path).
CHECKPOINT_LABEL='checkpoint: pre-compaction auto-save'
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_READ_CONFIG=""
if [[ -f "$HOOK_DIR/../scripts/read-config.sh" ]]; then
    _READ_CONFIG="$HOOK_DIR/../scripts/read-config.sh"
elif [[ -f "$HOOK_DIR/../../lockpick-workflow/scripts/read-config.sh" ]]; then
    _READ_CONFIG="$HOOK_DIR/../../lockpick-workflow/scripts/read-config.sh"
fi
if [[ -n "$_READ_CONFIG" ]]; then
    _LABEL=$("$_READ_CONFIG" checkpoint.commit_label 2>/dev/null || echo '')
    [[ -n "$_LABEL" ]] && CHECKPOINT_LABEL="$_LABEL"
fi

# --- Capture mechanical state ---

# Active tasks
ACTIVE_TASKS=""
if command -v tk &>/dev/null; then
    ACTIVE_TASKS=$(tk ready 2>/dev/null || echo "(tk unavailable)")
else
    ACTIVE_TASKS="(tk not installed)"
fi

# Git diff stat
GIT_DIFF_STAT=$(git diff --stat 2>/dev/null || echo "(no diff)")

# Git status short
GIT_STATUS=$(git status --short 2>/dev/null || echo "(no status)")

# --- Capture debug-everything phase state (if active) ---
WORKTREE_NAME=$(basename "$REPO_ROOT")
DEBUG_STATE_FILE="/tmp/lockpick-test-artifacts-${WORKTREE_NAME}/debug-phase-state.txt"
DEBUG_PHASE_STATE=""
if [[ -f "$DEBUG_STATE_FILE" ]]; then
    DEBUG_PHASE_STATE=$(cat "$DEBUG_STATE_FILE" 2>/dev/null || echo "(unreadable)")
fi

# --- Last 3 fix commits ---
RECENT_FIXES=$(git log --oneline -3 2>/dev/null || echo "(none)")

# --- Auto-save uncommitted work ---
# Exclude .tickets/ — these sync via their own dedicated mechanism
# (ticket-sync-push hook). Including them here caused 330+ spam ticket files
# to be committed in a single checkpoint (2026-03-04).
# (.sync-state.json now lives inside .tickets/ so is covered by this exclusion.)
git add -A 2>/dev/null || true
git reset HEAD -- .tickets/ 2>/dev/null || true
git commit -m "$CHECKPOINT_LABEL" --no-verify 2>/dev/null || true

# --- Output structured markdown (injected into post-compaction context) ---
cat <<CHECKPOINT
# Recovery State
Tasks: ${ACTIVE_TASKS:-None}
Changes: ${GIT_STATUS}
Checkpoint: ${CHECKPOINT_LABEL}
Debug phase: ${DEBUG_PHASE_STATE:-Not running}
Recent fixes: ${RECENT_FIXES}
Next: Run 'tk list' then 'tk show <id>' to find CHECKPOINT notes.
CHECKPOINT

exit 0
