#!/usr/bin/env bash
# hooks/lib/merge-state.sh
# Shared library: detect and handle merge/rebase in-progress state.
#
# Provides:
#   ms_get_git_dir                   — resolve git dir (worktree-aware); respects _MERGE_STATE_GIT_DIR override
#   ms_is_merge_in_progress          — returns 0 when MERGE_HEAD exists (and != HEAD)
#   ms_is_rebase_in_progress         — returns 0 when REBASE_HEAD or rebase-apply dir exists
#   ms_get_merge_base                — returns merge base SHA for current merge/rebase state
#   ms_get_worktree_only_files       — orig-head-anchored: files changed on worktree branch
#   ms_get_worktree_only_files_from_head — HEAD-anchored: files changed on worktree branch (for capture-review-diff.sh)
#   ms_filter_to_worktree_only       — filter a file list to worktree-only files; fail-open on error
#   ms_is_worktree_to_session_merge  — detects worktree-to-session merge (MERGE_HEAD branch contains "worktree")
#   ms_get_incoming_only_files       — returns files changed on MERGE_HEAD side (incoming branch)
#   ms_get_conflicted_files          — wraps git diff --name-only --diff-filter=U
#
# Source guard: _MERGE_STATE_LOADED + _MS_LOAD_COUNT sentinel (informational only, >1 is non-fatal)
# Test isolation: set _MERGE_STATE_GIT_DIR env var to override the git dir detection.
#
# Usage:
#   source ${CLAUDE_PLUGIN_ROOT}/hooks/lib/merge-state.sh
#
# Namespace: ms_ prefix for all exported functions.

# ── Source guard ─────────────────────────────────────────────────────────────
# _MS_LOAD_COUNT counts actual loads (not repeat sources). Guard returns early
# on re-source, preventing re-execution and keeping the count accurate.
: "${_MS_LOAD_COUNT:=0}"
if [[ "${_MERGE_STATE_LOADED:-}" == "1" ]]; then
    return 0 2>/dev/null || true
fi
_MERGE_STATE_LOADED=1
(( _MS_LOAD_COUNT++ )) || true

# Capture _MERGE_STATE_GIT_DIR at source time so that
#   _MERGE_STATE_GIT_DIR=/tmp source merge-state.sh && ms_get_git_dir
# returns /tmp even after _MERGE_STATE_GIT_DIR is unset.
# Functions also honor _MERGE_STATE_GIT_DIR when set at call time (per-call override).
_MS_GIT_DIR_AT_LOAD="${_MERGE_STATE_GIT_DIR:-}"

# ── ms_get_git_dir ────────────────────────────────────────────────────────────
# Returns the .git directory path.
# Priority:
#   1. _MERGE_STATE_GIT_DIR env var (call-time override, for test isolation)
#   2. _MS_GIT_DIR_AT_LOAD (captured at source time)
#   3. git rev-parse --git-dir (live detection)
ms_get_git_dir() {
    if [[ -n "${_MERGE_STATE_GIT_DIR:-}" ]]; then
        echo "$_MERGE_STATE_GIT_DIR"
        return 0
    fi
    if [[ -n "${_MS_GIT_DIR_AT_LOAD:-}" ]]; then
        echo "$_MS_GIT_DIR_AT_LOAD"
        return 0
    fi
    git rev-parse --git-dir 2>/dev/null
}

# ── ms_is_merge_in_progress ───────────────────────────────────────────────────
# Returns 0 (true) when a merge is in progress (MERGE_HEAD file exists).
# Includes MERGE_HEAD==HEAD guard: if MERGE_HEAD points to the same commit
# as HEAD (self-referencing / fake), returns 1 to prevent bypass.
# Re-computes on every call (no caching).
ms_is_merge_in_progress() {
    local _git_dir
    _git_dir=$(ms_get_git_dir)
    [[ -z "$_git_dir" ]] && return 1
    [[ -f "$_git_dir/MERGE_HEAD" ]] || return 1

    # MERGE_HEAD==HEAD guard
    local _merge_head_sha _merge_head_resolved _head_sha
    _merge_head_sha=$(head -1 "$_git_dir/MERGE_HEAD" 2>/dev/null || echo "")
    [[ -z "$_merge_head_sha" ]] && return 1

    _merge_head_resolved=$(git rev-parse "$_merge_head_sha" 2>/dev/null || echo "")
    _head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

    # If MERGE_HEAD cannot be resolved, fail-open (treat as merge in progress)
    if [[ -z "$_merge_head_resolved" ]]; then
        return 0
    fi

    # MERGE_HEAD == HEAD guard: self-referencing / fake merge — not a real merge
    if [[ "$_merge_head_resolved" == "$_head_sha" ]]; then
        return 1
    fi

    return 0
}

