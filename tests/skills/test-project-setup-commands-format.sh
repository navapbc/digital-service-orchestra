#!/usr/bin/env bash
# tests/skills/test-project-setup-commands-format.sh
# Tests that plugins/dso/skills/onboarding/SKILL.md (the successor to
# project-setup) uses a Phase-based structure with sequential one-at-a-time
# questioning, and includes format, version.file_path, and tickets.prefix
# config keys.
#
# Validates:
#   - SKILL.md exists at skills/onboarding/SKILL.md
#   - Onboarding uses "one at a time" / sequential guidance (Guardrails section)
#   - version.file_path and tickets.prefix config keys are present
#   - format.extensions and format.source_dirs config keys are present
#   - commands.test, commands.lint, commands.format config keys are present
#   - jira.project config key is present
#   - Onboarding uses project-detect.sh for detection-based pre-filling
#   - ci.workflow_name config key is present (CI section)
#
# Usage: bash tests/skills/test-project-setup-commands-format.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/onboarding/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-project-setup-commands-format.sh ==="

# test_skill_md_exists: SKILL.md must exist at onboarding path
_snapshot_fail
if [[ -f "$SKILL_MD" ]]; then
    skill_exists="exists"
else
    skill_exists="missing"
fi
assert_eq "test_skill_md_exists" "exists" "$skill_exists"
assert_pass_if_clean "test_skill_md_exists"

# test_sequential_questioning_guidance: onboarding must document the one-at-a-time
# sequential questioning approach (Guardrails section or Phase 2 intro)
_snapshot_fail
if grep -qiE "one (question|prompt) at a time|one at a time|sequential" "$SKILL_MD" 2>/dev/null; then
    has_sequential_guidance="found"
else
    has_sequential_guidance="missing"
fi
assert_eq "test_sequential_questioning_guidance" "found" "$has_sequential_guidance"
assert_pass_if_clean "test_sequential_questioning_guidance"

# test_version_file_path_prompted: version.file_path must appear in SKILL.md
_snapshot_fail
if grep -q "version\.file_path" "$SKILL_MD" 2>/dev/null; then
    has_version_file_path="found"
else
    has_version_file_path="missing"
fi
assert_eq "test_version_file_path_prompted" "found" "$has_version_file_path"
assert_pass_if_clean "test_version_file_path_prompted"

# test_tickets_prefix_prompted: tickets.prefix must appear in SKILL.md
_snapshot_fail
if grep -q "tickets\.prefix" "$SKILL_MD" 2>/dev/null; then
    has_tickets_prefix="found"
else
    has_tickets_prefix="missing"
fi
assert_eq "test_tickets_prefix_prompted" "found" "$has_tickets_prefix"
assert_pass_if_clean "test_tickets_prefix_prompted"

# test_format_extensions_prompted: format.extensions must appear in SKILL.md
_snapshot_fail
if grep -q "format\.extensions" "$SKILL_MD" 2>/dev/null; then
    has_format_extensions="found"
else
    has_format_extensions="missing"
fi
assert_eq "test_format_extensions_prompted" "found" "$has_format_extensions"
assert_pass_if_clean "test_format_extensions_prompted"

# test_format_source_dirs_prompted: format.source_dirs must appear in SKILL.md
_snapshot_fail
if grep -q "format\.source_dirs" "$SKILL_MD" 2>/dev/null; then
    has_format_source_dirs="found"
else
    has_format_source_dirs="missing"
fi
assert_eq "test_format_source_dirs_prompted" "found" "$has_format_source_dirs"
assert_pass_if_clean "test_format_source_dirs_prompted"

# test_commands_test_prompted: commands.test must appear as a config key
_snapshot_fail
if grep -q "commands\.test" "$SKILL_MD" 2>/dev/null; then
    has_commands_test="found"
else
    has_commands_test="missing"
fi
assert_eq "test_commands_test_prompted" "found" "$has_commands_test"
assert_pass_if_clean "test_commands_test_prompted"

# test_commands_lint_prompted: commands.lint must appear as a config key
_snapshot_fail
if grep -q "commands\.lint" "$SKILL_MD" 2>/dev/null; then
    has_commands_lint="found"
else
    has_commands_lint="missing"
fi
assert_eq "test_commands_lint_prompted" "found" "$has_commands_lint"
assert_pass_if_clean "test_commands_lint_prompted"

# test_commands_format_prompted: commands.format must appear as a config key
_snapshot_fail
if grep -q "commands\.format\b" "$SKILL_MD" 2>/dev/null; then
    has_commands_format="found"
else
    has_commands_format="missing"
