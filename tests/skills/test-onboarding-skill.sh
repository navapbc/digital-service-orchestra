#!/usr/bin/env bash
# tests/skills/test-onboarding-skill.sh
# Tests that plugins/dso/skills/onboarding/SKILL.md has the correct structure
# for the /dso:onboarding Socratic dialogue skill.
#
# Validates (41 named assertions):
#   test_skill_file_exists: SKILL.md exists at the expected path
#   test_frontmatter_valid: frontmatter has name=onboarding and user-invocable=true
#   test_sub_agent_guard_present: Orchestrator Signal SUB-AGENT-GUARD block present
#   test_understanding_areas_complete: references all 7 understanding areas
#   test_scratchpad_instructions: contains scratchpad/temp file append instructions
#   test_detection_integration: references project-detect.sh
#   test_socratic_dialogue_pattern: contains Socratic dialogue indicators
#   test_architect_foundation_offer: references /dso:architect-foundation
#   test_auto_detection_before_asking: reads package.json/.husky before asking
#   test_config_key_completeness: references 6+ of 8 required config keys
#   test_absolute_path_requirement: mentions absolute path for dso.plugin_root
#   test_semicolon_delimited_format: documents semicolon-delimited behavioral_patterns
#   test_fallback_behavior: describes fallback/omit behavior for undetected config
#   test_ci_workflow_filename_confirmation: instructs listing actual workflow filenames
#   test_config_merge_existing: instructs detecting/merging existing dso-config.conf
#   test_jira_bridge_project_key: mentions Jira Bridge connection (JIRA_URL/jira bridge)
#   test_no_rigid_multiple_choice: must NOT contain rigid (a)/(b)/(c) menu patterns
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

# ── GREEN config tests (pass now — config section already in SKILL.md) ────────

# test_config_generation_section: SKILL.md must contain a config generation phase/section
test_config_generation_section() {
    _snapshot_fail
    local has_config has_dso_config config_valid
    has_config="no"
    has_dso_config="no"
    if grep -qi "config" "$SKILL_MD" 2>/dev/null; then
        has_config="yes"
    fi
    if grep -qE "dso-config(\.conf)?" "$SKILL_MD" 2>/dev/null; then
        has_dso_config="yes"
    fi
    if [[ "$has_config" == "yes" && "$has_dso_config" == "yes" ]]; then
        config_valid="found"
    else
        config_valid="missing"
    fi
    assert_eq "test_config_generation_section" "found" "$config_valid"
    assert_pass_if_clean "test_config_generation_section"
}

# test_config_key_categories: SKILL.md must reference dso-config.conf key categories
# Must match at least 5 of: format, ci, commands, jira, design, tickets, merge, version, test
test_config_key_categories() {
    _snapshot_fail
    local categories_found categories_missing category
    categories_found=0
    categories_missing=""
    local required_categories=("format" "ci" "commands" "jira" "design" "tickets" "merge" "version" "test")
    for category in "${required_categories[@]}"; do
        if grep -qw "$category" "$SKILL_MD" 2>/dev/null; then
            (( categories_found++ ))
        else
            categories_missing="$categories_missing $category"
        fi
    done
    if [[ "$categories_found" -ge 5 ]]; then
        assert_eq "test_config_key_categories" "found" "found"
    else
        assert_eq "test_config_key_categories" "at least 5 categories" "$categories_found categories found (missing:$categories_missing)"
    fi
    assert_pass_if_clean "test_config_key_categories"
}

# ── RED config tests (not yet implemented in SKILL.md) ───────────────────────

# test_ticket_prefix_derivation: SKILL.md must mention ticket prefix derivation from project name
test_ticket_prefix_derivation() {
    _snapshot_fail
    local has_ticket has_prefix ticket_prefix_valid
    has_ticket="no"
    has_prefix="no"
    if grep -qi "ticket" "$SKILL_MD" 2>/dev/null; then
        has_ticket="yes"
    fi
    if grep -qi "prefix" "$SKILL_MD" 2>/dev/null; then
        has_prefix="yes"
    fi
    if [[ "$has_ticket" == "yes" && "$has_prefix" == "yes" ]]; then
        ticket_prefix_valid="found"
    else
        ticket_prefix_valid="missing"
    fi
    assert_eq "test_ticket_prefix_derivation" "found" "$ticket_prefix_valid"
    assert_pass_if_clean "test_ticket_prefix_derivation"
}

