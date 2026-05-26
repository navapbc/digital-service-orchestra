#!/usr/bin/env bash
# Sourced-only helper for sprint Phase F Step 18.
# Usage: source "${CLAUDE_PLUGIN_ROOT}/scripts/emit-story-merge-env.sh" "$STORY_ID"
# Exports: STORY_ID, STORY_EPIC_ID
# Returns: 0 on success; non-zero if parent epic cannot be resolved or invalid input
# Aborts: exit 1 if executed directly instead of sourced

# Self-check: must be sourced
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "ERROR: emit-story-merge-env.sh must be sourced, not executed" >&2
    exit 1
fi

# Parameter check
if [ -z "${1:-}" ]; then
    echo "ERROR: story_id required" >&2
    # shellcheck disable=SC2317  # `exit 1` is reachable when script is executed (not sourced)
    return 1 2>/dev/null || exit 1
fi

STORY_ID="$1"

# Look up parent epic via ticket CLI
STORY_EPIC_ID=$(.claude/scripts/dso ticket show "$STORY_ID" --format=llm 2>/dev/null \
    | grep -oE '^parent:[[:space:]]*[^[:space:]]+' \
    | head -1 \
    | sed -E 's/^parent:[[:space:]]*//')

if [ -z "$STORY_EPIC_ID" ]; then
    echo "ERROR: no parent epic resolvable for story $STORY_ID" >&2
    unset STORY_EPIC_ID 2>/dev/null || true
    return 1
fi

export STORY_ID STORY_EPIC_ID
