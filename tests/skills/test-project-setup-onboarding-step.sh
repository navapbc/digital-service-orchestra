#!/usr/bin/env bash
# tests/skills/test-project-setup-onboarding-step.sh
# Tests that plugins/dso/skills/project-setup/SKILL.md contains an onboarding
# integration step (Step 7) that offers /dso:dev-onboarding and /dso:design-onboarding
# with correct structure, prompts, and artifact detection.
#
# Validates (8 named assertions):
#   SC1: Step 7 heading present after Step 6 in SKILL.md
#   SC2: Option descriptions include brief summaries of what each skill produces
#   SC3: AskUserQuestion with 4 options when both skills available
#   SC4: yes/no variant when only one skill available
#   SC5: dev-onboarding invoked before design-onboarding in the sequence
#   SC6: skip option ends setup with no additional steps
#   SC8a: references DESIGN_NOTES.md and ARCH_ENFORCEMENT.md for artifact detection
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
# what each skill produces (e.g. what dev-onboarding and design-onboarding generate)
test_descriptive_labels() {
    _snapshot_fail
    local step7_content has_skill_names has_descriptions has_descriptive_labels
    step7_content=$(awk '/^## Step 7/,/^## Step [89]|^## Error/' "$SKILL_MD" 2>/dev/null)
    if echo "$step7_content" | grep -qiE "dev-onboarding|design-onboarding"; then
        has_skill_names="yes"
    else
        has_skill_names="no"
    fi
    if echo "$step7_content" | grep -qiE "produces|generates|creates|sets up|ARCH_ENFORCEMENT|DESIGN_NOTES|codebase guide|architecture"; then
        has_descriptions="yes"
    else
        has_descriptions="no"
    fi
    if [[ "$has_skill_names" == "yes" && "$has_descriptions" == "yes" ]]; then
        has_descriptive_labels="found"
    else
        has_descriptive_labels="missing"
    fi
    assert_eq "test_descriptive_labels" "found" "$has_descriptive_labels"
    assert_pass_if_clean "test_descriptive_labels"
}

# test_four_option_prompt (SC3): Step 7 must include an AskUserQuestion with 4 options
# when both skills are available (dev-onboarding and design-onboarding)
test_four_option_prompt() {
    _snapshot_fail
    local step7_content four_option_found
    step7_content=$(awk '/^## Step 7/,/^## Step [89]|^## Error/' "$SKILL_MD" 2>/dev/null)
    four_option_found="missing"
    if echo "$step7_content" | grep -qiE "AskUserQuestion"; then
        if echo "$step7_content" | grep -qiE "both.*onboarding|run both|both skills|option.*both|4\)"; then
            four_option_found="found"
        fi
    fi
    assert_eq "test_four_option_prompt" "found" "$four_option_found"
    assert_pass_if_clean "test_four_option_prompt"
}

# test_single_option_prompt (SC4): Step 7 must include a yes/no variant for when
# only one onboarding skill is available
test_single_option_prompt() {
    _snapshot_fail
    local step7_content single_option_found
    step7_content=$(awk '/^## Step 7/,/^## Step [89]|^## Error/' "$SKILL_MD" 2>/dev/null)
    single_option_found="missing"
    if echo "$step7_content" | grep -qiE "only one|one.*available|yes.*no|yes/no|if only"; then
        single_option_found="found"
    fi
    assert_eq "test_single_option_prompt" "found" "$single_option_found"
    assert_pass_if_clean "test_single_option_prompt"
}

# test_invocation_order (SC5): dev-onboarding must be invoked before design-onboarding
# when running in sequence (dev-onboarding appears at a lower line number)
test_invocation_order() {
    _snapshot_fail
    local step7_content dev_line design_line invocation_order_ok
    step7_content=$(awk '/^## Step 7/,/^## Step [89]|^## Error/' "$SKILL_MD" 2>/dev/null)
    invocation_order_ok="missing"
    dev_line=$(echo "$step7_content" | grep -n "dev-onboarding" | head -1 | cut -d: -f1)
    design_line=$(echo "$step7_content" | grep -n "design-onboarding" | head -1 | cut -d: -f1)
    if [[ -n "$dev_line" && -n "$design_line" && "$dev_line" -lt "$design_line" ]]; then
        invocation_order_ok="found"
    fi
    assert_eq "test_invocation_order" "found" "$invocation_order_ok"
    assert_pass_if_clean "test_invocation_order"
}

# test_skip_ends_setup (SC6): skip option must end setup with no additional steps
test_skip_ends_setup() {
    _snapshot_fail
    local step7_content skip_ends_setup
    step7_content=$(awk '/^## Step 7/,/^## Step [89]|^## Error/' "$SKILL_MD" 2>/dev/null)
    skip_ends_setup="missing"
    if echo "$step7_content" | grep -qiE "skip.*setup.*complete|skip.*no.*additional|skip.*end|skip.*nothing|skip.*done|setup is complete|no additional steps"; then
        skip_ends_setup="found"
    fi
    assert_eq "test_skip_ends_setup" "found" "$skip_ends_setup"
    assert_pass_if_clean "test_skip_ends_setup"
}

# test_artifact_detection (SC8): Step 7 must reference DESIGN_NOTES.md and
# ARCH_ENFORCEMENT.md as the artifacts used to detect whether onboarding already ran
test_artifact_detection() {
    _snapshot_fail
    local step7_content has_design_notes has_arch_enforcement artifact_detection
    step7_content=$(awk '/^## Step 7/,/^## Step [89]|^## Error/' "$SKILL_MD" 2>/dev/null)
    has_design_notes="no"
    has_arch_enforcement="no"
    if echo "$step7_content" | grep -q "DESIGN_NOTES.md"; then
        has_design_notes="yes"
    fi
    if echo "$step7_content" | grep -q "ARCH_ENFORCEMENT.md"; then
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

# test_both_artifacts_skip_entirely (SC8): when both DESIGN_NOTES.md and
# ARCH_ENFORCEMENT.md are present, the prompt must be skipped entirely
test_both_artifacts_skip_entirely() {
    _snapshot_fail
    local step7_content both_artifacts_skip
    step7_content=$(awk '/^## Step 7/,/^## Step [89]|^## Error/' "$SKILL_MD" 2>/dev/null)
    both_artifacts_skip="missing"
    if echo "$step7_content" | grep -qiE "both.*present.*skip|skip.*both.*present|both.*artifact.*skip|already.*both.*skip|both.*exist.*skip|skip.*entirely|skip.*prompt|skip this step"; then
        both_artifacts_skip="found"
    fi
    assert_eq "test_both_artifacts_skip_entirely" "found" "$both_artifacts_skip"
    assert_pass_if_clean "test_both_artifacts_skip_entirely"
}

# Run all 8 assertion functions
test_step7_exists
test_descriptive_labels
test_four_option_prompt
test_single_option_prompt
test_invocation_order
test_skip_ends_setup
test_artifact_detection
test_both_artifacts_skip_entirely

print_summary
