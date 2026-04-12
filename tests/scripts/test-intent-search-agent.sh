#!/usr/bin/env bash
# tests/scripts/test-intent-search-agent.sh
# Structural boundary tests for dso:intent-search agent definition.
#
# Tests:
#  1. test_budget_cap_advisory — '## Budget Enforcement' section header exists (structural boundary)
#
# Usage: bash tests/scripts/test-intent-search-agent.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_MD="$PLUGIN_ROOT/plugins/dso/agents/intent-search.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-intent-search-agent.sh ==="

# ── test_budget_cap_advisory ─────────────────────────────────────────────────
# The '## Budget Enforcement' section header must exist as a structural element
# in intent-search.md. Tests the structural contract boundary (section heading =
# interface) per behavioral-testing-standard.md Rule 5, not prose word presence.
test_budget_cap_advisory() {
    _snapshot_fail

    local _has_section=0
    if grep -q "^## Budget Enforcement" "$AGENT_MD"; then
        _has_section=1
    fi
    assert_eq "test_budget_cap_advisory: '## Budget Enforcement' section must exist in intent-search.md" "1" "$_has_section"

    assert_pass_if_clean "test_budget_cap_advisory"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_budget_cap_advisory

print_summary
