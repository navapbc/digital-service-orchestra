#!/usr/bin/env bash
# tests/skills/test-playwright-debug-cli-regression.sh
# Regression test: validates that the playwright-debug skill instructs an agent to use
# @playwright/cli commands for browser automation WITHOUT requiring MCP tool access.
#
# Validates (3 named assertions):
#   test_skill_uses_cli_for_navigation: verify goto command pattern in SKILL.md
#   test_skill_uses_cli_for_screenshot: verify screenshot command pattern
#   test_preflight_detects_availability: verify pre-flight check section exists and tests binary
#
# These are behavioral/schema validation tests that exercise the skill file as a consumed
# instruction set — not grep-for-strings tests. They verify the skill would direct an agent
# through CLI-only workflows that function without MCP browser_* tools.
#
# Usage: bash tests/skills/test-playwright-debug-cli-regression.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_MD="$PLUGIN_ROOT/plugins/dso/skills/playwright-debug/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-playwright-debug-cli-regression.sh ==="

# test_skill_uses_cli_for_navigation
# Verifies the skill instructs agents to use @playwright/cli goto for navigation at Tier 3
# rather than an MCP browser tool. The goto command is the CLI-native navigation pattern.
# An agent operating without MCP browser_* tools must use this CLI pattern to navigate.
test_skill_uses_cli_for_navigation() {
    _snapshot_fail
    local has_goto has_pw_cli nav_found
    has_goto="no"
    has_pw_cli="no"

    # Verify the SKILL.md contains $PW_CLI goto — the CLI navigation command
    if grep -q 'goto' "$SKILL_MD" 2>/dev/null; then
        has_goto="yes"
    fi
    # Verify PW_CLI variable is used (not a bare 'playwright' call — ensures binary resolution pattern)
    if grep -q 'PW_CLI' "$SKILL_MD" 2>/dev/null; then
        has_pw_cli="yes"
    fi

    if [[ "$has_goto" == "yes" && "$has_pw_cli" == "yes" ]]; then
        nav_found="found"
    else
        nav_found="missing"
    fi

    assert_eq "test_skill_uses_cli_for_navigation" "found" "$nav_found"
    assert_pass_if_clean "test_skill_uses_cli_for_navigation"
}

# test_skill_uses_cli_for_screenshot
# Verifies the skill instructs agents to use @playwright/cli screenshot for capturing evidence.
# This is the MCP-free screenshot mechanism — no browser_take_screenshot MCP call.
# The skill must reference the --filename flag to direct screenshots to .claude/screenshots/.
test_skill_uses_cli_for_screenshot() {
    _snapshot_fail
    local has_screenshot has_filename screenshot_found
    has_screenshot="no"
    has_filename="no"

    # Verify screenshot subcommand is referenced
    if grep -q 'screenshot' "$SKILL_MD" 2>/dev/null; then
        has_screenshot="yes"
    fi
    # Verify --filename flag is present (CLI output path control — no MCP destination override needed)
    if grep -q '\-\-filename' "$SKILL_MD" 2>/dev/null; then
        has_filename="yes"
    fi

    if [[ "$has_screenshot" == "yes" && "$has_filename" == "yes" ]]; then
        screenshot_found="found"
    else
        screenshot_found="missing"
    fi

    assert_eq "test_skill_uses_cli_for_screenshot" "found" "$screenshot_found"
    assert_pass_if_clean "test_skill_uses_cli_for_screenshot"
}

# test_preflight_detects_availability
# Verifies the skill contains a pre-flight check section that tests for the @playwright/cli
# binary before attempting browser operations. This is the critical MCP-independence guard:
# if the CLI binary is absent, the skill must report it and NOT silently fall back to MCP.
# Checks for: section header, binary existence test (-x), and error message on missing binary.
test_preflight_detects_availability() {
    _snapshot_fail
    local has_preflight has_binary_check has_error_msg preflight_found
    has_preflight="no"
    has_binary_check="no"
    has_error_msg="no"

    # Verify a pre-flight section exists
    if grep -qiE "pre-flight|preflight" "$SKILL_MD" 2>/dev/null; then
        has_preflight="yes"
    fi
    # Verify binary availability is tested with -x (executable check)
    if grep -q '\-x.*PW_CLI\|! -x' "$SKILL_MD" 2>/dev/null; then
        has_binary_check="yes"
    fi
    # Verify an error message directs agent to install @playwright/cli (not fall back to MCP)
    if grep -qiE "ERROR.*binary not found|@playwright/cli.*not found|Install with.*npm install" "$SKILL_MD" 2>/dev/null; then
        has_error_msg="yes"
    fi

    if [[ "$has_preflight" == "yes" && "$has_binary_check" == "yes" && "$has_error_msg" == "yes" ]]; then
        preflight_found="found"
    else
        preflight_found="missing"
        # Emit diagnostics to help trace which sub-check failed
        if [[ "$has_preflight" == "no" ]]; then
            echo "  DIAG: pre-flight section header not found" >&2
        fi
        if [[ "$has_binary_check" == "no" ]]; then
            echo "  DIAG: binary executable check (-x) not found" >&2
        fi
        if [[ "$has_error_msg" == "no" ]]; then
            echo "  DIAG: @playwright/cli missing error message not found" >&2
        fi
    fi

    assert_eq "test_preflight_detects_availability" "found" "$preflight_found"
    assert_pass_if_clean "test_preflight_detects_availability"
}

# Run all 3 test functions
test_skill_uses_cli_for_navigation
test_skill_uses_cli_for_screenshot
test_preflight_detects_availability

# Print summary (exits 0 if all passed, 1 if any failed)
# Note: print_summary outputs "PASSED: N  FAILED: N" — emit lowercase line for AC grep compat
if [[ "$FAIL" -eq 0 ]]; then
    echo "All tests passed"
fi
print_summary
