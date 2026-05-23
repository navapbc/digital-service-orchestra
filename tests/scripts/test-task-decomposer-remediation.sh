#!/usr/bin/env bash
# tests/scripts/test-task-decomposer-remediation.sh
# RED tests: verify dso:task-decomposer agent file declares the
# `remediation_context` input contract used by implementation-plan
# resolution cycles so the decomposer can emit a delta-only response
# while preserving the per-task TDD-ordering invariants.
#
# TDD RED phase: all six tests FAIL until the GREEN agent task
# (c84c-0d7d-4e68-4e61) adds the DELTA OUTPUT MODE section + Inputs entry
# to task-decomposer.md.
#
# Tests:
#  1. test_delta_output_mode_section_exists   — awk-scoped to "DELTA OUTPUT MODE"
#                                                section; assert the literal
#                                                token '=== DELTA OUTPUT MODE ==='
#                                                is present.
#  2. test_evidence_read_gate_required        — awk-scoped to the section;
#                                                assert the literal prefix
#                                                'EVIDENCE FROM' AND an
#                                                instruction phrase like
#                                                'Read each absolute' or
#                                                'pre-generation Read'.
#  3. test_preserve_by_omission_rule          — awk-scoped to the section;
#                                                assert a preservation-by-omission
#                                                directive (a 'preserve' verb
#                                                AND one of 'not named in any finding',
#                                                'omit unchanged', or 'unchanged proposals').
#  4. test_tdd_schema_preservation_clause     — awk-scoped to the section;
#                                                assert the inline TDD-preservation
#                                                rule references all three
#                                                invariant tokens: 'RED-before-GREEN',
#                                                'depends_on', and a testing-mode
#                                                token (matches 'testing.mode' so
#                                                either 'testing-mode' or
#                                                'testing_mode' wording is accepted).
#  5. test_target_story_id_filter_declared    — awk-scoped to the section;
#                                                assert 'target_story_id' AND
#                                                a filtering directive
#                                                (e.g., 'emit only',
#                                                'absent from output',
#                                                'not in that set'). Mirrors
#                                                the analog test in
#                                                test-approach-proposer-remediation.sh
#                                                so the producer-pair contract
#                                                is verified symmetrically.
#  6. test_backward_compat_default            — assert the Inputs section names
#                                                'remediation_context' AND
#                                                marks it optional (narrowed
#                                                to a 3-line window after the
#                                                field declaration to avoid
#                                                vacuous match on unrelated
#                                                '(optional)' headings); assert
#                                                pre-change output shape
#                                                ('task_drafts' field heading
#                                                still present).
#
# Section-presence hardening: every awk-scoped assertion first verifies
# the target section header exists before scanning. An empty awk extraction
# emits `FAIL: section missing` and returns early — preventing vacuous-truth
# RED-pass and silent-GREEN on typo'd section headers. The amendment regex
# `grep -qE 'fail .section missing.|section missing'` matches this helper.
#
# Usage: bash tests/scripts/test-task-decomposer-remediation.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

# FAIL counter initialized to satisfy set -u (PR #288 review finding)
FAIL=0
PASS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
TASK_DECOMPOSER_AGENT="$DSO_PLUGIN_DIR/agents/task-decomposer.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-task-decomposer-remediation.sh ==="
echo ""

# ── _fail_section_missing ─────────────────────────────────────────────────────
# Emit a FAIL line that matches the red-zone parser and the amendment
# verify regex (grep -qE 'fail .section missing.|section missing'). Used when
# the target section header is absent — preventing vacuous-truth RED-pass.
_fail_section_missing() {
  local label="$1"
  (( ++FAIL ))
  printf "FAIL: %s\n  at: %s:%s\n  reason: section missing (target heading not found in task-decomposer.md)\n" \
    "$label" "${BASH_SOURCE[1]:-?}" "${BASH_LINENO[0]:-?}" >&2
}

# ── _extract_delta_section ────────────────────────────────────────────────────
# Awk-scope the "DELTA OUTPUT MODE" section of task-decomposer.md — from the
# section header line through the line before the next '## ' heading. Mirrors
# the section-scoping pattern in test-story-decomposer-remediation.sh and
# test-approach-proposer-remediation.sh.
#
# The future GREEN agent file will add a top-level section beginning with
# '## DELTA OUTPUT MODE'. Until then, the extracted block is empty and the
# `_fail_section_missing` helper records the absence.
_extract_delta_section() {
  awk '/^## DELTA OUTPUT MODE/{found=1} found && /^## / && !/^## DELTA OUTPUT MODE/{exit} found{print}' \
    "$TASK_DECOMPOSER_AGENT"
}

# ── _extract_inputs_section ───────────────────────────────────────────────────
# Awk-scope the Inputs section (## Inputs) of task-decomposer.md.
_extract_inputs_section() {
  awk '/^## Inputs/{found=1} found && /^## / && !/^## Inputs/{exit} found{print}' \
    "$TASK_DECOMPOSER_AGENT"
}