# test_ci_workflow_examples: SKILL.md must mention offering example workflows when none exist
test_ci_workflow_examples() {
    _snapshot_fail
    local has_example has_workflow ci_workflow_valid
    has_example="no"
    has_workflow="no"
    if grep -qi "example" "$SKILL_MD" 2>/dev/null; then
        has_example="yes"
    fi
    if grep -qi "workflow" "$SKILL_MD" 2>/dev/null; then
        has_workflow="yes"
    fi
    if [[ "$has_example" == "yes" && "$has_workflow" == "yes" ]]; then
        ci_workflow_valid="found"
    else
        ci_workflow_valid="missing"
    fi
    assert_eq "test_ci_workflow_examples" "found" "$ci_workflow_valid"
    assert_pass_if_clean "test_ci_workflow_examples"
}

# test_acli_auto_suggestion: SKILL.md must mention ACLI_VERSION or acli-version-resolver
test_acli_auto_suggestion() {
    _snapshot_fail
    local acli_found
    acli_found="missing"
    if grep -qE "ACLI_VERSION|acli-version-resolver" "$SKILL_MD" 2>/dev/null; then
        acli_found="found"
    fi
    assert_eq "test_acli_auto_suggestion" "found" "$acli_found"
    assert_pass_if_clean "test_acli_auto_suggestion"
}

# ── GREEN design tests (pass now — terms already in SKILL.md) ────────────────

# test_design_questions_conditional: SKILL.md must mention conditional activation
# for UI projects (references "UI" and "component" or "frontend")
test_design_questions_conditional() {
    _snapshot_fail
    local has_ui has_component_or_frontend design_conditional_valid
    has_ui="no"
    has_component_or_frontend="no"
    if grep -qiE "\bUI\b" "$SKILL_MD" 2>/dev/null; then
        has_ui="yes"
    fi
    if grep -qiE "component|frontend" "$SKILL_MD" 2>/dev/null; then
        has_component_or_frontend="yes"
    fi
    if [[ "$has_ui" == "yes" && "$has_component_or_frontend" == "yes" ]]; then
        design_conditional_valid="found"
    else
        design_conditional_valid="missing"
    fi
    assert_eq "test_design_questions_conditional" "found" "$design_conditional_valid"
    assert_pass_if_clean "test_design_questions_conditional"
}

# test_design_skip_non_ui: SKILL.md must mention skipping design questions for non-UI projects
# (references "CLI" or "library" or "skip")
test_design_skip_non_ui() {
    _snapshot_fail
    local skip_found
    skip_found="missing"
    if grep -qiE "\bCLI\b|library|skip" "$SKILL_MD" 2>/dev/null; then
        skip_found="found"
    fi
    assert_eq "test_design_skip_non_ui" "found" "$skip_found"
    assert_pass_if_clean "test_design_skip_non_ui"
}

# ── RED design tests (not yet implemented in SKILL.md) ───────────────────────

# test_design_areas_complete: SKILL.md must reference design areas
# Must match at least 3 of: vision, archetypes, golden paths, visual language, accessibility
test_design_areas_complete() {
    _snapshot_fail
    local areas_found areas_missing area
    areas_found=0
    areas_missing=""
    local required_areas=("vision" "archetypes" "golden paths" "visual language" "accessibility")
    for area in "${required_areas[@]}"; do
        if grep -qiE "$area" "$SKILL_MD" 2>/dev/null; then
            (( areas_found++ ))
        else
            areas_missing="$areas_missing $area"
        fi
    done
    if [[ "$areas_found" -ge 3 ]]; then
        assert_eq "test_design_areas_complete" "found" "found"
    else
        assert_eq "test_design_areas_complete" "at least 3 design areas" "$areas_found design areas found (missing:$areas_missing)"
    fi
    assert_pass_if_clean "test_design_areas_complete"
}

# test_design_notes_output: SKILL.md must reference .claude/design-notes.md as output artifact
test_design_notes_output() {
    _snapshot_fail
    local artifact_found
    artifact_found="missing"
    if grep -q "design-notes.md" "$SKILL_MD" 2>/dev/null; then
        artifact_found="found"
    fi
    assert_eq "test_design_notes_output" "found" "$artifact_found"
    assert_pass_if_clean "test_design_notes_output"
}

# ── RED auto-detection / config / dialogue tests (new — fail until SKILL.md updated) ─────

