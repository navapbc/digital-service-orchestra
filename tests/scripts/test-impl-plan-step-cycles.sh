#!/usr/bin/env bash
# tests/scripts/test-impl-plan-step-cycles.sh
# Behavioral fixture: verify implementation-plan/SKILL.md Steps 2, 4, and 6
# each contain append_review_cycle.py invocation and ticket comment after append,
# and that the whole file contains the SC5 single-comment policy prose.
#
# Tests (7 total):
#  1. test_step2_append_review_cycle    — Step 2 section contains append_review_cycle.py
#  2. test_step2_ticket_comment         — Step 2 section contains 'ticket comment' after append
#  3. test_step4_append_review_cycle    — Step 4 section contains append_review_cycle.py
#  4. test_step4_ticket_comment         — Step 4 section contains 'ticket comment' after append
#  5. test_step6_append_review_cycle    — Step 6 section contains append_review_cycle.py
#  6. test_step6_ticket_comment         — Step 6 section contains 'ticket comment' after append
#  7. test_sc5_policy_not_duplicate     — whole file: grep for 'not duplicat|references the artifact path'
#
# Section scoping uses awk to extract each step region, preventing false
# positives from unrelated content elsewhere in the file.
#
# Usage: bash tests/scripts/test-impl-plan-step-cycles.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-impl-plan-step-cycles.sh ==="
echo ""

# ── Section extractors ────────────────────────────────────────────────────────
# Each extractor scopes output to the named step heading through the next
# same-level '## ' heading, preventing false positives from other sections.

_step2_section() {
  awk '/^## Step 2:/{found=1} found && /^## / && !/^## Step 2:/{exit} found{print}' "$SKILL_FILE"
}

_step4_section() {
  awk '/^## Step 4:/{found=1} found && /^## / && !/^## Step 4:/{exit} found{print}' "$SKILL_FILE"
}

_step6_section() {
  awk '/^## Step 6:/{found=1} found && /^## / && !/^## Step 6:/{exit} found{print}' "$SKILL_FILE"
}

# ── _fail_section_missing ─────────────────────────────────────────────────────
_fail_section_missing() {
  local label="$1"
  (( ++FAIL ))
  printf "FAIL: %s\n  at: %s:%s\n  reason: section missing (target heading not found in SKILL.md)\n" \
    "$label" "${BASH_SOURCE[1]:-?}" "${BASH_LINENO[0]:-?}" >&2
}

# ── Step 2 tests ──────────────────────────────────────────────────────────────

test_step2_append_review_cycle() {
  _snapshot_fail
  local _section
  _section=$(_step2_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_step2_append_review_cycle: Step 2 section missing"
    return
  fi
  local _found=0
  echo "$_section" | grep -qF 'append_review_cycle.py' && _found=1
  assert_eq "test_step2_append_review_cycle: 'append_review_cycle.py' invocation within Step 2" \
    "1" "$_found"
  assert_pass_if_clean "test_step2_append_review_cycle"
}

test_step2_ticket_comment() {
  _snapshot_fail
  local _section
  _section=$(_step2_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_step2_ticket_comment: Step 2 section missing"
    return
  fi
  local _found=0
  echo "$_section" | grep -qE 'ticket comment' && _found=1
  assert_eq "test_step2_ticket_comment: 'ticket comment' invocation within Step 2" \
    "1" "$_found"
  assert_pass_if_clean "test_step2_ticket_comment"
}

# ── Step 4 tests ──────────────────────────────────────────────────────────────

test_step4_append_review_cycle() {
  _snapshot_fail
  local _section
  _section=$(_step4_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_step4_append_review_cycle: Step 4 section missing"
    return
  fi
  local _found=0
  echo "$_section" | grep -qF 'append_review_cycle.py' && _found=1
  assert_eq "test_step4_append_review_cycle: 'append_review_cycle.py' invocation within Step 4" \
    "1" "$_found"
  assert_pass_if_clean "test_step4_append_review_cycle"
}

test_step4_ticket_comment() {
  _snapshot_fail
  local _section
  _section=$(_step4_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_step4_ticket_comment: Step 4 section missing"
    return
  fi
  local _found=0
  echo "$_section" | grep -qE 'ticket comment' && _found=1
  assert_eq "test_step4_ticket_comment: 'ticket comment' invocation within Step 4" \
    "1" "$_found"
  assert_pass_if_clean "test_step4_ticket_comment"
}

# ── Step 6 tests ──────────────────────────────────────────────────────────────

test_step6_append_review_cycle() {
  _snapshot_fail
  local _section
  _section=$(_step6_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_step6_append_review_cycle: Step 6 section missing"
    return
  fi
  local _found=0
  echo "$_section" | grep -qF 'append_review_cycle.py' && _found=1
  assert_eq "test_step6_append_review_cycle: 'append_review_cycle.py' invocation within Step 6" \
    "1" "$_found"
  assert_pass_if_clean "test_step6_append_review_cycle"
}

test_step6_ticket_comment() {
  _snapshot_fail
  local _section
  _section=$(_step6_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_step6_ticket_comment: Step 6 section missing"
    return
  fi
  local _found=0
  echo "$_section" | grep -qE 'ticket comment' && _found=1
  assert_eq "test_step6_ticket_comment: 'ticket comment' invocation within Step 6" \
    "1" "$_found"
  assert_pass_if_clean "test_step6_ticket_comment"
}

# ── SC5 policy test (whole-file) ──────────────────────────────────────────────

test_sc5_policy_not_duplicate() {
  _snapshot_fail
  local _found=0
  grep -qiE 'not duplicat|references the artifact path' "$SKILL_FILE" && _found=1
  assert_eq "test_sc5_policy_not_duplicate: SC5 'not duplicat|references the artifact path' present in SKILL.md" \
    "1" "$_found"
  assert_pass_if_clean "test_sc5_policy_not_duplicate"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "--- Step 2: append_review_cycle.py + ticket comment ---"
test_step2_append_review_cycle
test_step2_ticket_comment

echo ""
echo "--- Step 4: append_review_cycle.py + ticket comment ---"
test_step4_append_review_cycle
test_step4_ticket_comment

echo ""
echo "--- Step 6: append_review_cycle.py + ticket comment ---"
test_step6_append_review_cycle
test_step6_ticket_comment

echo ""
echo "--- SC5 single-comment policy (whole file) ---"
test_sc5_policy_not_duplicate

print_summary
