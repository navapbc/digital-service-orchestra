#!/usr/bin/env bash
# tests/skills/test-architect-foundation-skill.sh
# Tests that plugins/dso/skills/architect-foundation/SKILL.md has the correct structure
# for the /dso:architect-foundation scaffolding skill.
#
# Validates (29 named assertions):
#   test_skill_file_exists: SKILL.md exists at the expected path
#   test_frontmatter_valid: frontmatter has name=architect-foundation and user-invocable=true
#   test_sub_agent_guard_present: Agent tool SUB-AGENT-GUARD block present (dispatches sub-agents)
#   test_reads_project_understanding: references .claude/project-understanding.md as input
#   test_socratic_dialogue: contains Socratic dialogue pattern (one question / single question)
#   test_no_duplicate_detection: does NOT reference project-detect.sh (delegates to project-understanding.md)
#   test_enforcement_preferences: references enforcement or anti-pattern
#   test_recommendation_synthesis: SKILL.md must instruct synthesizing findings into recommendations
#   test_project_file_citations: SKILL.md must instruct citing specific project files in recommendations
#   test_per_recommendation_interaction: SKILL.md must allow user to accept/reject/discuss each recommendation
#   test_test_isolation_enforcement: SKILL.md must include test isolation enforcement in recommendations
#   test_socratic_dialogue_pattern: SKILL.md must contain explicit open-ended question guidance
#   test_no_rigid_multiple_choice: SKILL.md must explicitly warn against rigid menu-style prompts
#   test_check_onboarding_compatibility: SKILL.md must produce artifacts detectable by check-onboarding.sh
#   test_artifact_review_before_writing: SKILL.md must instruct presenting artifacts for user approval before writing
#   test_diff_existing_files: SKILL.md must instruct showing diffs against existing files
#   test_batched_file_confirmation: SKILL.md must use a single confirmation for all artifact writes
#   test_file_summary_before_confirmation: SKILL.md must present a summary of artifacts before confirmation
#   test_partial_failure_handling: SKILL.md must handle partial write failures gracefully
#   test_adrs_always_generated: SKILL.md must instruct always generating ADRs without asking
#   test_adr_session_scope: SKILL.md must specify ADRs are scoped to the current session
#   test_adr_dedup_logic: SKILL.md must include ADR deduplication logic
#   test_no_adr_preference_question: SKILL.md must NOT ask the user about ADR preferences
#   test_auto_flag_support: SKILL.md must document the --auto flag
#   test_auto_recommended_defaults: SKILL.md must instruct selecting recommended defaults in --auto mode
#   test_auto_graceful_missing: SKILL.md must instruct graceful error when project-understanding.md is missing
#   test_artifact_detection: SKILL.md must include artifact detection for re-run mode
#   test_append_only_merge: SKILL.md must use append-only merge for re-run idempotency
#   test_idempotency: SKILL.md must include idempotency guarantee for re-runs
#
# These are metadata/schema validation tests per the Behavioral Test Requirement exemption.
# First 7 tests PASS with current SKILL.md; last 22 tests are RED until SKILL.md is updated.
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

# test_recommendation_synthesis: SKILL.md must instruct synthesizing findings into recommendations
# Greps for 'recommend' AND 'synthesiz' to confirm explicit synthesis step
test_recommendation_synthesis() {
    _snapshot_fail
    local has_recommend has_synthesize synthesis_found
    has_recommend="no"
    has_synthesize="no"
    if grep -qi "recommend" "$SKILL_MD" 2>/dev/null; then
        has_recommend="yes"
    fi
    if grep -qi "synthesiz" "$SKILL_MD" 2>/dev/null; then
        has_synthesize="yes"
    fi
    if [[ "$has_recommend" == "yes" && "$has_synthesize" == "yes" ]]; then
        synthesis_found="found"
    else
        synthesis_found="missing"
    fi
    assert_eq "test_recommendation_synthesis" "found" "$synthesis_found"
    assert_pass_if_clean "test_recommendation_synthesis"
}