# ── ms_is_rebase_in_progress ─────────────────────────────────────────────────
# Returns 0 (true) when a rebase is in progress:
#   - REBASE_HEAD file exists, OR
#   - rebase-merge/ or rebase-apply/ directory exists
# Re-computes on every call (no caching).
ms_is_rebase_in_progress() {
    local _git_dir
    _git_dir=$(ms_get_git_dir)
    [[ -z "$_git_dir" ]] && return 1

    if [[ -f "$_git_dir/REBASE_HEAD" ]]; then
        return 0
    fi
    if [[ -d "$_git_dir/rebase-merge" ]]; then
        return 0
    fi
    if [[ -d "$_git_dir/rebase-apply" ]]; then
        return 0
    fi
    return 1
}

# ── ms_get_merge_base ─────────────────────────────────────────────────────────
# Returns the merge base SHA for the current merge or rebase state.
# For merge: merge-base HEAD MERGE_HEAD
# For rebase: merge-base onto orig-head (from rebase-merge or rebase-apply)
# Returns empty string if the state cannot be determined.
# Re-computes on every call (no caching).
ms_get_merge_base() {
    local _git_dir
    _git_dir=$(ms_get_git_dir)
    [[ -z "$_git_dir" ]] && return 1

    if [[ -f "$_git_dir/MERGE_HEAD" ]]; then
        local _merge_head_sha _merge_base
        _merge_head_sha=$(head -1 "$_git_dir/MERGE_HEAD" 2>/dev/null || echo "")
        [[ -z "$_merge_head_sha" ]] && return 1
        _merge_base=$(git merge-base HEAD "$_merge_head_sha" 2>/dev/null || echo "")
        if [[ -n "$_merge_base" ]]; then
            echo "$_merge_base"
            return 0
        fi
        return 1
    fi

    if [[ -f "$_git_dir/REBASE_HEAD" ]] || [[ -d "$_git_dir/rebase-merge" ]] || [[ -d "$_git_dir/rebase-apply" ]]; then
        local _onto="" _orig_head=""
        if [[ -f "$_git_dir/rebase-merge/onto" ]]; then
            _onto=$(cat "$_git_dir/rebase-merge/onto" 2>/dev/null || echo "")
            _orig_head=$(cat "$_git_dir/rebase-merge/orig-head" 2>/dev/null || echo "")
        elif [[ -f "$_git_dir/rebase-apply/onto" ]]; then
            _onto=$(cat "$_git_dir/rebase-apply/onto" 2>/dev/null || echo "")
            _orig_head=$(cat "$_git_dir/rebase-apply/orig-head" 2>/dev/null || echo "")
        fi

        if [[ -n "$_onto" && -n "$_orig_head" ]]; then
            local _rebase_merge_base
            _rebase_merge_base=$(git merge-base "$_onto" "$_orig_head" 2>/dev/null || echo "")
            if [[ -n "$_rebase_merge_base" ]]; then
                echo "$_rebase_merge_base"
                return 0
            fi
        fi
        return 1
    fi

    return 1
}

