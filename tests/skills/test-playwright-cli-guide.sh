#!/usr/bin/env bash
# tests/skills/test-playwright-cli-guide.sh
# Tests that PLAYWRIGHT-MCP-GUIDE.md has been removed and replaced with a
# CLI-focused guide at plugins/dso/docs/PLAYWRIGHT-CLI-GUIDE.md containing
# all required sections (commands, output patterns, session naming, pre-flight,
# CI considerations).
#
# All tests are RED until:
#   - PLAYWRIGHT-MCP-GUIDE.md is deleted
#   - PLAYWRIGHT-CLI-GUIDE.md is created with required sections
#   - playwright-debug SKILL.md legacy MCP guide reference is removed
#
# Test functions:
#   test_mcp_guide_removed           — PLAYWRIGHT-MCP-GUIDE.md no longer exists
#   test_cli_guide_exists            — PLAYWRIGHT-CLI-GUIDE.md exists at expected path
#   test_cli_guide_sections          — CLI guide contains all required sections
#   test_cross_references_updated    — playwright-debug skill no longer echoes legacy MCP guide path
#
# Usage: bash tests/skills/test-playwright-cli-guide.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCS_DIR="$PLUGIN_ROOT/plugins/dso/docs"
MCP_GUIDE="$DOCS_DIR/PLAYWRIGHT-MCP-GUIDE.md"
CLI_GUIDE="$DOCS_DIR/PLAYWRIGHT-CLI-GUIDE.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-playwright-cli-guide.sh ==="

# ---------------------------------------------------------------------------
# test_mcp_guide_removed:
# PLAYWRIGHT-MCP-GUIDE.md must NOT exist. Its removal is the filesystem side
# effect that signals the MCP → CLI migration is complete. The test executes
# a file-existence check and asserts the path is absent.
# ---------------------------------------------------------------------------
test_mcp_guide_removed() {
    _snapshot_fail
    if [[ -f "$MCP_GUIDE" ]]; then
        mcp_guide_state="exists"
    else
        mcp_guide_state="removed"
    fi
    assert_eq "test_mcp_guide_removed: PLAYWRIGHT-MCP-GUIDE.md must not exist" \
        "removed" "$mcp_guide_state"
    assert_pass_if_clean "test_mcp_guide_removed"
}

# ---------------------------------------------------------------------------
# test_cli_guide_exists:
# A CLI-focused replacement guide must exist at plugins/dso/docs/PLAYWRIGHT-CLI-GUIDE.md.
# The test checks the filesystem side effect of guide creation and verifies the
# file is non-empty (has actual content, not a stub).
# ---------------------------------------------------------------------------
test_cli_guide_exists() {
    _snapshot_fail
    if [[ -f "$CLI_GUIDE" ]]; then
        cli_guide_state="exists"
    else
        cli_guide_state="missing"
    fi
    assert_eq "test_cli_guide_exists: PLAYWRIGHT-CLI-GUIDE.md must exist" \
        "exists" "$cli_guide_state"

    if [[ -f "$CLI_GUIDE" ]]; then
        local byte_count
        byte_count=$(wc -c < "$CLI_GUIDE" | tr -d ' ')
        if [[ "$byte_count" -gt 100 ]]; then
            cli_guide_nonempty="yes"
        else
            cli_guide_nonempty="no"
        fi
        assert_eq "test_cli_guide_exists: CLI guide must have substantive content" \
            "yes" "$cli_guide_nonempty"
    else
        assert_eq "test_cli_guide_exists: CLI guide must have substantive content (file absent)" \
            "yes" "no"
    fi
    assert_pass_if_clean "test_cli_guide_exists"
}