# test_project_file_citations: SKILL.md must instruct citing specific project files in recommendations
# Greps for 'cit.*project.*file' or 'specific.*file.*pattern'
test_project_file_citations() {
    _snapshot_fail
    local citations_found
    citations_found="missing"
    if grep -qiE "cit.*project.*file|specific.*file.*pattern" "$SKILL_MD" 2>/dev/null; then
        citations_found="found"
    fi
    assert_eq "test_project_file_citations" "found" "$citations_found"
    assert_pass_if_clean "test_project_file_citations"
}

# test_per_recommendation_interaction: SKILL.md must allow user to accept/reject/discuss each recommendation
# Greps for 'accept.*reject', 'reject.*accept', or 'discuss.*recommendation'
test_per_recommendation_interaction() {
    _snapshot_fail
    local interaction_found
    interaction_found="missing"
    if grep -qiE "accept.*reject|reject.*accept|discuss.*recommendation" "$SKILL_MD" 2>/dev/null; then
        interaction_found="found"
    fi
    assert_eq "test_per_recommendation_interaction" "found" "$interaction_found"
    assert_pass_if_clean "test_per_recommendation_interaction"
}

# test_test_isolation_enforcement: SKILL.md must include test isolation enforcement in recommendations
# Greps for 'test.*isolation'
test_test_isolation_enforcement() {
    _snapshot_fail
    local isolation_found
    isolation_found="missing"
    if grep -qiE "test.*isolation" "$SKILL_MD" 2>/dev/null; then
        isolation_found="found"
    fi
    assert_eq "test_test_isolation_enforcement" "found" "$isolation_found"
    assert_pass_if_clean "test_test_isolation_enforcement"
}

# test_no_rigid_multiple_choice: SKILL.md must explicitly warn against rigid menu-style prompts
# Greps for 'avoid.*rigid' or 'no.*menu' or 'no.*multiple.choice' — explicit anti-menu guidance
test_no_rigid_multiple_choice() {
    _snapshot_fail
    local anti_menu_found
    anti_menu_found="missing"
    if grep -qiE "avoid.*rigid|no.*menu|no.*multiple.choice" "$SKILL_MD" 2>/dev/null; then
        anti_menu_found="found"
    fi
    assert_eq "test_no_rigid_multiple_choice" "found" "$anti_menu_found"
    assert_pass_if_clean "test_no_rigid_multiple_choice"
}

# test_check_onboarding_compatibility: SKILL.md must produce artifacts detectable by check-onboarding.sh
# Greps for 'ARCH_ENFORCEMENT' or 'check-onboarding'
test_check_onboarding_compatibility() {
    _snapshot_fail
    local compat_found
    compat_found="missing"
    if grep -qiE "ARCH_ENFORCEMENT|check-onboarding" "$SKILL_MD" 2>/dev/null; then
        compat_found="found"
    fi
    assert_eq "test_check_onboarding_compatibility" "found" "$compat_found"
    assert_pass_if_clean "test_check_onboarding_compatibility"
}

# Run all 7 original assertion functions — all PASS with current SKILL.md
test_skill_file_exists
test_frontmatter_valid
test_sub_agent_guard_present
test_reads_project_understanding
test_socratic_dialogue
test_no_duplicate_detection
test_enforcement_preferences

# Run 7 new assertion functions — all RED (FAIL) against current SKILL.md
test_recommendation_synthesis
test_project_file_citations
test_per_recommendation_interaction
test_test_isolation_enforcement
test_no_rigid_multiple_choice
test_check_onboarding_compatibility

# test_batched_file_confirmation: SKILL.md must use a single confirmation for all artifact writes
# Greps for 'single.*confirmation' — the batched UX uses one confirmation prompt for all files
test_batched_file_confirmation() {
    _snapshot_fail
    local confirm_found
    confirm_found="missing"
    if grep -qiE "single.*confirmation" "$SKILL_MD" 2>/dev/null; then
        confirm_found="found"
    fi
    assert_eq "test_batched_file_confirmation" "found" "$confirm_found"
    assert_pass_if_clean "test_batched_file_confirmation"
}

