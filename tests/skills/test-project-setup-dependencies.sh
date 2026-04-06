#!/usr/bin/env bash
# tests/skills/test-project-setup-dependencies.sh
# Tests that plugins/dso/skills/onboarding/SKILL.md (the successor to
# project-setup) handles dependency and tool installation correctly:
# acli version resolution, pre-commit hook installation with manager
# detection (Husky / pre-commit framework / bare .git/hooks), and
# Jira credential handling.
#
# Validates:
#   - SKILL.md exists at skills/onboarding/SKILL.md
#   - acli (Claude CLI) is referenced with version resolution
#   - pre-commit hook installation is documented
#   - git hook manager detection (Husky, pre-commit framework, bare hooks)
#   - Jira integration guidance: project key in config, credentials as env vars
#   - JIRA_URL environment variable mentioned (Jira bridge)
#   - Onboarding does NOT use the old bundled "install instructions?" question
#   - Hook installation uses idempotency checks (no duplicate appends)
#
# Usage: bash tests/skills/test-project-setup-dependencies.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/onboarding/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-project-setup-dependencies.sh ==="

# test_skill_md_exists: SKILL.md must exist at onboarding path
_snapshot_fail
if [[ -f "$SKILL_MD" ]]; then
    skill_exists="exists"
else
    skill_exists="missing"
fi
assert_eq "test_skill_md_exists" "exists" "$skill_exists"
assert_pass_if_clean "test_skill_md_exists"

# test_acli_version_resolution: onboarding must reference acli and version resolution
# (acli-version-resolver.sh or commands.acli_version config key)
_snapshot_fail
if grep -qiE "acli.*version|acli_version|acli-version-resolver" "$SKILL_MD" 2>/dev/null; then
    has_acli_version="found"
else
    has_acli_version="missing"
fi
assert_eq "test_acli_version_resolution" "found" "$has_acli_version"
assert_pass_if_clean "test_acli_version_resolution"

# test_precommit_hook_installation: onboarding must document pre-commit hook
# installation (pre-commit-test-gate.sh and pre-commit-review-gate.sh)
_snapshot_fail
if grep -qiE "pre-commit-test-gate|pre-commit-review-gate" "$SKILL_MD" 2>/dev/null; then
    has_hook_install="found"
else
    has_hook_install="missing"
fi
assert_eq "test_precommit_hook_installation" "found" "$has_hook_install"
assert_pass_if_clean "test_precommit_hook_installation"

# test_hook_manager_detection: onboarding must detect and handle multiple git hook
# managers (Husky, pre-commit framework, bare .git/hooks/)
_snapshot_fail
if grep -qiE "Husky|husky|pre-commit framework|\.husky/" "$SKILL_MD" 2>/dev/null; then
    has_hook_manager_detection="found"
else
    has_hook_manager_detection="missing"
fi
assert_eq "test_hook_manager_detection" "found" "$has_hook_manager_detection"
assert_pass_if_clean "test_hook_manager_detection"

# test_jira_credentials_as_env_vars: Jira credentials (JIRA_URL, JIRA_USER,
# JIRA_API_TOKEN) must stay as environment variables, not written to config
_snapshot_fail
if grep -q "JIRA_URL" "$SKILL_MD" 2>/dev/null; then
    has_jira_url_env="found"
else
    has_jira_url_env="missing"
fi
assert_eq "test_jira_credentials_as_env_vars" "found" "$has_jira_url_env"
assert_pass_if_clean "test_jira_credentials_as_env_vars"

# test_jira_project_key_in_config: jira.project (the project key) must be written
# to dso-config.conf when the user provides a Jira project key
_snapshot_fail
if grep -q "jira\.project" "$SKILL_MD" 2>/dev/null; then
    has_jira_project="found"
else
    has_jira_project="missing"
fi
assert_eq "test_jira_project_key_in_config" "found" "$has_jira_project"
assert_pass_if_clean "test_jira_project_key_in_config"

