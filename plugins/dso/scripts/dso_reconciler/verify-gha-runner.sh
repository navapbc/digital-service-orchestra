#!/usr/bin/env bash
# Verifies that the GHA runner is accessible and logs the result as a story comment.
#
# Usage:
#   STORY_ID=<ticket-id> WORKFLOW_NAME=<workflow-file> bash verify-gha-runner.sh
#
# Environment variables:
#   STORY_ID      — ticket ID to post the comment to (default: 7705-41e8-9f01-4ebb)
#   WORKFLOW_NAME — workflow file name to query (default: reconcile-bridge.yml)

set -euo pipefail

STORY_ID="${STORY_ID:-7705-41e8-9f01-4ebb}"
WORKFLOW_NAME="${WORKFLOW_NAME:-reconcile-bridge.yml}"

# Step 1: Verify gh authentication
if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh auth failed" >&2
    exit 1
fi

# Step 2: Run gh run list and capture combined output
_output=""
if ! _output=$(gh run list --workflow="$WORKFLOW_NAME" --limit 1 2>&1); then
    echo "ERROR: gh run list failed" >&2
    exit 1
fi

# Step 3: Log the output as a story comment
dso ticket comment "$STORY_ID" "GHA runner verified: $(echo "$_output" | head -5)"

exit 0
