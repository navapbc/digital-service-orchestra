#!/usr/bin/env bash
# tests/skills/test-onboarding-skill.sh
# Tests that plugins/dso/skills/onboarding/SKILL.md has the correct structure
# for the /dso:onboarding Socratic dialogue skill.
#
# Validates (8 named assertions):
#   test_skill_file_exists: SKILL.md exists at the expected path
#   test_frontmatter_valid: frontmatter has name=onboarding and user-invocable=true
#   test_sub_agent_guard_present: Orchestrator Signal SUB-AGENT-GUARD block present
#   test_understanding_areas_complete: references all 7 understanding areas
#   test_scratchpad_instructions: contains scratchpad/temp file append instructions
#   test_detection_integration: references project-detect.sh
#   test_socratic_dialogue_pattern: contains Socratic dialogue indicators
#   test_architect_foundation_offer: references /dso:architect-foundation
#
# These are metadata/schema validation tests per the Behavioral Test Requirement exemption.
# All tests will FAIL (RED) until plugins/dso/skills/onboarding/SKILL.md is created.
#
# Usage: bash tests/skills/test-onboarding-skill.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/onboarding/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-onboarding-skill.sh ==="

# test_skill_file_exists: SKILL.md must exist at plugins/dso/skills/onboarding/SKILL.md
test_skill_file_exists() {
    _snapshot_fail
    local exists="missing"
    if [[ -f "$SKILL_MD" ]]; then
        exists="found"
    fi
    assert_eq "test_skill_file_exists" "found" "$exists"
    assert_pass_if_clean "test_skill_file_exists"
}

