#!/usr/bin/env bash
# check-sprint-trailer.sh: Pre-commit hook enforcing DSO-Story trailers in sprint mode.
# When DSO_SPRINT_MODE=1, the latest commit must contain a DSO-Story: trailer.
# Set DSO_SPRINT_MODE=1 in the shell before committing (done by sprint SKILL.md Phase F).
set -euo pipefail

# No-op outside sprint mode
if [[ -z "${DSO_SPRINT_MODE:-}" ]]; then
    exit 0
fi

# Get latest commit message and parse trailers
_commit_msg=$(git log -1 --format=%B 2>/dev/null || echo "")
_has_trailer=0
if echo "$_commit_msg" | git interpret-trailers --parse 2>/dev/null | grep -q '^DSO-Story:'; then
    _has_trailer=1
fi

if [[ "$_has_trailer" -eq 0 ]]; then
    echo "ERROR: check-sprint-trailer: DSO-Story trailer required in sprint mode but not found in commit message. Run /dso:commit from within the story worktree to inject the trailer automatically." >&2
    exit 1
fi

exit 0
