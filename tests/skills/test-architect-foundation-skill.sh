#!/usr/bin/env bash
# tests/skills/test-architect-foundation-skill.sh
# Tests that plugins/dso/skills/architect-foundation/SKILL.md has the correct structure
# for the /dso:architect-foundation scaffolding skill.
#
# Validates (7 named assertions):
#   test_skill_file_exists: SKILL.md exists at the expected path
#   test_frontmatter_valid: frontmatter has name=architect-foundation and user-invocable=true
#   test_sub_agent_guard_present: Agent tool SUB-AGENT-GUARD block present (dispatches sub-agents)
#   test_reads_project_understanding: references .claude/project-understanding.md as input
#   test_socratic_dialogue: contains Socratic dialogue pattern (one question / single question)
#   test_no_duplicate_detection: does NOT reference project-detect.sh (delegates to project-understanding.md)
#   test_enforcement_preferences: references enforcement or anti-pattern
#
# These are metadata/schema validation tests per the Behavioral Test Requirement exemption.
# All tests will FAIL (RED) until plugins/dso/skills/architect-foundation/SKILL.md is created.
#
# Usage: bash tests/skills/test-architect-foundation-skill.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/architect-foundation/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-architect-foundation-skill.sh ==="

# test_skill_file_exists: SKILL.md must exist at plugins/dso/skills/architect-foundation/SKILL.md
test_skill_file_exists() {
    _snapshot_fail
    local exists="missing"
    if [[ -f "$SKILL_MD" ]]; then
        exists="found"
    fi
    assert_eq "test_skill_file_exists" "found" "$exists"
    assert_pass_if_clean "test_skill_file_exists"
}

# test_frontmatter_valid: frontmatter must contain name: architect-foundation and user-invocable: true
test_frontmatter_valid() {
    _snapshot_fail
    local has_name has_invocable frontmatter_valid
    has_name="no"
    has_invocable="no"
    if grep -q "^name: architect-foundation" "$SKILL_MD" 2>/dev/null; then
        has_name="yes"
    fi
    if grep -q "user-invocable: true" "$SKILL_MD" 2>/dev/null; then
        has_invocable="yes"
    fi
    if [[ "$has_name" == "yes" && "$has_invocable" == "yes" ]]; then
        frontmatter_valid="found"
    else
        frontmatter_valid="missing"
    fi
    assert_eq "test_frontmatter_valid" "found" "$frontmatter_valid"
    assert_pass_if_clean "test_frontmatter_valid"
}

# test_sub_agent_guard_present: Agent tool SUB-AGENT-GUARD block must be present
# (architect-foundation dispatches sub-agents for scaffolding tasks)
test_sub_agent_guard_present() {
    _snapshot_fail
    local has_guard has_agent_tool guard_valid
    has_guard="no"
    has_agent_tool="no"
    if grep -q "SUB-AGENT-GUARD" "$SKILL_MD" 2>/dev/null; then
        has_guard="yes"
    fi
    if grep -q "Agent tool" "$SKILL_MD" 2>/dev/null; then
        has_agent_tool="yes"
    fi
    if [[ "$has_guard" == "yes" && "$has_agent_tool" == "yes" ]]; then
        guard_valid="found"
    else
        guard_valid="missing"
    fi
    assert_eq "test_sub_agent_guard_present" "found" "$guard_valid"
    assert_pass_if_clean "test_sub_agent_guard_present"
}

# test_reads_project_understanding: must reference .claude/project-understanding.md as input artifact
test_reads_project_understanding() {
    _snapshot_fail
    local artifact_found
    artifact_found="missing"
    if grep -q "project-understanding.md" "$SKILL_MD" 2>/dev/null; then
        artifact_found="found"
    fi
    assert_eq "test_reads_project_understanding" "found" "$artifact_found"
    assert_pass_if_clean "test_reads_project_understanding"
}

# test_socratic_dialogue: must contain Socratic dialogue pattern indicators
# (asks one question at a time to refine scaffolding decisions)
test_socratic_dialogue() {
    _snapshot_fail
    local dialogue_found
    dialogue_found="missing"
    if grep -qiE "one question|single question|one at a time|Socratic" "$SKILL_MD" 2>/dev/null; then
        dialogue_found="found"
    fi
    assert_eq "test_socratic_dialogue" "found" "$dialogue_found"
    assert_pass_if_clean "test_socratic_dialogue"
}

# test_no_duplicate_detection: must NOT reference project-detect.sh
# (architect-foundation reads from project-understanding.md written by /dso:onboarding,
# it does not re-run detection itself)
test_no_duplicate_detection() {
    _snapshot_fail
    local detect_found
    detect_found="not-referenced"
    if grep -q "project-detect.sh" "$SKILL_MD" 2>/dev/null; then
        detect_found="referenced"
    fi
    assert_eq "test_no_duplicate_detection" "not-referenced" "$detect_found"
    assert_pass_if_clean "test_no_duplicate_detection"
}

# test_enforcement_preferences: must reference enforcement or anti-pattern areas
# (scaffolding must capture project-specific enforcement rules and coding preferences)
test_enforcement_preferences() {
    _snapshot_fail
    local enforcement_found
    enforcement_found="missing"
    if grep -qiE "enforcement|anti-pattern" "$SKILL_MD" 2>/dev/null; then
        enforcement_found="found"
    fi
    assert_eq "test_enforcement_preferences" "found" "$enforcement_found"
    assert_pass_if_clean "test_enforcement_preferences"
}

# Run all 7 assertion functions — all RED until SKILL.md is created
test_skill_file_exists
test_frontmatter_valid
test_sub_agent_guard_present
test_reads_project_understanding
test_socratic_dialogue
test_no_duplicate_detection
test_enforcement_preferences

print_summary
