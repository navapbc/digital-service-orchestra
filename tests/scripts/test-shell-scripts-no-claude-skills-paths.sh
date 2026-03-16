#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-shell-scripts-no-claude-skills-paths.sh
# Tests that no .sh files under lockpick-workflow/ (excluding tests/) reference .claude/skills/
#
# Validates:
#   - No shell scripts contain '.claude/skills/' literal references
#   - All skill paths should use CLAUDE_PLUGIN_ROOT-based paths instead
#
# Usage: bash lockpick-workflow/tests/scripts/test-shell-scripts-no-claude-skills-paths.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
WORKFLOW_DIR="$REPO_ROOT/lockpick-workflow"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-shell-scripts-no-claude-skills-paths.sh ==="

# test_no_claude_skills_paths: no .sh files under lockpick-workflow/ (excluding tests/) should reference .claude/skills/
_fail_before=$FAIL
match_count=$(grep -rn '\.claude/skills/' "$WORKFLOW_DIR" --exclude-dir=tests --include='*.sh' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no .claude/skills/ references in non-test shell scripts" "0" "$match_count"
if [[ "$FAIL" -gt "$_fail_before" ]]; then
    echo "  Found $match_count references:"
    grep -rn '\.claude/skills/' "$WORKFLOW_DIR" --exclude-dir=tests --include='*.sh' 2>/dev/null | head -30
fi

print_summary
