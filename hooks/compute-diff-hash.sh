#!/usr/bin/env bash
# .claude/hooks/compute-diff-hash.sh
# Computes a staging-invariant SHA-256 hash of all working tree changes.
# Includes working tree changes relative to the diff base and untracked file contents.
# Produces the same hash regardless of git staging state (git add).
# Excludes .tickets/ files (issue tracker metadata shouldn't affect code hashes).
#
# Usage:
#   HASH=$(.claude/hooks/compute-diff-hash.sh)
#
# Output: a single SHA-256 hex string on stdout

set -euo pipefail

# Source shared dependency library for hash_stdin and get_artifacts_dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/deps.sh"

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
_READ_CONFIG=""
if [[ -f "$SCRIPT_DIR/../scripts/read-config.sh" ]]; then
    _READ_CONFIG="$SCRIPT_DIR/../scripts/read-config.sh"
elif [[ -f "$SCRIPT_DIR/../../lockpick-workflow/scripts/read-config.sh" ]]; then
    _READ_CONFIG="$SCRIPT_DIR/../../lockpick-workflow/scripts/read-config.sh"
fi
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
    ':!.tickets/'
    ':!.checkpoint-needs-review'
    ':!app/tests/e2e/snapshots/'
    ':!app/tests/unit/templates/snapshots/*.html'
    ':!*.png' ':!*.jpg' ':!*.jpeg' ':!*.gif' ':!*.svg' ':!*.ico' ':!*.webp'
    ':!*.pdf' ':!*.docx'
)

# Grep pattern to filter untracked non-reviewable files
NON_REVIEWABLE_PATTERN='^\.tickets/|^\.checkpoint-needs-review$|^app/tests/e2e/snapshots/|^app/tests/unit/templates/snapshots/.*\.html$|\.(png|jpg|jpeg|gif|svg|ico|webp|pdf|docx)$'

{
    git diff "$DIFF_BASE" -- "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null | { grep -v -E "$NON_REVIEWABLE_PATTERN" || true; } | while IFS= read -r f; do
        echo "untracked: $f"
        cat "$f" 2>/dev/null || true
    done
} | hash_stdin
