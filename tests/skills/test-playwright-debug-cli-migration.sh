#!/usr/bin/env bash
# tests/skills/test-playwright-debug-cli-migration.sh
# Tests that playwright-debug SKILL.md uses @playwright/cli Bash commands instead
# of raw Playwright MCP tools (browser_run_code, browser_snapshot, etc.).
#
# Validates (all tests RED until SKILL.md is migrated to @playwright/cli):
#   test_frontmatter_no_mcp_tools:        allowed-tools does NOT list browser_* tools
#   test_skill_contains_cli_commands:     SKILL.md contains @playwright/cli command patterns
#   test_preflight_check_present:         SKILL.md has a pre-flight availability check for @playwright/cli binary
#   test_session_names_include_worktree:  SKILL.md session name patterns include worktree identifier variable
#   test_output_validation_guards:        SKILL.md contains output validation (non-empty check) after CLI commands
#
# Usage: bash tests/skills/test-playwright-debug-cli-migration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/playwright-debug/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-playwright-debug-cli-migration.sh ==="

# ---------------------------------------------------------------------------
# test_frontmatter_no_mcp_tools:
# The allowed-tools frontmatter must NOT list browser_* MCP tool names.
# After migration, browser tools should be removed from the allowed-tools list.
# (Structural — metadata validation, acceptable per exemption for SKILL.md files)
# ---------------------------------------------------------------------------
test_frontmatter_no_mcp_tools() {
    _snapshot_fail
    frontmatter_mcp=$(head -10 "$SKILL_MD" 2>/dev/null | grep 'allowed-tools' | grep -oE 'browser_[a-z_]+' | wc -l | tr -d ' ')
    if [[ "$frontmatter_mcp" -eq 0 ]]; then
        mcp_in_frontmatter="none"
    else
        mcp_in_frontmatter="found_${frontmatter_mcp}"
    fi
    assert_eq "test_frontmatter_no_mcp_tools" "none" "$mcp_in_frontmatter"
    assert_pass_if_clean "test_frontmatter_no_mcp_tools"
}

# ---------------------------------------------------------------------------
# test_skill_contains_cli_commands:
# SKILL.md must reference @playwright/cli command patterns (e.g., npx playwright,
# @playwright/cli, or playwright test). Raw browser_run_code calls must NOT appear
# as primary execution mechanism — they belong only in a legacy/deprecated note
# if referenced at all.
# ---------------------------------------------------------------------------
test_skill_contains_cli_commands() {
    _snapshot_fail
    if grep -qE '@playwright/cli|npx playwright|playwright test' "$SKILL_MD" 2>/dev/null; then
        has_cli_commands="found"
    else
        has_cli_commands="missing"
    fi
    assert_eq "test_skill_contains_cli_commands" "found" "$has_cli_commands"
    assert_pass_if_clean "test_skill_contains_cli_commands"
}

# ---------------------------------------------------------------------------
# test_preflight_check_present:
# SKILL.md must document a pre-flight availability check section that verifies
# the @playwright/cli binary is available before attempting CLI invocations.
# This guards against silent failures when Playwright is not installed.
# ---------------------------------------------------------------------------
test_preflight_check_present() {
    _snapshot_fail
    if grep -qE 'pre-?flight|which.*playwright|command -v.*playwright|playwright.*--version' "$SKILL_MD" 2>/dev/null; then
        has_preflight="found"
    else
        has_preflight="missing"
    fi
    assert_eq "test_preflight_check_present" "found" "$has_preflight"
    assert_pass_if_clean "test_preflight_check_present"
}

# ---------------------------------------------------------------------------
# test_session_names_include_worktree:
# SKILL.md must use session name patterns that include a worktree identifier
# variable (e.g., $WORKTREE_ID, $BRANCH, $WORKTREE, or similar) to avoid
# session collisions when multiple worktrees are active simultaneously.
# ---------------------------------------------------------------------------
test_session_names_include_worktree() {
    _snapshot_fail
    if grep -qE '\$WORKTREE[_A-Z]*|\$BRANCH[_A-Z]*|\$\{WORKTREE|\$\{BRANCH' "$SKILL_MD" 2>/dev/null; then
        has_worktree_var="found"
    else
        has_worktree_var="missing"
    fi
    assert_eq "test_session_names_include_worktree" "found" "$has_worktree_var"
    assert_pass_if_clean "test_session_names_include_worktree"
}

# ---------------------------------------------------------------------------
# test_output_validation_guards:
# SKILL.md must document output validation guards after CLI command invocations
# to ensure results are non-empty before proceeding. This prevents silent data
# loss when CLI commands succeed but produce no output.
# Pattern must match a shell conditional checking CLI command output is non-empty
# (e.g., [[ -n "$output" ]], or an explicit guard on CLI results). The existing
# SKILL.md uses MCP tools (no CLI output guards), so this test is RED until migration.
# ---------------------------------------------------------------------------
test_output_validation_guards() {
    _snapshot_fail
    if grep -qE '\[\[ -n "\$[a-z_]*output|\[\[ -z "\$[a-z_]*output|if \[\[ -z.*result|output.*-z\b|cli.*output.*empty|playwright.*output.*guard' "$SKILL_MD" 2>/dev/null; then
        has_output_validation="found"
    else
        has_output_validation="missing"
    fi
    assert_eq "test_output_validation_guards" "found" "$has_output_validation"
    assert_pass_if_clean "test_output_validation_guards"
}

# Run all test functions
test_frontmatter_no_mcp_tools
test_skill_contains_cli_commands
test_preflight_check_present
test_session_names_include_worktree
test_output_validation_guards

print_summary
