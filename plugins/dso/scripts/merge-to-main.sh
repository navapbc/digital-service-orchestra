#!/usr/bin/env bash
set -euo pipefail
# scripts/merge-to-main.sh
# Merge worktree branch into main and push.
# Called by /dso:end-session after all worktree commits are done.
#
# Replaces the old two-script flow (sprintend-sync.sh + merge-to-main.sh).
# The ticket CLI (event-sourced v3 system) uses .tickets-tracker/ as a git worktree
# branch; changes to .tickets-tracker/ are managed via the ticket CLI commands.
#
# Usage: scripts/merge-to-main.sh
# Exit codes: 0=success, 1=error
# Output: concise status for LLM consumption

set -euo pipefail

# --- CLI: --help (early exit before any context checks) ---
for _arg in "$@"; do
    if [[ "$_arg" == "--help" ]]; then
        cat <<'USAGE'
Usage: merge-to-main.sh [--bump [patch|minor]] [--resume|--help]

  --bump [TYPE]   Bump the project version before pushing. TYPE is 'patch' (default)
                  or 'minor'. Requires version.file_path in .claude/dso-config.conf.
  --resume        Resume from last incomplete phase. On merge failure, squash-rebase
                  recovery runs automatically before retrying (up to 5 retries).
  --help          Print this usage message and exit.

  (no args)       Run all phases sequentially (no version bump).

Merge recovery: on git merge failure the script squash-rebases the branch onto
main and retries. If recovery fails, run --resume (retry budget: 5 attempts).
USAGE
        exit 0
    fi
done

# --- Resolve repo root and cd into it ---
# This ensures relative path checks work regardless of where the script is called from
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not a git repository."
    exit 1
fi
cd "$REPO_ROOT"
WORKTREE_DIR="$REPO_ROOT"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set}"

# Pre-flight: ensure pre-commit is on PATH before any git commands that trigger hooks.
# git merge (in _phase_merge) triggers pre-commit hooks; if venv is not in PATH,
# the hooks fail with "pre-commit: command not found".
source "${CLAUDE_PLUGIN_ROOT}/scripts/ensure-pre-commit.sh" || true  # shim-exempt: plugin-internal sibling-script source from scripts/

# --- Load merge utility helpers (state file, lock, recovery, push-idempotency) ---
# shellcheck source=${CLAUDE_PLUGIN_ROOT}/hooks/lib/merge-helpers.sh
_MERGE_HELPERS_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/merge-helpers.sh"
if [[ -f "$_MERGE_HELPERS_LIB" ]]; then
    source "$_MERGE_HELPERS_LIB"
fi

# Maximum number of --resume retries before escalating to the user
MAX_MERGE_RETRIES=5

# --- SIGURG trap: save current phase to state file before exit ---
# Registered after _state_init is called (see below, after BRANCH is set).
_sigurg_handler() {
    _state_write_phase "${_CURRENT_PHASE:-interrupted}" 2>/dev/null || true
    exit 0
}

# --- Load hooks/lib/deps.sh for get_artifacts_dir and retry_with_backoff ---
# Needed for checkpoint sentinel verification (see below).
_HOOK_LIB="$CLAUDE_PLUGIN_ROOT/hooks/lib/deps.sh"
if [[ -f "$_HOOK_LIB" ]]; then
    source "$_HOOK_LIB"
fi

# --- Load hooks/lib/merge-state.sh for shared MERGE_HEAD/REBASE_HEAD detection ---
# shellcheck source=${CLAUDE_PLUGIN_ROOT}/hooks/lib/merge-state.sh
if [[ -f "$CLAUDE_PLUGIN_ROOT/hooks/lib/merge-state.sh" ]]; then
    source "$CLAUDE_PLUGIN_ROOT/hooks/lib/merge-state.sh"
fi

# --- Fallback: define retry_with_backoff inline if deps.sh was not found ---
# Regression guard for dso-kv4p: _phase_push calls retry_with_backoff; if deps.sh
# is absent (e.g., fresh clone, CLAUDE_PLUGIN_ROOT misconfiguration), the function
# would be undefined and cause "command not found" at runtime.
if ! type retry_with_backoff >/dev/null 2>&1; then
    retry_with_backoff() {
        local max_retries="$1"
        local initial_delay="$2"
        shift 2
        local attempt=0
        local exit_code=0
        local delay="$initial_delay"
        while true; do
            "$@"
            exit_code=$?
            if [[ $exit_code -eq 0 ]]; then
                return 0
            fi
            if [[ $attempt -ge $max_retries ]]; then
                echo "retry_with_backoff: all $max_retries retries exhausted (exit $exit_code)" >&2
                return $exit_code
            fi
            attempt=$(( attempt + 1 ))
            echo "retry_with_backoff: attempt $attempt/$max_retries failed (exit $exit_code), retrying in ${delay}s..." >&2
            sleep "$delay"
            delay=$(awk "BEGIN { printf \"%.2f\", $delay * 2 }")
        done
    }
fi

# --- Load project config (single batch call to read-config) ---
eval "$(bash "$_SCRIPT_DIR"/read-config.sh --batch 2>/dev/null || true)"
VISUAL_BASELINE_PATH="${MERGE_VISUAL_BASELINE_PATH:-}"
# ci.workflow_name (preferred) → merge.ci_workflow_name (deprecated fallback)
# --batch eval populates CI_WORKFLOW_NAME from ci.workflow_name; only fall back
# to MERGE_CI_WORKFLOW_NAME (merge.ci_workflow_name) when the new key is absent.
# Replaced: CI_WORKFLOW_NAME="${MERGE_CI_WORKFLOW_NAME:-}" (bare assignment)
if [ -z "${CI_WORKFLOW_NAME:-}" ] && [ -n "${MERGE_CI_WORKFLOW_NAME:-}" ]; then
  echo 'DEPRECATION WARNING: merge.ci_workflow_name is deprecated — migrate to ci.workflow_name in .claude/dso-config.conf' >&2
  CI_WORKFLOW_NAME="${MERGE_CI_WORKFLOW_NAME:-}"
fi
MSG_EXCLUSION_PATTERN="${MERGE_MESSAGE_EXCLUSION_PATTERN:-}"

