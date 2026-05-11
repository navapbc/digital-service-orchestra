#!/usr/bin/env bash
# worktree-session-head-sync.sh
# Syncs the current worktree to the session HEAD when the orchestrator is in a
# session worktree. Called by sub-agents after worktree initialization.
#
# Required env vars:
#   SESSION_BRANCH — name of the session branch (e.g. worktree-20260511-110342)
#   SESSION_HEAD   — full SHA of the session HEAD commit

set -euo pipefail

if [[ -z "${SESSION_BRANCH:-}" ]]; then
    echo "ERROR: SESSION_BRANCH is not set" >&2
    exit 1
fi

if [[ -z "${SESSION_HEAD:-}" ]]; then
    echo "ERROR: SESSION_HEAD is not set" >&2
    exit 1
fi

git fetch origin "${SESSION_BRANCH}"
git reset --hard "${SESSION_HEAD}"
