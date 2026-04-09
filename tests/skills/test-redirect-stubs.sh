#!/usr/bin/env bash
# tests/skills/test-redirect-stubs.sh
#
# Verifies that skills which have been superseded by agents are correctly
# implemented as redirect stubs:
#   - Contains DEPRECATED or superseded language in frontmatter/body
#   - Does NOT have a SUB-AGENT-GUARD (redirect stubs don't dispatch agents)
#   - References the replacement agent/skill
#
# Usage: bash tests/skills/test-redirect-stubs.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-redirect-stubs.sh ==="

# ---------------------------------------------------------------------------
# Helper: check_redirect_stub <skill-name> <replacement-agent-or-skill>
# Asserts that a redirect stub:
#   1. Contains DEPRECATED or superseded language
#   2. Does NOT have a SUB-AGENT-GUARD block
#   3. References the replacement
# ---------------------------------------------------------------------------
check_redirect_stub() {
    local skill="$1"
    local replacement="$2"
    local skill_file="$DSO_PLUGIN_DIR/skills/$skill/SKILL.md"
    local label_prefix="test_${skill//-/_}_redirect"

    # Test 1: deprecated/superseded language
    if [[ -f "$skill_file" ]] && grep -qE 'DEPRECATED|superseded' "$skill_file"; then
        assert_eq "${label_prefix}_has_deprecated_language" "present" "present"
    else
        assert_eq "${label_prefix}_has_deprecated_language" "present" "missing"
    fi

    # Test 2: no sub-agent guard (redirect stubs are static)
    if [[ -f "$skill_file" ]] && grep -q 'SUB-AGENT-GUARD' "$skill_file"; then
        assert_eq "${label_prefix}_no_sub_agent_guard" "absent" "present"
    else
        assert_eq "${label_prefix}_no_sub_agent_guard" "absent" "absent"
    fi

    # Test 3: references the replacement agent/skill
    if [[ -f "$skill_file" ]] && grep -q "$replacement" "$skill_file"; then
        assert_eq "${label_prefix}_references_replacement" "present" "present"
    else
        assert_eq "${label_prefix}_references_replacement" "present" "missing"
    fi
}

# ==========================================================================
# design-wireframe: superseded by dso:ui-designer dispatched via preplanning
# ==========================================================================
echo ""
echo "--- design-wireframe redirect stub ---"
check_redirect_stub "design-wireframe" "dso:ui-designer"

# Also verify the redirect points to preplanning (the dispatch orchestrator)
DW_SKILL="$DSO_PLUGIN_DIR/skills/design-wireframe/SKILL.md"
if [[ -f "$DW_SKILL" ]] && grep -q 'preplanning' "$DW_SKILL"; then
    assert_eq "test_design_wireframe_redirect_references_preplanning" "present" "present"
else
    assert_eq "test_design_wireframe_redirect_references_preplanning" "present" "missing"
fi

echo ""
print_summary
