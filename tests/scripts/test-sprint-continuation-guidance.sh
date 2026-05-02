#!/usr/bin/env bash
# tests/scripts/test-sprint-continuation-guidance.sh
# Tests that sprint/SKILL.md contains the required continuation guidance:
#   - A CONTINUE callout in Phase F Step 17 (Commit & Push)
#   - A MANDATORY directive in Phase F Step 20's Phase H routing bullet
#   - A Phase F Step 18 heading between Step 17 and Step 19
#   - No placeholder bug ID (project-specific-bug-id) in the file
#
# Usage: bash tests/scripts/test-sprint-continuation-guidance.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/sprint/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-continuation-guidance.sh ==="

# ── test_continue_callout_exists ─────────────────────────────────────────────
# Phase F Step 17 (Commit & Push) section must contain a > **CONTINUE:** callout
_snapshot_fail
continue_match=0
continue_match=$(awk '/### Step 17: /,/### Step 18:/' "$SKILL_FILE" | grep -c '> \*\*CONTINUE:\*\*' 2>/dev/null) || continue_match=0
[[ $continue_match -gt 0 ]] && continue_match=1
assert_eq "test_continue_callout_exists: CONTINUE callout in Phase F Step 17 (Commit & Push)" "1" "$continue_match"
assert_pass_if_clean "test_continue_callout_exists"

# ── test_mandatory_directive_exists ──────────────────────────────────────────
# Phase F Step 20 (Continuation Decision)'s Phase H routing bullet must contain MANDATORY
_snapshot_fail
mandatory_match=0
mandatory_match=$(awk '/### Step 20/,/## Phase H/' "$SKILL_FILE" | grep -c 'MANDATORY' 2>/dev/null) || mandatory_match=0
[[ $mandatory_match -gt 0 ]] && mandatory_match=1
assert_eq "test_mandatory_directive_exists: MANDATORY in Phase F Step 20 Phase H routing" "1" "$mandatory_match"
assert_pass_if_clean "test_mandatory_directive_exists"

# ── test_step_10a_exists ─────────────────────────────────────────────────────
# A ### Step 18 heading (Close Completed Tasks) must exist between ### Step 17 and ### Step 19
_snapshot_fail
step10a_match=0
step10a_match=$(awk '/### Step 17: /,/### Step 19:/' "$SKILL_FILE" | grep -c '### Step 18' 2>/dev/null) || step10a_match=0
[[ $step10a_match -gt 0 ]] && step10a_match=1
assert_eq "test_step_10a_exists: Phase F Step 18 (Close Completed Tasks) heading between Step 17 and Step 19" "1" "$step10a_match"
assert_pass_if_clean "test_step_10a_exists"

# ── test_no_placeholder_bug_id ───────────────────────────────────────────────
# The placeholder text project-specific-bug-id must not appear in SKILL.md
_snapshot_fail
placeholder_count=0
placeholder_count=$(grep -c 'project-specific-bug-id' "$SKILL_FILE" 2>/dev/null) || placeholder_count=0
assert_eq "test_no_placeholder_bug_id: no project-specific-bug-id in SKILL.md" "0" "$placeholder_count"
assert_pass_if_clean "test_no_placeholder_bug_id"

print_summary
