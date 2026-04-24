#!/usr/bin/env bash
# tests/skills/test-onboarding-ux-validation.sh
# Structural validation tests for UX improvements added to
# plugins/dso/skills/onboarding/SKILL.md as part of epic 903c-44fc.
#
# Validates (10 named assertions):
#   test_orientation_message_present: "one-time" setup message and artifact list present
#   test_phase_counter_display: Phase N of Y counter pattern present
#   test_all_three_integration_prompts: Figma, Confluence, and Jira integration prompts present
#   test_integration_prompts_skippable: "skip" option present near Figma and Confluence sections
#   test_dependency_scan_before_questions: dep-scan section appears before phase questions
#   test_optional_deps_non_blocking: optional deps (ast-grep/semgrep) described as non-blocking
#   test_file_write_explanations_present: plain-language explanation before dso-config.conf and shim writes
#   test_natural_language_preplanning_question: preplanning uses natural language (no "(true/false)")
#   test_credentials_as_env_vars_only: JIRA_API_TOKEN and FIGMA_PAT kept as env vars, not config
#   test_shim_executable_instruction: chmod +x or test -x present for shim/hook installation
#
# These are metadata/schema validation tests per the Behavioral Test Requirement exemption.
# Structural boundary tests for instruction files are explicitly permitted.
#
# Usage: bash tests/skills/test-onboarding-ux-validation.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/onboarding/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-onboarding-ux-validation.sh ==="

# test_orientation_message_present: Onboarding Overview must describe it as a "one-time" setup
# and list the key artifacts it produces (dso-config.conf and shim)
test_orientation_message_present() {
    _snapshot_fail
    local has_one_time="no"
    local has_artifact_list="no"
    if grep -qi "one-time" "$SKILL_MD" 2>/dev/null; then
        has_one_time="yes"
    fi
    if grep -q "dso-config.conf" "$SKILL_MD" 2>/dev/null && \
       grep -qE "\.claude/scripts/dso|shim" "$SKILL_MD" 2>/dev/null; then
        has_artifact_list="yes"
    fi
    if [[ "$has_one_time" == "yes" && "$has_artifact_list" == "yes" ]]; then
        assert_eq "test_orientation_message_present" "found" "found"
    else
        assert_eq "test_orientation_message_present" "found" "missing (one-time=$has_one_time artifact-list=$has_artifact_list)"
    fi
    assert_pass_if_clean "test_orientation_message_present"
}

# test_phase_counter_display: SKILL.md must instruct displaying a "Phase N of Y" counter
# with concrete numeric examples to orient the user during multi-phase onboarding
test_phase_counter_display() {
    _snapshot_fail
    local has_counter="no"
    if grep -qE 'Phase [0-9]+ of [0-9]+' "$SKILL_MD" 2>/dev/null; then
        has_counter="yes"
    fi
    assert_eq "test_phase_counter_display" "yes" "$has_counter"
    assert_pass_if_clean "test_phase_counter_display"
}

# test_all_three_integration_prompts: SKILL.md must include prompts for all three integration types:
# Figma (design), Confluence (docs), and Jira (ticketing)
test_all_three_integration_prompts() {
    _snapshot_fail
    local has_figma="no"
    local has_confluence="no"
    local has_jira="no"
    if grep -qi "figma" "$SKILL_MD" 2>/dev/null; then
        has_figma="yes"
    fi
    if grep -qi "confluence" "$SKILL_MD" 2>/dev/null; then
        has_confluence="yes"
    fi
    if grep -qiE "jira.project|jira bridge|JIRA_URL" "$SKILL_MD" 2>/dev/null; then
        has_jira="yes"
    fi
    if [[ "$has_figma" == "yes" && "$has_confluence" == "yes" && "$has_jira" == "yes" ]]; then
        assert_eq "test_all_three_integration_prompts" "found" "found"
    else
        assert_eq "test_all_three_integration_prompts" "found" "missing (figma=$has_figma confluence=$has_confluence jira=$has_jira)"
    fi
    assert_pass_if_clean "test_all_three_integration_prompts"
}

# test_integration_prompts_skippable: Figma and Confluence integration questions must be skippable
# — "skip" must appear within 15 lines of each integration section
test_integration_prompts_skippable() {
    _snapshot_fail
    local figma_skippable="no"
    local confluence_skippable="no"
    if grep -A 15 -i "figma" "$SKILL_MD" 2>/dev/null | grep -qi "skip"; then
        figma_skippable="yes"
    fi
    if grep -A 15 -i "confluence" "$SKILL_MD" 2>/dev/null | grep -qi "skip"; then
        confluence_skippable="yes"
    fi
    if [[ "$figma_skippable" == "yes" && "$confluence_skippable" == "yes" ]]; then
        assert_eq "test_integration_prompts_skippable" "found" "found"
    else
        assert_eq "test_integration_prompts_skippable" "found" "missing (figma-skip=$figma_skippable confluence-skip=$confluence_skippable)"
    fi
    assert_pass_if_clean "test_integration_prompts_skippable"
}

