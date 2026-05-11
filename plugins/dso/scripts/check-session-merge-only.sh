#!/usr/bin/env bash
# check-session-merge-only.sh
# Pre-commit hook: when .sprint-active is present, only accept merge commits.
# Rejects direct non-merge commits to the session worktree during sprint-active state.
#
# Exit codes:
#   0 — commit accepted (no .sprint-active, is a merge commit, or escape hatch)
#   1 — rejected (non-merge commit in sprint-active state)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SPRINT_ACTIVE_MARKER="$REPO_ROOT/.sprint-active"

# No marker = hook inactive (release pipeline / non-sprint mode)
if [[ ! -f "$SPRINT_ACTIVE_MARKER" ]]; then
    exit 0
fi

# Escape hatch: DSO_SPRINT_ACTIVE=0 bypasses with audit log
if [[ "${DSO_SPRINT_ACTIVE:-}" == "0" ]]; then
    _artifacts_dir="${DSO_ARTIFACTS_DIR:-$REPO_ROOT/.claude/artifacts}"
    mkdir -p "$_artifacts_dir"
    _log_file="$_artifacts_dir/sprint-merge-only-bypass-$(date +%Y%m%d-%H%M%S).log"
    echo "DSO_SPRINT_ACTIVE=0 bypass: $(date -u +%Y-%m-%dT%H:%M:%SZ) PID=$$" > "$_log_file"
    exit 0
fi

# Merge commit detection: MERGE_HEAD file exists in git dir
GIT_DIR="$(git rev-parse --git-dir)"
if [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
    exit 0
fi

# Non-merge commit in sprint-active state — reject
echo "ERROR: Direct commit to session worktree rejected (sprint-active mode)." >&2
echo "Commits must go through a story worktree and be merged into the session branch." >&2
echo "To bypass for emergency: set DSO_SPRINT_ACTIVE=0" >&2
exit 1
