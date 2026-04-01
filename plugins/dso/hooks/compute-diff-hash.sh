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

# Source shared dependency library for hash_stdin and get_artifacts_dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/deps.sh"

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
# Merge-aware: when MERGE_HEAD exists, scope the diff to only files changed on
# the worktree branch (merge-base..HEAD), excluding incoming-only files from the
# merge source. This matches the pre-commit review gate's MERGE_HEAD filtering
# (1ded-89e6) so the hash is consistent between review and commit time.
_GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
if [[ -f "$_GIT_DIR/MERGE_HEAD" ]]; then
    _merge_head_sha=$(head -1 "$_GIT_DIR/MERGE_HEAD" 2>/dev/null)
    _merge_head_resolved=$(git rev-parse "$_merge_head_sha" 2>/dev/null || echo "")
    _head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    # Guard: MERGE_HEAD must resolve to a real commit different from HEAD.
    # If MERGE_HEAD == HEAD (fake/self-referencing), skip merge-mode to prevent bypass.
    # In a real merge, MERGE_HEAD points to the incoming branch tip (different from HEAD).
    if [[ -n "$_merge_head_resolved" && "$_merge_head_resolved" != "$_head_sha" ]]; then
        _merge_base=$(git merge-base HEAD "$_merge_head_sha" 2>/dev/null || echo "")
        if [[ -n "$_merge_base" ]]; then
            # Only hash changes from the worktree branch (merge-base..HEAD + working tree)
            # This excludes incoming-only files from the merge source.
            _worktree_files=$(git diff --name-only "$_merge_base" HEAD 2>/dev/null || echo "")
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
    else
        # MERGE_HEAD == HEAD or unresolvable — skip merge-mode, use default behavior
        {
            git diff "$DIFF_BASE" -- "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true
        } | hash_stdin
    fi
elif [[ -f "$_GIT_DIR/REBASE_HEAD" ]]; then
    # Rebase-aware: when REBASE_HEAD exists, scope the diff to only files changed
    # on the worktree branch (merge-base..orig-head), excluding incoming-only files
    # from the onto branch. Mirrors the MERGE_HEAD filtering above.
    # Read onto and orig-head from rebase state dirs (rebase-merge takes precedence
    # over rebase-apply; do NOT use ORIG_HEAD ref which is per-repo, not per-worktree).
    # Use git rev-parse --git-dir for per-worktree path resolution.
    _rebase_git_dir=$(git rev-parse --git-dir 2>/dev/null)
    _rebase_onto=""
    _rebase_orig_head=""
    if [[ -f "$_rebase_git_dir/rebase-merge/onto" ]]; then
        _rebase_onto=$(cat "$_rebase_git_dir/rebase-merge/onto" 2>/dev/null || echo "")
        _rebase_orig_head=$(cat "$_rebase_git_dir/rebase-merge/orig-head" 2>/dev/null || echo "")
    elif [[ -f "$_rebase_git_dir/rebase-apply/onto" ]]; then
        _rebase_onto=$(cat "$_rebase_git_dir/rebase-apply/onto" 2>/dev/null || echo "")
        _rebase_orig_head=$(cat "$_rebase_git_dir/rebase-apply/orig-head" 2>/dev/null || echo "")
    fi

    if [[ -n "$_rebase_onto" && -n "$_rebase_orig_head" ]]; then
        _rebase_merge_base=$(git merge-base "$_rebase_orig_head" "$_rebase_onto" 2>/dev/null || echo "")
        if [[ -n "$_rebase_merge_base" ]]; then
            # Only hash changes from the worktree branch (merge-base..orig-head + working tree)
            # This excludes incoming-only files from the onto branch.
            _rebase_worktree_files=$(git diff --name-only "$_rebase_merge_base" "$_rebase_orig_head" 2>/dev/null || echo "")
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
        # onto or orig-head missing — fail-open, fall through to default behavior
        {
            git diff "$DIFF_BASE" -- "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true
        } | hash_stdin
    fi
else
    {
        git diff "$DIFF_BASE" -- "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true
    } | hash_stdin
fi
