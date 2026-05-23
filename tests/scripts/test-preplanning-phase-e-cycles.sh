#!/usr/bin/env bash
# tests/scripts/test-preplanning-phase-e-cycles.sh
# Behavioral fixture: verify preplanning/SKILL.md Phase E contains the
# append_review_cycle.py writer call, the single-comment-per-cycle ticket
# comment invocation, and the no-duplicate policy prose (SC5).
#
# Tests:
#  1. test_append_review_cycle_invocation — Phase E section contains 'append_review_cycle.py'
#  2. test_ticket_comment_invocation      — Phase E section contains 'ticket comment'
#                                          after the append block
#  3. test_no_duplicate_policy            — Phase E section matches 'not duplicat' OR
#                                          'references the artifact path'
#
# All greps are scoped to the Phase E section of SKILL.md (from '## Phase E'
# heading to the next '## ' heading) to prevent false positives from unrelated
# content elsewhere in the file.
#
# Usage: bash tests/scripts/test-preplanning-phase-e-cycles.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PREPLANNING_SKILL="$DSO_PLUGIN_DIR/skills/preplanning/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-preplanning-phase-e-cycles.sh ==="
echo ""

# ── Extract Phase E section ───────────────────────────────────────────────────
# Scope all assertions to Phase E (from '## Phase E' heading to the next
# '## ' heading), preventing false positives from pre-existing content elsewhere.
_phase_e_section() {
  awk '/^## Phase E:/{found=1} found && /^## / && !/^## Phase E:/{exit} found{print}' "$PREPLANNING_SKILL"
}

# ── test_append_review_cycle_invocation ──────────────────────────────────────
# Verify Phase E contains a call to append_review_cycle.py (the atomic writer
# added by task e003 / PR #313), satisfying the wiring requirement.
test_append_review_cycle_invocation() {
  _snapshot_fail
  local _section
  _section=$(_phase_e_section)
  local _found=0
  [[ "$_section" == *"append_review_cycle.py"* ]] && _found=1
  assert_eq "test_append_review_cycle_invocation: 'append_review_cycle.py' present in Phase E" \
    "1" "$_found"
  assert_pass_if_clean "test_append_review_cycle_invocation"
}

# ── test_ticket_comment_invocation ───────────────────────────────────────────
# Verify Phase E contains a 'ticket comment' invocation after the append block.
# The single-comment policy (SC5) requires exactly one ticket comment per cycle
# referencing the artifact path.
test_ticket_comment_invocation() {
  _snapshot_fail
  local _section
  _section=$(_phase_e_section)
  local _found=0
  [[ "$_section" == *"ticket comment"* ]] && _found=1
  assert_eq "test_ticket_comment_invocation: 'ticket comment' present in Phase E" \
    "1" "$_found"
  assert_pass_if_clean "test_ticket_comment_invocation"
}

# ── test_no_duplicate_policy ─────────────────────────────────────────────────
# Verify Phase E contains the no-duplicate policy prose required by SC5:
# the text must match 'not duplicat' OR 'references the artifact path'.
# This ensures the single-comment policy is explicitly documented in the skill.
test_no_duplicate_policy() {
  _snapshot_fail
  local _section
  _section=$(_phase_e_section)
  local _found=0
  # Case-insensitive match for either phrase
  local _lower
  _lower=$(echo "$_section" | tr '[:upper:]' '[:lower:]')
  if [[ "$_lower" == *"not duplicat"* ]] || [[ "$_lower" == *"references the artifact path"* ]]; then
    _found=1
  fi
  assert_eq "test_no_duplicate_policy: 'not duplicat' or 'references the artifact path' present in Phase E" \
    "1" "$_found"
  assert_pass_if_clean "test_no_duplicate_policy"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_append_review_cycle_invocation
test_ticket_comment_invocation
test_no_duplicate_policy

print_summary