# Post-merge validation commands
# Defaults: make format-check (commands.format_check), make lint (commands.lint)
CMD_FORMAT_CHECK="${COMMANDS_FORMAT_CHECK:-make format-check}"
CMD_LINT="${COMMANDS_LINT:-make lint}"

# --- Verify worktree context ---
if [ -d .git ]; then
    echo "ERROR: Not a worktree. This script is for worktree sessions only."
    exit 1
fi
if [ ! -f .git ]; then
    echo "ERROR: Not a git repository."
    exit 1
fi

# --- 1) Store worktree branch name ---
BRANCH=$(git branch --show-current)
if [ -z "$BRANCH" ]; then
    echo "ERROR: Could not determine worktree branch name."
    exit 1
fi

# --- Check for uncommitted or untracked changes on worktree ---
# Exclude ticket directory from the dirty check — the auto-commit block below
# handles ticket-tracker files separately before the merge starts.
_CFG_TKDIR=$(bash "$_SCRIPT_DIR"/read-config.sh tickets.directory 2>/dev/null || true)
_CFG_TKDIR="${_CFG_TKDIR:-.tickets-tracker}"
DIRTY=$(git diff --name-only -- ":!${_CFG_TKDIR}/" 2>/dev/null || true)
DIRTY_CACHED=$(git diff --cached --name-only -- ":!${_CFG_TKDIR}/" 2>/dev/null || true)
DIRTY_UNTRACKED=$(git ls-files --others --exclude-standard -- ":!${_CFG_TKDIR}/" 2>/dev/null || true)
if [ -n "$DIRTY" ] || [ -n "$DIRTY_CACHED" ] || [ -n "$DIRTY_UNTRACKED" ]; then
    echo "ERROR: Uncommitted changes on worktree. Commit or stash first."
    [ -n "$DIRTY" ] && echo "Unstaged: $DIRTY"
    [ -n "$DIRTY_CACHED" ] && echo "Staged: $DIRTY_CACHED"
    [ -n "$DIRTY_UNTRACKED" ] && echo "Untracked: $DIRTY_UNTRACKED"
    exit 1
fi

# --- Auto-commit dirty ticket-tracker files on the worktree ---
# ticket commands write .tickets-tracker/ files without staging them.
# These files must be committed before merging so they appear in the merge on
# main and don't leave the worktree dirty for post-merge cleanup checks.
TRACKER_DIRTY=$(git diff --name-only -- .tickets-tracker/ 2>/dev/null || true)
TRACKER_UNTRACKED=$(git ls-files --others --exclude-standard -- .tickets-tracker/ 2>/dev/null || true)
if [ -n "$TRACKER_DIRTY" ] || [ -n "$TRACKER_UNTRACKED" ]; then
    echo "Auto-committing uncommitted .tickets-tracker/ changes on worktree..."
    git add .tickets-tracker/ 2>/dev/null || true
    git commit -q -m "chore: auto-commit ticket changes before merge"
    echo "OK: Committed .tickets-tracker/ changes."
fi

# --- Initialize state file and register SIGURG trap ---
_state_init
trap '_sigurg_handler' URG

# --- Resolve MAIN_REPO early so all phases can use it (including --resume) ---
# MAIN_REPO is the path to the main (non-worktree) checkout. Phases like
# validate and ci_trigger need it, but it was previously set only inside
# _phase_sync — causing unbound variable errors on --resume.
MAIN_REPO=$(dirname "$(git rev-parse --git-common-dir)")
if [ -z "$MAIN_REPO" ]; then
    echo "ERROR: Could not determine main repo path."
    exit 1
fi

# PRE_MERGE_SHA: set to current HEAD as a safe default. _phase_merge overwrites
# it with the actual pre-merge SHA before merging. On --resume (merge already
# done), this default is stale but _phase_ci_trigger handles empty/stale values
# gracefully via git diff error suppression (2>/dev/null).
PRE_MERGE_SHA=$(git -C "$MAIN_REPO" rev-parse HEAD 2>/dev/null || echo "")

# =============================================================================
# Helpers
# =============================================================================

# Detect and auto-reset a stale orphan version-bump on local main.
# Pattern: a prior merge-to-main run completed the local merge + version bump
# but failed to push (e.g., CI failure). The next run sees local `main`
# divergent from `origin/main`: same merged content plus an extra version-bump
# commit. The diverged-branch merge then produces a false plugin.json conflict.
#
# This helper is conservative: it ONLY resets when the diff between HEAD and
# origin/main is a SINGLE file equal to VERSION_FILE_PATH. Any other divergent
# file (real work) causes a no-op so user resolution is preserved. The version
# bump that gets discarded is reapplied later by _phase_version_bump.
#
# Returns 0 if reset performed, 1 otherwise (no divergence, unset config, or
# other files differ).
_try_reset_stale_version_bump() {
    local _vf="${VERSION_FILE_PATH:-}"
    [ -z "$_vf" ] && return 1

    git fetch origin main --quiet 2>/dev/null || true

    # No divergence → nothing to do
    if [ "$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)" = "0" ]; then
        return 1
    fi

    local _diff_files
    _diff_files=$(git diff --name-only origin/main..HEAD 2>/dev/null || true)
    # Single-file diff and that file matches the configured version file path
    if [ "$_diff_files" = "$_vf" ]; then
        echo "INFO: Local main diverges from origin/main only by a stale version bump in ${_vf} — resetting to origin/main (version_bump phase will reapply correctly)."
        if ! git reset --hard origin/main -q 2>/dev/null; then
            echo "WARNING: Could not reset local main to origin/main."
            return 1
        fi
        return 0
    fi
    return 1
}

# =============================================================================
# Phase functions — each wraps a sequential phase with state recording
# =============================================================================

