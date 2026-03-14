#!/usr/bin/env bash
# lockpick-workflow/tests/skills/test-quick-ref-skill.sh
# Tests that /quick-ref SKILL.md exists, has valid structure, and uses auto-discovery.
#
# Validates:
#   - SKILL.md exists at lockpick-workflow/skills/quick-ref/SKILL.md
#   - Has valid YAML frontmatter with name: quick-ref and user-invocable: true
#   - References CLAUDE_PLUGIN_ROOT for path resolution (not hardcoded)
#   - Contains script auto-discovery command (not a hardcoded list)
#   - Contains skills auto-discovery section
#   - No broken internal references ($PLUGIN_ROOT/... paths exist)
#
# Usage: bash lockpick-workflow/tests/skills/test-quick-ref-skill.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SKILL_MD="$REPO_ROOT/lockpick-workflow/skills/quick-ref/SKILL.md"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-quick-ref-skill.sh ==="

# test_quick_ref_skill_exists_and_has_valid_structure: SKILL.md must exist
_snapshot_fail
if [[ -f "$SKILL_MD" ]]; then
    skill_exists="exists"
else
    skill_exists="missing"
fi
assert_eq "test_skill_exists" "exists" "$skill_exists"
assert_pass_if_clean "test_skill_exists"

# test_frontmatter_name: must have name: quick-ref in frontmatter
_snapshot_fail
if head -5 "$SKILL_MD" 2>/dev/null | grep -q 'name: quick-ref'; then
    has_name="found"
else
    has_name="missing"
fi
assert_eq "test_frontmatter_name" "found" "$has_name"
assert_pass_if_clean "test_frontmatter_name"

# test_frontmatter_user_invocable: must have user-invocable: true
_snapshot_fail
if grep -q 'user-invocable: true' "$SKILL_MD" 2>/dev/null; then
    has_invocable="found"
else
    has_invocable="missing"
fi
assert_eq "test_frontmatter_user_invocable" "found" "$has_invocable"
assert_pass_if_clean "test_frontmatter_user_invocable"

# test_claude_plugin_root_resolution: must use CLAUDE_PLUGIN_ROOT (not hardcoded)
_snapshot_fail
if grep -q 'CLAUDE_PLUGIN_ROOT' "$SKILL_MD" 2>/dev/null; then
    has_plugin_root="found"
else
    has_plugin_root="missing"
fi
assert_eq "test_claude_plugin_root_resolution" "found" "$has_plugin_root"
assert_pass_if_clean "test_claude_plugin_root_resolution"

# test_script_auto_discovery: must contain script auto-discovery (ls/glob/for over scripts/*.sh)
_snapshot_fail
if grep -qE 'ls.*scripts.*\.sh|glob.*scripts|for.*scripts' "$SKILL_MD" 2>/dev/null; then
    has_auto_discovery="found"
else
    has_auto_discovery="missing"
fi
assert_eq "test_script_auto_discovery" "found" "$has_auto_discovery"
assert_pass_if_clean "test_script_auto_discovery"

# test_skills_discovery: must contain skills auto-discovery section
_snapshot_fail
if grep -qE 'skills/\*/SKILL\.md|skills.*SKILL' "$SKILL_MD" 2>/dev/null; then
    has_skills_discovery="found"
else
    has_skills_discovery="missing"
fi
assert_eq "test_skills_discovery" "found" "$has_skills_discovery"
assert_pass_if_clean "test_skills_discovery"

# test_no_broken_references: all $PLUGIN_ROOT/... paths must resolve
_snapshot_fail
broken_count=0
while IFS= read -r ref_path; do
    resolved="$REPO_ROOT/lockpick-workflow/${ref_path#\$PLUGIN_ROOT/}"
    if [[ ! -e "$resolved" ]]; then
        broken_count=$((broken_count + 1))
        echo "  BROKEN REF: $ref_path -> $resolved" >&2
    fi
done < <(grep -oE '\$PLUGIN_ROOT/[^ )`"]+' "$SKILL_MD" 2>/dev/null || true)
assert_eq "test_no_broken_references" "0" "$broken_count"
assert_pass_if_clean "test_no_broken_references"

print_summary
