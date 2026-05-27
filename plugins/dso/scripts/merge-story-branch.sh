#!/usr/bin/env bash
# Merges a story branch into the current session branch with DSO-Story-Merge trailer.
# Usage: merge-story-branch.sh <story-branch> <story-id>
#
# Config-aware: when dso.workflow=ci-pr, routes through merge-to-main.sh (which
# creates a GitHub PR) instead of performing a local merge. Defense-in-depth for
# bug 570a-b3b9 — even if the orchestrator calls this script in ci-pr mode, the
# script itself routes correctly.
#
# DSO-Story-Merge trailer: machine-readable story ID for this merge commit.
# Distinct from DSO-Story: written by apply-attribution-trailers.sh (parent title on task commits).
# check-sprint-trailer.sh does NOT fire on session-branch merge commits — no modification needed.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: merge-story-branch.sh <story-branch> <story-id>" >&2
  exit 1
fi

_STORY_BRANCH="$1"
_STORY_ID="$2"
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
_REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"

if ! git rev-parse --verify "refs/heads/${_STORY_BRANCH}" >/dev/null 2>&1; then
  echo "ERROR: story branch '${_STORY_BRANCH}' does not exist" >&2
  exit 1
fi

# ── ci-pr mode defense-in-depth (bug 570a-b3b9) ─────────────────────────────
# When dso.workflow=ci-pr, route through merge-to-main.sh to create a GitHub PR
# instead of a local merge. The orchestrator SHOULD call merge-to-main.sh
# directly in ci-pr mode, but if it calls this script instead (compaction loss,
# routing error), this guard prevents silent bypass of the PR flow.
_WORKFLOW=$(bash "$_SCRIPT_DIR/read-config.sh" dso.workflow 2>/dev/null || echo "local")
if [[ "$_WORKFLOW" == "ci-pr" ]]; then
    echo "INFO: dso.workflow=ci-pr — routing through merge-to-main.sh for PR-based story merge" >&2
    _SESSION_BRANCH=$(bash "$_SCRIPT_DIR/resolve-session-branch.sh" 2>/dev/null) || {
        echo "WARNING: resolve-session-branch.sh failed — falling back to local merge" >&2
        _WORKFLOW="local"
    }
    if [[ "$_WORKFLOW" == "ci-pr" ]]; then
        # Source story env vars for trailer injection
        # shellcheck disable=SC1091
        source "$_SCRIPT_DIR/emit-story-merge-env.sh" "$_STORY_ID" || {
            echo "WARNING: emit-story-merge-env.sh failed — falling back to local merge" >&2
            _WORKFLOW="local"
        }
    fi
    if [[ "$_WORKFLOW" == "ci-pr" ]]; then
        export BRANCH="$_STORY_BRANCH"
        export STORY_PR_BASE="$_SESSION_BRANCH"
        exec bash "$_SCRIPT_DIR/merge-to-main.sh"
    fi
fi

# ── Local merge path ────────────────────────────────────────────────────────
_MSG="$(printf 'Merge %s\n\nDSO-Story-Merge: %s' "${_STORY_BRANCH}" "${_STORY_ID}")"

# Bug db71-e078-ec99-4fbf: in the default worktree-isolation post-harvest
# state, the story branch tip equals the session tip — `git merge --no-ff`
# reports "Already up to date." and silently writes NO commit and NO
# trailer, breaking the provenance pipeline. Detect that case and write
# an empty commit carrying the trailer instead, preserving the
# Phase F Step 18 invariant that a DSO-Story-Merge trailer always lands
# when this script returns 0.
if git merge-base --is-ancestor "${_STORY_BRANCH}" HEAD 2>/dev/null; then
    git commit --allow-empty -m "${_MSG}"
else
    git merge --no-ff "${_STORY_BRANCH}" -m "${_MSG}"
fi
