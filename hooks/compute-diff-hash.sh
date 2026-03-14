#!/usr/bin/env bash
# .claude/hooks/compute-diff-hash.sh
# Computes a staging-invariant SHA-256 hash of all working tree changes.
# Includes working tree changes relative to the diff base and untracked file contents.
# Produces the same hash regardless of git staging state (git add).
# Excludes .tickets/ files from hash — ticket metadata changes must not invalidate code reviews.
#
# Usage:
#   HASH=$(.claude/hooks/compute-diff-hash.sh)
#   HASH=$(.claude/hooks/compute-diff-hash.sh --snapshot /tmp/untracked-snapshot.txt)
#
# Options:
#   --snapshot <file>  Save the untracked file list to <file> on first run.
#                      On subsequent runs, reuse the saved list instead of
#                      live `git ls-files --others`. This makes the hash
#                      deterministic within a review session regardless of
#                      concurrent file creation by sub-agents.
#
# Output: a single SHA-256 hex string on stdout

set -euo pipefail

# Parse optional --snapshot flag
SNAPSHOT_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --snapshot)
            SNAPSHOT_FILE="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Source shared dependency library for hash_stdin and get_artifacts_dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/deps.sh"

# Source config-driven path resolver (provides CFG_VISUAL_BASELINE_PATH, CFG_UNIT_SNAPSHOT_PATH, etc.)
source "$SCRIPT_DIR/lib/config-paths.sh"

# Anchor all git pathspec exclusions and file operations to the repo root,
# regardless of the caller's CWD. Without this, pathspecs like ':!app/.tickets/'
# resolve relative to CWD, producing different hashes when called from app/.
cd "$(git rev-parse --show-toplevel)"

# --- Checkpoint-aware diff base detection ---
# After a pre-compaction auto-save, HEAD points to the checkpoint commit.
# We need to diff against the pre-checkpoint base instead of HEAD to get
# the correct hash of the user's actual working tree changes.
#
# Strategy:
#   1. Primary: Read stored SHA from $ARTIFACTS_DIR/pre-checkpoint-base
#      (written by pre-compact-checkpoint.sh before the checkpoint commit)
#   2. Fallback: Walk HEAD backwards (max 10 commits) looking for checkpoint
#      commits, then use the parent of the first checkpoint found
#   3. Default: Use HEAD if no checkpoint detected

# Shared constant — must match the label used by pre-compact-checkpoint.sh
CHECKPOINT_LABEL='checkpoint: pre-compaction auto-save'
# Read config-driven checkpoint label (same resolution as pre-compact-checkpoint.sh)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
_READ_CONFIG="$CLAUDE_PLUGIN_ROOT/scripts/read-config.sh"
if [[ -n "$_READ_CONFIG" ]]; then
    _LABEL=$("$_READ_CONFIG" checkpoint.commit_label 2>/dev/null || echo '')
    [[ -n "$_LABEL" ]] && CHECKPOINT_LABEL="$_LABEL"
fi

MAX_WALK=10
DIFF_BASE="HEAD"

# Primary: read pre-checkpoint-base from artifacts dir
ARTIFACTS_DIR=$(get_artifacts_dir 2>/dev/null || echo "")
if [[ -n "$ARTIFACTS_DIR" && -f "$ARTIFACTS_DIR/pre-checkpoint-base" ]]; then
    STORED_SHA=$(cat "$ARTIFACTS_DIR/pre-checkpoint-base" 2>/dev/null || echo "")
    if [[ -n "$STORED_SHA" ]]; then
        # Validate: SHA must be a real commit and an ancestor of HEAD
        if git rev-parse --verify "$STORED_SHA^{commit}" &>/dev/null && \
           git merge-base --is-ancestor "$STORED_SHA" HEAD 2>/dev/null; then
            DIFF_BASE="$STORED_SHA"
        fi
    fi
fi

