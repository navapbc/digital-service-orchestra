#!/usr/bin/env bash
# tests/skills/test-preplanning-sc-contradiction-check.sh
# Structural boundary tests for preplanning SKILL.md SC Contradiction Check.
#
# Tests:
#  1. SC Contradiction Check section exists
#  2. Section is positioned within Done Definitions subsection (after format, before TDD)
#
# Usage: bash tests/skills/test-preplanning-sc-contradiction-check.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_MD="$PLUGIN_ROOT/plugins/dso/skills/preplanning/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-preplanning-sc-contradiction-check.sh ==="

# ── test_sc_contradiction_section_exists ──────────────────────────────────────
_snapshot_fail
_has=0
if grep -q "^#### SC Contradiction Check" "$SKILL_MD"; then
    _has=1
fi
assert_eq "test_sc_contradiction_section_exists: SC Contradiction Check section must exist" "1" "$_has"
assert_pass_if_clean "test_sc_contradiction_section_exists"

# ── test_sc_contradiction_between_dd_and_tdd ─────────────────────────────────
_snapshot_fail
_dd_line=$(grep -n "^#### Done Definitions" "$SKILL_MD" | head -1 | cut -d: -f1)
_sc_line=$(grep -n "^#### SC Contradiction Check" "$SKILL_MD" | head -1 | cut -d: -f1)
_tdd_line=$(grep -n "^#### TDD Done-of-Done Requirement" "$SKILL_MD" | head -1 | cut -d: -f1)
_ordered=0
if [[ -n "$_dd_line" && -n "$_sc_line" && -n "$_tdd_line" ]]; then
    if (( _dd_line < _sc_line && _sc_line < _tdd_line )); then
        _ordered=1
    fi
fi
assert_eq "test_sc_contradiction_between_dd_and_tdd: SC Contradiction Check between Done Definitions and TDD" "1" "$_ordered"
assert_pass_if_clean "test_sc_contradiction_between_dd_and_tdd"

print_summary
