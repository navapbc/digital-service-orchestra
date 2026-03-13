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

# Capture start time for telemetry duration_ms
if command -v perl &>/dev/null; then
    _START_MS=$(perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null || echo 0)
else
    _START_MS=$(( $(date +%s 2>/dev/null || echo 0) * 1000 ))
fi

# --- Telemetry writer ---
# Appends a single JSONL line to ~/.claude/precompact-telemetry.jsonl on every
# hook invocation (including early exits). No jq dependency — uses printf.
_TELEMETRY_FILE="$HOME/.claude/precompact-telemetry.jsonl"

_write_telemetry() {
    local hook_outcome="$1" exit_reason="$2"

    # Compute duration
    local end_ms
    if command -v perl &>/dev/null; then
        end_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null || echo 0)
    else
        end_ms=$(( $(date +%s 2>/dev/null || echo 0) * 1000 ))
    fi
    local duration_ms=$(( end_ms - _START_MS ))
    [[ $duration_ms -lt 0 ]] && duration_ms=0

    # Gather field values
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")

    local session_id="${CLAUDE_SESSION_ID:-unknown}"

    local parent_session_id_json="null"
    [[ -n "${CLAUDE_PARENT_SESSION_ID:-}" ]] && parent_session_id_json="\"$CLAUDE_PARENT_SESSION_ID\""

    local context_tokens_json="null"
    [[ -n "${CLAUDE_CONTEXT_WINDOW_TOKENS:-}" ]] && context_tokens_json="$CLAUDE_CONTEXT_WINDOW_TOKENS"

    local context_limit_json="null"
    [[ -n "${CLAUDE_CONTEXT_WINDOW_LIMIT:-}" ]] && context_limit_json="$CLAUDE_CONTEXT_WINDOW_LIMIT"

    local active_task_count=-1
    if command -v tk &>/dev/null; then
        active_task_count=$(tk list 2>/dev/null | grep -c in_progress 2>/dev/null || echo -1)
    fi

    local git_dirty=false
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        git_dirty=true
    fi

    local working_directory
    working_directory=$(pwd -P 2>/dev/null || pwd)

    # Write JSONL line (mkdir -p for safety)
    mkdir -p "$(dirname "$_TELEMETRY_FILE")" 2>/dev/null || true
    printf '{"timestamp":"%s","session_id":"%s","parent_session_id":%s,"context_tokens":%s,"context_limit":%s,"active_task_count":%s,"git_dirty":%s,"hook_outcome":"%s","exit_reason":"%s","working_directory":"%s","duration_ms":%s}\n' \
        "$timestamp" \
        "$session_id" \
        "$parent_session_id_json" \
        "$context_tokens_json" \
        "$context_limit_json" \
        "$active_task_count" \
        "$git_dirty" \
        "$hook_outcome" \
        "$exit_reason" \
        "$working_directory" \
        "$duration_ms" \
        >> "$_TELEMETRY_FILE" 2>/dev/null || true
}

# Log unexpected errors to JSONL and exit cleanly (never surface to user)
HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"pre-compact-checkpoint.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; _write_telemetry "exited_early" "error_trap"; exit 0' ERR

# Allow temporary disabling during commit workflows to prevent checkpoint loops.
# Supports both env var (for subshell calls) and file flag (for hook invocations
# which run in fresh shells without inheriting env vars).
[[ -n "${LOCKPICK_DISABLE_PRECOMPACT:-}" ]] && { _write_telemetry "exited_early" "env_var_disabled"; exit 0; }
REPO_ROOT_EARLY=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$REPO_ROOT_EARLY" && -f "$REPO_ROOT_EARLY/.disable-precompact-checkpoint" ]] && { _write_telemetry "exited_early" "file_disabled"; exit 0; }
# Sub-agent guard: orchestrator creates this file before Task dispatches; remove after batch completes
[[ -n "$REPO_ROOT_EARLY" && -f "$REPO_ROOT_EARLY/.disable-precompact-subagent" ]] && { _write_telemetry "exited_early" "subagent_guard"; exit 0; }