# test_auto_detection_before_asking: SKILL.md must instruct reading project files
# (package.json, .husky/, .github/workflows/) BEFORE asking questions
test_auto_detection_before_asking() {
    _snapshot_fail
    local package_json_found husky_found workflows_found result
    package_json_found="no"
    husky_found="no"
    workflows_found="no"
    if grep -qF "package.json" "$SKILL_MD" 2>/dev/null; then
        package_json_found="yes"
    fi
    if grep -qF ".husky/" "$SKILL_MD" 2>/dev/null; then
        husky_found="yes"
    fi
    if grep -qE "\.github/workflows|workflows/\*\.yml" "$SKILL_MD" 2>/dev/null; then
        workflows_found="yes"
    fi
    if [[ "$package_json_found" == "yes" && "$husky_found" == "yes" && "$workflows_found" == "yes" ]]; then
        result="found"
    else
        result="missing"
    fi
    assert_eq "test_auto_detection_before_asking" "found" "$result"
    assert_pass_if_clean "test_auto_detection_before_asking"
}

# test_config_key_completeness: SKILL.md must reference ALL required config keys:
# dso.plugin_root, format.extensions, format.source_dirs, test_gate.test_dirs,
# commands.validate, tickets.directory, checkpoint.marker_file, review.behavioral_patterns
# Must find at least 6 of 8
test_config_key_completeness() {
    _snapshot_fail
    local keys_found keys_missing key
    keys_found=0
    keys_missing=""
    local required_keys=("dso.plugin_root" "format.extensions" "format.source_dirs" "test_gate.test_dirs" "commands.validate" "tickets.directory" "checkpoint.marker_file" "review.behavioral_patterns")
    for key in "${required_keys[@]}"; do
        if grep -qF "$key" "$SKILL_MD" 2>/dev/null; then
            (( keys_found++ ))
        else
            keys_missing="$keys_missing $key"
        fi
    done
    if [[ "$keys_found" -ge 6 ]]; then
        assert_eq "test_config_key_completeness" "found" "found"
    else
        assert_eq "test_config_key_completeness" "at least 6 of 8 config keys" "$keys_found keys found (missing:$keys_missing)"
    fi
    assert_pass_if_clean "test_config_key_completeness"
}

# test_absolute_path_requirement: SKILL.md must mention absolute path for dso.plugin_root
# grep for 'absolute.*path' or 'realpath' near 'plugin_root'
test_absolute_path_requirement() {
    _snapshot_fail
    local absolute_found
    absolute_found="missing"
    if grep -qiE "absolute.*path|realpath" "$SKILL_MD" 2>/dev/null; then
        absolute_found="found"
    fi
    assert_eq "test_absolute_path_requirement" "found" "$absolute_found"
    assert_pass_if_clean "test_absolute_path_requirement"
}

# test_semicolon_delimited_format: SKILL.md must document semicolon-delimited format
# for review.behavioral_patterns — grep for 'semicolon'
test_semicolon_delimited_format() {
    _snapshot_fail
    local semicolon_found
    semicolon_found="missing"
    if grep -qi "semicolon" "$SKILL_MD" 2>/dev/null; then
        semicolon_found="found"
    fi
    assert_eq "test_semicolon_delimited_format" "found" "$semicolon_found"
    assert_pass_if_clean "test_semicolon_delimited_format"
}

# test_fallback_behavior: SKILL.md must describe fallback when config cannot be auto-detected
# grep for 'fallback' or 'omit.*comment'
test_fallback_behavior() {
    _snapshot_fail
    local fallback_found
    fallback_found="missing"
    if grep -qiE "fallback|omit.*comment" "$SKILL_MD" 2>/dev/null; then
        fallback_found="found"
    fi
    assert_eq "test_fallback_behavior" "found" "$fallback_found"
    assert_pass_if_clean "test_fallback_behavior"
}

# test_ci_workflow_filename_confirmation: SKILL.md must instruct listing actual workflow filenames
# (e.g., scanning existing .github/workflows/ files by name, not just offering examples)
# grep for 'workflow.*filename' (specific — not just any mention of .yml or list)
test_ci_workflow_filename_confirmation() {
    _snapshot_fail
    local filename_found
    filename_found="missing"
    if grep -qiE "workflow.*filename" "$SKILL_MD" 2>/dev/null; then
        filename_found="found"
    fi
    assert_eq "test_ci_workflow_filename_confirmation" "found" "$filename_found"
    assert_pass_if_clean "test_ci_workflow_filename_confirmation"
}

