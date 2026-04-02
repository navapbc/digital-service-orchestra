#!/usr/bin/env bash
set -euo pipefail
# scripts/capture-review-diff.sh
# Canonical diff capture for the review workflow.
#
# Usage: capture-review-diff.sh <diff-file> <stat-file> [extra-exclusion ...]
#
# Always excludes:
#   - visual.baseline_directory/*.png (from dso-config.conf; skipped if unset)
#
# Additional exclusions can be passed as extra arguments (e.g., ':!app/snapshots/*.html').
#
# Uses `tee` instead of `>` to avoid the worktree fd redirect issue where
# `git diff > file` silently produces an empty file.
#
# Guard: if diff is empty after exclusions (e.g., snapshot-only commit), falls
# back to a tickets-only-excluded diff so the reviewer still has content.
# Final fallback: HEAD~1 (post-compaction checkpoint scenario).

set -euo pipefail

DIFF_FILE="$1"
STAT_FILE="$2"
shift 2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../hooks/lib/merge-state.sh
source "$SCRIPT_DIR/../hooks/lib/merge-state.sh"

# --- Build exclusion list ---
# REVIEW-DEFENSE: hardcoded default matches the v3 ticket system path; config-driven
# ticket directory support (reading tickets.directory from dso-config.conf) is tracked
# as a follow-up improvement — see bug ticket 3f9b-421d for stale path cleanup.
EXCLUDES=(':!.tickets-tracker/' ':!.sync-state.json')

# Read visual baseline directory from config (e.g., app/tests/e2e/snapshots/)
BASELINE_DIR=$("$SCRIPT_DIR/read-config.sh" visual.baseline_directory 2>/dev/null || true)
if [[ -n "$BASELINE_DIR" ]]; then
    EXCLUDES+=(":!${BASELINE_DIR%/}/*.png")
fi

# Caller-supplied exclusions (e.g., ':!app/tests/unit/templates/snapshots/*.html')
for ex in "$@"; do
    EXCLUDES+=("$ex")
done

# --- Merge-aware / Rebase-aware: scope diff to worktree-branch files only ---
# Uses shared library (merge-state.sh) to detect merge/rebase state and return
# only files changed on the worktree branch (HEAD-anchored).
# ms_get_worktree_only_files_from_head: diff merge-base..HEAD (HEAD-anchored variant
# required here; other consumers use orig-head-anchored ms_get_worktree_only_files).
#
# REVIEW-DEFENSE: _merge_base and _MERGE_FILE_PATHSPECS are computed via separate
# library calls. If ms_get_merge_base fails (returns empty) we must also discard the
# pathspecs — otherwise git diff "" -- <pathspecs> uses HEAD as the base while
# applying merge-filtered pathspecs, producing a contradictory diff that excludes
# incoming-only files but uses the wrong base commit. The guard below keeps both
# values in sync: if _merge_base is empty, _MERGE_FILE_PATHSPECS is cleared so the
# script falls back to the standard staged/unstaged diff path.
_MERGE_FILE_PATHSPECS=()
_merge_base=""
if ms_is_merge_in_progress || ms_is_rebase_in_progress; then
    _merge_base=$(ms_get_merge_base 2>/dev/null || echo "")
    while IFS= read -r _f; do
        [[ -n "$_f" ]] && _MERGE_FILE_PATHSPECS+=("$_f")
    done <<< "$(ms_get_worktree_only_files_from_head 2>/dev/null || echo "")"
    # Guard: if merge-base computation failed, discard pathspecs too so both
    # fail together and the script falls through to the normal diff path.
    if [[ -z "$_merge_base" ]]; then
        _MERGE_FILE_PATHSPECS=()
    fi
fi

