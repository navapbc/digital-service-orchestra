#!/usr/bin/env bash
# hooks/inject-using-dso.sh
# SessionStart hook: inject using-dso skill context into conversation
#
# Mirrors the superpowers:using-superpowers injection mechanism.
# Outputs the using-dso SKILL.md content to stdout so Claude Code
# includes it as session context, enforcing skill-invocation discipline
# without requiring the superpowers plugin.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
# Use slim hook injection (no flowchart/Red Flags table); full content in SKILL.md
HOOK_FILE="$PLUGIN_ROOT/skills/using-dso/HOOK-INJECTION.md"
SKILL_FILE="$PLUGIN_ROOT/skills/using-dso/SKILL.md"

if [[ -f "$HOOK_FILE" ]]; then
    cat "$HOOK_FILE"
elif [[ -f "$SKILL_FILE" ]]; then
    cat "$SKILL_FILE"
fi

exit 0