# ── ms_get_worktree_only_files ────────────────────────────────────────────────
# Returns (to stdout, newline-separated) the list of files changed on the
# worktree branch only, excluding incoming-only files.
#
# For merge state (MERGE_HEAD):
#   - merge base = merge-base(HEAD, MERGE_HEAD)
#   - worktree files = diff --name-only merge-base..HEAD
#   - Guard: if MERGE_HEAD == HEAD, fail-open (return staged files)
#
# For rebase state (REBASE_HEAD):
#   - onto and orig-head read from rebase-merge or rebase-apply dirs
#   - merge base = merge-base(orig-head, onto)
#   - worktree files = diff --name-only merge-base..orig-head
#
# Fail-open: if merge-base computation fails, returns all staged files.
# Re-computes on every call (no caching).
ms_get_worktree_only_files() {
    # Determine git dir for state checks
    local _actual_git_dir
    if [[ -n "${_MERGE_STATE_GIT_DIR:-}" ]]; then
        _actual_git_dir="$_MERGE_STATE_GIT_DIR"
    else
        _actual_git_dir=$(ms_get_git_dir)
    fi

    # ── Merge state ──────────────────────────────────────────────────────────
    if [[ -n "$_actual_git_dir" && -f "$_actual_git_dir/MERGE_HEAD" ]]; then
        local _merge_head_sha _merge_head_resolved _head_sha _merge_base _worktree_changed
        _merge_head_sha=$(head -1 "$_actual_git_dir/MERGE_HEAD" 2>/dev/null || echo "")
        _head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        _merge_head_resolved=$(git rev-parse "$_merge_head_sha" 2>/dev/null || echo "")

        # Guard: MERGE_HEAD == HEAD → fail-open, return staged files
        if [[ -n "$_merge_head_resolved" && "$_merge_head_resolved" == "$_head_sha" ]]; then
            git diff --cached --name-only 2>/dev/null || true
            return 0
        fi

        # Attempt merge-base computation
        if [[ -n "$_merge_head_sha" ]]; then
            _merge_base=$(git merge-base HEAD "$_merge_head_sha" 2>/dev/null || echo "")
            if [[ -n "$_merge_base" ]]; then
                _worktree_changed=$(git diff --name-only "$_merge_base" HEAD 2>/dev/null || echo "")
                echo "$_worktree_changed"
                return 0
            fi
        fi

        # Fail-open: merge-base failed (e.g., invalid MERGE_HEAD SHA)
        git diff --cached --name-only 2>/dev/null || true
        return 0
    fi

    # ── Rebase state ─────────────────────────────────────────────────────────
    if [[ -n "$_actual_git_dir" && -f "$_actual_git_dir/REBASE_HEAD" ]]; then
        local _onto="" _orig_head=""
        if [[ -f "$_actual_git_dir/rebase-merge/onto" ]]; then
            _onto=$(cat "$_actual_git_dir/rebase-merge/onto" 2>/dev/null || echo "")
            _orig_head=$(cat "$_actual_git_dir/rebase-merge/orig-head" 2>/dev/null || echo "")
        elif [[ -f "$_actual_git_dir/rebase-apply/onto" ]]; then
            _onto=$(cat "$_actual_git_dir/rebase-apply/onto" 2>/dev/null || echo "")
            _orig_head=$(cat "$_actual_git_dir/rebase-apply/orig-head" 2>/dev/null || echo "")
        fi

        if [[ -n "$_onto" && -n "$_orig_head" ]]; then
            local _rebase_merge_base _rebase_worktree_changed
            _rebase_merge_base=$(git merge-base "$_orig_head" "$_onto" 2>/dev/null || echo "")
            if [[ -n "$_rebase_merge_base" ]]; then
                _rebase_worktree_changed=$(git diff --name-only "$_rebase_merge_base" "$_orig_head" 2>/dev/null || echo "")
                echo "$_rebase_worktree_changed"
                return 0
            fi
        fi

        # Fail-open: onto or orig-head missing, or merge-base failed
        git diff --cached --name-only 2>/dev/null || true
        return 0
    fi

    # No merge/rebase in progress — return staged files
    git diff --cached --name-only 2>/dev/null || true
    return 0
}

