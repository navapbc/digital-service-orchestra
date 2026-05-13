#!/usr/bin/env bash
# Creates a story branch at current HEAD for sprint Phase E.
# Usage: create-story-branch.sh [--prefix <name>] <epic-id> <story-id>
# Options:
#   --prefix <name>   Branch prefix (default: story)
# Output: STORY_BRANCH=<prefix>/<epic-id>/<story-id>
set -euo pipefail

_PREFIX="story"
_POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      _PREFIX="$2"
      shift 2
      ;;
    --prefix=*)
      _PREFIX="${1#--prefix=}"
      shift
      ;;
    *)
      _POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ ${#_POSITIONAL[@]} -lt 2 ]]; then
  echo "Usage: create-story-branch.sh [--prefix <name>] <epic-id> <story-id>" >&2
  exit 1
fi

_EPIC_ID="${_POSITIONAL[0]}"
_STORY_ID="${_POSITIONAL[1]}"
_BRANCH="${_PREFIX}/${_EPIC_ID}/${_STORY_ID}"

if git rev-parse --verify "refs/heads/${_BRANCH}" >/dev/null 2>&1; then
  # Branch already exists — idempotent
  echo "STORY_BRANCH=${_BRANCH}"
  exit 0
fi

git checkout -b "${_BRANCH}"
echo "STORY_BRANCH=${_BRANCH}"
