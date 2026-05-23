#!/usr/bin/env bash
# tests/scripts/test-implementation-plan-step4-remediation.sh
# RED tests: verify implementation-plan SKILL.md Step 4 declares a
# "Remediation Re-dispatch" subsection with the required contract tokens
# for re-dispatching dso:task-decomposer on Step 4 plan-reviewer findings.
#
# TDD RED phase: all seven tests FAIL until the GREEN SKILL.md task adds the
# "Remediation Re-dispatch" subsection to Step 4.
#
# Tests:
#  1. test_remediation_redispatch_heading_exists   — awk-scoped to Step 4
#                                                    section; assert the literal
#                                                    heading 'Remediation Re-dispatch'
#                                                    is present.
#  2. test_plan_reviewer_findings_trigger          — awk-scoped to Step 4
#                                                    section; assert the trigger
#                                                    condition references plan-reviewer
#                                                    findings.
#  3. test_task_decomposer_target                  — awk-scoped to Step 4
#                                                    section; assert that
#                                                    'dso:task-decomposer' is
#                                                    referenced as re-dispatch target.
#  4. test_model_opus_literal                      — awk-scoped to Step 4
#                                                    section; assert the literal
#                                                    string 'model: "opus"' is present.
#  5. test_remediation_context_with_artifact_paths — awk-scoped to Step 4
#                                                    section; assert
#                                                    'remediation_context' keyword
#                                                    is present AND mentions
#                                                    'reviewer_artifact_paths'.
#  6. test_delta_mode_preservation_clause         — awk-scoped to Step 4
#                                                    section; assert delta-mode
#                                                    preservation behavior is declared
#                                                    (grep for 'delta|DELTA|preserve.*omission').
#  7. test_sc5_single_comment_instruction          — awk-scoped to Step 4
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
# Usage: bash tests/scripts/test-implementation-plan-step4-remediation.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-step4-remediation.sh ==="
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

# ── _extract_step4_section ────────────────────────────────────────────────────
# Awk-scope the Step 4 section of implementation-plan SKILL.md — from the
# '## Step 4' line through the line before '## Step 5' or '## Step 6'.
# Mirrors the section-scoping pattern in test-implementation-plan-step2-remediation.sh.
_extract_step4_section() {
  awk '/^## Step 4/,/^## Step [56]/' "$SKILL_FILE"
}