# test_idempotent_hook_install: hook installation must check for existing entries
# before appending (no duplicate DSO hook calls on re-run)
_snapshot_fail
_idm_found=0
grep -q "grep-qF" "$SKILL_MD" 2>/dev/null && _idm_found=1
[[ "$_idm_found" -eq 0 ]] && grep -q "Idempotency" "$SKILL_MD" 2>/dev/null && _idm_found=1
[[ "$_idm_found" -eq 0 ]] && grep -q "idempotent" "$SKILL_MD" 2>/dev/null && _idm_found=1
[[ "$_idm_found" -eq 0 ]] && grep -q "already exists before" "$SKILL_MD" 2>/dev/null && _idm_found=1
if [[ "$_idm_found" -eq 1 ]]; then
    has_idempotency="found"
else
    has_idempotency="missing"
fi
assert_eq "test_idempotent_hook_install" "found" "$has_idempotency"
assert_pass_if_clean "test_idempotent_hook_install"

# test_no_bundled_install_question: the old bundled "Would you like install
# instructions for these optional tools?" question must NOT appear in onboarding
_snapshot_fail
if grep -q "Would you like install instructions for these optional tools" "$SKILL_MD" 2>/dev/null; then
    has_bundled_question="found"
else
    has_bundled_question="removed"
fi
assert_eq "test_no_bundled_install_question" "removed" "$has_bundled_question"
assert_pass_if_clean "test_no_bundled_install_question"

# test_git_common_dir_for_worktrees: hook installation must use git-common-dir
# to support worktrees and submodules (where .git may be a file, not a directory)
_snapshot_fail
if grep -q "git-common-dir\|git.*common.*dir\|--git-common-dir" "$SKILL_MD" 2>/dev/null; then
    has_git_common_dir="found"
else
    has_git_common_dir="missing"
fi
assert_eq "test_git_common_dir_for_worktrees" "found" "$has_git_common_dir"
assert_pass_if_clean "test_git_common_dir_for_worktrees"

# test_ticket_system_init: onboarding must initialize the ticket system
# (orphan branch, .tickets-tracker/)
_snapshot_fail
if grep -qiE "ticket.*system|\.tickets-tracker|tickets.*branch|orphan.*branch" "$SKILL_MD" 2>/dev/null; then
    has_ticket_init="found"
else
    has_ticket_init="missing"
fi
assert_eq "test_ticket_system_init" "found" "$has_ticket_init"
assert_pass_if_clean "test_ticket_system_init"

# test_ast_grep_recommended: onboarding must reference ast-grep as a recommended
# optional tool with installation instructions for macOS (brew) and Linux (cargo)
_snapshot_fail
if grep -q "ast-grep" "$SKILL_MD" 2>/dev/null; then
    has_ast_grep="found"
else
    has_ast_grep="missing"
fi
assert_eq "test_ast_grep_recommended" "found" "$has_ast_grep"
assert_pass_if_clean "test_ast_grep_recommended"

# test_ast_grep_macos_install: onboarding must include macOS install command for ast-grep
_snapshot_fail
if grep -qE "brew install ast-grep" "$SKILL_MD" 2>/dev/null; then
    has_ast_grep_brew="found"
else
    has_ast_grep_brew="missing"
fi
assert_eq "test_ast_grep_macos_install" "found" "$has_ast_grep_brew"
assert_pass_if_clean "test_ast_grep_macos_install"

# test_ast_grep_linux_install: onboarding must include Linux install command for ast-grep
_snapshot_fail
if grep -qE "cargo install ast-grep" "$SKILL_MD" 2>/dev/null; then
    has_ast_grep_cargo="found"
else
    has_ast_grep_cargo="missing"
fi
assert_eq "test_ast_grep_linux_install" "found" "$has_ast_grep_cargo"
assert_pass_if_clean "test_ast_grep_linux_install"

print_summary
