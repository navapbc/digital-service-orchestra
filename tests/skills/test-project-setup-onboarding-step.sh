#!/usr/bin/env bash
# tests/skills/test-project-setup-onboarding-step.sh
# Tests that plugins/dso/skills/onboarding/SKILL.md contains an onboarding
# integration step (Step 7) that offers /dso:architect-foundation
# with correct structure, prompts, and artifact detection.
#
# Validates (6 named assertions):
#   SC1: Step 7 heading present after Step 6 in SKILL.md
#   SC2: Option descriptions include brief summaries of what architect-foundation produces
#   SC3: AskUserQuestion with options when architect-foundation not yet run
#   SC6: skip option ends setup with no additional steps
#   SC8a: references design-notes.md and ARCH_ENFORCEMENT.md for artifact detection
#   SC8b: both artifacts present → prompt skipped entirely
#
# Usage: bash tests/skills/test-project-setup-onboarding-step.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/onboarding/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-project-setup-onboarding-step.sh ==="

# test_step7_exists (SC1): Step 7 heading must be present in SKILL.md after Step 6
test_step7_exists() {
    _snapshot_fail
    local step7_exists="missing"
    if grep -q "^## Step 7" "$SKILL_MD" 2>/dev/null; then
        local step6_line step7_line
        step6_line=$(grep -n "^## Step 6" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)
        step7_line=$(grep -n "^## Step 7" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)
        if [[ -n "$step6_line" && -n "$step7_line" && "$step7_line" -gt "$step6_line" ]]; then
            step7_exists="found"
        fi
    fi
    assert_eq "test_step7_exists" "found" "$step7_exists"
    assert_pass_if_clean "test_step7_exists"
}

# test_descriptive_labels (SC2): option descriptions must include brief summaries of
# what architect-foundation produces (e.g. ARCH_ENFORCEMENT.md, architecture enforcement)
test_descriptive_labels() {
    _snapshot_fail
    local step7_content has_skill_name has_descriptions has_descriptive_labels
    step7_content=$(awk '/^## Step 7/,/^## Step [89]|^## Error|^## Guardrails/' "$SKILL_MD" 2>/dev/null)
    if grep -qiE "architect-foundation" <<< "$step7_content"; then
        has_skill_name="yes"
    else
        has_skill_name="no"
    fi
    if grep -qiE "produces|generates|creates|sets up|ARCH_ENFORCEMENT|architecture.*enforcement|scaffolding" <<< "$step7_content"; then
        has_descriptions="yes"
    else
        has_descriptions="no"
    fi
    if [[ "$has_skill_name" == "yes" && "$has_descriptions" == "yes" ]]; then
        has_descriptive_labels="found"
    else
        has_descriptive_labels="missing"
    fi
    assert_eq "test_descriptive_labels" "found" "$has_descriptive_labels"
    assert_pass_if_clean "test_descriptive_labels"
}

# test_prompt_with_options (SC3): Step 7 must include an AskUserQuestion with options
# when architect-foundation has not been run
test_prompt_with_options() {
    _snapshot_fail
    local step7_content prompt_found
    step7_content=$(awk '/^## Step 7/,/^## Step [89]|^## Error|^## Guardrails/' "$SKILL_MD" 2>/dev/null)
    prompt_found="missing"
    if grep -qiE "AskUserQuestion|Which would you like|1\)|2\)" <<< "$step7_content"; then
        prompt_found="found"
    fi
    assert_eq "test_prompt_with_options" "found" "$prompt_found"
    assert_pass_if_clean "test_prompt_with_options"
}

# test_skip_ends_setup (SC6): skip option must end setup with no additional steps
test_skip_ends_setup() {
    _snapshot_fail
    local step7_content skip_ends_setup
    step7_content=$(awk '/^## Step 7/,/^## Step [89]|^## Error|^## Guardrails/' "$SKILL_MD" 2>/dev/null)
    skip_ends_setup="missing"
    if grep -qiE "skip.*setup.*complete|skip.*no.*additional|skip.*end|skip.*nothing|skip.*done|setup is complete|no additional steps" <<< "$step7_content"; then
        skip_ends_setup="found"
    fi
    assert_eq "test_skip_ends_setup" "found" "$skip_ends_setup"
    assert_pass_if_clean "test_skip_ends_setup"
}

# test_artifact_detection (SC8a): Step 7 must reference design-notes.md and
# ARCH_ENFORCEMENT.md as the artifacts used to detect whether onboarding already ran
test_artifact_detection() {
    _snapshot_fail
    local step7_content has_design_notes has_arch_enforcement artifact_detection
    step7_content=$(awk '/^## Step 7/,/^## Step [89]|^## Error|^## Guardrails/' "$SKILL_MD" 2>/dev/null)
    has_design_notes="no"
    has_arch_enforcement="no"
    if grep -qE "DESIGN_NOTES\.md|design-notes\.md" <<< "$step7_content"; then
        has_design_notes="yes"
    fi
    if grep -q "ARCH_ENFORCEMENT.md" <<< "$step7_content"; then
        has_arch_enforcement="yes"
    fi
    if [[ "$has_design_notes" == "yes" && "$has_arch_enforcement" == "yes" ]]; then
        artifact_detection="found"
    else
        artifact_detection="missing"
    fi
    assert_eq "test_artifact_detection" "found" "$artifact_detection"
    assert_pass_if_clean "test_artifact_detection"
}

# test_both_artifacts_skip_entirely (SC8b): when both artifacts are present,
# the prompt must be skipped entirely
test_both_artifacts_skip_entirely() {
    _snapshot_fail
    local step7_content both_artifacts_skip
    step7_content=$(awk '/^## Step 7/,/^## Step [89]|^## Error|^## Guardrails/' "$SKILL_MD" 2>/dev/null)
    both_artifacts_skip="missing"
    if grep -qiE "both.*present.*skip|skip.*both.*present|both.*artifact.*skip|already.*both.*skip|both.*exist.*skip|skip.*entirely|skip.*prompt|skip this step" <<< "$step7_content"; then
        both_artifacts_skip="found"
    fi
    assert_eq "test_both_artifacts_skip_entirely" "found" "$both_artifacts_skip"
    assert_pass_if_clean "test_both_artifacts_skip_entirely"
}

# test_sc2_numbered_ci_workflow_selection (SC2): SKILL.md must contain numbered
# selection dialogue when multiple CI workflows are detected
test_sc2_numbered_ci_workflow_selection() {
    _snapshot_fail
    local has_numbered_ci_selection="missing"
    if grep -qiE "numbered selection dialogue|numbered.*workflow|multiple.*workflow.*select|ci_workflow_confidence" "$SKILL_MD" 2>/dev/null; then
        has_numbered_ci_selection="found"
    fi
    assert_eq "test_sc2_numbered_ci_workflow_selection" "found" "$has_numbered_ci_selection"
    assert_pass_if_clean "test_sc2_numbered_ci_workflow_selection"
}

# Run all assertion functions
test_step7_exists
test_descriptive_labels
test_prompt_with_options
test_skip_ends_setup
test_artifact_detection
test_both_artifacts_skip_entirely
test_sc2_numbered_ci_workflow_selection

print_summary
