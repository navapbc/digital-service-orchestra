#!/usr/bin/env bash
# tests/scripts/test-fix-bug-flaky-scoring.sh
# RED tests: assert fix-bug SKILL.md scoring rubric includes a flaky/intermittent
# dimension row and an additive contribution note.
#
# These tests are intentionally RED against the current SKILL.md (which has no
# intermittent/flaky dimension). The GREEN implementation task will add that row
# and a note explaining the dimension contributes additively to the total score.
#
# Usage: bash tests/scripts/test-fix-bug-flaky-scoring.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/fix-bug/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-fix-bug-flaky-scoring.sh ==="
echo ""

# ── test_flaky_dimension_in_rubric ────────────────────────────────────────────
# The scoring rubric table must contain a row for the intermittent/flaky
# dimension so agents know to score flaky bugs higher than deterministic ones.
# Pattern: 'intermittent.*flaky' (case-insensitive) anywhere in SKILL.md.
echo "--- test_flaky_dimension_in_rubric ---"
_snapshot_fail

_has_flaky_row=0
grep -qiE 'intermittent.*flaky' "$SKILL_FILE" && _has_flaky_row=1 || true
assert_eq "test_flaky_dimension_in_rubric: scoring rubric must contain intermittent/flaky dimension row" \
    "1" "$_has_flaky_row"
assert_pass_if_clean "test_flaky_dimension_in_rubric"

# ── test_additive_contribution_note ──────────────────────────────────────────
# Near the scoring rubric, SKILL.md must mention that the flaky/intermittent
# dimension contributes additively to the total score (keyword: 'additive').
# This prevents agents from treating the dimension as a modifier rather than a
# first-class rubric row.
echo ""
echo "--- test_additive_contribution_note ---"
_snapshot_fail

_has_additive=0
grep -qi 'additive' "$SKILL_FILE" && _has_additive=1 || true
assert_eq "test_additive_contribution_note: SKILL.md must mention 'additive' contribution near rubric" \
    "1" "$_has_additive"
assert_pass_if_clean "test_additive_contribution_note"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
