#!/usr/bin/env bash
# tests/hooks/test-fix-bug-skill.sh
# Verifies that the /dso:fix-bug skill file exists at
# skills/fix-bug/SKILL.md and contains the
# required frontmatter and content sections.
#
# RED PHASE: All tests are expected to FAIL until the skill is implemented.
#
# Usage:
#   bash tests/hooks/test-fix-bug-skill.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

SKILL_FILE="$DSO_PLUGIN_DIR/skills/fix-bug/SKILL.md"

echo "=== test-fix-bug-skill.sh ==="

# test_fix_bug_skill_file_exists
# The SKILL.md must exist at the expected path.
if [[ -f "$SKILL_FILE" ]]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_fix_bug_skill_file_exists" "exists" "$actual"

# test_fix_bug_skill_frontmatter_name
# Frontmatter must declare: name: fix-bug
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "^name: fix-bug" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_frontmatter_name" "present" "$actual"
fi

# test_fix_bug_skill_user_invocable
# Frontmatter must declare: user-invocable: true
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "^user-invocable: true" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_user_invocable" "present" "$actual"
fi

# test_fix_bug_skill_mechanical_path_section
# Skill must reference a mechanical path for classification/routing.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -qi "mechanical" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_mechanical_path_section" "present" "$actual"
fi

# test_fix_bug_skill_scoring_section
# Skill must include a scoring rubric for bug classification.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -qi "scor" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_scoring_section" "present" "$actual"
fi

# test_fix_bug_skill_config_resolution_section
# Skill must document Config Resolution steps or section.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "Config Resolution" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_config_resolution_section" "present" "$actual"
fi

# test_fix_bug_skill_workflow_skeleton_section
# Skill must include workflow step indicators (e.g., Step 1, Phase 1, or numbered steps).
if [[ -f "$SKILL_FILE" ]]; then
    if grep -qE "^(Step [0-9]|Phase [0-9]|[0-9]+\\.)" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_workflow_skeleton_section" "present" "$actual"
fi

print_summary
