#!/usr/bin/env bash
# tests/hooks/test-generate-claude-md-skill.sh
# Verifies that the /dso:generate-claude-md skill file exists at
# skills/generate-claude-md/SKILL.md and contains the
# required frontmatter and content sections.
#
# RED PHASE: All tests are expected to FAIL until the skill is implemented.
#
# Usage:
#   bash tests/hooks/test-generate-claude-md-skill.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

SKILL_FILE="$DSO_PLUGIN_DIR/skills/generate-claude-md/SKILL.md"

echo "=== test-generate-claude-md-skill.sh ==="

# test_generate_claude_md_skill_file_exists
# The SKILL.md must exist at the expected path.
if [[ -f "$SKILL_FILE" ]]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_generate_claude_md_skill_file_exists" "exists" "$actual"

# test_generate_claude_md_skill_frontmatter_name
# Frontmatter must declare: name: generate-claude-md
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "^name: generate-claude-md" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_generate_claude_md_skill_frontmatter_name" "present" "$actual"
fi

# test_generate_claude_md_skill_user_invocable
# Frontmatter must declare: user-invocable: true
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "^user-invocable: true" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_generate_claude_md_skill_user_invocable" "present" "$actual"
fi

# test_generate_claude_md_quick_ref_table_present
# Skill must reference a Quick Reference section (the table of commands).
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "Quick Reference" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_generate_claude_md_quick_ref_table_present" "present" "$actual"
fi

# test_generate_claude_md_validation_command_rendered
# Skill must reference commands.validate (config key for the validation command).
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "commands.validate" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_generate_claude_md_validation_command_rendered" "present" "$actual"
fi

# test_generate_claude_md_format_command_rendered
# Skill must reference commands.format (config key for the format command).
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "commands.format" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_generate_claude_md_format_command_rendered" "present" "$actual"
fi

# test_generate_claude_md_never_do_these_section_present
# Skill must document the 'Never Do These' rules in the template.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "Never Do These" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_generate_claude_md_never_do_these_section_present" "present" "$actual"
fi

# test_generate_claude_md_merge_strategy_documented
# Skill must explain how to merge with project-specific sections.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "merge" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_generate_claude_md_merge_strategy_documented" "present" "$actual"
fi

# test_generate_claude_md_escalation_triggers_documented
# Skill must have an Escalation Triggers section.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "Escalation Triggers" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_generate_claude_md_escalation_triggers_documented" "present" "$actual"
fi

print_summary