# test_config_merge_existing: SKILL.md must instruct detecting and merging with
# existing dso-config.conf — grep for 'existing.*config' or 'existing dso-config'
test_config_merge_existing() {
    _snapshot_fail
    local merge_existing_found
    merge_existing_found="missing"
    if grep -qiE "existing.*config|existing dso-config" "$SKILL_MD" 2>/dev/null; then
        merge_existing_found="found"
    fi
    assert_eq "test_config_merge_existing" "found" "$merge_existing_found"
    assert_pass_if_clean "test_config_merge_existing"
}

# test_jira_bridge_project_key: SKILL.md must mention Jira Bridge connection with project key
# grep for 'jira bridge' or 'JIRA_URL' (not merely jira.project_key config key)
test_jira_bridge_project_key() {
    _snapshot_fail
    local jira_bridge_found
    jira_bridge_found="missing"
    if grep -qiE "jira bridge|JIRA_URL" "$SKILL_MD" 2>/dev/null; then
        jira_bridge_found="found"
    fi
    assert_eq "test_jira_bridge_project_key" "found" "$jira_bridge_found"
    assert_pass_if_clean "test_jira_bridge_project_key"
}

# test_no_rigid_multiple_choice: SKILL.md must NOT contain rigid quiz-style instruction patterns.
# The skill must use confirmation-based dialogue, not letterd menus like "(a) X (b) Y (c) Z".
# This is a negative assertion: presence of letter-option menus causes failure.
test_no_rigid_multiple_choice() {
    _snapshot_fail
    local rigid_count
    rigid_count=$(grep -cE "^\s*(a\)|b\)|c\)|d\)|e\))" "$SKILL_MD" 2>/dev/null || true)
    if [[ "$rigid_count" -eq 0 ]]; then
        assert_eq "test_no_rigid_multiple_choice" "found" "found"
    else
        assert_eq "test_no_rigid_multiple_choice" "no rigid (a)/(b)/(c) menus" "$rigid_count rigid menu lines found"
    fi
    assert_pass_if_clean "test_no_rigid_multiple_choice"
}

# ── RED infrastructure initialization tests (new — fail until SKILL.md updated) ─

# test_hook_installation_instructions: SKILL.md must instruct installing git pre-commit hooks
# grep for 'pre-commit-test-gate' or 'pre-commit-review-gate' or 'hook.*install'
test_hook_installation_instructions() {
    _snapshot_fail
    local hooks_found
    hooks_found="missing"
    if grep -qiE "pre-commit-test-gate|pre-commit-review-gate|hook.*install" "$SKILL_MD" 2>/dev/null; then
        hooks_found="found"
    fi
    assert_eq "test_hook_installation_instructions" "found" "$hooks_found"
    assert_pass_if_clean "test_hook_installation_instructions"
}

# test_hook_manager_detection: SKILL.md must mention detecting hook managers
# (Husky, pre-commit framework, bare .git/hooks) — grep for 'Husky' AND ('pre-commit' or '.git/hooks')
test_hook_manager_detection() {
    _snapshot_fail
    local has_husky has_hook_manager result
    has_husky="no"
    has_hook_manager="no"
    if grep -q "Husky" "$SKILL_MD" 2>/dev/null; then
        has_husky="yes"
    fi
    if grep -qiE "pre-commit framework|\.git/hooks" "$SKILL_MD" 2>/dev/null; then
        has_hook_manager="yes"
    fi
    if [[ "$has_husky" == "yes" && "$has_hook_manager" == "yes" ]]; then
        result="found"
    else
        result="missing"
    fi
    assert_eq "test_hook_manager_detection" "found" "$result"
    assert_pass_if_clean "test_hook_manager_detection"
}

# test_git_common_dir: SKILL.md must mention git rev-parse --git-common-dir
# for worktree/submodule support
test_git_common_dir() {
    _snapshot_fail
    local git_common_dir_found
    git_common_dir_found="missing"
    if grep -q "git-common-dir" "$SKILL_MD" 2>/dev/null; then
        git_common_dir_found="found"
    fi
    assert_eq "test_git_common_dir" "found" "$git_common_dir_found"
    assert_pass_if_clean "test_git_common_dir"
}