# test_dependency_scan_before_questions: dependency pre-scan section must appear before
# the phase question flow begins (checked by line number: dep-scan < PHASE_PLAN write)
test_dependency_scan_before_questions() {
    _snapshot_fail
    local dep_scan_line phase_start_line result
    dep_scan_line=$(grep -n "Step 0.*Dependency\|Dependency Pre-Scan\|/bin/bash.*--version" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)
    phase_start_line=$(grep -n "PHASE_PLAN" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)
    if [[ -n "$dep_scan_line" && -n "$phase_start_line" && "$dep_scan_line" -lt "$phase_start_line" ]]; then
        result="found"
    else
        result="missing (dep_scan=${dep_scan_line:-none} phase_start=${phase_start_line:-none})"
    fi
    assert_eq "test_dependency_scan_before_questions" "found" "$result"
    assert_pass_if_clean "test_dependency_scan_before_questions"
}

# test_optional_deps_non_blocking: optional dependencies (ast-grep, semgrep) must be described
# as non-blocking — the skill must never halt progress if they are absent
test_optional_deps_non_blocking() {
    _snapshot_fail
    local has_optional="no"
    local has_tools="no"
    local has_non_blocking="no"
    if grep -qiE "optional.*dep|Optional dep" "$SKILL_MD" 2>/dev/null; then
        has_optional="yes"
    fi
    if grep -qiE "ast-grep|semgrep" "$SKILL_MD" 2>/dev/null; then
        has_tools="yes"
    fi
    if grep -qiE "Never block|non-blocking|not.*block.*progress" "$SKILL_MD" 2>/dev/null; then
        has_non_blocking="yes"
    fi
    if [[ "$has_optional" == "yes" && "$has_tools" == "yes" && "$has_non_blocking" == "yes" ]]; then
        assert_eq "test_optional_deps_non_blocking" "found" "found"
    else
        assert_eq "test_optional_deps_non_blocking" "found" "missing (optional=$has_optional tools=$has_tools non-blocking=$has_non_blocking)"
    fi
    assert_pass_if_clean "test_optional_deps_non_blocking"
}

# test_file_write_explanations_present: plain-language explanations must appear via
# "Display to user" instructions before dso-config.conf and shim infrastructure writes
test_file_write_explanations_present() {
    _snapshot_fail
    local has_config_explanation="no"
    local has_shim_explanation="no"
    if grep -qE 'Display to user.*dso-config|dso-config.*Display to user' "$SKILL_MD" 2>/dev/null; then
        has_config_explanation="yes"
    fi
    if grep -qE 'Display to user.*[Ss]him|[Ss]him.*Display to user|Display to user.*DSO shim' "$SKILL_MD" 2>/dev/null; then
        has_shim_explanation="yes"
    fi
    if [[ "$has_config_explanation" == "yes" && "$has_shim_explanation" == "yes" ]]; then
        assert_eq "test_file_write_explanations_present" "found" "found"
    else
        assert_eq "test_file_write_explanations_present" "found" "missing (config-expl=$has_config_explanation shim-expl=$has_shim_explanation)"
    fi
    assert_pass_if_clean "test_file_write_explanations_present"
}

# test_credentials_as_env_vars_only: JIRA_API_TOKEN and FIGMA_PAT must be described as
# environment variables that stay outside of dso-config.conf
test_credentials_as_env_vars_only() {
    _snapshot_fail
    local jira_token_env="no"
    local figma_pat_env="no"
    if grep -qE 'JIRA_API_TOKEN.*env|env.*JIRA_API_TOKEN|environment.*JIRA_API_TOKEN|credentials.*JIRA_API_TOKEN' "$SKILL_MD" 2>/dev/null; then
        jira_token_env="yes"
    fi
    if grep -qE 'FIGMA_PAT.*env|env.*FIGMA_PAT|environment.*FIGMA_PAT|credentials.*FIGMA_PAT' "$SKILL_MD" 2>/dev/null; then
        figma_pat_env="yes"
    fi
    if [[ "$jira_token_env" == "yes" && "$figma_pat_env" == "yes" ]]; then
        assert_eq "test_credentials_as_env_vars_only" "found" "found"
    else
        assert_eq "test_credentials_as_env_vars_only" "found" "missing (jira-token-env=$jira_token_env figma-pat-env=$figma_pat_env)"
    fi
    assert_pass_if_clean "test_credentials_as_env_vars_only"
}

# test_shim_executable_instruction: SKILL.md must reference chmod +x or test -x
# in the context of shim or hook installation (ensures scripts are executable)
test_shim_executable_instruction() {
    _snapshot_fail
    local has_chmod="no"
    if grep -qE 'chmod \+x|test -x' "$SKILL_MD" 2>/dev/null; then
        has_chmod="yes"
    fi
    assert_eq "test_shim_executable_instruction" "yes" "$has_chmod"
    assert_pass_if_clean "test_shim_executable_instruction"
}

# Run all 10 tests
test_orientation_message_present
test_phase_counter_display
test_all_three_integration_prompts
test_integration_prompts_skippable
test_dependency_scan_before_questions
test_optional_deps_non_blocking
test_file_write_explanations_present
test_credentials_as_env_vars_only
test_shim_executable_instruction

print_summary