# --- Guard: merge in progress with no worktree-only files ---
# When merge-base was computed successfully but the worktree branch has no
# changed files (all staged files came from main), produce an empty diff.
# Without this, the fallback to `git diff --staged` captures ALL merge files.
if (ms_is_merge_in_progress || ms_is_rebase_in_progress) && \
   [[ -n "$_merge_base" ]] && [[ ${#_MERGE_FILE_PATHSPECS[@]} -eq 0 ]]; then
    touch "$DIFF_FILE"
    echo "" > "${DIFF_FILE%.diff}.stat"
    exit 0
fi

# --- Check for untracked files that would be invisible to diff ---
# Untracked files are not seen by `git diff --staged` or `git diff`, so
# they produce an empty diff and cause hash mismatches at the review gate.
# Warn the user to stage them first.
_untracked_files=$(git ls-files --others --exclude-standard 2>/dev/null \
    | { grep -v '^\.tickets-tracker/' || true; } \
    | { grep -v '^\.sync-state\.json$' || true; })
if [[ -n "$_untracked_files" ]]; then
    # Check if any staged or modified tracked files exist — if the diff would
    # otherwise be empty (only untracked files), warn about the gap.
    _has_staged=$(git diff --staged --name-only 2>/dev/null | head -1)
    _has_unstaged=$(git diff --name-only 2>/dev/null | head -1)
    if [[ -z "$_has_staged" && -z "$_has_unstaged" ]]; then
        echo "WARNING: Only untracked files detected — git add them before review:" >&2
        echo "$_untracked_files" | sed 's/^/  /' >&2
        echo "Run: git add <files> then re-run /dso:review" >&2
    fi
fi

# --- Capture diff with exclusions (tee for worktree fd compatibility) ---
if [[ ${#_MERGE_FILE_PATHSPECS[@]} -gt 0 ]]; then
    # Merge mode: diff from merge-base to show only worktree-branch changes.
    # git diff --staged/git diff don't work here because during a merge the
    # staged files are the incoming changes, not the worktree branch's work.
    git diff "$_merge_base" -- "${_MERGE_FILE_PATHSPECS[@]}" "${EXCLUDES[@]}" | tee "$DIFF_FILE" > /dev/null
else
    { git diff --staged -- "${EXCLUDES[@]}"; git diff -- "${EXCLUDES[@]}"; } | tee "$DIFF_FILE" > /dev/null
fi

# Guard: if empty after exclusions (snapshot-only commit), fall back to a diff
# without any exclusions so verify-review-diff.sh doesn't reject the empty file.
# Merge-aware: if in merge mode, use the merge-base diff instead of the staged diff
# to avoid capturing incoming-only changes from the merge source.
if ! [ -s "$DIFF_FILE" ]; then
    if [[ ${#_MERGE_FILE_PATHSPECS[@]} -gt 0 ]]; then
        git diff "$_merge_base" -- "${_MERGE_FILE_PATHSPECS[@]}" | tee "$DIFF_FILE" > /dev/null
    else
        { git diff --staged; git diff; } | tee "$DIFF_FILE" > /dev/null
    fi
fi

# Final fallback: last commit (e.g., post-compaction checkpoint scenario)
[ -s "$DIFF_FILE" ] || git diff HEAD~1 | tee "$DIFF_FILE" > /dev/null

# --- Capture stat with exclusions ---
# Guard grep -v with || true to prevent pipefail crash when no untracked files
# match (grep -v returns exit 1 when all lines are filtered out).
if [[ ${#_MERGE_FILE_PATHSPECS[@]} -gt 0 ]]; then
    { git diff "$_merge_base" --stat -- "${_MERGE_FILE_PATHSPECS[@]}" "${EXCLUDES[@]}"; \
      git ls-files --others --exclude-standard | { grep -v '^\.tickets-tracker/' || true; } | { grep -v '^\.sync-state\.json$' || true; } | sed 's/$/ (untracked)/'; } | tee "$STAT_FILE" > /dev/null
else
    { git diff HEAD --stat -- "${EXCLUDES[@]}"; \
      git ls-files --others --exclude-standard | { grep -v '^\.tickets-tracker/' || true; } | { grep -v '^\.sync-state\.json$' || true; } | sed 's/$/ (untracked)/'; } | tee "$STAT_FILE" > /dev/null
fi