# Deduplication guard: prevent double-firing when hook is registered via both
# settings.json and hooks.json plugin manifest. Use a per-HEAD lockfile with a
# 120-second TTL — the second sequential invocation exits immediately.
_LOCK_KEY=$(git rev-parse HEAD 2>/dev/null | head -c 12 || echo "nohead")
_LOCK_FILE="${TMPDIR:-/tmp}/.precompact-lock-${_LOCK_KEY}"
_NOW=$(date +%s 2>/dev/null || echo 0)
if [[ -f "$_LOCK_FILE" ]]; then
    _LOCK_TIME=$(cat "$_LOCK_FILE" 2>/dev/null || echo 0)
    _AGE=$(( _NOW - _LOCK_TIME ))
    [[ $_AGE -lt 120 ]] && { _write_telemetry "exited_early" "dedup_lock"; exit 0; }
fi
echo "$_NOW" > "$_LOCK_FILE"
trap 'rm -f "$_LOCK_FILE"' EXIT

# --- Determine repo root ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
    # Not in a git repo; nothing useful to capture
    _write_telemetry "exited_early" "no_git_repo"
    exit 0
fi

# --- Disable sentinel ---
# If .disable-precompact-checkpoint exists at repo root, skip the hook entirely.
# Used to prevent checkpoint commits during worktree sessions with hook timing issues.
if [[ -f "$REPO_ROOT/.disable-precompact-checkpoint" ]]; then
    _write_telemetry "exited_early" "disable_sentinel"
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

# Read config-driven rollback marker filename (with fallback default)
CHECKPOINT_MARKER_FILE='.checkpoint-pending-rollback'
if [[ -n "$_READ_CONFIG" ]]; then
    _MARKER=$("$_READ_CONFIG" checkpoint.marker_file 2>/dev/null || echo '')
    [[ -n "$_MARKER" ]] && CHECKPOINT_MARKER_FILE="$_MARKER"
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
# Source deps.sh for get_artifacts_dir (hash-based artifact path)
_DEPS_SH="$HOOK_DIR/lib/deps.sh"
if [[ ! -f "$_DEPS_SH" ]]; then
    _DEPS_SH="$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
fi
if [[ -f "$_DEPS_SH" ]]; then
    source "$_DEPS_SH"
    DEBUG_STATE_FILE="$(get_artifacts_dir)/debug-phase-state.txt"
else
    # Fallback to old path if deps.sh not found
    WORKTREE_NAME=$(basename "$REPO_ROOT")
    DEBUG_STATE_FILE="/tmp/lockpick-test-artifacts-${WORKTREE_NAME}/debug-phase-state.txt"
fi
DEBUG_PHASE_STATE=""
if [[ -f "$DEBUG_STATE_FILE" ]]; then
    DEBUG_PHASE_STATE=$(cat "$DEBUG_STATE_FILE" 2>/dev/null || echo "(unreadable)")
fi

# --- Last 3 fix commits ---
RECENT_FIXES=$(git log --oneline -3 2>/dev/null || echo "(none)")

# --- Write pre-checkpoint-base for diff hash detection (Phase 2) ---
# Record current HEAD SHA *before* the checkpoint commit so that
# compute-diff-hash.sh can identify the pre-compaction base.
ARTIFACTS_DIR="$(get_artifacts_dir 2>/dev/null || echo "")"
if [[ -n "$ARTIFACTS_DIR" ]]; then
    _PRE_BASE_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [[ -n "$_PRE_BASE_SHA" ]]; then
        echo -n "$_PRE_BASE_SHA" > "$ARTIFACTS_DIR/pre-checkpoint-base"
    fi
fi

