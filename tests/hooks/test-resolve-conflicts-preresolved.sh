#!/usr/bin/env bash
# tests/hooks/test-resolve-conflicts-preresolved.sh
# Verifies that /dso:resolve-conflicts skill handles the pre-resolved
# merge state (MERGE_HEAD exists, no unresolved conflicts).
#
# Bug: dso-vcrq — resolve-conflicts skill misdetects merge state when
# conflicts are pre-resolved.
#
# Usage:
#   bash tests/hooks/test-resolve-conflicts-preresolved.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

SKILL_FILE="$DSO_PLUGIN_DIR/skills/resolve-conflicts/SKILL.md"

echo "=== test-resolve-conflicts-preresolved.sh ==="

# ---------------------------------------------------------------
# Test 1: Skill checks for MERGE_HEAD in the conflict detection step
# When all conflicts are pre-resolved (git add), --diff-filter=U returns
# empty but MERGE_HEAD still exists. The skill must check for MERGE_HEAD
# to avoid incorrectly reporting "no conflicts detected" when a merge
# is still in progress and just needs committing.
# ---------------------------------------------------------------
if grep -q 'MERGE_HEAD' "$SKILL_FILE"; then
    actual="present"
else
    actual="missing"
fi
assert_eq "test_skill_checks_merge_head" "present" "$actual"

# ---------------------------------------------------------------
# Test 2: Skill handles the case where MERGE_HEAD exists but no
# unresolved conflicts remain (pre-resolved state)
# ---------------------------------------------------------------
if grep -qi 'pre-resolved\|all.*conflicts.*resolved\|no.*unresolved.*conflicts.*remain\|merge.*needs.*commit' "$SKILL_FILE"; then
    actual="present"
else
    actual="missing"
fi
assert_eq "test_skill_handles_preresolved_state" "present" "$actual"

print_summary