# Fallback: bounded commit walk searching for checkpoint commits
if [[ "$DIFF_BASE" == "HEAD" ]]; then
    WALK_SHA="HEAD"
    for (( _walk_i=0; _walk_i < MAX_WALK; _walk_i++ )); do
        COMMIT_MSG=$(git log -1 --format='%s' "$WALK_SHA" 2>/dev/null || echo "")
        if [[ "$COMMIT_MSG" == "$CHECKPOINT_LABEL" ]]; then
            # Found a checkpoint — use its parent as the diff base
            PARENT_SHA=$(git rev-parse "${WALK_SHA}^" 2>/dev/null || echo "")
            if [[ -n "$PARENT_SHA" ]] && git rev-parse --verify "$PARENT_SHA^{commit}" &>/dev/null; then
                DIFF_BASE="$PARENT_SHA"
            fi
            break
        fi
        # Move to parent commit
        NEXT_SHA=$(git rev-parse "${WALK_SHA}^" 2>/dev/null || echo "")
        if [[ -z "$NEXT_SHA" ]] || [[ "$NEXT_SHA" == "$WALK_SHA" ]]; then
            break  # Reached root commit
        fi
        WALK_SHA="$NEXT_SHA"
    done
fi

# Pathspec exclusions for non-reviewable files (binary, snapshots, images, docs)
EXCLUDE_PATHSPECS=(
    ':!.checkpoint-needs-review'
    ':!.tickets/'
    ':!.sync-state.json'
    ':!*.png' ':!*.jpg' ':!*.jpeg' ':!*.gif' ':!*.svg' ':!*.ico' ':!*.webp'
    ':!*.pdf' ':!*.docx'
)
# Add config-driven snapshot exclusions (visual baselines and unit snapshots)
if [[ -n "$CFG_VISUAL_BASELINE_PATH" ]]; then
    EXCLUDE_PATHSPECS+=(":!${CFG_VISUAL_BASELINE_PATH}")
fi
if [[ -n "$CFG_UNIT_SNAPSHOT_PATH" ]]; then
    EXCLUDE_PATHSPECS+=(":!${CFG_UNIT_SNAPSHOT_PATH}*.html")
fi

# Grep pattern to filter untracked non-reviewable files
# Build pattern dynamically from config-driven paths
NON_REVIEWABLE_PATTERN='^\.checkpoint-needs-review$|^\.tickets/|^\.sync-state\.json$|\.(png|jpg|jpeg|gif|svg|ico|webp|pdf|docx)$'
if [[ -n "$CFG_VISUAL_BASELINE_PATH" ]]; then
    _VBP_ESCAPED="${CFG_VISUAL_BASELINE_PATH//./\\.}"
    NON_REVIEWABLE_PATTERN="${NON_REVIEWABLE_PATTERN}|^${_VBP_ESCAPED}"
fi
if [[ -n "$CFG_UNIT_SNAPSHOT_PATH" ]]; then
    _USP_ESCAPED="${CFG_UNIT_SNAPSHOT_PATH//./\\.}"
    NON_REVIEWABLE_PATTERN="${NON_REVIEWABLE_PATTERN}|^${_USP_ESCAPED}.*\\.html$"
fi

# Build the untracked file list — either from snapshot or live query
_get_untracked_files() {
    if [[ -n "$SNAPSHOT_FILE" && -f "$SNAPSHOT_FILE" ]]; then
        # Reuse saved snapshot for deterministic hashing across calls
        cat "$SNAPSHOT_FILE"
    else
        # Live query
        local _live_list
        _live_list=$(git ls-files --others --exclude-standard 2>/dev/null | { grep -v -E "$NON_REVIEWABLE_PATTERN" || true; })
        # Save snapshot if requested and this is the first run (empty list is valid)
        if [[ -n "$SNAPSHOT_FILE" && ! -f "$SNAPSHOT_FILE" ]]; then
            echo "$_live_list" > "$SNAPSHOT_FILE"
        fi
        echo "$_live_list"
    fi
}

{
    git diff "$DIFF_BASE" -- "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true
    _get_untracked_files | while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        echo "untracked: $f"
        cat "$f" 2>/dev/null || true
    done
} | hash_stdin
