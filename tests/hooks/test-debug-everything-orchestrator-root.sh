#!/usr/bin/env bash
# tests/hooks/test-debug-everything-orchestrator-root.sh
# Structural tests for debug-everything/SKILL.md single-agent-integrate integration.
#
# These tests verify that debug-everything/SKILL.md contains the structural
# strings required for the ORCHESTRATOR_ROOT + single-agent-integrate dispatch
# pattern added in epic c737-977d.
#
# Assertion (1): SKILL.md contains "single-agent-integrate"
#   - Currently RED (string not yet present)
#   - Goes GREEN after T8 adds the dispatch reference
#
# Assertion (2): SKILL.md contains "DISPATCH_ISOLATION" adjacent to "single-agent-integrate"
#   - Currently RED (string not yet present)
#   - Goes GREEN after T8 adds the conditional dispatch block
#
# Usage:
#   bash tests/hooks/test-debug-everything-orchestrator-root.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

SKILL_FILE="$REPO_ROOT/plugins/dso/skills/debug-everything/SKILL.md"

echo "=== test-debug-everything-orchestrator-root.sh ==="

# ---------------------------------------------------------------------------
# Assertion 1: SKILL.md contains "single-agent-integrate"
# This string will be added when the Bug-Fix Mode section is updated to
# reference the single-agent-integrate.md workflow for ORCHESTRATOR_ROOT dispatch.
# ---------------------------------------------------------------------------
echo "--- assertion 1: single-agent-integrate present ---"
count1=$(grep -c 'single-agent-integrate' "$SKILL_FILE" 2>/dev/null || echo 0)
assert_eq \
    "test_debug_everything_skill_contains_single_agent_integrate" \
    "1" \
    "$([ "${count1}" -gt 0 ] 2>/dev/null && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# Assertion 2: SKILL.md contains DISPATCH_ISOLATION adjacent to single-agent-integrate
# This pattern will appear when the conditional dispatch block is added, e.g.:
#   DISPATCH_ISOLATION=true ... single-agent-integrate
# or the reverse order in the same instruction block.
# ---------------------------------------------------------------------------
echo "--- assertion 2: DISPATCH_ISOLATION adjacent to single-agent-integrate ---"
count2=$(grep -Ec 'DISPATCH_ISOLATION.*single-agent-integrate|single-agent-integrate.*DISPATCH_ISOLATION' "$SKILL_FILE" 2>/dev/null || echo 0)
assert_eq \
    "test_debug_everything_skill_contains_dispatch_isolation_with_single_agent_integrate" \
    "1" \
    "$([ "${count2}" -gt 0 ] 2>/dev/null && echo 1 || echo 0)"

print_summary
