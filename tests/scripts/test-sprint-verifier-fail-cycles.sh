#!/usr/bin/env bash
# tests/scripts/test-sprint-verifier-fail-cycles.sh
# Behavioral fixture: verify sprint/SKILL.md planner-dispatch-story-level HARD-GATE
# contains the cycles[] artifact-append block (9a9a/21f3 block) and the
# single-comment-policy prose (SC6).
#
# Scoped to the planner-dispatch-story-level HARD-GATE block to prevent false
# positives from the epic-level gate or other sections.
#
# Tests (3 assertions):
#  1. test_append_review_cycle_present  — grep for 'append_review_cycle.py' in block
#  2. test_ticket_comment_present       — grep for 'ticket comment' in block
#  3. test_single_comment_policy        — grep for 'not duplicat' OR
#                                         'references the artifact path' in block
#
# Usage: bash tests/scripts/test-sprint-verifier-fail-cycles.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
SPRINT_SKILL="$DSO_PLUGIN_DIR/skills/sprint/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-verifier-fail-cycles.sh ==="
echo ""

# ── Extract the planner-dispatch-story-level HARD-GATE section ───────────────
# Scope all assertions to the block delimited by
#   <HARD-GATE id="planner-dispatch-story-level"> ... </HARD-GATE>
# This is the canonical verifier-fail re-dispatch block in Phase F Step 18.
_story_level_gate_section() {
  awk '/HARD-GATE id="planner-dispatch-story-level"/{found=1} found && /^<\/HARD-GATE>/{print; exit} found{print}' "$SPRINT_SKILL"
}

# ── test_append_review_cycle_present ─────────────────────────────────────────
# Verify the block invokes append_review_cycle.py (9a9a/21f3 cycle recorder).
test_append_review_cycle_present() {
  _snapshot_fail
  local _section
  _section=$(_story_level_gate_section)
  local _found=0
  [[ "$_section" == *"append_review_cycle.py"* ]] && _found=1
  assert_eq "test_append_review_cycle_present: 'append_review_cycle.py' present in story-level gate" \
    "1" "$_found"
  assert_pass_if_clean "test_append_review_cycle_present"
}

# ── test_ticket_comment_present ───────────────────────────────────────────────
# Verify the block emits a ticket comment after each append_review_cycle.py call.
test_ticket_comment_present() {
  _snapshot_fail
  local _section
  _section=$(_story_level_gate_section)
  local _found=0
  [[ "$_section" == *"ticket comment"* ]] && _found=1
  assert_eq "test_ticket_comment_present: 'ticket comment' present in story-level gate" \
    "1" "$_found"
  assert_pass_if_clean "test_ticket_comment_present"
}

# ── test_single_comment_policy ────────────────────────────────────────────────
# Verify the block documents the single-comment policy: the ticket comment
# references the artifact path and does NOT duplicate the cycle body.
# Accepts either 'not duplicat' or 'references the artifact path' phrasing.
test_single_comment_policy() {
  _snapshot_fail
  local _section
  _section=$(_story_level_gate_section)
  local _found=0
  # Case-insensitive match
  local _lower="${_section,,}"
  [[ "$_lower" == *"not duplicat"* || "$_lower" == *"references the artifact path"* ]] && _found=1
  assert_eq "test_single_comment_policy: single-comment-policy prose ('not duplicat' or 'references the artifact path') present in story-level gate" \
    "1" "$_found"
  assert_pass_if_clean "test_single_comment_policy"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_append_review_cycle_present
test_ticket_comment_present
test_single_comment_policy

print_summary
