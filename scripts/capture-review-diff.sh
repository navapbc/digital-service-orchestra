#!/usr/bin/env bash
# lockpick-workflow/scripts/capture-review-diff.sh
# Canonical diff capture for the review workflow.
#
# Usage: capture-review-diff.sh <diff-file> <stat-file> [extra-exclusion ...]
#
# Always excludes:
#   - .tickets/ (issue tracker metadata; always unstaged in worktree sessions)
#   - visual.baseline_directory/*.png (from workflow-config.yaml; skipped if unset)
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

# --- Build exclusion list ---
EXCLUDES=(':!.tickets/')

# Read visual baseline directory from config (e.g., app/tests/e2e/snapshots/)
BASELINE_DIR=$("$SCRIPT_DIR/read-config.sh" visual.baseline_directory 2>/dev/null || true)
if [[ -n "$BASELINE_DIR" ]]; then
    EXCLUDES+=(":!${BASELINE_DIR%/}/*.png")
fi

# Caller-supplied exclusions (e.g., ':!app/tests/unit/templates/snapshots/*.html')
for ex in "$@"; do
    EXCLUDES+=("$ex")
done

# --- Capture diff with exclusions (tee for worktree fd compatibility) ---
{ git diff --staged -- "${EXCLUDES[@]}"; git diff -- "${EXCLUDES[@]}"; } | tee "$DIFF_FILE" > /dev/null

# Guard: if empty after exclusions (snapshot-only commit), fall back to tickets-excluded diff
# so verify-review-diff.sh doesn't reject the empty file. The reviewer ignores binary files.
[ -s "$DIFF_FILE" ] || \
    { git diff --staged -- ':!.tickets/'; git diff -- ':!.tickets/'; } | tee "$DIFF_FILE" > /dev/null

# Final fallback: last commit (e.g., post-compaction checkpoint scenario)
[ -s "$DIFF_FILE" ] || git diff HEAD~1 -- ':!.tickets/' | tee "$DIFF_FILE" > /dev/null

# --- Capture stat with exclusions ---
{ git diff HEAD --stat -- "${EXCLUDES[@]}"; \
  git ls-files --others --exclude-standard | sed 's/$/ (untracked)/'; } | tee "$STAT_FILE" > /dev/null