# test_ticket_system_init: SKILL.md must instruct initializing ticket system
# (orphan branch, .tickets-tracker/) — grep for 'orphan' AND 'tickets-tracker'
test_ticket_system_init() {
    _snapshot_fail
    local has_orphan has_tickets_tracker result
    has_orphan="no"
    has_tickets_tracker="no"
    if grep -q "orphan" "$SKILL_MD" 2>/dev/null; then
        has_orphan="yes"
    fi
    if grep -q "tickets-tracker" "$SKILL_MD" 2>/dev/null; then
        has_tickets_tracker="yes"
    fi
    if [[ "$has_orphan" == "yes" && "$has_tickets_tracker" == "yes" ]]; then
        result="found"
    else
        result="missing"
    fi
    assert_eq "test_ticket_system_init" "found" "$result"
    assert_pass_if_clean "test_ticket_system_init"
}

# test_ticket_smoke_test: SKILL.md must instruct performing a ticket smoke test after init
# grep for 'smoke.*test' or 'create.*read.*ticket'
test_ticket_smoke_test() {
    _snapshot_fail
    local smoke_test_found
    smoke_test_found="missing"
    if grep -qiE "smoke.*test|create.*read.*ticket" "$SKILL_MD" 2>/dev/null; then
        smoke_test_found="found"
    fi
    assert_eq "test_ticket_smoke_test" "found" "$smoke_test_found"
    assert_pass_if_clean "test_ticket_smoke_test"
}

# test_generate_test_index: SKILL.md must reference generate-test-index.sh
test_generate_test_index() {
    _snapshot_fail
    local test_index_found
    test_index_found="missing"
    if grep -q "generate-test-index" "$SKILL_MD" 2>/dev/null; then
        test_index_found="found"
    fi
    assert_eq "test_generate_test_index" "found" "$test_index_found"
    assert_pass_if_clean "test_generate_test_index"
}

# test_claude_md_generation: SKILL.md must instruct generating CLAUDE.md with ticket command references
# grep for 'CLAUDE.md' AND 'ticket.*command'
test_claude_md_generation() {
    _snapshot_fail
    local has_claude_md has_ticket_command result
    has_claude_md="no"
    has_ticket_command="no"
    if grep -q "CLAUDE.md" "$SKILL_MD" 2>/dev/null; then
        has_claude_md="yes"
    fi
    if grep -qiE "ticket.*command" "$SKILL_MD" 2>/dev/null; then
        has_ticket_command="yes"
    fi
    if [[ "$has_claude_md" == "yes" && "$has_ticket_command" == "yes" ]]; then
        result="found"
    else
        result="missing"
    fi
    assert_eq "test_claude_md_generation" "found" "$result"
    assert_pass_if_clean "test_claude_md_generation"
}

# test_known_issues_template: SKILL.md must reference KNOWN-ISSUES template
test_known_issues_template() {
    _snapshot_fail
    local known_issues_found
    known_issues_found="missing"
    if grep -q "KNOWN-ISSUES" "$SKILL_MD" 2>/dev/null; then
        known_issues_found="found"
    fi
    assert_eq "test_known_issues_template" "found" "$known_issues_found"
    assert_pass_if_clean "test_known_issues_template"
}

# test_ci_trigger_strategy: SKILL.md must ask about CI trigger strategy (not assume PR-based)
# grep for 'trigger.*strategy' or 'CI.*trigger' or 'not.*assume.*PR'
test_ci_trigger_strategy() {
    _snapshot_fail
    local ci_trigger_found
    ci_trigger_found="missing"
    if grep -qiE "trigger.*strategy|CI.*trigger|not.*assume.*PR" "$SKILL_MD" 2>/dev/null; then
        ci_trigger_found="found"
    fi
    assert_eq "test_ci_trigger_strategy" "found" "$ci_trigger_found"
    assert_pass_if_clean "test_ci_trigger_strategy"
}

# test_push_verification: SKILL.md must verify push success after ticket system init
# grep for 'push.*verif' or 'push.*fail' or 'push.*warn'
test_push_verification() {
    _snapshot_fail
    local push_verif_found
    push_verif_found="missing"
    if grep -qiE "push.*verif|push.*fail|push.*warn" "$SKILL_MD" 2>/dev/null; then
        push_verif_found="found"
    fi
    assert_eq "test_push_verification" "found" "$push_verif_found"
    assert_pass_if_clean "test_push_verification"
}