# ── test_remediation_redispatch_heading_exists ────────────────────────────────
# Verify Step 4 contains a 'Remediation Re-dispatch' subsection heading.
# Awk-scoped so the token cannot match prose elsewhere in the file.
# RED: FAIL because Step 4 has no Remediation Re-dispatch subsection yet.
test_remediation_redispatch_heading_exists() {
  _snapshot_fail
  local _section
  _section=$(_extract_step4_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_remediation_redispatch_heading_exists: Step 4 section missing"
    return
  fi
  local _has_heading=0
  echo "$_section" | grep -qF 'Remediation Re-dispatch' && _has_heading=1
  assert_eq "test_remediation_redispatch_heading_exists: 'Remediation Re-dispatch' heading within Step 4" \
    "1" "$_has_heading"
  assert_pass_if_clean "test_remediation_redispatch_heading_exists"
}

# ── test_plan_reviewer_findings_trigger ───────────────────────────────────────
# Verify the Step 4 Remediation Re-dispatch subsection declares the trigger
# condition as plan-reviewer findings.
# Awk-scoped to Step 4.
# RED: FAIL because the subsection does not exist yet.
test_plan_reviewer_findings_trigger() {
  _snapshot_fail
  local _section
  _section=$(_extract_step4_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_plan_reviewer_findings_trigger: Step 4 section missing"
    return
  fi
  local _has_trigger=0
  echo "$_section" | grep -qE 'plan.?reviewer.*findings|findings.*plan.?reviewer|plan-reviewer findings|plan reviewer findings' && _has_trigger=1
  assert_eq "test_plan_reviewer_findings_trigger: plan-reviewer findings trigger within Step 4" \
    "1" "$_has_trigger"
  assert_pass_if_clean "test_plan_reviewer_findings_trigger"
}

# ── test_task_decomposer_target ───────────────────────────────────────────────
# Verify the Step 4 Remediation Re-dispatch subsection references
# 'dso:task-decomposer' as the re-dispatch target.
# Awk-scoped to Step 4.
# RED: FAIL because the subsection does not exist yet.
test_task_decomposer_target() {
  _snapshot_fail
  local _section
  _section=$(_extract_step4_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_task_decomposer_target: Step 4 section missing"
    return
  fi
  local _has_target=0
  echo "$_section" | grep -qF 'dso:task-decomposer' && _has_target=1
  assert_eq "test_task_decomposer_target: 'dso:task-decomposer' re-dispatch target within Step 4" \
    "1" "$_has_target"
  assert_pass_if_clean "test_task_decomposer_target"
}

# ── test_model_opus_literal ───────────────────────────────────────────────────
# Verify the Step 4 Remediation Re-dispatch subsection declares
# literal 'model: "opus"' for the re-dispatch target.
# Awk-scoped to Step 4.
# RED: FAIL because the subsection does not exist yet.
test_model_opus_literal() {
  _snapshot_fail
  local _section
  _section=$(_extract_step4_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_model_opus_literal: Step 4 section missing"
    return
  fi
  local _has_model_opus=0
  echo "$_section" | grep -qF 'model: "opus"' && _has_model_opus=1
  assert_eq "test_model_opus_literal: literal 'model: \"opus\"' within Step 4" \
    "1" "$_has_model_opus"
  assert_pass_if_clean "test_model_opus_literal"
}

# ── test_remediation_context_with_artifact_paths ──────────────────────────────
# Verify the Step 4 Remediation Re-dispatch subsection contains
# 'remediation_context' keyword AND mentions 'reviewer_artifact_paths'.
# Awk-scoped to Step 4.
# RED: FAIL because the subsection does not exist yet.
test_remediation_context_with_artifact_paths() {
  _snapshot_fail
  local _section
  _section=$(_extract_step4_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_remediation_context_with_artifact_paths: Step 4 section missing"
    return
  fi
  local _has_remediation_context=0 _has_artifact_paths=0
  echo "$_section" | grep -qF 'remediation_context' && _has_remediation_context=1
  echo "$_section" | grep -qF 'reviewer_artifact_paths' && _has_artifact_paths=1
  assert_eq "test_remediation_context_with_artifact_paths: 'remediation_context' keyword within Step 4" \
    "1" "$_has_remediation_context"
  assert_eq "test_remediation_context_with_artifact_paths: 'reviewer_artifact_paths' within Step 4" \
    "1" "$_has_artifact_paths"
  assert_pass_if_clean "test_remediation_context_with_artifact_paths"
}

# ── test_delta_mode_preservation_clause ──────────────────────────────────────
# Verify the Step 4 Remediation Re-dispatch subsection notes delta-mode
# preserve-by-omission behavior.
# Awk-scoped to Step 4.
# RED: FAIL because the subsection does not exist yet.
test_delta_mode_preservation_clause() {
  _snapshot_fail
  local _section
  _section=$(_extract_step4_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_delta_mode_preservation_clause: Step 4 section missing"
    return
  fi
  local _has_delta_clause=0
  echo "$_section" | grep -qE 'delta|DELTA|preserve.*omission' && _has_delta_clause=1
  assert_eq "test_delta_mode_preservation_clause: delta/DELTA/preserve-by-omission clause within Step 4" \
    "1" "$_has_delta_clause"
  assert_pass_if_clean "test_delta_mode_preservation_clause"
}

# ── test_sc5_single_comment_instruction ───────────────────────────────────────
# Verify the Step 4 Remediation Re-dispatch subsection ends with an
# SC5 single-comment instruction (grep for 'ticket comment' or 'SC5').
# Awk-scoped to Step 4.
# RED: FAIL because the subsection does not exist yet.
test_sc5_single_comment_instruction() {
  _snapshot_fail
  local _section
  _section=$(_extract_step4_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_sc5_single_comment_instruction: Step 4 section missing"
    return
  fi
  local _has_sc5_instruction=0
  echo "$_section" | grep -qE 'ticket comment|SC5' && _has_sc5_instruction=1
  assert_eq "test_sc5_single_comment_instruction: 'ticket comment' or 'SC5' instruction within Step 4" \
    "1" "$_has_sc5_instruction"
  assert_pass_if_clean "test_sc5_single_comment_instruction"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_remediation_redispatch_heading_exists
test_plan_reviewer_findings_trigger
test_task_decomposer_target
test_model_opus_literal
test_remediation_context_with_artifact_paths
test_delta_mode_preservation_clause
test_sc5_single_comment_instruction

print_summary
