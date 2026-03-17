#!/usr/bin/env bash
# tests/scripts/test-doc-migration.sh
# Verifies all ${CLAUDE_PLUGIN_ROOT}/scripts/ invocations have been migrated
# to .claude/scripts/dso <name> in skills/ docs/workflows/ CLAUDE.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-doc-migration.sh ==="

test_no_legacy_plugin_root_refs() {
    # Count ${CLAUDE_PLUGIN_ROOT}/scripts/ invocations, excluding known-good lines:
    # - PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts" variable assignments (config-resolution internal, 10 lines)
    # - ls directory listings like: ls "${CLAUDE_PLUGIN_ROOT}/scripts/"*.sh (1 line in dev-onboarding/SKILL.md)
    local COUNT
    # The trailing " in the ls exclusion anchors on the closing quote of the directory
    # argument (e.g. ls "${CLAUDE_PLUGIN_ROOT}/scripts/"*.sh) to avoid over-excluding.
    # If that line is ever reformatted (e.g. single-quoted), update this pattern to match.
    COUNT=$(grep -r '${CLAUDE_PLUGIN_ROOT}/scripts/' \
        "$PLUGIN_ROOT/skills" \
        "$PLUGIN_ROOT/docs/workflows" \
        "$PLUGIN_ROOT/CLAUDE.md" \
        2>/dev/null \
        | grep -v 'PLUGIN_SCRIPTS=' \
        | grep -v 'ls.*CLAUDE_PLUGIN_ROOT.*scripts/\"' \
        | wc -l \
        | tr -d ' ')
    assert_eq "test_no_legacy_plugin_root_refs" "0" "$COUNT"
}

test_no_legacy_plugin_root_refs

print_summary
