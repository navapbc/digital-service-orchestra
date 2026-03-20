#!/usr/bin/env bash
# tests/skills/test-project-setup-commands-format.sh
# Tests that plugins/dso/skills/project-setup/SKILL.md Step 3 is rewritten
# to use AskUserQuestion for sequential command prompts with detection-aware
# labels, and includes format, version.file_path, and tickets.prefix prompts.
#
# Validates:
#   - SKILL.md exists at skills/project-setup/SKILL.md
#   - Step 3 uses AskUserQuestion for command prompts (at least 5 occurrences)
#   - Each command suggestion includes detection-aware labels
#     ("exists in project" or "convention for")
#   - version.file_path and tickets.prefix prompts are included in Step 3
#   - format.extensions and format.source_dirs prompts describe coverage
#   - Jira integration prompts (jira.project) are retained in Step 3
#   - monitoring.tool_errors prompt is retained in Step 3
#
# Usage: bash tests/skills/test-project-setup-commands-format.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/project-setup/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-project-setup-commands-format.sh ==="

# test_skill_md_exists: SKILL.md must exist
_snapshot_fail
if [[ -f "$SKILL_MD" ]]; then
    skill_exists="exists"
else
    skill_exists="missing"
fi
assert_eq "test_skill_md_exists" "exists" "$skill_exists"
assert_pass_if_clean "test_skill_md_exists"

# test_askuserquestion_used_at_least_5_times: Step 3 must use AskUserQuestion
# for individual command prompts (commands.test, commands.lint, etc.)
_snapshot_fail
ask_count=$(grep -c "AskUserQuestion" "$SKILL_MD" 2>/dev/null) || ask_count=0
if [[ "$ask_count" -ge 5 ]]; then
    has_enough_ask="yes"
else
    has_enough_ask="no"
fi
assert_eq "test_askuserquestion_used_at_least_5_times" "yes" "$has_enough_ask"
assert_pass_if_clean "test_askuserquestion_used_at_least_5_times"

# test_detection_aware_labels_present: command suggestions must include labels
# showing whether a target "exists in project" or is a "convention for <stack>"
_snapshot_fail
label_count=$(grep -c "exists in project\|convention for" "$SKILL_MD" 2>/dev/null) || label_count=0
if [[ "$label_count" -ge 3 ]]; then
    has_labels="yes"
else
    has_labels="no"
fi
assert_eq "test_detection_aware_labels_present" "yes" "$has_labels"
assert_pass_if_clean "test_detection_aware_labels_present"

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

# test_commands_test_prompted: commands.test must appear as a sequential prompt
_snapshot_fail
if grep -q "commands\.test" "$SKILL_MD" 2>/dev/null; then
    has_commands_test="found"
else
    has_commands_test="missing"
fi
assert_eq "test_commands_test_prompted" "found" "$has_commands_test"
assert_pass_if_clean "test_commands_test_prompted"

# test_commands_lint_prompted: commands.lint must appear as a sequential prompt
_snapshot_fail
if grep -q "commands\.lint" "$SKILL_MD" 2>/dev/null; then
    has_commands_lint="found"
else
    has_commands_lint="missing"
fi
assert_eq "test_commands_lint_prompted" "found" "$has_commands_lint"
assert_pass_if_clean "test_commands_lint_prompted"

# test_commands_format_prompted: commands.format must appear in SKILL.md
_snapshot_fail
if grep -q "commands\.format\b" "$SKILL_MD" 2>/dev/null; then
    has_commands_format="found"
else
    has_commands_format="missing"
fi
assert_eq "test_commands_format_prompted" "found" "$has_commands_format"
assert_pass_if_clean "test_commands_format_prompted"

# test_jira_project_retained: jira.project must still appear in Step 3
_snapshot_fail
if grep -q "jira\.project" "$SKILL_MD" 2>/dev/null; then
    has_jira_project="found"
else
    has_jira_project="missing"
fi
assert_eq "test_jira_project_retained" "found" "$has_jira_project"
assert_pass_if_clean "test_jira_project_retained"

# test_monitoring_tool_errors_retained: monitoring.tool_errors must still appear
_snapshot_fail
if grep -q "monitoring\.tool_errors" "$SKILL_MD" 2>/dev/null; then
    has_monitoring="found"
else
    has_monitoring="missing"
fi
assert_eq "test_monitoring_tool_errors_retained" "found" "$has_monitoring"
assert_pass_if_clean "test_monitoring_tool_errors_retained"

# test_one_question_at_a_time_guidance: Step 3 must document the sequential approach
_snapshot_fail
if grep -qiE "one (question|prompt) at a time|one at a time|sequential" "$SKILL_MD" 2>/dev/null; then
    has_sequential_guidance="found"
else
    has_sequential_guidance="missing"
fi
assert_eq "test_one_question_at_a_time_guidance" "found" "$has_sequential_guidance"
assert_pass_if_clean "test_one_question_at_a_time_guidance"

print_summary
