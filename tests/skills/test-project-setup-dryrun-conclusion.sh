#!/usr/bin/env bash
# tests/skills/test-project-setup-dryrun-conclusion.sh
# Tests that plugins/dso/skills/project-setup/SKILL.md Step 4 (dryrun preview)
# presents a flat outcome list without script/skill distinction, and that
# Step 6 (conclusion) displays manual commands and environment exports.
#
# Validates:
#   - Step 4 dryrun preview uses a flat outcome list format (not split by script vs skill)
#   - Step 4 dryrun preview does NOT distinguish "Script actions" vs "workflow-config" sections
#   - Step 6 conclusion includes manual steps/commands the user still needs to run
#   - Step 6 conclusion includes environment export instructions (JIRA env vars)
#   - Jira env vars shown in conclusion section (Step 6), not only in Step 4 dryrun
#   - The "will write"/"will merge"/"will supplement" outcome language appears in Step 4
#
# Usage: bash tests/skills/test-project-setup-dryrun-conclusion.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/project-setup/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-project-setup-dryrun-conclusion.sh ==="

# test_skill_md_exists: SKILL.md must exist
_snapshot_fail
if [[ -f "$SKILL_MD" ]]; then
    skill_exists="exists"
else
    skill_exists="missing"
fi
assert_eq "test_skill_md_exists" "exists" "$skill_exists"
assert_pass_if_clean "test_skill_md_exists"

# test_dryrun_flat_outcome_list: Step 4 dryrun section must describe a flat list of outcomes.
# The preview should NOT use a two-section format that separates script actions from
# workflow-config content. Instead it should present outcomes as a unified flat list.
_snapshot_fail
if grep -qE "flat.*list|outcome.*list|planned.*action|what.*will.*happen|=== Dryrun Preview ===" "$SKILL_MD" 2>/dev/null; then
    has_flat_outcome_language="found"
else
    has_flat_outcome_language="missing"
fi
assert_eq "test_dryrun_flat_outcome_list" "found" "$has_flat_outcome_language"
assert_pass_if_clean "test_dryrun_flat_outcome_list"

# test_dryrun_no_script_vs_skill_split: Step 4 dryrun should NOT use the old two-section
# format that says "[Script actions that would run:]" and "[dso-config.conf that would be written:]"
# as separate headings that emphasize the script/skill distinction.
_snapshot_fail
if grep -qF "[Script actions that would run:]" "$SKILL_MD" 2>/dev/null; then
    has_old_split="yes"
else
    has_old_split="no"
fi
assert_eq "test_dryrun_no_script_vs_skill_split" "no" "$has_old_split"
assert_pass_if_clean "test_dryrun_no_script_vs_skill_split"

# test_dryrun_outcome_language: Step 4 dryrun preview should use outcome language
# like "will write", "will merge", or "will supplement" to describe what will happen
# to the user's files, rather than referencing internal component names.
_snapshot_fail
if grep -qE "will write|will merge|will supplement|will copy|will create|will install" "$SKILL_MD" 2>/dev/null; then
    has_outcome_verbs="found"
else
    has_outcome_verbs="missing"
fi
assert_eq "test_dryrun_outcome_language" "found" "$has_outcome_verbs"
assert_pass_if_clean "test_dryrun_outcome_language"

# test_conclusion_manual_steps: Step 6 must include instructions for manual steps
# the user still needs to perform after setup completes.
_snapshot_fail
if grep -qiE "manual.*step|manual.*command|still need|next step|you (still |must |should )?(run|add|configure|set)" "$SKILL_MD" 2>/dev/null; then
    has_manual_steps="found"
else
    has_manual_steps="missing"
fi
assert_eq "test_conclusion_manual_steps" "found" "$has_manual_steps"
assert_pass_if_clean "test_conclusion_manual_steps"

# test_conclusion_env_exports: Step 6 conclusion must display environment variable exports
# (JIRA_URL, JIRA_USER, JIRA_API_TOKEN) that the user needs to add to their shell profile.
# These are never written to dso-config.conf, so must be surfaced in the conclusion.
_snapshot_fail
if grep -q "JIRA_URL\|JIRA_USER\|JIRA_API_TOKEN" "$SKILL_MD" 2>/dev/null; then
    has_jira_env_vars="found"
else
    has_jira_env_vars="missing"
fi
assert_eq "test_conclusion_env_exports" "found" "$has_jira_env_vars"
assert_pass_if_clean "test_conclusion_env_exports"

# test_conclusion_env_exports_in_step6: The Jira env vars must appear in Step 6 (conclusion),
# not ONLY in the Jira sub-section of Step 3. Extract content from Step 6 onward and check.
_snapshot_fail
step6_content=$(awk '/^## Step 6:/,0' "$SKILL_MD" 2>/dev/null)
if echo "$step6_content" | grep -q "JIRA_URL\|JIRA_USER\|JIRA_API_TOKEN\|export.*JIRA\|shell profile"; then
    jira_in_step6="found"
else
    jira_in_step6="missing"
fi
assert_eq "test_conclusion_env_exports_in_step6" "found" "$jira_in_step6"
assert_pass_if_clean "test_conclusion_env_exports_in_step6"

# test_conclusion_shows_keys_configured: Step 6 must list the keys that were configured
# so the user knows what was written to dso-config.conf.
_snapshot_fail
step6_content=$(awk '/^## Step 6:/,0' "$SKILL_MD" 2>/dev/null)
if echo "$step6_content" | grep -qiE "keys configured|Keys configured|keys written|configured:"; then
    has_keys_list="found"
else
    has_keys_list="missing"
fi
assert_eq "test_conclusion_shows_keys_configured" "found" "$has_keys_list"
assert_pass_if_clean "test_conclusion_shows_keys_configured"

# test_conclusion_next_steps_section: Step 6 must have a dedicated next steps section
# listing things the user still needs to do (e.g. env vars, optional installs).
_snapshot_fail
step6_content=$(awk '/^## Step 6:/,0' "$SKILL_MD" 2>/dev/null)
if echo "$step6_content" | grep -qiE "next steps|manual steps|Manual steps|Next steps|still need|What.*still.*do"; then
    has_next_steps="found"
else
    has_next_steps="missing"
fi
assert_eq "test_conclusion_next_steps_section" "found" "$has_next_steps"
assert_pass_if_clean "test_conclusion_next_steps_section"

# test_dryrun_proceeds_to_real_run: Step 4 must still ask "Proceed with setup?" and
# re-run without --dryrun if yes. This ensures the dryrun → actual setup flow is preserved.
_snapshot_fail
if grep -q "Proceed with setup" "$SKILL_MD" 2>/dev/null; then
    has_proceed_prompt="found"
else
    has_proceed_prompt="missing"
fi
assert_eq "test_dryrun_proceeds_to_real_run" "found" "$has_proceed_prompt"
assert_pass_if_clean "test_dryrun_proceeds_to_real_run"

print_summary