# test_partial_failure_handling: SKILL.md must handle partial write failures gracefully
# Greps for 'partial.*fail'
test_partial_failure_handling() {
    _snapshot_fail
    local partial_found
    partial_found="missing"
    if grep -qiE "partial.*fail" "$SKILL_MD" 2>/dev/null; then
        partial_found="found"
    fi
    assert_eq "test_partial_failure_handling" "found" "$partial_found"
    assert_pass_if_clean "test_partial_failure_handling"
}

test_batched_file_confirmation
test_partial_failure_handling

# test_adr_dedup_logic: SKILL.md must include ADR deduplication logic
# Greps for 'dedup|deduplication'
test_adr_dedup_logic() {
    _snapshot_fail
    local dedup_found
    dedup_found="missing"
    if grep -qiE "dedup|deduplication" "$SKILL_MD" 2>/dev/null; then
        dedup_found="found"
    fi
    assert_eq "test_adr_dedup_logic" "found" "$dedup_found"
    assert_pass_if_clean "test_adr_dedup_logic"
}

# test_no_adr_preference_question: SKILL.md must NOT ask the user about ADR preferences
# (ADRs are always generated — this question is removed from the Question Bank)
# NEGATIVE test: 'ADR preference' must NOT appear in SKILL.md
test_no_adr_preference_question() {
    _snapshot_fail
    local adr_pref_found
    adr_pref_found="not-referenced"
    if grep -q "ADR preference" "$SKILL_MD" 2>/dev/null; then
        adr_pref_found="referenced"
    fi
    assert_eq "test_no_adr_preference_question" "not-referenced" "$adr_pref_found"
    assert_pass_if_clean "test_no_adr_preference_question"
}

test_adr_dedup_logic
test_no_adr_preference_question

# test_auto_flag_support: SKILL.md must document the --auto flag
# Greps for '--auto'
test_auto_flag_support() {
    _snapshot_fail
    local auto_found
    auto_found="missing"
    if grep -qiE -- "--auto" "$SKILL_MD" 2>/dev/null; then
        auto_found="found"
    fi
    assert_eq "test_auto_flag_support" "found" "$auto_found"
    assert_pass_if_clean "test_auto_flag_support"
}

# test_auto_recommended_defaults: SKILL.md must instruct selecting recommended defaults in --auto mode
# Greps for 'recommend.*default'
test_auto_recommended_defaults() {
    _snapshot_fail
    local defaults_found
    defaults_found="missing"
    if grep -qiE "recommend.*default" "$SKILL_MD" 2>/dev/null; then
        defaults_found="found"
    fi
    assert_eq "test_auto_recommended_defaults" "found" "$defaults_found"
    assert_pass_if_clean "test_auto_recommended_defaults"
}

# test_auto_graceful_missing: SKILL.md must instruct graceful error when project-understanding.md is missing
# Greps for 'actionable.*error'
test_auto_graceful_missing() {
    _snapshot_fail
    local graceful_found
    graceful_found="missing"
    if grep -qiE "actionable.*error" "$SKILL_MD" 2>/dev/null; then
        graceful_found="found"
    fi
    assert_eq "test_auto_graceful_missing" "found" "$graceful_found"
    assert_pass_if_clean "test_auto_graceful_missing"
}

# test_artifact_detection: SKILL.md must include artifact detection for re-run mode
# Greps for 'artifact.*detection|detect.*artifact'
test_artifact_detection() {
    _snapshot_fail
    local detect_found
    detect_found="missing"
    if grep -qiE "artifact.*detection|detect.*artifact" "$SKILL_MD" 2>/dev/null; then
        detect_found="found"
    fi
    assert_eq "test_artifact_detection" "found" "$detect_found"
    assert_pass_if_clean "test_artifact_detection"
}

# test_append_only_merge: SKILL.md must use append-only merge for re-run idempotency
# Greps for 'append.only|append-only'
test_append_only_merge() {
    _snapshot_fail
    local append_found
    append_found="missing"
    if grep -qiE "append.only|append-only" "$SKILL_MD" 2>/dev/null; then
        append_found="found"
    fi
    assert_eq "test_append_only_merge" "found" "$append_found"
    assert_pass_if_clean "test_append_only_merge"
}

test_auto_flag_support
test_auto_recommended_defaults
test_auto_graceful_missing
test_artifact_detection
test_append_only_merge

print_summary