# ── test_delta_output_mode_section_exists ─────────────────────────────────────
# Verify task-decomposer.md contains a DELTA OUTPUT MODE section with the
# literal token '=== DELTA OUTPUT MODE ==='. Awk-scoped so the token cannot
# match pre-existing prose elsewhere in the agent file.
# RED: FAIL because the agent file has no DELTA OUTPUT MODE section yet.
test_delta_output_mode_section_exists() {
  _snapshot_fail
  local _section
  _section=$(_extract_delta_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_delta_output_mode_section_exists: DELTA OUTPUT MODE section missing"
    return
  fi
  local _has_token=0
  echo "$_section" | grep -qF '=== DELTA OUTPUT MODE ===' && _has_token=1
  assert_eq "test_delta_output_mode_section_exists: '=== DELTA OUTPUT MODE ===' literal token within section" \
    "1" "$_has_token"
  assert_pass_if_clean "test_delta_output_mode_section_exists"
}

# ── test_evidence_read_gate_required ──────────────────────────────────────────
# Verify the DELTA OUTPUT MODE section requires reading the reviewer artifact
# before drafting. Asserts:
#   (a) the literal prefix 'EVIDENCE FROM' (used to mark per-finding evidence
#       blocks the agent must include in its output), AND
#   (b) an instruction phrase enforcing pre-generation Read of the absolute
#       artifact path (one of: 'Read each absolute' OR 'pre-generation Read').
# Awk-scoped to the section.
# RED: FAIL because the section does not exist yet.
test_evidence_read_gate_required() {
  _snapshot_fail
  local _section
  _section=$(_extract_delta_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_evidence_read_gate_required: DELTA OUTPUT MODE section missing"
    return
  fi
  local _has_evidence_prefix=0 _has_read_instruction=0
  echo "$_section" | grep -qF 'EVIDENCE FROM' && _has_evidence_prefix=1
  echo "$_section" | grep -qE 'Read each absolute|pre-generation Read' && _has_read_instruction=1
  assert_eq "test_evidence_read_gate_required: 'EVIDENCE FROM' literal prefix within DELTA OUTPUT MODE section" \
    "1" "$_has_evidence_prefix"
  assert_eq "test_evidence_read_gate_required: 'Read each absolute' or 'pre-generation Read' instruction within section" \
    "1" "$_has_read_instruction"
  assert_pass_if_clean "test_evidence_read_gate_required"
}

# ── test_preserve_by_omission_rule ────────────────────────────────────────────
# Verify the DELTA OUTPUT MODE section declares the preserve-by-omission
# semantic — task_drafts not named in any finding are preserved by being
# omitted from the delta (caller treats absent items as unchanged). Asserts:
#   (a) a preservation verb ('preserve' or 'preserved'), AND
#   (b) one of the standard preservation phrasings: 'not named in any finding',
#       'omit unchanged', or 'unchanged proposals'.
# Awk-scoped to the section.
# RED: FAIL because the section does not exist yet.
test_preserve_by_omission_rule() {
  _snapshot_fail
  local _section
  _section=$(_extract_delta_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_preserve_by_omission_rule: DELTA OUTPUT MODE section missing"
    return
  fi
  local _has_preserve_verb=0 _has_omission_phrasing=0
  echo "$_section" | grep -qiE 'preserve' && _has_preserve_verb=1
  echo "$_section" | grep -qE 'not named in any finding|omit unchanged|unchanged proposals' && _has_omission_phrasing=1
  assert_eq "test_preserve_by_omission_rule: preservation verb ('preserve') within DELTA OUTPUT MODE section" \
    "1" "$_has_preserve_verb"
  assert_eq "test_preserve_by_omission_rule: preservation-by-omission phrasing ('not named in any finding' / 'omit unchanged' / 'unchanged proposals') within section" \
    "1" "$_has_omission_phrasing"
  assert_pass_if_clean "test_preserve_by_omission_rule"
}

# ── test_tdd_schema_preservation_clause ───────────────────────────────────────
# Verify the DELTA OUTPUT MODE section declares the inline TDD-preservation
# rule that protects per-task TDD invariants when emitting a delta. Asserts
# all three invariant tokens appear within the section:
#   (a) 'RED-before-GREEN' — the dependency-ordering invariant the sprint
#       router and review gate rely on.
#   (b) 'depends_on'       — the task-graph link that encodes RED→GREEN.
#   (c) a testing-mode token (regex 'testing.mode' matches either
#       'testing-mode' or 'testing_mode' phrasing) — the per-task
#       RED/GREEN/UPDATE classification the sprint router routes on.
# Awk-scoped to the section so the tokens cannot match pre-existing prose
# elsewhere in the agent file (e.g., the existing `### Testing Mode` Inputs
# sub-heading, which is unrelated to delta-mode preservation).
# RED: FAIL because the section does not exist yet.
test_tdd_schema_preservation_clause() {
  _snapshot_fail
  local _section
  _section=$(_extract_delta_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_tdd_schema_preservation_clause: DELTA OUTPUT MODE section missing"
    return
  fi
  local _has_red_before_green=0 _has_depends_on=0 _has_testing_mode=0
  echo "$_section" | grep -qF 'RED-before-GREEN' && _has_red_before_green=1
  echo "$_section" | grep -qF 'depends_on' && _has_depends_on=1
  echo "$_section" | grep -qE 'testing.mode' && _has_testing_mode=1
  assert_eq "test_tdd_schema_preservation_clause: 'RED-before-GREEN' token within DELTA OUTPUT MODE section" \
    "1" "$_has_red_before_green"
  assert_eq "test_tdd_schema_preservation_clause: 'depends_on' token within DELTA OUTPUT MODE section" \
    "1" "$_has_depends_on"
  assert_eq "test_tdd_schema_preservation_clause: testing-mode token (matches 'testing.mode') within DELTA OUTPUT MODE section" \
    "1" "$_has_testing_mode"
  assert_pass_if_clean "test_tdd_schema_preservation_clause"
}

# ── test_target_story_id_filter_declared ──────────────────────────────────────
# Verify the DELTA OUTPUT MODE section declares the target_story_id allow-list
# semantic and a filtering directive. Asserts:
#   (a) the literal token 'target_story_id', AND
#   (b) a filtering directive (one of: 'emit only', 'absent from output',
#       'not in that set').
# Awk-scoped to the section. Mirrors the analog test in
# tests/scripts/test-approach-proposer-remediation.sh so the producer-pair
# contract (proposer → decomposer) is verified symmetrically: the fixture at
# tests/fixtures/task-decomposer/remediation-context-sample.json carries a
# target_story_id and the GREEN agent must scope its delta to it.
# RED: FAIL because the section does not exist yet.
test_target_story_id_filter_declared() {
  _snapshot_fail
  local _section
  _section=$(_extract_delta_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_target_story_id_filter_declared: DELTA OUTPUT MODE section missing"
    return
  fi
  local _has_target_id=0 _has_filter_directive=0
  echo "$_section" | grep -qF 'target_story_id' && _has_target_id=1
  echo "$_section" | grep -qE 'emit only|absent from output|not in that set' && _has_filter_directive=1
  assert_eq "test_target_story_id_filter_declared: 'target_story_id' literal within DELTA OUTPUT MODE section" \
    "1" "$_has_target_id"
  assert_eq "test_target_story_id_filter_declared: filtering directive ('emit only' / 'absent from output' / 'not in that set') within section" \
    "1" "$_has_filter_directive"
  assert_pass_if_clean "test_target_story_id_filter_declared"
}

# ── test_backward_compat_default ──────────────────────────────────────────────
# Verify the Inputs section declares `remediation_context` AND marks it
# optional, so callers that omit it still get the pre-change output shape.
# Also assert the pre-change output shape is preserved — `task_drafts` field
# heading must still be present in the agent file (anywhere).
# Section-existence guard: the Inputs section already exists today, but we
# verify presence first to keep the assertion symmetry with the other tests.
# RED: FAIL because Inputs has no `remediation_context` entry yet.
test_backward_compat_default() {
  _snapshot_fail
  local _inputs_section
  _inputs_section=$(_extract_inputs_section)
  if [[ -z "$_inputs_section" ]]; then
    _fail_section_missing "test_backward_compat_default: Inputs section missing"
    return
  fi
  local _has_remediation_context=0 _has_optional_marker=0 _has_task_drafts=0
  echo "$_inputs_section" | grep -qF 'remediation_context' && _has_remediation_context=1
  # Narrow the optional-marker check to the 3-line window starting at the
  # line that names 'remediation_context'. This prevents a vacuous-truth
  # pass from any unrelated '(optional)' heading elsewhere in the Inputs
  # section. Accept any common optional-marker phrasing on the field's line
  # or the two lines immediately below it.
  local _remediation_window
  _remediation_window=$(echo "$_inputs_section" | grep -A2 -m1 'remediation_context')
  echo "$_remediation_window" | grep -qiE 'optional' && _has_optional_marker=1
  # Pre-change output shape: the 'task_drafts' field heading remains anywhere
  # in the agent file (Output Format JSON block or Field Definitions table).
  grep -qF 'task_drafts' "$TASK_DECOMPOSER_AGENT" && _has_task_drafts=1
  assert_eq "test_backward_compat_default: 'remediation_context' named within Inputs section" \
    "1" "$_has_remediation_context"
  assert_eq "test_backward_compat_default: 'optional' marker for remediation_context within Inputs section" \
    "1" "$_has_optional_marker"
  assert_eq "test_backward_compat_default: 'task_drafts' output-shape field still present in agent file" \
    "1" "$_has_task_drafts"
  assert_pass_if_clean "test_backward_compat_default"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_delta_output_mode_section_exists
test_evidence_read_gate_required
test_preserve_by_omission_rule
test_tdd_schema_preservation_clause
test_target_story_id_filter_declared
test_backward_compat_default

print_summary