# Run all 21 assertion functions — GREEN tests first, RED tests last
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
test_config_generation_section
test_config_key_categories
test_ticket_prefix_derivation
test_ci_workflow_examples
test_acli_auto_suggestion
test_design_questions_conditional
test_design_skip_non_ui
# RED design tests below — these fail until design areas/notes are added to SKILL.md
test_design_areas_complete
test_design_notes_output
# RED auto-detection/config/dialogue tests — these fail until SKILL.md is updated
test_auto_detection_before_asking
test_config_key_completeness
test_absolute_path_requirement
test_semicolon_delimited_format
test_fallback_behavior
test_ci_workflow_filename_confirmation
test_config_merge_existing
test_jira_bridge_project_key
test_no_rigid_multiple_choice
# RED infrastructure initialization tests — these fail until SKILL.md is updated
test_hook_installation_instructions
test_hook_manager_detection
test_git_common_dir
test_ticket_system_init
test_ticket_smoke_test
test_generate_test_index
test_claude_md_generation
test_known_issues_template
test_ci_trigger_strategy
test_push_verification

# test_artifact_review_before_writing: SKILL.md must instruct presenting artifacts for user approval
# before writing — grep for 'review.*before.*writ' or 'approval.*before.*writ' or 'present.*artifact'
test_artifact_review_before_writing() {
    _snapshot_fail
    local review_before_found
    review_before_found="missing"
    if grep -qiE "review.*before.*writ|approval.*before.*writ|present.*artifact" "$SKILL_MD" 2>/dev/null; then
        review_before_found="found"
    fi
    assert_eq "test_artifact_review_before_writing" "found" "$review_before_found"
    assert_pass_if_clean "test_artifact_review_before_writing"
}

# test_diff_existing_files: SKILL.md must instruct showing diffs against existing files
# grep for 'diff.*existing' or 'existing.*diff'
test_diff_existing_files() {
    _snapshot_fail
    local diff_existing_found
    diff_existing_found="missing"
    if grep -qiE "diff.*existing|existing.*diff" "$SKILL_MD" 2>/dev/null; then
        diff_existing_found="found"
    fi
    assert_eq "test_diff_existing_files" "found" "$diff_existing_found"
    assert_pass_if_clean "test_diff_existing_files"
}

# RED artifact review tests — these fail until SKILL.md is updated
test_artifact_review_before_writing
test_diff_existing_files

# test_dso_setup_invocation: SKILL.md must reference dso-setup.sh to install the shim
test_dso_setup_invocation() {
    _snapshot_fail
    local dso_setup_found="missing"
    if grep -q "dso-setup.sh" "$SKILL_MD" 2>/dev/null; then
        dso_setup_found="found"
    fi
    assert_eq "test_dso_setup_invocation" "found" "$dso_setup_found"
    assert_pass_if_clean "test_dso_setup_invocation"
}

test_dso_setup_invocation

# test_template_selection_gate: Phase 1.5 template gate section exists and references key components
test_template_selection_gate() {
    _snapshot_fail
    local gate_found="missing"
    if grep -q "Phase 1.5" "$SKILL_MD" 2>/dev/null && \
       grep -q "parse-template-registry" "$SKILL_MD" 2>/dev/null && \
       grep -q "Template Selection Result" "$SKILL_MD" 2>/dev/null; then
        gate_found="found"
    fi
    assert_eq "test_template_selection_gate" "found" "$gate_found"
    assert_pass_if_clean "test_template_selection_gate"
}

test_template_selection_gate

# test_nava_platform_install_path: Phase 1.6a nava-platform install section exists
test_nava_platform_install_path() {
    _snapshot_fail
    local path_found="missing"
    if grep -q "Phase 1.6a" "$SKILL_MD" 2>/dev/null && \
       grep -q "nava-platform" "$SKILL_MD" 2>/dev/null && \
       grep -q "run_with_timeout" "$SKILL_MD" 2>/dev/null; then
        path_found="found"
    fi
    assert_eq "test_nava_platform_install_path" "found" "$path_found"
    assert_pass_if_clean "test_nava_platform_install_path"
}

test_nava_platform_install_path

# test_jekyll_git_clone_path: Phase 1.6b git clone section exists with safety checks
test_jekyll_git_clone_path() {
    _snapshot_fail
    local path_found="missing"
    if grep -q "Phase 1.6b" "$SKILL_MD" 2>/dev/null && \
       grep -q "git clone" "$SKILL_MD" 2>/dev/null && \
       grep -qi "captive" "$SKILL_MD" 2>/dev/null; then
        path_found="found"
    fi
    assert_eq "test_jekyll_git_clone_path" "found" "$path_found"
    assert_pass_if_clean "test_jekyll_git_clone_path"
}

