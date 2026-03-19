#!/usr/bin/env bash
set -euo pipefail
# scripts/worktree-sync-from-main.sh
# Sync a worktree branch with origin/main by fetching and merging.
#
# Usage: scripts/worktree-sync-from-main.sh
# Exit codes: 0=success, 1=error (merge conflict)
#
# This script is called by:
#   - /dso:sprint Phase 4 (pre-batch update from main)
#   - merge-to-main.sh (pre-merge sync)
#   - Any worktree workflow needing to pull latest from main
#
# Never run bare `git merge origin/main` in a worktree — use this script instead.

set -euo pipefail

# --- Resolve repo root ---
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "ERROR: Not a git repository."
    exit 1
fi

# Source config-paths.sh for CFG_PYTHON_VENV
_SYNC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$_SYNC_SCRIPT_DIR/..}"
[[ ! -f "${CLAUDE_PLUGIN_ROOT}/plugin.json" ]] && CLAUDE_PLUGIN_ROOT="$_SYNC_SCRIPT_DIR/.."
_sync_config_paths="${CLAUDE_PLUGIN_ROOT}/hooks/lib/config-paths.sh"
[[ -f "$_sync_config_paths" ]] && source "$_sync_config_paths"

# --- Ensure pre-commit is available in PATH ---
# git merge --no-edit auto-commits, which runs pre-commit hooks. If the venv
# is not activated, `pre-commit` is not found and the merge commit fails.
# Probe the conventional venv location and prepend it without activating the
# full venv (activation changes PS1, sys.path, and other env state).
_VENV_BIN="$REPO_ROOT/$(dirname "$CFG_PYTHON_VENV")"
if [[ -f "$_VENV_BIN/pre-commit" && ":$PATH:" != *":$_VENV_BIN:"* ]]; then
    export PATH="$_VENV_BIN:$PATH"
