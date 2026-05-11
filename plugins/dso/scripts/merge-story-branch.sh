#!/usr/bin/env bash
# Merges a story branch into the current session branch with DSO-Story-Merge trailer.
# Usage: merge-story-branch.sh <story-branch> <story-id>
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

if ! git rev-parse --verify "refs/heads/${_STORY_BRANCH}" >/dev/null 2>&1; then
  echo "ERROR: story branch '${_STORY_BRANCH}' does not exist" >&2
  exit 1
fi

_MSG="$(printf 'Merge %s\n\nDSO-Story-Merge: %s' "${_STORY_BRANCH}" "${_STORY_ID}")"
git merge --no-ff "${_STORY_BRANCH}" -m "${_MSG}"