test_jekyll_git_clone_path

# ── RED CI config key / workflow tests (7330-bf69) ───────────────────────────

# test_ci_config_key_coverage: SKILL.md must reference all 4 CI config keys:
# ci.fast_gate_job, ci.fast_fail_job, ci.test_ceil_job, ci.integration_workflow
test_ci_config_key_coverage() {
    _snapshot_fail
    local keys_found keys_missing key
    keys_found=0
    keys_missing=""
    local required_keys=("ci.fast_gate_job" "ci.fast_fail_job" "ci.test_ceil_job" "ci.integration_workflow")
    for key in "${required_keys[@]}"; do
        if grep -qF "$key" "$SKILL_MD" 2>/dev/null; then
            (( keys_found++ ))
        else
            keys_missing="$keys_missing $key"
        fi
    done
    if [[ "$keys_found" -eq 4 ]]; then
        assert_eq "test_ci_config_key_coverage" "found" "found"
    else
        assert_eq "test_ci_config_key_coverage" "all 4 CI config keys" "$keys_found keys found (missing:$keys_missing)"
    fi
    assert_pass_if_clean "test_ci_config_key_coverage"
}

# test_ci_workflow_confidence_gating: SKILL.md must reference ci_workflow_confidence-gated logic —
# must reference ci_workflow_confidence AND contain numbered selection for low-confidence/multiple workflows
test_ci_workflow_confidence_gating() {
    _snapshot_fail
    local has_confidence has_selection result
    has_confidence="no"
    has_selection="no"
    if grep -q "ci_workflow_confidence" "$SKILL_MD" 2>/dev/null; then
        has_confidence="yes"
    fi
    if grep -qiE "numbered selection|multiple.*workflow|low.*confidence|confidence.*low" "$SKILL_MD" 2>/dev/null; then
        has_selection="yes"
    fi
    if [[ "$has_confidence" == "yes" && "$has_selection" == "yes" ]]; then
        result="found"
    else
        result="missing"
    fi
    assert_eq "test_ci_workflow_confidence_gating" "found" "$result"
    assert_pass_if_clean "test_ci_workflow_confidence_gating"
}

test_ci_config_key_coverage
test_ci_workflow_confidence_gating

# ── RED merge.ci_workflow_name auto-migration tests (e9a7-39cd) ──────────────

# test_ci_workflow_name_deprecation_migration: SKILL.md must contain auto-migration logic from
# merge.ci_workflow_name to ci.workflow_name, with a conditional skip when ci.workflow_name exists
test_ci_workflow_name_deprecation_migration() {
    _snapshot_fail
    local has_old_key has_new_key has_skip result
    has_old_key="no"
    has_new_key="no"
    has_skip="no"
    if grep -q "merge.ci_workflow_name" "$SKILL_MD" 2>/dev/null; then
        has_old_key="yes"
    fi
    if grep -q "ci.workflow_name" "$SKILL_MD" 2>/dev/null; then
        has_new_key="yes"
    fi
    if grep -qiE "skip.*if.*ci\.workflow_name|ci\.workflow_name.*already|already.*exists" "$SKILL_MD" 2>/dev/null; then
        has_skip="yes"
    fi
    if [[ "$has_old_key" == "yes" && "$has_new_key" == "yes" && "$has_skip" == "yes" ]]; then
        result="found"
    else
        result="missing"
    fi
    assert_eq "test_ci_workflow_name_deprecation_migration" "found" "$result"
    assert_pass_if_clean "test_ci_workflow_name_deprecation_migration"
}

test_ci_workflow_name_deprecation_migration

# ── RED key name mismatch tests (89aa-3b1f) ──────────────────────────────────

# test_key_name_jira_project: SKILL.md must reference "jira.project" but NOT "jira.project_key"
test_key_name_jira_project() {
    _snapshot_fail
    local has_correct has_incorrect result
    has_correct="no"
    has_incorrect="no"
    if grep -q "jira.project" "$SKILL_MD" 2>/dev/null; then
        has_correct="yes"
    fi
    if grep -q "jira.project_key" "$SKILL_MD" 2>/dev/null; then
        has_incorrect="yes"
    fi
    if [[ "$has_correct" == "yes" && "$has_incorrect" == "no" ]]; then
        result="found"
    else
        result="missing"
    fi
    assert_eq "test_key_name_jira_project" "found" "$result"
    assert_pass_if_clean "test_key_name_jira_project"
}

