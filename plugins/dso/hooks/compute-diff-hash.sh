#!/usr/bin/env bash
# .claude/hooks/compute-diff-hash.sh
# Computes a staging-invariant SHA-256 hash of all staged and tracked working tree changes.
# Includes changes in the git index (staged) and modifications to tracked files.
# Excludes untracked files — new files must be staged before review (per COMMIT-WORKFLOW.md).
# This prevents temp test fixtures from causing hash mismatches between review and pre-commit.
# Excludes .tickets-tracker/ files from hash — ticket metadata changes must not invalidate code reviews.
#
# Usage:
#   HASH=$(.claude/hooks/compute-diff-hash.sh)
#
# Output: a single SHA-256 hex string on stdout

set -euo pipefail

# --- Per-commit hash cache (1849-145d, 3bd1-6c02) ---
# During a single pre-commit run, multiple hooks call compute-diff-hash.sh.
# Cache the result keyed on repo path + git index mtime so repeated calls are instant.
_GIT_DIR_EARLY=$(git rev-parse --git-dir 2>/dev/null || echo ".git")
_REPO_ID=$(git rev-parse --show-toplevel 2>/dev/null | shasum -a 256 | cut -c1-12)
if [[ "$(uname)" == "Darwin" ]]; then
    _INDEX_MTIME=$(stat -f '%m' "$_GIT_DIR_EARLY/index" 2>/dev/null || echo "0")
    _INDEX_SIZE=$(stat -f '%z' "$_GIT_DIR_EARLY/index" 2>/dev/null || echo "0")
else
    _INDEX_MTIME=$(stat -c '%Y' "$_GIT_DIR_EARLY/index" 2>/dev/null || echo "0")
    _INDEX_SIZE=$(stat -c '%s' "$_GIT_DIR_EARLY/index" 2>/dev/null || echo "0")
fi
_CACHE_DIR="${TMPDIR:-/tmp}/compute-diff-hash-cache-${_REPO_ID}"
mkdir -p "$_CACHE_DIR" 2>/dev/null || true
# Cache key includes both mtime and file size to prevent second-resolution collisions
# when two git add operations occur within the same second (c3b6-7462)
_CACHE_KEY="${_CACHE_DIR}/hash-${_INDEX_MTIME}-${_INDEX_SIZE}"
if [ -f "$_CACHE_KEY" ]; then
    cat "$_CACHE_KEY"
    exit 0
fi

# Source shared dependency library for hash_stdin and get_artifacts_dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/deps.sh"

# Source shared merge/rebase state library
source "$SCRIPT_DIR/lib/merge-state.sh"

# Save original hash_stdin, then override to also write result to cache
_cdh_hash_stdin_inner() { shasum -a 256 | cut -d' ' -f1; }
hash_stdin() {
    local _result
    _result=$(_cdh_hash_stdin_inner)
    rm -f "${_CACHE_DIR}"/hash-* 2>/dev/null || true
    echo "$_result" > "$_CACHE_KEY" 2>/dev/null || true
    echo "$_result"
}

# Source config-driven path resolver (provides CFG_VISUAL_BASELINE_PATH, CFG_UNIT_SNAPSHOT_PATH, etc.)
source "$SCRIPT_DIR/lib/config-paths.sh"

# Anchor all git pathspec exclusions and file operations to the repo root,
# regardless of the caller's CWD. Without this, pathspecs like ':!app/.tickets-tracker/'
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
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" || ! -d "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib" ]]; then
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

# --- Load exclusion patterns from shared review-gate-allowlist.conf ---
# The allowlist is the single source of truth for non-reviewable file patterns.
# Falls back to hardcoded defaults if the allowlist is missing or helper functions
# are unavailable (graceful degradation for isolated test environments).
_ALLOWLIST_PATH="${CONF_OVERRIDE:-$SCRIPT_DIR/lib/review-gate-allowlist.conf}"
_ALLOWLIST_PATTERNS=""
_ALLOWLIST_LOADED=false
_HELPERS_AVAILABLE=false

# Check if the allowlist helper functions from deps.sh are available
if declare -f _load_allowlist_patterns &>/dev/null && \
   declare -f _allowlist_to_pathspecs &>/dev/null; then
    _HELPERS_AVAILABLE=true
fi

if [[ "$_HELPERS_AVAILABLE" == "true" ]]; then
    if _ALLOWLIST_PATTERNS=$(_load_allowlist_patterns "$_ALLOWLIST_PATH" 2>/dev/null); then
        _ALLOWLIST_LOADED=true
    fi
fi

