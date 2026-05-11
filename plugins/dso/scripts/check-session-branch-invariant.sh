#!/usr/bin/env bash
# Post-hoc audit: verifies all story/* merge commits on current branch have DSO-Story-Merge: trailer.
# Called by validate.sh. NOT a pre-commit hook.
# Distinct from check-session-merge-only.sh (pre-commit, individual commit guard).
set -euo pipefail

_failed=0

while IFS= read -r _sha; do
  _body=$(git log -1 --format=%B "$_sha")
  # Check if this is a merge from a story/* branch
  if echo "$_body" | grep -qE '^Merge (story/|refs/heads/story/)'; then
    if ! echo "$_body" | grep -q '^DSO-Story-Merge:'; then
      echo "ERROR: merge commit ${_sha} missing DSO-Story-Merge: trailer" >&2
      _failed=1
    fi
  fi
done < <(git log --merges --format='%H')

exit $_failed