fi

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Allow sourcing without executing ---
# When merge-to-main.sh sources this file to call _worktree_sync_from_main,
# it should not execute the main block. Only run when executed directly.
_worktree_sync_from_main() {
    local quiet="${1:-}"

    # --- 1) Fetch and merge ---
    echo "Syncing worktree with main..."
    if ! git fetch origin main 2>&1; then
        echo "ERROR: git fetch origin main failed."
        return 1
    fi

    if ! git merge origin/main ${quiet:+--quiet} --no-edit 2>&1; then
        local CONFLICTED
        CONFLICTED=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
        local BRANCH
        BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

        # --- Fallback auto-resolve for tickets-only conflicts ---
        # This handles CI/fresh-clone environments where the merge driver is not
        # registered. If ALL conflicted files are under .tickets/ AND
        # .tickets/.index.json is among them, attempt to resolve automatically
        # via merge-ticket-index.py.
        #
        # CRITICAL SAFETY GUARD: if any non-ticket file is conflicted, abort.
        # Only .tickets/.index.json is auto-resolved; other .tickets/ conflicts abort.
        local _can_auto_resolve=true
        local _index_json_conflicted=false

        if [ -n "$CONFLICTED" ]; then
            # Check each conflicted file
            while IFS= read -r _file; do
                case "$_file" in
                    .tickets/*)
                        # Ticket file — check if it's .index.json
                        if [ "$_file" = ".tickets/.index.json" ]; then
                            _index_json_conflicted=true
                        else
                            # Non-index ticket file — cannot auto-resolve
                            _can_auto_resolve=false
                            break
                        fi
                        ;;
                    *)
                        # Non-ticket file — cannot auto-resolve
                        _can_auto_resolve=false
                        break
                        ;;
                esac
            done <<< "$CONFLICTED"
        else
            _can_auto_resolve=false
        fi

        # Also abort if .tickets/.index.json is not among the conflicted files
        # (e.g., only .tickets/foo.md is conflicted — we cannot safely merge those)
        if ! $_index_json_conflicted; then
            _can_auto_resolve=false
        fi

        if $_can_auto_resolve; then
            # Locate merge-ticket-index.py (provided by the merge driver setup story)
            local _merge_script="$_SCRIPT_DIR/merge-ticket-index.py"

            if [ ! -f "$_merge_script" ]; then
                echo "ERROR: merge-ticket-index.py not found at $_merge_script — cannot auto-resolve."
                git merge --abort 2>/dev/null || true
                return 1
            fi

            # Extract ancestor, ours, and theirs versions to temp files.
            # During a merge conflict, the working-tree .tickets/.index.json
            # contains git conflict markers (not valid JSON). We must extract
            # the clean ours version from HEAD:.tickets/.index.json instead.
            # Argument order: ancestor_path ours_path theirs_path
            local _tmp_ancestor _tmp_ours _tmp_theirs
            _tmp_ancestor=$(mktemp)
            _tmp_ours=$(mktemp)
            _tmp_theirs=$(mktemp)

            # Extract ancestor version (common merge base)
            local _merge_base
            _merge_base=$(git merge-base HEAD MERGE_HEAD 2>/dev/null || true)
            if [ -z "$_merge_base" ]; then
                echo "ERROR: Could not determine merge base for fallback resolution."
                git merge --abort 2>/dev/null || true
                rm -f "$_tmp_ancestor" "$_tmp_ours" "$_tmp_theirs"
                return 1
            fi

            git show "${_merge_base}:.tickets/.index.json" > "$_tmp_ancestor" 2>/dev/null || {
                echo "ERROR: Could not extract ancestor .tickets/.index.json from merge base."
                git merge --abort 2>/dev/null || true
                rm -f "$_tmp_ancestor" "$_tmp_ours" "$_tmp_theirs"
                return 1
            }

            # Extract ours version from HEAD (clean JSON, no conflict markers)
            git show "HEAD:.tickets/.index.json" > "$_tmp_ours" 2>/dev/null || {
                echo "ERROR: Could not extract HEAD .tickets/.index.json."
                git merge --abort 2>/dev/null || true
                rm -f "$_tmp_ancestor" "$_tmp_ours" "$_tmp_theirs"
                return 1
            }

            # Extract theirs version (MERGE_HEAD)
            git show "MERGE_HEAD:.tickets/.index.json" > "$_tmp_theirs" 2>/dev/null || {
                echo "ERROR: Could not extract MERGE_HEAD .tickets/.index.json."
                git merge --abort 2>/dev/null || true
                rm -f "$_tmp_ancestor" "$_tmp_ours" "$_tmp_theirs"
                return 1
            }

            # Run merge-ticket-index.py with three temp file paths: ancestor, ours, theirs
            # The script writes the merged result back to the ours temp file.
            if ! python3 "$_merge_script" "$_tmp_ancestor" "$_tmp_ours" "$_tmp_theirs" 2>&1; then
                echo "ERROR: merge-ticket-index.py failed — aborting merge."
                git merge --abort 2>/dev/null || true
                rm -f "$_tmp_ancestor" "$_tmp_ours" "$_tmp_theirs"
                return 1
            fi

            # Copy the merged result from the temp file back to the working tree
            cp "$_tmp_ours" ".tickets/.index.json"

            rm -f "$_tmp_ancestor" "$_tmp_ours" "$_tmp_theirs"

            # Stage the resolved file
            if ! git add .tickets/.index.json 2>&1; then
                echo "ERROR: git add .tickets/.index.json failed — aborting merge."
                git merge --abort 2>/dev/null || true
                return 1
            fi

            echo "MERGE_AUTO_RESOLVE: path=.tickets/.index.json layer=fallback"

            # Complete the merge commit
            if ! git commit --no-edit 2>&1; then
                echo "ERROR: git commit failed after auto-resolve — cleaning up."
                # Unstage the resolved file before aborting
                git reset HEAD .tickets/.index.json 2>/dev/null || true
                git merge --abort 2>/dev/null || true
                return 1
            fi

            return 0
        fi

        # Could not auto-resolve — emit conflict info and abort
        echo "ERROR: Merge conflict."
        echo "CONFLICT_DATA: direction=main-into-worktree branch=$BRANCH merge_base=$(git merge-base HEAD origin/main 2>/dev/null || echo unknown)"
        [ -n "$CONFLICTED" ] && echo "CONFLICT_FILES: $CONFLICTED"
        git merge --abort 2>/dev/null || true
        return 1
    fi
    echo "OK: Worktree synced with main."

    return 0
}

# --- Execute when run directly (not sourced) ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cd "$REPO_ROOT"
    _worktree_sync_from_main "$@"
fi