# Fallback defaults when allowlist or helpers are unavailable
_FALLBACK_PATHSPECS=(
    ':!.checkpoint-needs-review'
    ':!.tickets-tracker/**'
    ':!.sync-state.json'
    ':!*.png' ':!*.jpg' ':!*.jpeg' ':!*.gif' ':!*.svg' ':!*.ico' ':!*.webp'
    ':!*.pdf' ':!*.docx'
    ':!docs/**'
    ':!.claude/docs/**'
    ':!.claude/session-logs/**'
)

if [[ "$_ALLOWLIST_LOADED" == "true" ]] && [[ -n "$_ALLOWLIST_PATTERNS" ]]; then
    # Build EXCLUDE_PATHSPECS array from allowlist patterns
    declare -a EXCLUDE_PATHSPECS
    while IFS= read -r _pathspec; do
        [[ -z "$_pathspec" ]] && continue
        EXCLUDE_PATHSPECS+=("$_pathspec")
    done <<< "$(_allowlist_to_pathspecs "$_ALLOWLIST_PATTERNS")"
else
    # Graceful degradation: use hardcoded fallback patterns
    declare -a EXCLUDE_PATHSPECS
    EXCLUDE_PATHSPECS+=("${_FALLBACK_PATHSPECS[@]}")
fi

# Add config-driven snapshot exclusions (visual baselines and unit snapshots) — ADDITIVE
if [[ -n "${CFG_VISUAL_BASELINE_PATH:-}" ]]; then
    EXCLUDE_PATHSPECS+=(":!${CFG_VISUAL_BASELINE_PATH}")
fi
if [[ -n "${CFG_UNIT_SNAPSHOT_PATH:-}" ]]; then
    EXCLUDE_PATHSPECS+=(":!${CFG_UNIT_SNAPSHOT_PATH}*.html")
fi

# Hash staged and tracked working-tree changes only.
# Untracked files are excluded to prevent temp test fixtures from causing hash
# mismatches between review time and pre-commit time (dso-fqxu).
# New files must be explicitly staged (git add) before running /dso:review so that
# they appear in `git diff HEAD` and are included in the hash at both review and
# pre-commit time (dso-g8cz: staging-invariant for new files).
#
# Merge/rebase-aware: when MERGE_HEAD or REBASE_HEAD exists, scope the diff to
# only files changed on the worktree branch, excluding incoming-only files.
# Detection and file-list computation delegated to shared merge-state.sh library.
# This matches the pre-commit review gate's MERGE_HEAD/REBASE_HEAD filtering
# (1ded-89e6) so the hash is consistent between review and commit time.
if ms_is_merge_in_progress; then
    # Merge state: compute worktree-branch files and merge base via library.
    # ms_get_worktree_only_files returns diff --name-only merge-base..HEAD.
    # ms_get_merge_base returns the merge-base SHA for use in the hash pipeline.
    _worktree_files=$(ms_get_worktree_only_files 2>/dev/null || echo "")
    _merge_base=$(ms_get_merge_base 2>/dev/null || echo "")
    if [[ -n "$_merge_base" ]]; then
        if [[ -n "$_worktree_files" ]]; then
            _file_pathspecs=()
            while IFS= read -r _f; do
                [[ -n "$_f" ]] && _file_pathspecs+=("$_f")
            done <<< "$_worktree_files"
            {
                git diff "$DIFF_BASE" -- "${_file_pathspecs[@]}" "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true
            } | hash_stdin
        else
            # No worktree-branch changes — hash an empty diff
            echo "" | hash_stdin
        fi
    else
        # merge-base failed — fall through to default behavior
        {
            git diff "$DIFF_BASE" -- "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true
        } | hash_stdin
    fi
elif ms_is_rebase_in_progress; then
    # Rebase state: compute worktree-branch files (merge-base..orig-head) and
    # merge base via library. Mirrors the MERGE_HEAD filtering above.
    _rebase_worktree_files=$(ms_get_worktree_only_files 2>/dev/null || echo "")
    _rebase_merge_base=$(ms_get_merge_base 2>/dev/null || echo "")
    if [[ -n "$_rebase_merge_base" ]]; then
        if [[ -n "$_rebase_worktree_files" ]]; then
            _rebase_file_pathspecs=()
            while IFS= read -r _f; do
                [[ -n "$_f" ]] && _rebase_file_pathspecs+=("$_f")
            done <<< "$_rebase_worktree_files"
            {
                git diff "$DIFF_BASE" -- "${_rebase_file_pathspecs[@]}" "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true
            } | hash_stdin
        else
            # No worktree-branch changes — hash an empty diff
            echo "" | hash_stdin
        fi
    else
        # merge-base failed — fall through to default behavior
        {
            git diff "$DIFF_BASE" -- "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true
        } | hash_stdin
    fi
else
    {
        git diff "$DIFF_BASE" -- "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true
    } | hash_stdin
fi