# --- Write checkpoint review sentinel ---
# Generate a random nonce and write .checkpoint-needs-review before the
# checkpoint commit. record-review.sh detects this file when recording a
# review and appends checkpoint_cleared=<nonce> to review-status.
# merge-to-main.sh verifies checkpoint_cleared before allowing the merge,
# ensuring that no code written during a compaction can bypass code review.
# Note: .checkpoint-needs-review is intentionally committed (not .gitignore'd).
# It must be tracked so git rm --cached can stage its removal inside record-review.sh,
# and so merge-to-main.sh can read its nonce from the commit tree after it's removed.
NONCE=$(openssl rand -hex 16 2>/dev/null || \
    echo "$(date +%s 2>/dev/null || echo 0)$RANDOM$RANDOM" | shasum -a 256 2>/dev/null | head -c 32 || \
    echo "$(date +%s 2>/dev/null || echo 0)$RANDOM$RANDOM" | sha256sum 2>/dev/null | head -c 32 || \
    echo "fallback-$(date -u +%Y%m%d%H%M%S)")

# --- Auto-save uncommitted work ---
# Skip the commit (and sentinel write) when there are no real changes to preserve.
# This prevents checkpoint spam in sub-agent contexts (Task tool agents compact their
# own contexts independently, sharing the same git worktree) and in idle orchestrator
# sessions where all work has already been committed. Sub-agent file changes (e.g.,
# reviewer-findings.json) survive compaction on disk without a git commit; Task agents
# do not resume across sessions so a checkpoint commit adds no recovery value for them.
#
# "Real changes" = anything except .checkpoint-needs-review.
# .tickets/ files are included — they now flow through normal commits (no separate sync hook).
# The sentinel is only meaningful when committed alongside actual code changes.
_HAS_REAL_CHANGES=$(git status --porcelain \
    -- ':!.checkpoint-needs-review' 2>/dev/null)

if [[ -z "$_HAS_REAL_CHANGES" ]]; then
    # Nothing meaningful to save — emit recovery state but skip the commit.
    # The sentinel is not written to avoid creating a false "unreviewed code" signal.
    _HOOK_OUTCOME="skipped"
    _EXIT_REASON="no_real_changes"
else
    # Real uncommitted work exists — write sentinel and commit.
    echo "$NONCE" > "$REPO_ROOT/.checkpoint-needs-review"

    # Capture the index state of the sentinel BEFORE git add -A so we can
    # restore a staged deletion (written by record-review.sh during /commit)
    # that git add -A would otherwise silently un-stage.
    _SENTINEL_INDEX=$(git status --porcelain -- .checkpoint-needs-review 2>/dev/null | head -1)

    # Stage everything except the sentinel; handle it explicitly below.
    # .tickets/ is included — tickets now flow through normal commits (no separate sync hook).
    git add -A -- ':!.checkpoint-needs-review' 2>/dev/null || true

    # Restore sentinel index state:
    if [[ "${_SENTINEL_INDEX:0:2}" == "D " ]]; then
        # record-review.sh had staged a deletion — preserve it so /commit can commit it.
        # REVIEW-DEFENSE: git add -A above would re-stage the file from working tree,
        # un-doing the staged deletion. We must restore the deletion explicitly.
        git rm --cached .checkpoint-needs-review 2>/dev/null || true
    else
        # Normal case — stage the newly written nonce.
        git add -- .checkpoint-needs-review 2>/dev/null || true
    fi

    git commit -m "$CHECKPOINT_LABEL" --no-verify 2>/dev/null || true
    # Write rollback marker so downstream hooks know a checkpoint needs unwinding.
    # The marker is .gitignore'd — it lives only in the working tree, never committed.
    echo "$(git rev-parse HEAD 2>/dev/null || echo unknown)" > "$REPO_ROOT/$CHECKPOINT_MARKER_FILE" 2>/dev/null || true
    _HOOK_OUTCOME="committed"
    _EXIT_REASON="committed"
fi

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

_write_telemetry "${_HOOK_OUTCOME:-skipped}" "${_EXIT_REASON:-unknown}"
exit 0
