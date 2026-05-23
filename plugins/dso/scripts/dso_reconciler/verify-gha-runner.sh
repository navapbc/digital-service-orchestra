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
GH_TIMEOUT="${GH_TIMEOUT:-30s}"

# Resolve repo root so we can invoke the repo-pinned dso shim rather than the
# bare `dso` lookup (PATH may resolve the wrong binary in CI/dev shells).
_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
DSO_CMD="${DSO_CMD:-${_REPO_ROOT}/.claude/scripts/dso}"
if [[ ! -x "$DSO_CMD" ]]; then
    DSO_CMD="dso"  # fall back to PATH (e.g., outside a checkout)
fi

# Step 1: Verify gh authentication (with timeout to avoid hanging on slow/blocked CLI state)
if ! timeout "$GH_TIMEOUT" gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh auth failed (or timed out after $GH_TIMEOUT)" >&2
    exit 1
fi

# Step 2: Run gh run list and capture combined output (with timeout)
_output=""
if ! _output=$(timeout "$GH_TIMEOUT" gh run list --workflow="$WORKFLOW_NAME" --limit 1 2>&1); then
    echo "ERROR: gh run list failed (or timed out after $GH_TIMEOUT)" >&2
    exit 1
fi

# Step 3: Log the output as a story comment via the repo-pinned dso shim
"$DSO_CMD" ticket comment "$STORY_ID" "GHA runner verified: $(echo "$_output" | head -5)"

exit 0
