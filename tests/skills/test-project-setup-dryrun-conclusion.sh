#!/usr/bin/env bash
# tests/skills/test-project-setup-dryrun-conclusion.sh
# Tests that plugins/dso/skills/onboarding/SKILL.md (the successor to
# project-setup) has Phase 3 completion content: artifact review before
# writing, dso-config.conf generation, infrastructure initialization, and
# a hand-off offer to /dso:architect-foundation.
#
# Validates:
#   - SKILL.md exists at skills/onboarding/SKILL.md
#   - Phase 3 presents a project understanding summary before writing files
#   - Artifact review before writing: existing files get a diff, not full replace
#   - dso-config.conf generation is documented with merge behavior
#   - Jira credentials (JIRA_URL etc.) are documented as env vars (not in config)
#   - Infrastructure initialization: ticket system init is documented
#   - Onboarding offers /dso:architect-foundation as the next step
#   - Onboarding does NOT use the old [Script actions that would run:] split format
#   - Config generation documents deprecated key migration (merge.ci_workflow_name)
#
# Usage: bash tests/skills/test-project-setup-dryrun-conclusion.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/onboarding/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-project-setup-dryrun-conclusion.sh ==="

# test_skill_md_exists: SKILL.md must exist at onboarding path
_snapshot_fail
if [[ -f "$SKILL_MD" ]]; then
    skill_exists="exists"
else
    skill_exists="missing"
fi
assert_eq "test_skill_md_exists" "exists" "$skill_exists"
assert_pass_if_clean "test_skill_md_exists"

# test_phase3_completion_exists: Phase 3 (Completion) must be present in SKILL.md
# Onboarding uses Phases, not Steps — Phase 3 replaces the old Step 4 dryrun and Step 6 conclusion.
_snapshot_fail
if grep -q "^## Phase 3" "$SKILL_MD" 2>/dev/null; then
    has_phase3="found"
else
    has_phase3="missing"
fi
assert_eq "test_phase3_completion_exists" "found" "$has_phase3"
assert_pass_if_clean "test_phase3_completion_exists"

# test_artifact_review_before_writing: Phase 3 must present artifacts for user review
# before writing. Existing files must show a diff rather than silent replacement.
_snapshot_fail
if grep -qiE "present.*artifact|review.*before.*writ|diff.*existing|existing.*diff|show a diff|before writing|without.*approval|explicit.*approval" "$SKILL_MD" 2>/dev/null; then
    has_artifact_review="found"
else
    has_artifact_review="missing"
fi
assert_eq "test_artifact_review_before_writing" "found" "$has_artifact_review"
assert_pass_if_clean "test_artifact_review_before_writing"

# test_no_script_vs_skill_split: onboarding must NOT use the old project-setup
# format that says "[Script actions that would run:]" as a section heading.
_snapshot_fail
if grep -qF "[Script actions that would run:]" "$SKILL_MD" 2>/dev/null; then
    has_old_split="yes"
else
    has_old_split="no"
fi
assert_eq "test_no_script_vs_skill_split" "no" "$has_old_split"
assert_pass_if_clean "test_no_script_vs_skill_split"

# test_dso_config_generation: Phase 3 must generate dso-config.conf with merge behavior
# (new keys added, existing values not overwritten)
_snapshot_fail
if grep -qiE "dso-config\.conf|merge.*new.*keys|only add keys|existing.*config|Detect and Merge" "$SKILL_MD" 2>/dev/null; then
    has_config_generation="found"
else
    has_config_generation="missing"
fi
assert_eq "test_dso_config_generation" "found" "$has_config_generation"
assert_pass_if_clean "test_dso_config_generation"

# test_jira_env_vars_documented: JIRA_URL (and related credentials) must be documented
# as environment variables — not written to dso-config.conf
_snapshot_fail
if grep -q "JIRA_URL" "$SKILL_MD" 2>/dev/null; then
    has_jira_env_vars="found"
else
    has_jira_env_vars="missing"
fi
assert_eq "test_jira_env_vars_documented" "found" "$has_jira_env_vars"
assert_pass_if_clean "test_jira_env_vars_documented"

# test_jira_credentials_stay_as_env_vars: the Jira credentials note (stay as env vars)
# must appear to clarify that only jira.project goes in config, not credentials
_snapshot_fail
if grep -qiE "credentials.*environment|stay as environment|env.*variable.*not.*config|JIRA.*env" "$SKILL_MD" 2>/dev/null; then
    has_credentials_note="found"
else
    has_credentials_note="missing"
fi
assert_eq "test_jira_credentials_stay_as_env_vars" "found" "$has_credentials_note"
assert_pass_if_clean "test_jira_credentials_stay_as_env_vars"

# test_ticket_system_infrastructure: Phase 3 must initialize the ticket system
# (orphan branch, .tickets-tracker directory)
_snapshot_fail
if grep -qiE "\.tickets-tracker|ticket.*system|orphan.*branch|tickets.*branch" "$SKILL_MD" 2>/dev/null; then
    has_ticket_system="found"
else
    has_ticket_system="missing"
fi
assert_eq "test_ticket_system_infrastructure" "found" "$has_ticket_system"
assert_pass_if_clean "test_ticket_system_infrastructure"

# test_architect_foundation_offer: Phase 3 must offer to invoke /dso:architect-foundation
# as the next step after writing project-understanding.md
_snapshot_fail
if grep -qiE "architect-foundation|dso:architect-foundation" "$SKILL_MD" 2>/dev/null; then
    has_architect_offer="found"
else
    has_architect_offer="missing"
fi
assert_eq "test_architect_foundation_offer" "found" "$has_architect_offer"
assert_pass_if_clean "test_architect_foundation_offer"

# test_deprecated_key_migration: Phase 3 config generation must document the
# merge.ci_workflow_name → ci.workflow_name deprecated key migration
_snapshot_fail
if grep -q "merge\.ci_workflow_name" "$SKILL_MD" 2>/dev/null; then
    has_deprecated_migration="found"
else
    has_deprecated_migration="missing"
fi
assert_eq "test_deprecated_key_migration" "found" "$has_deprecated_migration"
assert_pass_if_clean "test_deprecated_key_migration"

print_summary
