#!/usr/bin/env bash
# .claude/hooks/pre-compact-checkpoint.sh
# PreCompact hook: auto-save work state before context compaction.
#
# Captures mechanical state (git diff, active beads tasks)
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

# Active beads tasks
ACTIVE_TASKS=""
if command -v bd &>/dev/null; then
    ACTIVE_TASKS=$(bd list --status=in_progress --quiet 2>/dev/null || echo "(bd unavailable)")
else
    ACTIVE_TASKS="(bd not installed)"
fi

# Git diff stat
GIT_DIFF_STAT=$(git diff --stat 2>/dev/null || echo "(no diff)")

# Git status short
GIT_STATUS=$(git status --short 2>/dev/null || echo "(no status)")

# --- Auto-save uncommitted work ---
git add -A 2>/dev/null || true
git commit -m "$CHECKPOINT_LABEL" --no-verify 2>/dev/null || true

# Sync beads if available
if command -v bd &>/dev/null; then
    bd sync --quiet 2>/dev/null || true
fi

# --- Output structured markdown (injected into post-compaction context) ---
cat <<CHECKPOINT
# Recovery State
Tasks: ${ACTIVE_TASKS:-None}
Changes: ${GIT_STATUS}
Checkpoint: ${CHECKPOINT_LABEL}
Next: See CLAUDE.md "Session recovery" section for steps.
CHECKPOINT

exit 0
