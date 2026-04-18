#!/usr/bin/env bash
# .claude/hooks/plan-review-gate.sh
# PreToolUse hook (ExitPlanMode matcher): blocks ExitPlanMode if no plan review
# has been recorded for this session.
#
# How it works:
#   1. Triggers on ExitPlanMode tool calls
#   2. Checks for plan-review-status marker file
#   3. Blocks (exit 2) if no review has been run
#
# The marker file is written by the plan-review skill after a successful review.

HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"plan-review-gate.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

INPUT=$(cat)

# Only act on ExitPlanMode tool calls
TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
if [[ "$TOOL_NAME" != "ExitPlanMode" ]]; then
    exit 0
fi

# Determine worktree and state file location
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
    exit 0
fi

ARTIFACTS_DIR=$(get_artifacts_dir)
REVIEW_STATE_FILE="$ARTIFACTS_DIR/plan-review-status"

# If no plan review has been recorded, block
if [[ ! -f "$REVIEW_STATE_FILE" ]]; then
    echo "# PLAN REVIEW GATE: BLOCKED" >&2
    echo "" >&2
    echo "**No plan review has been recorded for this session.**" >&2
    echo "" >&2
    echo "Before presenting a plan to the user, run the plan-review skill:" >&2
    echo "  Invoke \`/dso:plan-review\` with the plan content." >&2
    echo "" >&2
    echo "This ensures plans are reviewed by a sub-agent before user approval." >&2
    echo "" >&2
    exit 2
fi

# Check that review passed
REVIEW_STATUS=$(head -n 1 "$REVIEW_STATE_FILE" 2>/dev/null || echo "")
if [[ "$REVIEW_STATUS" != "passed" ]]; then
    echo "# PLAN REVIEW GATE: BLOCKED (REVIEW NOT PASSED)" >&2
    echo "" >&2
    echo "**The plan review did not pass.**" >&2
    echo "" >&2
    echo "Address the review findings and re-run \`/dso:plan-review\`." >&2
    echo "" >&2
    exit 2
fi

# Review passed — allow ExitPlanMode
exit 0