# ── ms_get_worktree_only_files_from_head ─────────────────────────────────────
# HEAD-anchored variant: for use in capture-review-diff.sh where we want to
# diff merge-base..HEAD (not merge-base..orig-head).
#
# For merge state: same as ms_get_worktree_only_files (already HEAD-anchored)
# For rebase state: diff merge-base..HEAD instead of merge-base..orig-head
# Fail-open: returns staged files on failure.
ms_get_worktree_only_files_from_head() {
    # Determine git dir for state checks
    local _actual_git_dir
    if [[ -n "${_MERGE_STATE_GIT_DIR:-}" ]]; then
        _actual_git_dir="$_MERGE_STATE_GIT_DIR"
    else
        _actual_git_dir=$(ms_get_git_dir)
    fi

    # ── Merge state ──────────────────────────────────────────────────────────
    if [[ -n "$_actual_git_dir" && -f "$_actual_git_dir/MERGE_HEAD" ]]; then
        local _merge_head_sha _merge_head_resolved _head_sha _merge_base _worktree_changed
        _merge_head_sha=$(head -1 "$_actual_git_dir/MERGE_HEAD" 2>/dev/null || echo "")
        _head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        _merge_head_resolved=$(git rev-parse "$_merge_head_sha" 2>/dev/null || echo "")

        # Guard: MERGE_HEAD == HEAD → fail-open, return staged files
        if [[ -n "$_merge_head_resolved" && "$_merge_head_resolved" == "$_head_sha" ]]; then
            git diff --cached --name-only 2>/dev/null || true
            return 0
        fi

        if [[ -n "$_merge_head_sha" ]]; then
            _merge_base=$(git merge-base HEAD "$_merge_head_sha" 2>/dev/null || echo "")
            if [[ -n "$_merge_base" ]]; then
                _worktree_changed=$(git diff --name-only "$_merge_base" HEAD 2>/dev/null || echo "")
                echo "$_worktree_changed"
                return 0
            fi
        fi
        git diff --cached --name-only 2>/dev/null || true
        return 0
    fi

    # ── Rebase state ─────────────────────────────────────────────────────────
    if [[ -n "$_actual_git_dir" && -f "$_actual_git_dir/REBASE_HEAD" ]]; then
        local _onto="" _orig_head=""
        if [[ -f "$_actual_git_dir/rebase-merge/onto" ]]; then
            _onto=$(cat "$_actual_git_dir/rebase-merge/onto" 2>/dev/null || echo "")
            _orig_head=$(cat "$_actual_git_dir/rebase-merge/orig-head" 2>/dev/null || echo "")
        elif [[ -f "$_actual_git_dir/rebase-apply/onto" ]]; then
            _onto=$(cat "$_actual_git_dir/rebase-apply/onto" 2>/dev/null || echo "")
            _orig_head=$(cat "$_actual_git_dir/rebase-apply/orig-head" 2>/dev/null || echo "")
        fi

        if [[ -n "$_onto" && -n "$_orig_head" ]]; then
            local _rebase_merge_base _rebase_worktree_changed
            _rebase_merge_base=$(git merge-base "$_orig_head" "$_onto" 2>/dev/null || echo "")
            if [[ -n "$_rebase_merge_base" ]]; then
                # HEAD-anchored: diff merge-base..HEAD
                _rebase_worktree_changed=$(git diff --name-only "$_rebase_merge_base" HEAD 2>/dev/null || echo "")
                echo "$_rebase_worktree_changed"
                return 0
            fi
        fi

        git diff --cached --name-only 2>/dev/null || true
        return 0
    fi

    git diff --cached --name-only 2>/dev/null || true
    return 0
}