# test_frontmatter_valid: frontmatter must contain name: onboarding and user-invocable: true
test_frontmatter_valid() {
    _snapshot_fail
    local has_name has_invocable frontmatter_valid
    has_name="no"
    has_invocable="no"
    if grep -q "^name: onboarding" "$SKILL_MD" 2>/dev/null; then
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

# test_sub_agent_guard_present: Orchestrator Signal SUB-AGENT-GUARD block must be present
test_sub_agent_guard_present() {
    _snapshot_fail
    local has_guard has_signal guard_valid
    has_guard="no"
    has_signal="no"
    if grep -q "SUB-AGENT-GUARD" "$SKILL_MD" 2>/dev/null; then
        has_guard="yes"
    fi
    if grep -q "running as a sub-agent" "$SKILL_MD" 2>/dev/null; then
        has_signal="yes"
    fi
    if [[ "$has_guard" == "yes" && "$has_signal" == "yes" ]]; then
        guard_valid="found"
    else
        guard_valid="missing"
    fi
    assert_eq "test_sub_agent_guard_present" "found" "$guard_valid"
    assert_pass_if_clean "test_sub_agent_guard_present"
}

# test_understanding_areas_complete: must reference all 7 understanding areas:
# stack, commands, architecture, infrastructure, CI, design, enforcement
test_understanding_areas_complete() {
    _snapshot_fail
    local areas_found areas_missing area
    areas_found=0
    areas_missing=""
    local required_areas=("stack" "commands" "architecture" "infrastructure" "CI" "design" "enforcement")
    for area in "${required_areas[@]}"; do
        if grep -qw "$area" "$SKILL_MD" 2>/dev/null; then
            (( areas_found++ ))
        else
            areas_missing="$areas_missing $area"
        fi
    done
    if [[ "$areas_found" -eq 7 ]]; then
        assert_eq "test_understanding_areas_complete" "7" "$areas_found"
    else
        assert_eq "test_understanding_areas_complete" "7 areas found" "$areas_found areas found (missing:$areas_missing)"
    fi
    assert_pass_if_clean "test_understanding_areas_complete"
}

# test_scratchpad_instructions: must contain scratchpad/temp file append instructions
test_scratchpad_instructions() {
    _snapshot_fail
    local scratchpad_found
    scratchpad_found="missing"
    if grep -qiE "mktemp|scratchpad|append.*scratchpad|scratchpad.*append" "$SKILL_MD" 2>/dev/null; then
        scratchpad_found="found"
    fi
    assert_eq "test_scratchpad_instructions" "found" "$scratchpad_found"
    assert_pass_if_clean "test_scratchpad_instructions"
}

# test_detection_integration: must reference project-detect.sh for grounded detection
test_detection_integration() {
    _snapshot_fail
    local detection_found
    detection_found="missing"
    if grep -q "project-detect.sh" "$SKILL_MD" 2>/dev/null; then
        detection_found="found"
    fi
    assert_eq "test_detection_integration" "found" "$detection_found"
    assert_pass_if_clean "test_detection_integration"
}

# test_socratic_dialogue_pattern: must contain Socratic dialogue indicators
test_socratic_dialogue_pattern() {
    _snapshot_fail
    local dialogue_found
    dialogue_found="missing"
    if grep -qiE "one question|multiple-choice|Socratic|one at a time" "$SKILL_MD" 2>/dev/null; then
        dialogue_found="found"
    fi
    assert_eq "test_socratic_dialogue_pattern" "found" "$dialogue_found"
    assert_pass_if_clean "test_socratic_dialogue_pattern"
}

# test_architect_foundation_offer: must reference /dso:architect-foundation
test_architect_foundation_offer() {
    _snapshot_fail
    local architect_found
    architect_found="missing"
    if grep -q "/dso:architect-foundation" "$SKILL_MD" 2>/dev/null; then
        architect_found="found"
    fi
    assert_eq "test_architect_foundation_offer" "found" "$architect_found"
    assert_pass_if_clean "test_architect_foundation_offer"
}

# test_project_understanding_output: SKILL.md must reference .claude/project-understanding.md as output artifact
test_project_understanding_output() {
    _snapshot_fail
    local artifact_found
    artifact_found="missing"
    if grep -q "project-understanding.md" "$SKILL_MD" 2>/dev/null; then
        artifact_found="found"
    fi
    assert_eq "test_project_understanding_output" "found" "$artifact_found"
    assert_pass_if_clean "test_project_understanding_output"
}

# test_understanding_sections: SKILL.md must mention structured sections
# (stack, architecture, commands, infrastructure, enforcement)
test_understanding_sections() {
    _snapshot_fail
    local sections_found sections_missing section
    sections_found=0
    sections_missing=""
    local required_sections=("stack" "architecture" "commands" "infrastructure" "enforcement")
    for section in "${required_sections[@]}"; do
        if grep -qw "$section" "$SKILL_MD" 2>/dev/null; then
            (( sections_found++ ))
        else
            sections_missing="$sections_missing $section"
        fi
    done
    if [[ "$sections_found" -eq 5 ]]; then
        assert_eq "test_understanding_sections" "5" "$sections_found"
    else
        assert_eq "test_understanding_sections" "5 sections found" "$sections_found sections found (missing:$sections_missing)"
    fi
    assert_pass_if_clean "test_understanding_sections"
}

# test_attribution_tagging: SKILL.md must mention attribution (detected vs user-stated or confirmed vs inferred)
test_attribution_tagging() {
    _snapshot_fail
    local attribution_found
    attribution_found="missing"
    if grep -qiE "detected|user-stated|confirmed|inferred" "$SKILL_MD" 2>/dev/null; then
        attribution_found="found"
    fi
    assert_eq "test_attribution_tagging" "found" "$attribution_found"
    assert_pass_if_clean "test_attribution_tagging"
}

# test_human_readable_format: SKILL.md must mention human-readable or editable format
test_human_readable_format() {
    _snapshot_fail
    local format_found
    format_found="missing"
    if grep -qiE "human-readable|human readable|editable" "$SKILL_MD" 2>/dev/null; then
        format_found="found"
    fi
    assert_eq "test_human_readable_format" "found" "$format_found"
    assert_pass_if_clean "test_human_readable_format"
}

# Run all 12 assertion functions
test_skill_file_exists
test_frontmatter_valid
test_sub_agent_guard_present
test_understanding_areas_complete
test_scratchpad_instructions
test_detection_integration
test_socratic_dialogue_pattern
test_architect_foundation_offer
test_project_understanding_output
test_understanding_sections
test_attribution_tagging
test_human_readable_format

print_summary