fi
assert_eq "test_commands_format_prompted" "found" "$has_commands_format"
assert_pass_if_clean "test_commands_format_prompted"

# test_jira_project_present: jira.project must appear in SKILL.md
_snapshot_fail
if grep -q "jira\.project" "$SKILL_MD" 2>/dev/null; then
    has_jira_project="found"
else
    has_jira_project="missing"
fi
assert_eq "test_jira_project_present" "found" "$has_jira_project"
assert_pass_if_clean "test_jira_project_present"

# test_detection_based_prefill: onboarding must reference project-detect.sh for
# auto-detecting values before asking the user (detection-based pre-filling)
_snapshot_fail
if grep -q "project-detect" "$SKILL_MD" 2>/dev/null; then
    has_detection="found"
else
    has_detection="missing"
fi
assert_eq "test_detection_based_prefill" "found" "$has_detection"
assert_pass_if_clean "test_detection_based_prefill"

# test_ci_workflow_name_present: ci.workflow_name must appear in SKILL.md
# (onboarding manages CI configuration directly, replacing project-setup)
_snapshot_fail
if grep -q "ci\.workflow_name" "$SKILL_MD" 2>/dev/null; then
    has_ci_workflow_name="found"
else
    has_ci_workflow_name="missing"
fi
assert_eq "test_ci_workflow_name_present" "found" "$has_ci_workflow_name"
assert_pass_if_clean "test_ci_workflow_name_present"

# test_sc1_ci_fast_gate_job_present: ci.fast_gate_job must appear in SKILL.md (SC1)
_snapshot_fail
if grep -q "ci\.fast_gate_job" "$SKILL_MD" 2>/dev/null; then
    has_ci_fast_gate_job="found"
else
    has_ci_fast_gate_job="missing"
fi
assert_eq "test_sc1_ci_fast_gate_job_present" "found" "$has_ci_fast_gate_job"
assert_pass_if_clean "test_sc1_ci_fast_gate_job_present"

# test_sc1_ci_fast_fail_job_present: ci.fast_fail_job must appear in SKILL.md (SC1)
_snapshot_fail
if grep -q "ci\.fast_fail_job" "$SKILL_MD" 2>/dev/null; then
    has_ci_fast_fail_job="found"
else
    has_ci_fast_fail_job="missing"
fi
assert_eq "test_sc1_ci_fast_fail_job_present" "found" "$has_ci_fast_fail_job"
assert_pass_if_clean "test_sc1_ci_fast_fail_job_present"

# test_sc1_ci_test_ceil_job_present: ci.test_ceil_job must appear in SKILL.md (SC1)
_snapshot_fail
if grep -q "ci\.test_ceil_job" "$SKILL_MD" 2>/dev/null; then
    has_ci_test_ceil_job="found"
else
    has_ci_test_ceil_job="missing"
fi
assert_eq "test_sc1_ci_test_ceil_job_present" "found" "$has_ci_test_ceil_job"
assert_pass_if_clean "test_sc1_ci_test_ceil_job_present"

# test_sc1_ci_integration_workflow_present: ci.integration_workflow must appear in SKILL.md (SC1)
_snapshot_fail
if grep -q "ci\.integration_workflow" "$SKILL_MD" 2>/dev/null; then
    has_ci_integration_workflow="found"
else
    has_ci_integration_workflow="missing"
fi
assert_eq "test_sc1_ci_integration_workflow_present" "found" "$has_ci_integration_workflow"
assert_pass_if_clean "test_sc1_ci_integration_workflow_present"

# test_sc5_jira_project_key_absent: jira.project_key must NOT appear in SKILL.md (SC5)
# Regression guard: the correct key is jira.project, not jira.project_key
_snapshot_fail
if grep -q "jira\.project_key" "$SKILL_MD" 2>/dev/null; then
    has_jira_project_key="found"
else
    has_jira_project_key="absent"
fi
assert_eq "test_sc5_jira_project_key_absent" "absent" "$has_jira_project_key"
assert_pass_if_clean "test_sc5_jira_project_key_absent"

# test_sc5_design_system_name_not_bare: design.system without _name suffix must NOT
# appear as a standalone config key (SC5). Correct key is design.system_name.
_snapshot_fail
_tmp=$(grep -E "design\.system[^_]" "$SKILL_MD" 2>/dev/null)
if [[ -n "$_tmp" ]] && grep -qv "^#" <<< "$_tmp"; then
    has_bare_design_system="found"
else
    has_bare_design_system="absent"
fi
assert_eq "test_sc5_design_system_name_not_bare" "absent" "$has_bare_design_system"
assert_pass_if_clean "test_sc5_design_system_name_not_bare"

print_summary
