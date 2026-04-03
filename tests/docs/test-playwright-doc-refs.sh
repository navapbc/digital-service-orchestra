#!/usr/bin/env bash
# tests/docs/test-playwright-doc-refs.sh
#
# Contract tests: project docs must reference @playwright/cli, not Playwright MCP.
#
# All tests are intentionally RED because the docs have not yet been updated
# to include @playwright/cli CLI patterns and setup instructions.
#
# RED phase: tests FAIL because:
#   - CLAUDE.md does not yet reference @playwright/cli as the browser automation interface
#   - CONFIGURATION-REFERENCE.md E2E command examples do not yet reference @playwright/cli
#   - INSTALL.md does not yet include @playwright/cli installation instructions
#
# GREEN promotion blocked until docs are updated (story 413f-d504).
#
# Usage: bash tests/docs/test-playwright-doc-refs.sh
# Returns: exit 1 (RED — docs not yet updated)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"

source "$REPO_ROOT/tests/lib/assert.sh"

CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
CONFIG_REF="$REPO_ROOT/plugins/dso/docs/CONFIGURATION-REFERENCE.md"
INSTALL_MD="$REPO_ROOT/plugins/dso/docs/INSTALL.md"

echo "=== test-playwright-doc-refs.sh ==="

# ---------------------------------------------------------------------------
# test_claude_md_no_mcp_refs
#
# Asserts that CLAUDE.md does not reference Playwright MCP as the active
# browser automation interface, AND references @playwright/cli as the
# current interface for browser automation.
#
# Observable behavior: agents reading CLAUDE.md will use @playwright/cli
# commands (npx @playwright/cli ...) rather than expecting MCP browser_*
# tools to be available.
# ---------------------------------------------------------------------------
test_claude_md_no_mcp_refs() {
    # Assert no MCP browser tool references remain as active interface directives
    if grep -q "browser_run_code\|browser_snapshot\|Playwright MCP\|playwright-mcp" "$CLAUDE_MD" 2>/dev/null; then
        mcp_tool_refs="found"
    else
        mcp_tool_refs="none"
    fi
    assert_eq \
        "CLAUDE.md has no MCP browser tool references" \
        "none" \
        "$mcp_tool_refs"

    # Assert CLAUDE.md references @playwright/cli as the active browser automation tool
    if grep -q "@playwright/cli" "$CLAUDE_MD" 2>/dev/null; then
        cli_ref_present="yes"
    else
        cli_ref_present="no"
    fi
    assert_eq \
        "CLAUDE.md references @playwright/cli as browser automation interface" \
        "yes" \
        "$cli_ref_present"
}

# ---------------------------------------------------------------------------
# test_config_ref_no_mcp
#
# Asserts that CONFIGURATION-REFERENCE.md uses @playwright/cli CLI patterns
# in its E2E test command examples, not MCP browser_* tool calls.
#
# Observable behavior: developers reading the config reference will configure
# their e2e_command using @playwright/cli syntax.
# ---------------------------------------------------------------------------
test_config_ref_no_mcp() {
    # Assert no MCP-specific browser tool patterns in config reference
    if grep -q "browser_run_code\|browser_snapshot\|Playwright MCP\|playwright-mcp" "$CONFIG_REF" 2>/dev/null; then
        mcp_refs_in_config="found"
    else
        mcp_refs_in_config="none"
    fi
    assert_eq \
        "CONFIGURATION-REFERENCE.md has no MCP browser tool references" \
        "none" \
        "$mcp_refs_in_config"

    # Assert the config reference uses @playwright/cli in its examples
    if grep -q "@playwright/cli" "$CONFIG_REF" 2>/dev/null; then
        config_cli_pattern="yes"
    else
        config_cli_pattern="no"
    fi
    assert_eq \
        "CONFIGURATION-REFERENCE.md uses @playwright/cli CLI patterns in examples" \
        "yes" \
        "$config_cli_pattern"
}

# ---------------------------------------------------------------------------
# test_install_md_updated
#
# Asserts that INSTALL.md references @playwright/cli CLI setup instructions,
# not MCP-based Playwright setup.
#
# Observable behavior: developers following the install guide will set up
# @playwright/cli for browser automation, not the Playwright MCP server.
# ---------------------------------------------------------------------------
test_install_md_updated() {
    # Assert no MCP setup instructions remain in INSTALL.md
    if grep -q "browser_run_code\|browser_snapshot\|Playwright MCP\|playwright-mcp" "$INSTALL_MD" 2>/dev/null; then
        mcp_refs_in_install="found"
    else
        mcp_refs_in_install="none"
    fi
    assert_eq \
        "INSTALL.md has no MCP setup instructions" \
        "none" \
        "$mcp_refs_in_install"

    # Assert INSTALL.md references @playwright/cli installation
    if grep -q "@playwright/cli" "$INSTALL_MD" 2>/dev/null; then
        install_cli_ref="yes"
    else
        install_cli_ref="no"
    fi
    assert_eq \
        "INSTALL.md references @playwright/cli setup" \
        "yes" \
        "$install_cli_ref"
}

# Run all test functions
echo "--- test_claude_md_no_mcp_refs ---"
test_claude_md_no_mcp_refs

echo "--- test_config_ref_no_mcp ---"
test_config_ref_no_mcp

echo "--- test_install_md_updated ---"
test_install_md_updated

print_summary
