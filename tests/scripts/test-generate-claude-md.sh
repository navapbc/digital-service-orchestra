#!/usr/bin/env bash
# tests/scripts/test-generate-claude-md.sh
# TDD red-phase tests for templates/CLAUDE.md.template
#
# Verifies that the CLAUDE.md template file exists and contains the required
# placeholder tokens and section headers used by the generate-claude-md skill.
#
# RED PHASE: All tests are expected to FAIL until the template is created.
#
# Usage:
#   bash tests/scripts/test-generate-claude-md.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
TEMPLATE_FILE="$PLUGIN_ROOT/plugins/dso/templates/CLAUDE.md.template"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-generate-claude-md.sh ==="

# ── test_generate_claude_md_template_file_exists ──────────────────────────────
# The template file must exist at templates/CLAUDE.md.template.
if [[ -f "$TEMPLATE_FILE" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_generate_claude_md_template_file_exists" "exists" "$actual_exists"

# ── test_generate_claude_md_template_has_quick_ref_placeholder ────────────────
# Template must contain {{commands.validate}} placeholder for the validate command.
if [[ -f "$TEMPLATE_FILE" ]]; then
    template_content="$(cat "$TEMPLATE_FILE")"
    assert_contains "test_generate_claude_md_template_has_quick_ref_placeholder" \
        "{{commands.validate}}" "$template_content"
fi

# ── test_generate_claude_md_template_has_format_placeholder ───────────────────
# Template must contain {{commands.format}} placeholder for the format command.
if [[ -f "$TEMPLATE_FILE" ]]; then
    template_content="$(cat "$TEMPLATE_FILE")"
    assert_contains "test_generate_claude_md_template_has_format_placeholder" \
        "{{commands.format}}" "$template_content"
fi

# ── test_generate_claude_md_template_has_never_do_these ───────────────────────
# Template must contain a 'Never Do These' section header.
if [[ -f "$TEMPLATE_FILE" ]]; then
    template_content="$(cat "$TEMPLATE_FILE")"
    assert_contains "test_generate_claude_md_template_has_never_do_these" \
        "Never Do These" "$template_content"
fi

print_summary
