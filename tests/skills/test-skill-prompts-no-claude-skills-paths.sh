#!/usr/bin/env bash
# lockpick-workflow/tests/skills/test-skill-prompts-no-claude-skills-paths.sh
# Tests that no .md files under lockpick-workflow/skills/ reference .claude/skills/
#
# Validates:
#   - No SKILL.md or prompts/*.md files contain '.claude/skills/' references
#   - All skill paths should use PLUGIN_ROOT-based paths instead
#
# Usage: bash lockpick-workflow/tests/skills/test-skill-prompts-no-claude-skills-paths.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SKILLS_DIR="$REPO_ROOT/lockpick-workflow/skills"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-skill-prompts-no-claude-skills-paths.sh ==="

# test_no_claude_skills_paths: no .md files under lockpick-workflow/skills/ should reference .claude/skills/
_fail_before=$FAIL
match_count=$(grep -rn '\.claude/skills/' "$SKILLS_DIR" --include='*.md' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no .claude/skills/ references in skill .md files" "0" "$match_count"
if [[ "$FAIL" -gt "$_fail_before" ]]; then
    echo "  Found $match_count references:"
    grep -rn '\.claude/skills/' "$SKILLS_DIR" --include='*.md' 2>/dev/null | head -30
fi

print_summary
