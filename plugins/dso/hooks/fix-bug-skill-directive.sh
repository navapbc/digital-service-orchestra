#!/usr/bin/env bash
# fix-bug-skill-directive.sh
# UserPromptSubmit hook: outputs a skill directive when the user's prompt
# contains the fix-bug or dso:fix-bug skill invocation (slash-anchored).
#
# Reads a JSON payload from stdin with shape:
#   {
#     "hook_event_name": "UserPromptSubmit",
#     "session_id": "...",
#     "transcript_path": "...",
#     "cwd": "...",
#     "permission_mode": "default",
#     "prompt": "<user text here>"
#   }
#
# If the prompt invokes the fix-bug skill (qualified or unqualified), outputs a
# directive to stdout instructing the agent to invoke the Skill tool before any
# other action.  If not matched, outputs nothing.
# Always exits 0 (hooks must never fail).

set -uo pipefail  # -e omitted: hook is fail-open (always exit 0)

# Resolve plugin root (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" || ! -d "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/deps.sh"

# Read full JSON payload from stdin
INPUT=$(cat)

# Extract the user's prompt text
MSG=$(parse_json_field "$INPUT" '.prompt')

# Check for the fix-bug skill invocation (qualified /dso:fix-bug or unqualified
# alias) at the start of the prompt (command position).
# Only match when the slash command is the first non-whitespace content — this
# prevents false positives from task notifications and narrative text that
# references the skill (bug fbd3-60c9).
if printf '%s' "$MSG" | grep -qE '^\s*/(dso:)?fix-bug'; then
    printf '%s\n' "IMPORTANT: The user has invoked the /dso:fix-bug skill. You MUST invoke the Skill tool with skill=\"fix-bug\" as your FIRST action before any other response or tool call. Do not begin investigation, reading files, or any other activity until you have invoked the Skill tool."
fi

exit 0