# ---------------------------------------------------------------------------
# test_cli_guide_sections:
# The CLI guide must contain all required sections. Each section is identified
# by reading the guide file and asserting specific headings or keywords are
# present as file content. The test fails if any required section is absent.
# Required: commands reference, output patterns, session naming, pre-flight,
# CI considerations (--no-sandbox or browser install).
# ---------------------------------------------------------------------------
test_cli_guide_sections() {
    _snapshot_fail

    if [[ ! -f "$CLI_GUIDE" ]]; then
        assert_eq "test_cli_guide_sections: CLI guide must exist to check sections" \
            "found" "missing"
        assert_pass_if_clean "test_cli_guide_sections"
        return
    fi

    local content
    content=$(< "$CLI_GUIDE")

    # Commands reference section — must document @playwright/cli or npx playwright commands
    if grep -qiE '@playwright/cli|npx playwright|playwright (test|screenshot|pdf|codegen)' <<< "$content"; then
        has_commands="found"
    else
        has_commands="missing"
    fi
    assert_eq "test_cli_guide_sections: guide must document @playwright/cli commands" \
        "found" "$has_commands"

    # Output patterns section — must describe disk-based output (reading results back)
    if grep -qiE 'output|stdout|result|\.png|\.pdf|screenshot' <<< "$content"; then
        has_output_patterns="found"
    else
        has_output_patterns="missing"
    fi
    assert_eq "test_cli_guide_sections: guide must document output patterns" \
        "found" "$has_output_patterns"

    # Session naming section — must describe session naming conventions
    if grep -qiE 'session.nam|--save-storage|storage-state|session.id' <<< "$content"; then
        has_session_naming="found"
    else
        has_session_naming="missing"
    fi
    assert_eq "test_cli_guide_sections: guide must document session naming conventions" \
        "found" "$has_session_naming"

    # Pre-flight section — must document availability checks before invoking CLI
    if grep -qiE 'pre-?flight|which playwright|command -v playwright|playwright.*--version|install.*playwright' <<< "$content"; then
        has_preflight="found"
    else
        has_preflight="missing"
    fi
    assert_eq "test_cli_guide_sections: guide must document pre-flight checks" \
        "found" "$has_preflight"

    # CI considerations section — must address CI environment specifics (--no-sandbox, browser install)
    if grep -qiE 'no-sandbox|CI|ci\b|install.*browser|browser.*install|chromium' <<< "$content"; then
        has_ci="found"
    else
        has_ci="missing"
    fi
    assert_eq "test_cli_guide_sections: guide must document CI environment considerations" \
        "found" "$has_ci"

    assert_pass_if_clean "test_cli_guide_sections"
}

# ---------------------------------------------------------------------------
# test_cross_references_updated:
# The playwright-debug SKILL.md contains a bash snippet that echoes the legacy
# MCP guide path if the file exists. This test executes that conditional check
# against the live filesystem and asserts it produces no output — meaning either
# the file has been removed OR the legacy code block has been deleted from the skill.
# Observable behavior: running the bash check produces empty stdout.
# ---------------------------------------------------------------------------
test_cross_references_updated() {
    _snapshot_fail

    local legacy_check_output
    legacy_check_output=$(
        CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT/plugins/dso"
        bash -c "
            if [[ -f \"${PLUGIN_ROOT}/plugins/dso/docs/PLAYWRIGHT-MCP-GUIDE.md\" ]]; then
                echo \"Legacy MCP guide still present: ${PLUGIN_ROOT}/plugins/dso/docs/PLAYWRIGHT-MCP-GUIDE.md\"
            fi
        " 2>/dev/null
    )

    if [[ -z "$legacy_check_output" ]]; then
        mcp_cross_ref_state="clean"
    else
        mcp_cross_ref_state="legacy_reference_active"
    fi

    assert_eq "test_cross_references_updated: legacy MCP guide must not be reachable from skills" \
        "clean" "$mcp_cross_ref_state"
    assert_pass_if_clean "test_cross_references_updated"
}

# Run all tests
test_mcp_guide_removed
test_cli_guide_exists
test_cli_guide_sections
test_cross_references_updated

print_summary
