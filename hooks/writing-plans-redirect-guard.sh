#!/usr/bin/env bash
# lockpick-workflow/hooks/writing-plans-redirect-guard.sh
# PreToolUse hook: redirect writing-plans Skill invocations to epic + preplanning workflow
#
# Addresses beads issue 4tqsg:
#   When brainstorming completes and an epic needs to be created,
#   agents sometimes invoke the 'writing-plans' or 'superpowers:writing-plans' skill.
#   This is incorrect — writing-plans is for single-task implementation plans.
#   For epics, the correct workflow is:
#     1. bd create --type=epic ...
#     2. /preplanning (which creates stories, sets dependencies, and generates context files)
#
# How it works:
#   - Intercepts Skill tool invocations
#   - If the skill name matches writing-plans (with or without superpowers: prefix)
#   - Blocks with the correct workflow instructions

HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"writing-plans-redirect-guard.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

INPUT=$(cat)

SKILL_NAME=$(parse_json_field "$INPUT" '.tool_input.skill')

# Only intercept writing-plans (with or without superpowers: prefix)
if [[ "$SKILL_NAME" != "writing-plans" ]] && [[ "$SKILL_NAME" != "superpowers:writing-plans" ]]; then
    exit 0
fi

echo "BLOCKED: /writing-plans is not the right skill for epic planning." >&2
echo "" >&2
echo "writing-plans generates an implementation plan for a single task." >&2
echo "For epics with multiple stories and dependencies, use the epic workflow instead:" >&2
echo "" >&2
echo "  1. bd create --title=\"<epic title>\" --type=epic --priority=<N>" >&2
echo "  2. /preplanning  (creates stories, sets Beads dependencies, writes context file)" >&2
echo "" >&2
echo "After /preplanning is approved and synced to Beads, use /sprint to execute the epic." >&2
exit 2
