#!/usr/bin/env bash
# tests/scripts/test-implementation-plan-step2-remediation.sh
# RED tests: verify implementation-plan SKILL.md Step 2 declares a
# "Remediation Re-dispatch" subsection with the required contract tokens
# for re-dispatching dso:approach-proposer on Step 2 FAIL verdict.
#
# TDD RED phase: all seven tests FAIL until the GREEN SKILL.md task adds the
# "Remediation Re-dispatch" subsection to Step 2.
#
# Tests:
#  1. test_remediation_redispatch_heading_exists   — awk-scoped to Step 2
#                                                    section; assert the literal
#                                                    heading 'Remediation Re-dispatch'
#                                                    is present.
#  2. test_model_opus_literal                      — awk-scoped to Step 2
#                                                    section; assert the literal
#                                                    string 'model: "opus"' is present.
#  3. test_approach_proposer_target                — awk-scoped to Step 2
#                                                    section; assert that
#                                                    'dso:approach-proposer' is
#                                                    referenced as re-dispatch target.
#  4. test_remediation_context_with_absolute_paths — awk-scoped to Step 2
#                                                    section; assert
#                                                    'remediation_context' keyword
#                                                    is present AND mentions
#                                                    absolute paths or 'by reference'.
#  5. test_mode_remediation_declared               — awk-scoped to Step 2
#                                                    section; assert
#                                                    'mode: remediation' (or
#                                                    'mode:remediation') is present.
#  6. test_evidence_quote_anchor                   — awk-scoped to Step 2
#                                                    section; assert an evidence-quote
#                                                    anchor ('evidence quote' or
#                                                    'evidence_quotes') is present.
#  7. test_sc5_single_comment_instruction          — awk-scoped to Step 2
#                                                    section; assert the SC5
#                                                    single-comment instruction
#                                                    ('ticket comment' or 'SC5')
#                                                    is present.
#
# Section-presence hardening: every awk-scoped assertion first verifies the
# target section header exists before scanning. An empty awk extraction emits
# `FAIL: section missing` and returns early — preventing vacuous-truth RED-pass
# and silent-GREEN on typo'd section headers.
#
# Usage: bash tests/scripts/test-implementation-plan-step2-remediation.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-step2-remediation.sh ==="
echo ""

# ── _fail_section_missing ─────────────────────────────────────────────────────
# Emit a FAIL line that matches the red-zone parser. Used when the target
# section header is absent — preventing vacuous-truth RED-pass.
_fail_section_missing() {
  local label="$1"
  (( ++FAIL ))
  printf "FAIL: %s\n  at: %s:%s\n  reason: section missing (target heading not found in SKILL.md)\n" \
    "$label" "${BASH_SOURCE[1]:-?}" "${BASH_LINENO[0]:-?}" >&2
}

# ── _extract_step2_section ────────────────────────────────────────────────────
# Awk-scope the Step 2 section of implementation-plan SKILL.md — from the
# '## Step 2' line through the line before '## Step 3'. Mirrors the
# section-scoping pattern in test-approach-proposer-remediation.sh.
_extract_step2_section() {
  awk '/^## Step 2/,/^## Step 3/' "$SKILL_FILE"
}

