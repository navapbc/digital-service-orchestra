#!/usr/bin/env bash
# Creates a story branch at current HEAD for sprint Phase E.
# Usage: create-story-branch.sh <epic-id> <story-id>
# Output: STORY_BRANCH=story/<epic-id>/<story-id>
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: create-story-branch.sh <epic-id> <story-id>" >&2
  exit 1
fi

_EPIC_ID="$1"
_STORY_ID="$2"
_BRANCH="story/${_EPIC_ID}/${_STORY_ID}"

if git rev-parse --verify "refs/heads/${_BRANCH}" >/dev/null 2>&1; then
  # Branch already exists — idempotent
  echo "STORY_BRANCH=${_BRANCH}"
  exit 0
fi

git checkout -b "${_BRANCH}"
echo "STORY_BRANCH=${_BRANCH}"