# --- 1.5) Sync worktree with main ---
_phase_sync() {
    _CURRENT_PHASE="sync"
    _state_write_phase "sync"

    # Fetch and merge origin/main into the worktree branch.
    # This surfaces merge conflicts here (where /dso:resolve-conflicts can operate)
    # rather than discovering them during the main-repo merge.
    echo "Syncing worktree with main..."
    git fetch origin main 2>&1 || {
        echo "WARNING: git fetch origin main failed — continuing with local state."
    }
    if ! git merge origin/main --no-edit -q 2>&1; then
        echo "ERROR: Syncing worktree with main failed. Resolve conflicts, then re-run."
        exit 1
    fi
    echo "OK: Worktree synced with main."
    # Clear any files restaged by pre-commit hooks during the merge commit,
    # to prevent dirty-check failures on resume (2613-a2eb).
    git reset HEAD --quiet || true

    # --- Check visual baseline intent ---
    # Use merge-base against origin/main (not local main) to detect only branch-originated
    # snapshot changes. After the sync merge above, local main hasn't been fast-forwarded
    # yet, so diffing HEAD vs local main would incorrectly flag CI baseline updates pulled
    # in from origin/main as branch-originated changes (false positive).
    MERGE_BASE_ORIGIN=$(git merge-base HEAD origin/main 2>/dev/null || git rev-parse HEAD)
    if [ -n "$VISUAL_BASELINE_PATH" ]; then
        BASELINE_DIFF=$(git diff --name-only "$MERGE_BASE_ORIGIN" HEAD -- "$VISUAL_BASELINE_PATH" 2>/dev/null | grep '\.png$' || true)
        if [ -n "$BASELINE_DIFF" ]; then
            BASELINE_CHECK_EXIT=0
            "${CLAUDE_PLUGIN_ROOT}/scripts/verify-baseline-intent.sh" || BASELINE_CHECK_EXIT=$?  # shim-exempt: plugin-internal sibling-script call from scripts/
            if [ "$BASELINE_CHECK_EXIT" -eq 2 ]; then
                echo "ERROR: Visual baseline changes need review. See .claude/docs/VISUAL-BASELINES.md"
                exit 1
            elif [ "$BASELINE_CHECK_EXIT" -ne 0 ]; then
                echo "ERROR: verify-baseline-intent.sh failed with exit code $BASELINE_CHECK_EXIT."
                exit 1
            fi
        fi
    else
        echo 'INFO: merge.visual_baseline_path not configured -- skipping baseline intent check.'
    fi

    # --- 2) Resolve main repo path and cd into it ---
    MAIN_REPO=$(dirname "$(git rev-parse --git-common-dir)")
    if [ -z "$MAIN_REPO" ]; then
        echo "ERROR: Could not determine main repo path."
        exit 1
    fi
    cd "$MAIN_REPO"
    # --- 2.3) Derive lock file path and clean stale git state ---
    LOCK_FILE="/tmp/merge-to-main-lock-$(echo -n "$MAIN_REPO" | shasum 2>/dev/null | cut -c1-8 || echo "default")"
    _cleanup_stale_git_state "$MAIN_REPO"

    # Verify main is checked out
    MAIN_BRANCH=$(git branch --show-current)
    if [ "$MAIN_BRANCH" != "main" ]; then
        echo "ERROR: Main repo is on '$MAIN_BRANCH', expected 'main'."
        exit 1
    fi

    # --- 2.4) Acquire merge lock (per-main-repo isolation) ---
    if ! _wait_for_lock "$LOCK_FILE"; then
        echo "ERROR: Could not acquire merge lock after timeout. Another merge may be in progress."
        exit 1
    fi
    # Release lock on any exit path (including CONFLICT_DATA exits)
    trap '_release_lock "$LOCK_FILE"' EXIT

    # --- 2.6) Pull remote changes before merging ---
    # The worktree branch already has origin/main merged (line 876), so after
    # _phase_merge, main will contain origin/main's content via the worktree.
    # The pull here is an optimization to reduce merge conflicts in _phase_merge,
    # but must not become a blocker when main and origin have diverged.
    echo "Pulling remote changes..."
    git fetch origin main 2>&1 || {
        echo "WARNING: git fetch origin main failed in main repo — continuing with local state."
    }
    if git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
        # origin/main is an ancestor of main. Distinguish two sub-cases:
        # (a) equal (HEAD == origin/main): local is up-to-date, skip pull.
        # (b) ahead (HEAD has commits not on origin): stale squash commits from a prior
        #     worktree session create false plugin.json conflicts in _phase_merge.
        #     Hard-reset to origin/main to restore a clean base (35eb-1824).
        _AHEAD_COUNT=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "0")
        if [ "$_AHEAD_COUNT" -gt 0 ]; then
            echo "INFO: Local main is ${_AHEAD_COUNT} commit(s) ahead of origin/main (stale) — resetting to origin/main."
            git reset --hard origin/main -q 2>&1 || {
                echo "WARNING: Could not reset local main to origin/main — _phase_merge may encounter false conflicts."
            }
        else
            echo "OK: origin/main is already an ancestor of main — skipping pull."
        fi
    else
        # main and origin have diverged. First check if the divergence is just
        # a stale orphan version bump from a prior failed merge-to-main run —
        # in that case, hard reset to origin/main and skip the merge.
        if _try_reset_stale_version_bump; then
            echo "OK: Stale-version-bump auto-reset complete (pull skipped)."
            _state_mark_complete "sync"
            return 0
        fi
        # Otherwise try merge (more tolerant than rebase).
        # Stash any local changes so the merge can proceed cleanly.
        STASHED=false
        if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
            echo "Stashing local changes before pull..."
            git stash push --quiet -m "merge-to-main: pre-pull stash"
            STASHED=true
        fi
        _abort_stale_rebase
        if git merge origin/main --no-edit -q 2>&1; then
            echo "OK: Merged origin/main into main."
        else
            # Merge failed — check if all conflicts are ticket-data files.
            local _merge_conflicts
            _merge_conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
            local _non_ticket=0
            while IFS= read -r _f; do
                [[ -z "$_f" ]] && continue
                case "$_f" in
                    .tickets-tracker/*/*.json | .tickets-tracker/*.json) ;;
                    *) _non_ticket=$(( _non_ticket + 1 )) ;;
                esac
            done <<< "$_merge_conflicts"

            if [[ "$_non_ticket" -eq 0 && -n "$_merge_conflicts" ]]; then
                # All conflicts are ticket-data — accept ours and complete merge.
                while IFS= read -r _f; do
                    [[ -z "$_f" ]] && continue
                    git checkout --ours "$_f" 2>/dev/null || true
                    git add "$_f" 2>/dev/null || true
                done <<< "$_merge_conflicts"
                git commit --no-edit -q 2>/dev/null || true
                echo "OK: Ticket-data conflicts auto-resolved during origin/main merge."
            else
                # Non-ticket conflicts present. Abort the merge and rely on the
                # worktree branch (which already has origin/main merged) to bring
                # origin/main content into main during _phase_merge.
                git merge --abort 2>/dev/null || true
                echo "WARNING: Could not merge origin/main into main (non-ticket conflicts). Continuing — worktree branch carries origin/main content."
            fi
        fi
        if $STASHED; then
            echo "Restoring stashed changes..."
            if ! git stash pop --quiet 2>/dev/null; then
                # Stash pop conflicted — discard the stash. The pre-stash files were
                # ticket data files (.tickets-tracker/), which the merge
                # step will overwrite anyway. Keeping an unmerged stash pop would block all subsequent ops.
                echo "WARNING: Stash pop had conflicts — resetting. Merge step will reconcile."
                git reset --merge 2>/dev/null || true
                git stash drop --quiet 2>/dev/null || true
            fi
        fi
    fi
    echo "OK: Pulled remote changes."

    _state_mark_complete "sync"
}

# --- 3) Merge worktree branch ---
_phase_merge() {
    # _phase_merge() — calls _squash_rebase_recovery on failure, then retries merge.
    # On unrecoverable failure: _state_increment_retry, directive to run --resume.
    _CURRENT_PHASE="merge"
    _state_write_phase "merge"

    # Ensure we are in the main repo directory. cd "$MAIN_REPO" normally happens
    # inside _phase_sync (line 938), but --resume skips _phase_sync when sync is
    # already complete, leaving CWD in the worktree. All git operations in
    # _phase_merge, _phase_version_bump, _phase_validate, and _phase_push must
    # run from MAIN_REPO — make the cd explicit here so the invariant holds
    # regardless of how the phase was reached. (Fixes 34cc-526c, 687d-b448.)
    cd "$MAIN_REPO"

    # Detect and reset stale local main before merging (f6c6-362c).
    # Mirrors _phase_sync's drift-reset block. Needed because --resume can skip
    # _phase_sync and enter _phase_merge directly with local main still ahead of
    # origin/main (e.g., after an interrupted version_bump), causing a
    # plugin.json conflict on the merge retry.
    git fetch origin main --quiet 2>/dev/null || true
    if git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
        _MERGE_PHASE_AHEAD=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "0")
        if [ "$_MERGE_PHASE_AHEAD" -gt 0 ]; then
            echo "INFO: _phase_merge: local main is ${_MERGE_PHASE_AHEAD} commit(s) ahead of origin/main (stale version bump?) — resetting to origin/main."
            git reset --hard origin/main -q 2>/dev/null || {
                echo "WARNING: _phase_merge: Could not reset to origin/main — merge may encounter false conflicts."
            }
        fi
    else
        # Diverged case: detect the same stale-version-bump pattern as in
        # _phase_sync. Mirrors the diverged-branch handling so --resume
        # entering _phase_merge directly after an interrupted sync also
        # auto-resolves the conflict. The helper's INFO log is preserved
        # so the reset is visible in the merge-phase output.
        _try_reset_stale_version_bump || true
    fi

    # Find the last meaningful commit message from the worktree branch (skip chore/cleanup commits)
    if [ -n "$MSG_EXCLUSION_PATTERN" ]; then
        LAST_MSG=$(git log "$BRANCH" --format='%s' --no-merges -- \
            | grep -v -E "$MSG_EXCLUSION_PATTERN" \
            | head -1 || true)
    else
        LAST_MSG=$(git log "$BRANCH" --format='%s' --no-merges -- \
            | head -1 || true)
    fi
    if [ -z "$LAST_MSG" ]; then
        LAST_MSG="Merge $BRANCH"
    fi
    MERGE_MSG="$LAST_MSG (merge $BRANCH)"

    # Capture pre-merge SHA so we can later detect whether the merge contained
    # non-ticket-data changes (used for the CI trigger check after push).
    PRE_MERGE_SHA=$(git rev-parse HEAD)

    # Stash dirty tracked files on main before merging. Hook scripts that load
    # library files from the main repo via CLAUDE_PLUGIN_ROOT can leave modified
    # tracked files on main, causing "local changes would be overwritten" errors.
    _MERGE_PHASE_STASHED=false
    if ! git diff --quiet 2>/dev/null; then
        local _dirty_count
        _dirty_count=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
        echo "INFO: Stashing ${_dirty_count} dirty file(s) on main before merge..."
        if git stash push --quiet -m "merge-to-main: pre-merge stash" 2>/dev/null; then
            _MERGE_PHASE_STASHED=true
        else
            echo "WARNING: Failed to stash dirty files before merge — proceeding without stash."
        fi
    fi

    # Helper: restore stash after merge (pop on success, reset+drop on conflict).
    _restore_pre_merge_stash() {
        if ! $_MERGE_PHASE_STASHED; then return 0; fi
        if ! git stash pop --quiet 2>/dev/null; then
            echo "WARNING: Pre-merge stash pop conflicted — dropping stash (merged content takes precedence)."
            git reset --merge 2>/dev/null || true
            git stash drop --quiet 2>/dev/null || true
        fi
    }

    echo "Merging $BRANCH into main..."
    if ! git merge --no-ff "$BRANCH" -m "$MERGE_MSG" --quiet 2>&1; then
        # First attempt failed — abort the merge and try squash-rebase recovery
        git merge --abort 2>/dev/null || true
        echo "INFO: Merge failed. Attempting squash-rebase recovery..."

        # Save current directory and cd back to worktree for squash-rebase
        _MERGE_SAVED_DIR="$(pwd)"
        cd "$WORKTREE_DIR"

        _RECOVERY_RC=0
        _squash_rebase_recovery 2>&1 || _RECOVERY_RC=$?

        if [ "$_RECOVERY_RC" -eq 0 ]; then
            # Recovery succeeded — return to main repo and retry the merge
            cd "$_MERGE_SAVED_DIR"
            echo "INFO: Squash-rebase recovery succeeded. Retrying merge..."
            if git merge --no-ff "$BRANCH" -m "$MERGE_MSG" --quiet 2>&1; then
                echo "OK: Merged $BRANCH into main (after squash-rebase recovery)."
                _restore_pre_merge_stash
            else
                # Retry also failed — increment retry count and exit with directive
                git merge --abort 2>/dev/null || true
                _restore_pre_merge_stash
                _state_increment_retry
                echo "ERROR: Merge retry failed after squash-rebase recovery."
                echo "  Run: merge-to-main.sh --resume"
                exit 1
            fi
        else
            # Recovery failed — return to main repo, increment retry, exit with directive
            cd "$_MERGE_SAVED_DIR"
            _restore_pre_merge_stash
            _state_increment_retry
            echo "ERROR: Squash-rebase recovery failed. Cannot resolve automatically."
            echo "  Run: merge-to-main.sh --resume"
            exit 1
        fi
    else
        echo "OK: Merged $BRANCH into main."
        _restore_pre_merge_stash
    fi

    _state_record_merge_sha "$(git rev-parse HEAD)"
    _state_mark_complete "merge"
}

# --- 3.25) Version bump (between merge and validate) ---
_phase_version_bump() {
    _CURRENT_PHASE="version_bump"; _state_write_phase "version_bump"
    # Ensure CWD is the main repo — --resume may skip _phase_merge (when merge is
    # already complete), so the cd "$MAIN_REPO" in _phase_merge would not run.
    # All git operations (git diff, git add -u, git commit --amend) must target
    # MAIN_REPO HEAD, not the worktree. (Fixes resume-from-version_bump gap.)
    cd "$MAIN_REPO"
    # Idempotency: skip if completed in state AND _state_init not called in this process.
    # The marker file records the PID of the process that ran _state_init; if the current
    # process did not call _state_init (i.e. PIDs differ), a prior run may have already
    # completed this phase — check the state file before running again.
    local _marker_file="/tmp/merge-state-init-marker-${BRANCH//\//-}" _init_pid=""
    [[ -f "$_marker_file" ]] && _init_pid=$(cat "$_marker_file" 2>/dev/null || echo "")
    if [[ "$_init_pid" != "${BASHPID:-$$}" ]]; then
        local _state_file; _state_file=$(_state_file_path) 2>/dev/null || true
        if [[ -n "$_state_file" && -f "$_state_file" ]] && [[ "$(python3 -c "import json;d=json.load(open('$_state_file'));print('y' if 'version_bump' in d.get('completed_phases',[]) else 'n')" 2>/dev/null)" == "y" ]]; then
            echo "INFO: version_bump already completed (resume skip)."; return 0; fi; fi
    if [[ -z "${BUMP_TYPE:-}" ]]; then
        # Default to patch when version.file_path is configured (fb93-69da).
        # This eliminates the fragile multi-hop --bump relay chain:
        # sprint → end-session → merge-to-main.sh was losing --bump.
        if [[ -n "${VERSION_FILE_PATH:-}" ]]; then
            BUMP_TYPE="patch"
            echo "INFO: --bump not specified — defaulting to patch (version.file_path configured)."
        else
            echo 'INFO: --bump not specified and version.file_path not configured -- skipping version bump.'
            _state_mark_complete "version_bump"; return 0
        fi
    fi
    if [[ "${VERSION_FILE_PATH+SET}" == "SET" && -z "${VERSION_FILE_PATH:-}" ]]; then
        echo 'INFO: version.file_path not configured -- skipping version bump.'
        _state_mark_complete "version_bump"; return 0; fi
    local _bf="--${BUMP_TYPE:-patch}" _bs
    _bs=$(command -v bump-version.sh 2>/dev/null || echo "${_SCRIPT_DIR:-${CLAUDE_PLUGIN_ROOT:-}/scripts}/bump-version.sh")
    # Idempotency guard: if the version file is already bumped (modified on disk)
    # from a prior interrupted attempt, skip bump-version.sh to avoid double-bump.
    local _vf="${VERSION_FILE_PATH:-}"
    if [[ -n "$_vf" && -f "$_vf" ]] && ! git diff --quiet -- "$_vf" 2>/dev/null; then
        echo "INFO: version file already bumped (prior attempt) — skipping bump-version.sh."
    else
        echo "Bumping version ($_bf)..."
        if ! bash "$_bs" "$_bf" 2>&1; then echo 'ERROR: bump-version.sh failed. Fix version file before pushing.'; exit 1; fi
    fi
    echo "OK: Version bumped."
    # If version file is package.json, sync package-lock.json (f1d9-5071)
    if [[ "${_vf}" == *"package.json" ]] && command -v npm >/dev/null 2>&1; then
        local _pkg_dir
        _pkg_dir=$(dirname "${_vf}")
        echo "version_bump: running npm install --package-lock-only to sync package-lock.json"
        (cd "$_pkg_dir" && npm install --package-lock-only --quiet 2>/dev/null) || \
            echo "WARNING: npm install --package-lock-only failed — package-lock.json may be out of sync"
    fi
    git add -u 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        DSO_MECHANICAL_AMEND=1 git commit --amend --no-edit --quiet
        echo 'OK: Folded version bump into merge commit.'; fi
    _state_mark_complete "version_bump"
}

# --- 3.5) Post-merge validation ---
_phase_validate() {
    _CURRENT_PHASE="validate"
    _state_write_phase "validate"
    # Ensure CWD is the main repo — --resume may skip _phase_merge, so bare git
    # operations (git add .gitignore, git diff --cached, git commit --amend) must
    # run from MAIN_REPO. (Fixes resume-from-validate gap.)
    cd "$MAIN_REPO"

    # Pre-commit hooks use stages: [commit] which excludes merge commits.
    # Run format-check and lint here to catch issues that bypass pre-commit via merge.
    _APP_DIR_NAME="${PATHS_APP_DIR:-app}"
    if [ -d "$MAIN_REPO/$_APP_DIR_NAME" ]; then
        echo "Running post-merge validation (format-check + lint in parallel)..."
        POST_MERGE_FAIL=false
        create_managed_tempdir _VALIDATION_TMPDIR
        _FMT_LOG="${_VALIDATION_TMPDIR}/fmt.log"
        _LINT_LOG="${_VALIDATION_TMPDIR}/lint.log"

        # Run both checks concurrently as background jobs
        (cd "$MAIN_REPO/$_APP_DIR_NAME" && PY_RUN_APPROACH=local $CMD_FORMAT_CHECK 2>&1) > "$_FMT_LOG" &
        _FMT_PID=$!
        (cd "$MAIN_REPO/$_APP_DIR_NAME" && PY_RUN_APPROACH=local $CMD_LINT 2>&1) > "$_LINT_LOG" &
        _LINT_PID=$!

        # Collect exit codes after both finish
        wait $_FMT_PID
        _FMT_RC=$?
        wait $_LINT_PID
        _LINT_RC=$?

        if [[ $_FMT_RC -ne 0 ]]; then
            cat "$_FMT_LOG"
            echo "WARNING: Post-merge format-check failed. Run 'make format' to fix."
            POST_MERGE_FAIL=true
        fi
        if [[ $_LINT_RC -ne 0 ]]; then
            cat "$_LINT_LOG"
            echo "WARNING: Post-merge lint failed. Fix lint errors before pushing."
            POST_MERGE_FAIL=true
        fi
        rm -f "$_FMT_LOG" "$_LINT_LOG"

        if [[ "$POST_MERGE_FAIL" == "true" ]]; then
            echo "ERROR: Post-merge validation failed. Fix issues, amend the merge commit, then retry."
            exit 1
        fi
        echo "OK: Post-merge validation passed."
    fi

    # Stage any post-merge artifacts (.gitignore entries for worktree dirs)
    git add .gitignore 2>/dev/null || true

    # Auto-stage ticket-tracker changes — CI failure tracking pushes ticket
    # commits directly to main, and the merge can leave ticket-tracker data files dirty.
    # These are data files, not code, so auto-staging into the merge commit is safe.
    git add .tickets-tracker/ 2>/dev/null || true

    # Check for dirty tracked files (modified but not staged)
    REMAINING_DIRTY=$(git diff --name-only 2>/dev/null || true)
    # Check for untracked files (not in .gitignore)
    REMAINING_UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || true)

    if [ -n "$REMAINING_DIRTY" ] || [ -n "$REMAINING_UNTRACKED" ]; then
        echo "ERROR: Main repo has unexpected dirty files after merge. Fix before pushing."
        [ -n "$REMAINING_DIRTY" ] && echo "  Modified (unstaged): $REMAINING_DIRTY"
        [ -n "$REMAINING_UNTRACKED" ] && echo "  Untracked: $REMAINING_UNTRACKED"
        exit 1
    fi

    if ! git diff --cached --quiet 2>/dev/null; then
        DSO_MECHANICAL_AMEND=1 git commit --amend --no-edit --quiet
        echo "OK: Folded post-merge changes into merge commit."
    fi

    _state_mark_complete "validate"
}

# --- 4) Push ---
_phase_push() {
    _CURRENT_PHASE="push"
    _state_write_phase "push"
    # Ensure CWD is the main repo — --resume may skip _phase_merge, so bare
    # git push must run from MAIN_REPO. (Fixes resume-from-push gap.)
    cd "$MAIN_REPO"

    echo "Pushing main..."
    if ! _check_push_needed; then
        echo "INFO: Push skipped - already on origin/main."
    else
        if ! retry_with_backoff 4 2 git push 2>&1; then
            echo "ERROR: Push failed after retries. Try: git pull --rebase && git push"
            exit 1
        fi
        echo "OK: Pushed main to remote."
    fi

    _state_mark_complete "push"

    # --- Push tickets branch (triggers outbound bridge) ---
    # The ticket CLI commits events to the local tickets branch but never pushes.
    # Push here so the outbound bridge workflow picks up local ticket changes.
    # Pull first (with rebase) to incorporate inbound bridge changes from CI.
    _TRACKER_DIR="$MAIN_REPO/.tickets-tracker"
    if [ -d "$_TRACKER_DIR" ] && git -C "$_TRACKER_DIR" rev-parse --verify tickets &>/dev/null; then
        echo "Syncing tickets branch..."
        # Commit any uncommitted ticket changes before syncing.
        # The ticket CLI commits per-mutation, but cache files and
        # interrupted operations can leave uncommitted state.
        if [ -n "$(git -C "$_TRACKER_DIR" status --porcelain 2>/dev/null)" ]; then
            git -C "$_TRACKER_DIR" add -A 2>/dev/null
            git -C "$_TRACKER_DIR" commit -q --no-verify -m "chore: commit uncommitted ticket state before sync" 2>/dev/null || true
        fi
        # Remove stale SNAPSHOT files before pull to prevent "untracked files
        # would be overwritten by merge" errors. SNAPSHOTs are regenerated on
        # demand by the compact-all command and are safe to delete (3534-b90d).
        while IFS= read -r _snap_rel; do
            [[ -z "$_snap_rel" ]] && continue
            rm -f "$_TRACKER_DIR/$_snap_rel" 2>/dev/null && \
                echo "INFO: Removed stale SNAPSHOT before tickets sync: $_snap_rel" || true
        done < <(git -C "$_TRACKER_DIR" ls-files --others 2>/dev/null | grep -E "SNAPSHOT\.json$" || true)

        # Pull inbound bridge changes (SYNC events, Jira-originated tickets)
        if git -C "$_TRACKER_DIR" pull --rebase origin tickets 2>&1; then
            # Capture remote SHA before push to detect no-op pushes (71fa-c068).
            _REMOTE_SHA_BEFORE=$(git -C "$_TRACKER_DIR" rev-parse origin/tickets 2>/dev/null || echo "")
            _LOCAL_SHA=$(git -C "$_TRACKER_DIR" rev-parse tickets 2>/dev/null || echo "")
            # Push local ticket events to trigger outbound bridge.
            # Skip hooks: the tickets orphan branch has no .pre-commit-config.yaml
            # and pre-push hooks are designed for the main branch, not ticket data.
            # (ticket-lib.sh already uses --no-verify for ticket commits.)
            if PRE_COMMIT_ALLOW_NO_CONFIG=1 git -C "$_TRACKER_DIR" push origin tickets 2>&1; then
                echo "OK: Tickets branch synced with remote."
                # Only dispatch outbound bridge when the push actually sent new
                # commits. Prevents dispatch storms when multiple merge-to-main
                # runs push an already-up-to-date tickets branch (71fa-c068).
                if [ "$_LOCAL_SHA" != "$_REMOTE_SHA_BEFORE" ] && command -v gh &>/dev/null; then
                    gh workflow run "Outbound Bridge" --ref main 2>/dev/null && \
                        echo "OK: Outbound Bridge triggered." || \
                        echo "WARNING: Could not trigger Outbound Bridge workflow."
                elif [ "$_LOCAL_SHA" = "$_REMOTE_SHA_BEFORE" ]; then
                    echo "INFO: Tickets branch already up-to-date — skipping Outbound Bridge dispatch."
                fi
            else
                echo "WARNING: Tickets branch push failed — ticket changes will sync on next merge."
            fi
        else
            echo "WARNING: Tickets branch pull failed — aborting rebase and skipping push."
            git -C "$_TRACKER_DIR" rebase --abort 2>/dev/null || true
        fi
    fi
}

# --- 4.5) Archive phase — read PRECONDITIONS context and log; no-op on failure ---
_phase_archive() {
    _CURRENT_PHASE="archive"
    _state_write_phase "archive"

    # Read PRECONDITIONS context for informational logging (fail-open).
    # Tickets with no PRECONDITIONS events (legacy / pre-manifest) exit non-zero
    # from _read_latest_preconditions; the || true guard prevents phase failure.
    local _ticket_lib="$_SCRIPT_DIR/ticket-lib.sh"
    if [[ -f "$_ticket_lib" ]]; then
        # shellcheck source=/dev/null
        source "$_ticket_lib" 2>/dev/null || true
        if declare -f _read_latest_preconditions >/dev/null 2>&1; then
            local _tkdir="$_CFG_TKDIR"
            # If no tickets directory is configured, use the default
            [[ -z "$_tkdir" ]] && _tkdir="${REPO_ROOT}/.tickets-tracker"
            local _epic_id="${BRANCH_NAME:-unknown}"
            local _ticket_dir="$_tkdir/$_epic_id"
            local _preconditions_json=""
            _preconditions_json=$(_read_latest_preconditions "$_ticket_dir" 2>/dev/null) || true
            if [[ -n "$_preconditions_json" ]]; then
                echo "[merge-to-main] archive: preconditions summary: $_preconditions_json" >&2
            else
                echo "[merge-to-main] archive: preconditions: pre-manifest (no events for $_epic_id)" >&2
            fi
        fi
    fi

    _state_mark_complete "archive"
}

# --- 5) Trigger CI if HEAD has [skip ci] but merge contained changes ---
_phase_ci_trigger() {
    _CURRENT_PHASE="ci_trigger"
    _state_write_phase "ci_trigger"

    # If a [skip ci] commit lands on top of the merge commit, CI is suppressed even
    # though the merge contained real changes.
    # Mitigation: if the merge introduced changes AND the current HEAD
    # on origin carries [skip ci], explicitly dispatch the CI workflow so it runs.
    HEAD_MSG=$(git log -1 --format='%s' origin/main 2>/dev/null || git log -1 --format='%s' 2>/dev/null || true)
    CODE_CHANGES=$(git diff --name-only "$PRE_MERGE_SHA" HEAD 2>/dev/null | head -1 || true)
    if [ -n "${CI_WORKFLOW_NAME:-}" ]; then
        if echo "$HEAD_MSG" | grep -q '\[skip ci\]' && [ -n "$CODE_CHANGES" ]; then
            echo "INFO: HEAD has [skip ci] but merge contained code changes — triggering CI workflow..."
            if command -v gh >/dev/null 2>&1; then
                if gh workflow run "$CI_WORKFLOW_NAME" --ref main 2>&1; then
                    echo "OK: CI workflow triggered on main."
                else
                    echo "WARNING: Could not trigger CI workflow (gh workflow run failed). Trigger manually or check GitHub Actions."
                fi
            else
                echo "WARNING: gh CLI not found — cannot trigger CI. Trigger manually or check GitHub Actions."
            fi
        fi
    else
        echo 'INFO: merge.ci_workflow_name not configured -- skipping CI trigger.'
    fi

    _state_mark_complete "ci_trigger"
}

# =============================================================================
# CLI argument dispatch
# =============================================================================

# Ordered list of all phase names (used by --resume to find next incomplete phase)
_ALL_PHASES=(sync merge version_bump validate push archive ci_trigger)

# --- Parse CLI arguments ---
_CLI_RESUME=false
BUMP_TYPE=""

_CLI_ARGS=("$@")
_CLI_IDX=0
while [[ $_CLI_IDX -lt ${#_CLI_ARGS[@]} ]]; do
    _arg="${_CLI_ARGS[$_CLI_IDX]}"
    case "$_arg" in
        --resume)
            _CLI_RESUME=true
            ;;
        --bump=*)
            BUMP_TYPE="${_arg#--bump=}"
            ;;
        --bump)
            # Look ahead for optional type argument (patch|minor)
            _NEXT_IDX=$(( _CLI_IDX + 1 ))
            if [[ $_NEXT_IDX -lt ${#_CLI_ARGS[@]} ]]; then
                _next="${_CLI_ARGS[$_NEXT_IDX]}"
                case "$_next" in
                    patch|minor)
                        BUMP_TYPE="$_next"
                        _CLI_IDX=$_NEXT_IDX
                        ;;
                    *)
                        # Next arg is not a bump type — default to patch
                        BUMP_TYPE="patch"
                        ;;
                esac
            else
                BUMP_TYPE="patch"
            fi
            ;;
        --help)
            # Already handled above (before worktree checks); should not reach here
            exit 0
            ;;
        *)
            echo "WARNING: Unknown argument '$_arg'. See --help for usage." >&2
            ;;
    esac
    _CLI_IDX=$(( _CLI_IDX + 1 ))
done
export BUMP_TYPE

# --- Dispatch: --resume ---
if [[ "$_CLI_RESUME" == "true" ]]; then
    _sf=$(_state_file_path)
    # Escalation gate: check retry budget before attempting anything
    _resume_retry_count=$(_state_get_retry_count 2>/dev/null || echo "0")
    if [[ "$_resume_retry_count" -ge "$MAX_MERGE_RETRIES" ]]; then
        echo "ESCALATE: Merge has failed 5 times. Stop and ask the user for help. Do NOT retry."
        exit 1
    fi

    # --- Mid-rebase state detection ---
    # If a rebase is currently in progress (REBASE_HEAD exists in the main repo git dir),
    # the previous sync phase was interrupted mid-rebase. Attempt auto-resolution of
    # archive conflicts first; if that fails, report actionable instructions.
    _MAIN_REPO_FOR_RESUME=""
    if [[ -f .git ]]; then
        # We're in a worktree (.git is a file) — resolve main repo from git common dir.
        # git-common-dir may return a relative path (e.g., "../main/.git") — resolve to
        # absolute so dirname yields the main repo root, not a relative/wrong directory.
        _common_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)
        if [[ -n "$_common_dir" && "$_common_dir" != /* ]]; then
            _common_dir="$(cd "$_common_dir" 2>/dev/null && pwd || true)"
        fi
        _MAIN_REPO_FOR_RESUME=$(dirname "$_common_dir" 2>/dev/null || true)
    elif [[ -d .git ]]; then
        # We're in the main repo (.git is a directory) — main repo is CWD
        _MAIN_REPO_FOR_RESUME="$(pwd)"
    fi
    _MAIN_GIT_DIR=""
    if [[ -n "$_MAIN_REPO_FOR_RESUME" ]]; then
        _MAIN_GIT_DIR=$(git -C "$_MAIN_REPO_FOR_RESUME" rev-parse --git-dir 2>/dev/null || true)
        if [[ -n "$_MAIN_GIT_DIR" && "$_MAIN_GIT_DIR" != /* ]]; then
            _MAIN_GIT_DIR="$_MAIN_REPO_FOR_RESUME/$_MAIN_GIT_DIR"
        fi
    fi
    if [[ -n "$_MAIN_GIT_DIR" && -f "$_MAIN_GIT_DIR/REBASE_HEAD" ]]; then
        echo "INFO: --resume detected mid-rebase state in main repo (REBASE_HEAD present)."
        echo "INFO: Attempting auto-resolution of archive rename/delete conflicts..."
        _PREV_DIR="$(pwd)"
        cd "$_MAIN_REPO_FOR_RESUME"
        _REBASE_AUTO_RC=0
        _auto_resolve_archive_conflicts 2>&1 || _REBASE_AUTO_RC=$?
        cd "$_PREV_DIR"
        if [[ "$_REBASE_AUTO_RC" -ne 0 ]]; then
            echo "ACTION REQUIRED: Rebase is in progress in main repo but conflicts could not be auto-resolved."
            echo "  1. cd ${_MAIN_REPO_FOR_RESUME:-<main-repo>}"
            echo "  2. Resolve conflicts manually (git status to inspect)"
            echo "  3. git rebase --continue"
            echo "  4. cd back to worktree and run: merge-to-main.sh --resume"
            exit 1
        fi
        echo "OK: Mid-rebase conflicts resolved. Continuing from sync phase..."
        # Mark sync as complete so --resume continues from merge
        _state_mark_complete "sync"
    fi

    # --- Idempotent push detection (f9e7-2c50) ---
    # If origin/main already contains local HEAD, the push phase already completed
    # but was not recorded in the state file (SIGURG fired between git push and
    # _state_mark_complete "push", or the state file expired/was lost).
    # Pre-mark all phases through push as complete so the resume loop skips them
    # and never re-runs _phase_merge (which would create a duplicate merge commit).
    if git fetch origin main --quiet 2>/dev/null; then
        _ORIGIN_AHEAD_RESUME=$(git log origin/main..HEAD --oneline 2>/dev/null || true)
        if [[ -z "$_ORIGIN_AHEAD_RESUME" ]]; then
            echo "INFO: --resume: origin/main already contains local HEAD — push was already done."
            echo "INFO: Pre-marking phases through push as complete to prevent duplicate merge."
            # Ensure state file exists so _state_mark_complete can write
            if [[ ! -f "$_sf" ]]; then
                _state_init 2>/dev/null || true
            fi
            for _pre_phase in sync merge version_bump validate push; do
                _state_mark_complete "$_pre_phase" 2>/dev/null || true
            done
        fi
    fi

    if [[ ! -f "$_sf" ]]; then
        echo "WARNING: No state file found at '$_sf'. Starting from the beginning."
        # Fall through to run all phases
    else
        # Read completed_phases and find the first incomplete phase
        _COMPLETED=$(python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
print(' '.join(d.get('completed_phases', [])))
" 2>/dev/null || echo "")
        # Find the first phase with conflict state (fresh attempt)
        _CONFLICT_PHASE=$(python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
phases = d.get('phases', {})
for name, info in phases.items():
    if info.get('status') == 'conflict':
        print(name)
        break
" 2>/dev/null || echo "")

        _FOUND_RESUME_START=false
        for _pname in "${_ALL_PHASES[@]}"; do
            # If this phase has a conflict, start fresh from here
            if [[ -n "$_CONFLICT_PHASE" && "$_pname" == "$_CONFLICT_PHASE" ]]; then
                echo "INFO: Resuming from phase '$_pname' (conflict state — fresh attempt)."
                _FOUND_RESUME_START=true
            fi
            if [[ "$_FOUND_RESUME_START" == "true" ]]; then
                "_phase_${_pname}"
            elif ! echo " $_COMPLETED " | grep -q " $_pname "; then
                # Not in completed_phases — start here
                echo "INFO: Resuming from phase '$_pname' (first incomplete phase)."
                _FOUND_RESUME_START=true
                "_phase_${_pname}"
            fi
            # else: phase is already complete — skip it
        done

        if [[ "$_FOUND_RESUME_START" == "false" ]]; then
            echo "INFO: All phases already complete (nothing to resume)."
        fi

        echo "DONE: $BRANCH resumed, merged, committed, and pushed."
        _state_reset_retry_count
        rm -f "$(_state_file_path)" 2>/dev/null
        rm -f "/tmp/merge-state-init-marker-${BRANCH//\//-}" 2>/dev/null
        exit 0
    fi
fi

# --- No-args (or state file missing for --resume): run all phases sequentially ---
if [[ $# -eq 0 ]]; then
    echo "Running all phases sequentially. Use --resume to continue from the last" \
         "incomplete phase if interrupted." >&2
fi

_phase_sync
_phase_merge
_phase_version_bump
_phase_validate
_phase_push
_phase_archive
_phase_ci_trigger

rm -f "$(_state_file_path)" 2>/dev/null
rm -f "/tmp/merge-state-init-marker-${BRANCH//\//-}" 2>/dev/null
echo "DONE: $BRANCH merged, committed, and pushed."