# ── test_remediation_redispatch_heading_exists ────────────────────────────────
# Verify Step 2 contains a 'Remediation Re-dispatch' subsection heading.
# Awk-scoped so the token cannot match prose elsewhere in the file.
# RED: FAIL because Step 2 has no Remediation Re-dispatch subsection yet.
test_remediation_redispatch_heading_exists() {
  _snapshot_fail
  local _section
  _section=$(_extract_step2_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_remediation_redispatch_heading_exists: Step 2 section missing"
    return
  fi
  local _has_heading=0
  echo "$_section" | grep -qF 'Remediation Re-dispatch' && _has_heading=1
  assert_eq "test_remediation_redispatch_heading_exists: 'Remediation Re-dispatch' heading within Step 2" \
    "1" "$_has_heading"
  assert_pass_if_clean "test_remediation_redispatch_heading_exists"
}

# ── test_model_opus_literal ───────────────────────────────────────────────────
# Verify the Step 2 Remediation Re-dispatch subsection declares
# literal 'model: "opus"' for the re-dispatch target.
# Awk-scoped to Step 2.
# RED: FAIL because the subsection does not exist yet.
test_model_opus_literal() {
  _snapshot_fail
  local _section
  _section=$(_extract_step2_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_model_opus_literal: Step 2 section missing"
    return
  fi
  local _has_model_opus=0
  echo "$_section" | grep -qF 'model: "opus"' && _has_model_opus=1
  assert_eq "test_model_opus_literal: literal 'model: \"opus\"' within Step 2" \
    "1" "$_has_model_opus"
  assert_pass_if_clean "test_model_opus_literal"
}

# ── test_approach_proposer_target ─────────────────────────────────────────────
# Verify the Step 2 Remediation Re-dispatch subsection references
# 'dso:approach-proposer' as the re-dispatch target.
# Awk-scoped to Step 2.
# RED: FAIL because the subsection does not exist yet.
test_approach_proposer_target() {
  _snapshot_fail
  local _section
  _section=$(_extract_step2_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_approach_proposer_target: Step 2 section missing"
    return
  fi
  local _has_target=0
  echo "$_section" | grep -qF 'dso:approach-proposer' && _has_target=1
  assert_eq "test_approach_proposer_target: 'dso:approach-proposer' re-dispatch target within Step 2" \
    "1" "$_has_target"
  assert_pass_if_clean "test_approach_proposer_target"
}

# ── test_remediation_context_with_absolute_paths ──────────────────────────────
# Verify the Step 2 Remediation Re-dispatch subsection contains
# 'remediation_context' keyword AND mentions absolute paths or 'by reference'.
# Awk-scoped to Step 2.
# RED: FAIL because the subsection does not exist yet.
test_remediation_context_with_absolute_paths() {
  _snapshot_fail
  local _section
  _section=$(_extract_step2_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_remediation_context_with_absolute_paths: Step 2 section missing"
    return
  fi
  local _has_remediation_context=0 _has_absolute_ref=0
  echo "$_section" | grep -qF 'remediation_context' && _has_remediation_context=1
  echo "$_section" | grep -qE 'absolute (file )?path|by reference' && _has_absolute_ref=1
  assert_eq "test_remediation_context_with_absolute_paths: 'remediation_context' keyword within Step 2" \
    "1" "$_has_remediation_context"
  assert_eq "test_remediation_context_with_absolute_paths: 'absolute path' or 'by reference' within Step 2" \
    "1" "$_has_absolute_ref"
  assert_pass_if_clean "test_remediation_context_with_absolute_paths"
}

# ── test_mode_remediation_declared ────────────────────────────────────────────
# Verify the Step 2 Remediation Re-dispatch subsection declares
# 'mode: remediation' on the dispatch payload.
# Awk-scoped to Step 2.
# RED: FAIL because the subsection does not exist yet.
test_mode_remediation_declared() {
  _snapshot_fail
  local _section
  _section=$(_extract_step2_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_mode_remediation_declared: Step 2 section missing"
    return
  fi
  local _has_mode_remediation=0
  echo "$_section" | grep -qE 'mode:[[:space:]]*remediation' && _has_mode_remediation=1
  assert_eq "test_mode_remediation_declared: 'mode: remediation' within Step 2" \
    "1" "$_has_mode_remediation"
  assert_pass_if_clean "test_mode_remediation_declared"
}

# ── test_evidence_quote_anchor ────────────────────────────────────────────────
# Verify the Step 2 Remediation Re-dispatch subsection contains an
# evidence-quote anchor ('evidence quote' or 'evidence_quotes').
# Awk-scoped to Step 2.
# RED: FAIL because the subsection does not exist yet.
test_evidence_quote_anchor() {
  _snapshot_fail
  local _section
  _section=$(_extract_step2_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_evidence_quote_anchor: Step 2 section missing"
    return
  fi
  local _has_evidence_anchor=0
  echo "$_section" | grep -qE 'evidence.?quote[s]?' && _has_evidence_anchor=1
  assert_eq "test_evidence_quote_anchor: 'evidence quote' or 'evidence_quotes' anchor within Step 2" \
    "1" "$_has_evidence_anchor"
  assert_pass_if_clean "test_evidence_quote_anchor"
}

# ── test_sc5_single_comment_instruction ───────────────────────────────────────
# Verify the Step 2 Remediation Re-dispatch subsection ends with an
# SC5 single-comment instruction (grep for 'ticket comment' or 'SC5').
# Awk-scoped to Step 2.
# RED: FAIL because the subsection does not exist yet.
test_sc5_single_comment_instruction() {
  _snapshot_fail
  local _section
  _section=$(_extract_step2_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_sc5_single_comment_instruction: Step 2 section missing"
    return
  fi
  local _has_sc5_instruction=0
  echo "$_section" | grep -qE 'ticket comment|SC5' && _has_sc5_instruction=1
  assert_eq "test_sc5_single_comment_instruction: 'ticket comment' or 'SC5' instruction within Step 2" \
    "1" "$_has_sc5_instruction"
  assert_pass_if_clean "test_sc5_single_comment_instruction"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_remediation_redispatch_heading_exists
test_model_opus_literal
test_approach_proposer_target
test_remediation_context_with_absolute_paths
test_mode_remediation_declared
test_evidence_quote_anchor
test_sc5_single_comment_instruction

print_summary
