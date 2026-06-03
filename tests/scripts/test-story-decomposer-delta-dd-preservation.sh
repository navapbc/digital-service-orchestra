#!/usr/bin/env bash
# tests/scripts/test-story-decomposer-delta-dd-preservation.sh
# RED tests: verify DD-superset preservation rules are present across three
# instruction files touched by bug a957-1724-f1a7-4728.
#
# TDD RED phase: all three tests FAIL until the GREEN edits add the DD-superset
# preservation rule to story-decomposer.md DELTA OUTPUT MODE section, the
# explicit carry-forward merge instruction to phase-e-adversarial-review.md
# Step 4 #5, and the Schema Preservation — story-decomposer sub-section to
# remediation-loop-protocol.md.
#
# Tests:
#  1. test_delta_section_superset_language     — awk-scoped to DELTA OUTPUT MODE
#     section of story-decomposer.md; assert 'superset' OR 'preserve' language
#     is present in that section (the DD-superset preservation rule).
#  2. test_delta_section_not_named_exclusion   — awk-scoped to DELTA OUTPUT MODE
#     section of story-decomposer.md; assert 'not explicitly named' OR
#     'not named in any finding' OR 'no finding addresses' language is present
#     (the exclusion condition for omitting a prior DD).
#  3. test_phase_e_consume_carry_forward       — awk-scoped to the Step 4 #5
#     consume block in phase-e-adversarial-review.md; assert 'carry' OR
#     'carried forward' OR 'carry-forward' language is present (the merge
#     instruction).
#
# Section-presence hardening: every awk-scoped assertion first verifies the
# target section header exists before scanning. An empty awk extraction emits
# `FAIL: section missing` and returns early — preventing vacuous-truth RED-pass
# on typo'd section headers.
#
# Usage: bash tests/scripts/test-story-decomposer-delta-dd-preservation.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

FAIL=0
PASS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
STORY_DECOMPOSER_AGENT="$DSO_PLUGIN_DIR/agents/story-decomposer.md"
PHASE_E_PROMPT="$DSO_PLUGIN_DIR/skills/preplanning/prompts/phase-e-adversarial-review.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-story-decomposer-delta-dd-preservation.sh ==="
echo ""

# ── _fail_section_missing ─────────────────────────────────────────────────────
_fail_section_missing() {
  local label="$1"
  (( ++FAIL ))
  printf "FAIL: %s\n  at: %s:%s\n  reason: section missing (target heading not found)\n" \
    "$label" "${BASH_SOURCE[1]:-?}" "${BASH_LINENO[0]:-?}" >&2
}

# ── _extract_delta_section ────────────────────────────────────────────────────
# Awk-scope the "DELTA OUTPUT MODE" section of story-decomposer.md.
_extract_delta_section() {
  awk '/^## DELTA OUTPUT MODE/{found=1} found && /^## / && !/^## DELTA OUTPUT MODE/{exit} found{print}' \
    "$STORY_DECOMPOSER_AGENT"
}

# ── _extract_phase_e_step4 ────────────────────────────────────────────────────
# Awk-scope Step 4 of phase-e-adversarial-review.md (from the Step 4 heading
# through the line before Step 5).
_extract_phase_e_step4() {
  awk '/^## Step 4:/{found=1} found && /^## Step 5:/{exit} found{print}' \
    "$PHASE_E_PROMPT"
}

# ── test_delta_section_superset_language ──────────────────────────────────────
# Verify the DELTA OUTPUT MODE section of story-decomposer.md contains
# DD-superset preservation language: the word 'superset' OR 'preserve' (in the
# context of done_definitions / DDs).
# RED: FAIL until the GREEN edit adds the preservation rule.
test_delta_section_superset_language() {
  _snapshot_fail
  local _section
  _section=$(_extract_delta_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_delta_section_superset_language: DELTA OUTPUT MODE section missing"
    return
  fi
  local _has_superset_or_preserve=0
  echo "$_section" | grep -qiE 'superset|preserve' && _has_superset_or_preserve=1
  assert_eq "test_delta_section_superset_language: 'superset' or 'preserve' language in DELTA OUTPUT MODE section" \
    "1" "$_has_superset_or_preserve"
  assert_pass_if_clean "test_delta_section_superset_language"
}

# ── test_delta_section_not_named_exclusion ────────────────────────────────────
# Verify the DELTA OUTPUT MODE section of story-decomposer.md contains the
# exclusion condition that links DD omission to the finding set: 'not explicitly
# named' OR 'not named in any finding' OR 'no finding addresses'.
# RED: FAIL until the GREEN edit adds the rule.
test_delta_section_not_named_exclusion() {
  _snapshot_fail
  local _section
  _section=$(_extract_delta_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_delta_section_not_named_exclusion: DELTA OUTPUT MODE section missing"
    return
  fi
  local _has_exclusion=0
  echo "$_section" | grep -qE 'not explicitly named|not named in any finding|no finding addresses' \
    && _has_exclusion=1
  assert_eq "test_delta_section_not_named_exclusion: exclusion condition ('not explicitly named' / 'not named in any finding' / 'no finding addresses') in DELTA OUTPUT MODE section" \
    "1" "$_has_exclusion"
  assert_pass_if_clean "test_delta_section_not_named_exclusion"
}

# ── test_phase_e_consume_carry_forward ────────────────────────────────────────
# Verify Step 4 of phase-e-adversarial-review.md contains explicit carry-forward
# merge language: 'carry' OR 'carried forward' OR 'carry-forward'.
# RED: FAIL until the GREEN edit replaces the vague "Consume the delta only" line
# with the explicit merge instruction.
test_phase_e_consume_carry_forward() {
  _snapshot_fail
  local _section
  _section=$(_extract_phase_e_step4)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_phase_e_consume_carry_forward: Step 4 section missing from phase-e-adversarial-review.md"
    return
  fi
  local _has_carry_forward=0
  echo "$_section" | grep -qiE 'carry.forward|carried forward|carry forward' && _has_carry_forward=1
  assert_eq "test_phase_e_consume_carry_forward: carry-forward merge language in Phase E Step 4" \
    "1" "$_has_carry_forward"
  assert_pass_if_clean "test_phase_e_consume_carry_forward"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_delta_section_superset_language
test_delta_section_not_named_exclusion
test_phase_e_consume_carry_forward

print_summary