# test_key_name_design_system_name: SKILL.md must reference "design.system_name" but NOT
# bare "design.system" without the _name suffix
test_key_name_design_system_name() {
    _snapshot_fail
    local has_correct has_incorrect result
    has_correct="no"
    has_incorrect="no"
    if grep -q "design.system_name" "$SKILL_MD" 2>/dev/null; then
        has_correct="yes"
    fi
    if grep "design\.system" "$SKILL_MD" 2>/dev/null | grep -v "design\.system_name" | grep -q "design\.system"; then
        has_incorrect="yes"
    fi
    if [[ "$has_correct" == "yes" && "$has_incorrect" == "no" ]]; then
        result="found"
    else
        result="missing"
    fi
    assert_eq "test_key_name_design_system_name" "found" "$result"
    assert_pass_if_clean "test_key_name_design_system_name"
}

# test_design_tokens_path_audit: design.tokens_path must either exist in validate-config.sh KNOWN_KEYS
# OR must NOT be referenced in SKILL.md config table
test_design_tokens_path_audit() {
    _snapshot_fail
    local validate_config_sh tokens_in_known_keys tokens_in_skill result
    validate_config_sh="$PLUGIN_ROOT/plugins/dso/scripts/validate-config.sh"
    tokens_in_known_keys="no"
    tokens_in_skill="no"
    if grep -q "design.tokens_path" "$validate_config_sh" 2>/dev/null; then
        tokens_in_known_keys="yes"
    fi
    if grep -q "design.tokens_path" "$SKILL_MD" 2>/dev/null; then
        tokens_in_skill="yes"
    fi
    # Pass if: tokens_path is in KNOWN_KEYS (legitimate) OR not referenced in SKILL.md (no mismatch)
    if [[ "$tokens_in_known_keys" == "yes" || "$tokens_in_skill" == "no" ]]; then
        result="found"
    else
        result="missing"
    fi
    assert_eq "test_design_tokens_path_audit" "found" "$result"
    assert_pass_if_clean "test_design_tokens_path_audit"
}

test_key_name_jira_project
test_key_name_design_system_name
test_design_tokens_path_audit

# ── RED version.file_path and stack config tests (2e7c-d060) ─────────────────

# test_version_file_path_config: SKILL.md must reference version.file_path AND version_files
# (the project-detect.sh output key), with numbered selection when multiple version files exist
test_version_file_path_config() {
    _snapshot_fail
    local has_config_key has_detect_key has_selection result
    has_config_key="no"
    has_detect_key="no"
    has_selection="no"
    if grep -q "version.file_path" "$SKILL_MD" 2>/dev/null; then
        has_config_key="yes"
    fi
    if grep -q "version_files" "$SKILL_MD" 2>/dev/null; then
        has_detect_key="yes"
    fi
    if grep -qiE "numbered selection|multiple.*version|version.*multiple|select.*version" "$SKILL_MD" 2>/dev/null; then
        has_selection="yes"
    fi
    if [[ "$has_config_key" == "yes" && "$has_detect_key" == "yes" && "$has_selection" == "yes" ]]; then
        result="found"
    else
        result="missing"
    fi
    assert_eq "test_version_file_path_config" "found" "$result"
    assert_pass_if_clean "test_version_file_path_config"
}

# test_stack_config_key: SKILL.md must reference "stack" as a config key populated
# from detect-stack.sh output
test_stack_config_key() {
    _snapshot_fail
    local has_stack_key has_detect_stack result
    has_stack_key="no"
    has_detect_stack="no"
    if grep -qE "\bstack\b" "$SKILL_MD" 2>/dev/null; then
        has_stack_key="yes"
    fi
    if grep -q "detect-stack.sh" "$SKILL_MD" 2>/dev/null; then
        has_detect_stack="yes"
    fi
    if [[ "$has_stack_key" == "yes" && "$has_detect_stack" == "yes" ]]; then
        result="found"
    else
        result="missing"
    fi
    assert_eq "test_stack_config_key" "found" "$result"
    assert_pass_if_clean "test_stack_config_key"
}

test_version_file_path_config
test_stack_config_key

print_summary
