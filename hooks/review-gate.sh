#!/usr/bin/env bash
# lockpick-workflow/hooks/review-gate.sh
# PreToolUse hook (Bash matcher): HARD GATE that blocks git commit if code
# review hasn't passed for the current working tree state.
#
# This file is a thin wrapper. The hook logic lives in:
#   lockpick-workflow/hooks/lib/pre-bash-functions.sh (hook_review_gate)
#
# Exempt cases:
#   - Commits with "WIP" or "wip" in the message (work-in-progress)
#   - Commits from the pre-compact-checkpoint hook (emergency saves)
#   - Merge commits (merge-to-main.sh merges already-reviewed work)

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/pre-bash-functions.sh"

INPUT=$(cat)
hook_review_gate "$INPUT"
exit $?