# ── ms_filter_to_worktree_only ────────────────────────────────────────────────
# Filters a newline-separated file list to only include files that are in the
# worktree-only file set. Returns the original list on failure (fail-open).
#
# Usage: echo "$file_list" | ms_filter_to_worktree_only
#   OR:  ms_filter_to_worktree_only <<< "$file_list"
#   OR:  ms_filter_to_worktree_only "$file_list"
#
# Output: filtered newline-separated file list on stdout.
ms_filter_to_worktree_only() {
    local _input_files
    if [[ $# -gt 0 ]]; then
        _input_files="$1"
    else
        _input_files=$(cat)
    fi

    local _worktree_files
    _worktree_files=$(ms_get_worktree_only_files 2>/dev/null || echo "")

    if [[ -z "$_worktree_files" ]]; then
        # Fail-open: no worktree files computed — return original list
        echo "$_input_files"
        return 0
    fi

    # Filter: only return files present in the worktree-only set
    local _filtered=""
    while IFS= read -r _file; do
        [[ -z "$_file" ]] && continue
        if echo "$_worktree_files" | grep -qxF "$_file" 2>/dev/null; then
            _filtered+="$_file"$'\n'
        fi
    done <<< "$_input_files"

    if [[ -z "$_filtered" ]]; then
        # Fail-open: filtering produced empty result — return original list
        echo "$_input_files"
        return 0
    fi

    printf '%s' "$_filtered"
    return 0
}

# ── ms_is_worktree_to_session_merge ──────────────────────────────────────────
# Returns 0 (true) when the current merge is a worktree-to-session merge:
#   - MERGE_HEAD exists (merge in progress)
#   - MERGE_HEAD's branch name contains "worktree" (created via `git worktree add`)
#
# Heuristic: resolves MERGE_HEAD to a branch name via `git name-rev` or
# `git branch --contains`, then checks for the "worktree" substring.
# Fail-closed: returns 1 if detection is ambiguous.
ms_is_worktree_to_session_merge() {
    local _git_dir
    _git_dir=$(ms_get_git_dir)
    [[ -z "$_git_dir" ]] && return 1
    [[ -f "$_git_dir/MERGE_HEAD" ]] || return 1

    local _merge_head_sha
    _merge_head_sha=$(head -1 "$_git_dir/MERGE_HEAD" 2>/dev/null || echo "")
    [[ -z "$_merge_head_sha" ]] && return 1

    # Try to find a branch name for MERGE_HEAD
    local _branch_name=""

    # Method 1: git branch --contains (most reliable for local branches)
    _branch_name=$(git branch --contains "$_merge_head_sha" 2>/dev/null \
        | sed 's/^[* ]*//' | grep -i "worktree" | head -1 || echo "")

    # Method 2: git name-rev fallback
    if [[ -z "$_branch_name" ]]; then
        local _name_rev
        _name_rev=$(git name-rev --name-only "$_merge_head_sha" 2>/dev/null || echo "")
        if [[ "$_name_rev" == *worktree* ]]; then
            _branch_name="$_name_rev"
        fi
    fi

    # Check if the branch name contains "worktree"
    if [[ -n "$_branch_name" && "$_branch_name" == *worktree* ]]; then
        return 0
    fi

    return 1
}

# ── ms_get_incoming_only_files ───────────────────────────────────────────────
# Returns (to stdout, newline-separated) the list of files changed on the
# MERGE_HEAD (incoming) branch only, excluding HEAD-side files.
#
# This is the semantic inverse of ms_get_worktree_only_files:
#   - ms_get_worktree_only_files returns diff(merge_base..HEAD)
#   - ms_get_incoming_only_files returns diff(merge_base..MERGE_HEAD)
#
# Use case: during worktree-to-session merge, the incoming changes (MERGE_HEAD)
# ARE the implementation files we want. The review gate uses this to identify
# worktree branch files and verify they were already reviewed.
#
# Only supports merge state (MERGE_HEAD). Returns empty for rebase state.
# Fail-open: if merge-base computation fails, returns all staged files.
# Re-computes on every call (no caching).
ms_get_incoming_only_files() {
    local _actual_git_dir
    if [[ -n "${_MERGE_STATE_GIT_DIR:-}" ]]; then
        _actual_git_dir="$_MERGE_STATE_GIT_DIR"
    else
        _actual_git_dir=$(ms_get_git_dir)
    fi

    # Only merge state is supported for incoming files
    if [[ -n "$_actual_git_dir" && -f "$_actual_git_dir/MERGE_HEAD" ]]; then
        local _merge_head_sha _merge_head_resolved _head_sha _merge_base _incoming_changed
        _merge_head_sha=$(head -1 "$_actual_git_dir/MERGE_HEAD" 2>/dev/null || echo "")
        _head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        _merge_head_resolved=$(git rev-parse "$_merge_head_sha" 2>/dev/null || echo "")

        # Guard: MERGE_HEAD == HEAD -> fail-open, return staged files
        if [[ -n "$_merge_head_resolved" && "$_merge_head_resolved" == "$_head_sha" ]]; then
            git diff --cached --name-only 2>/dev/null || true
            return 0
        fi

        # Compute merge-base and diff to MERGE_HEAD (incoming side)
        if [[ -n "$_merge_head_sha" ]]; then
            _merge_base=$(git merge-base HEAD "$_merge_head_sha" 2>/dev/null || echo "")
            if [[ -n "$_merge_base" ]]; then
                _incoming_changed=$(git diff --name-only "$_merge_base" "$_merge_head_sha" 2>/dev/null || echo "")
                echo "$_incoming_changed"
                return 0
            fi
        fi

        # Fail-open: merge-base failed
        git diff --cached --name-only 2>/dev/null || true
        return 0
    fi

    # No merge in progress — return staged files (fail-open)
    git diff --cached --name-only 2>/dev/null || true
    return 0
}

# ── ms_get_conflicted_files ───────────────────────────────────────────────────
# Returns (to stdout, newline-separated) the list of files with unresolved
# merge conflicts in the current index.
# Wraps: git diff --name-only --diff-filter=U
ms_get_conflicted_files() {
    git diff --name-only --diff-filter=U 2>/dev/null || true
}
