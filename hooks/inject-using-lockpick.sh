#!/usr/bin/env bash
# lockpick-workflow/hooks/inject-using-lockpick.sh
# SessionStart hook: inject using-lockpick skill context into conversation
#
# Mirrors the superpowers:using-superpowers injection mechanism.
# Outputs the using-lockpick SKILL.md content to stdout so Claude Code
# includes it as session context, enforcing skill-invocation discipline
# without requiring the superpowers plugin.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
SKILL_FILE="${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/skills/using-lockpick/SKILL.md"

if [[ -f "$SKILL_FILE" ]]; then
    cat "$SKILL_FILE"
fi

exit 0
