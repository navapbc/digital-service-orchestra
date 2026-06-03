#!/usr/bin/env bash
# tests/scripts/test-task-decomposer-db-case.sh
# Structural-boundary suite: verify the db case of the Migration-Class Pair
# Emission section in plugins/dso/agents/task-decomposer.md declares all
# required db-case contract markers.
#
# TDD RED phase: all four tests FAIL until task ffec (sibling GREEN task)
# fills in the active db-case prose under "### Case: `db`" in task-decomposer.md.
# Each assertion targets a distinct clause of the db-case specification.
#
# Tests:
#  1. test_db_case_emits_rollback_task_pair
#        clause a: BOTH task-types present — rollback migration AND
#        rollback-verification (as distinct, named task roles).
#        Awk-scoped to the db case section only; markers elsewhere do NOT
#        satisfy this clause.
#
#  2. test_db_case_classification_tokens
#        clause b: classification tokens 'safe-revert' AND
#        'compensating-forward' present within the db section, PLUS the
#        'DATA LOSS RISK' ambiguity-default annotation.
#        Awk-scoped to the db case section only.
#
#  3. test_db_case_rollback_verification_schema_state
#        clause c: the rollback-verification done-definition asserts on
#        SCHEMA STATE (post-rollback schema assertion) — not merely
#        command exit 0. Presence of schema-state assertion wording within
#        the awk-scoped db section.
#        Awk-scoped to the db case section only.
#
#  4. test_db_case_three_task_co_authoring
#        clause d (dd-1 three-task): the db-case prose describes emitting the
#        THREE tasks (forward migration + rollback + rollback-verification) as
#        a CO-AUTHORED unit. Asserts forward-migration co-authoring wording
#        within the awk-scoped db section — so a prose edit that adds only
#        "rollback tasks alongside existing forward migrations" FAILS this
#        clause.
#        Awk-scoped to the db case section only.
#
# Section-presence hardening: every awk-scoped assertion first verifies the
# db case section header exists before scanning. An empty awk extraction emits
# `FAIL: section missing` and returns early — preventing vacuous-truth RED-pass
# and silent-GREEN on a typo'd section header. The amendment verify regex
# `grep -qE 'fail .section missing.|section missing'` matches this helper.
#
# Usage: bash tests/scripts/test-task-decomposer-db-case.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

# FAIL counter initialized to satisfy set -u
FAIL=0
PASS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
TASK_DECOMPOSER_AGENT="$DSO_PLUGIN_DIR/agents/task-decomposer.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-task-decomposer-db-case.sh ==="
echo ""

# ── _fail_section_missing ─────────────────────────────────────────────────────
# Emit a FAIL line that matches the red-zone parser and the amendment verify
# regex (grep -qE 'fail .section missing.|section missing'). Used when the
# target section header is absent — preventing vacuous-truth RED-pass.
_fail_section_missing() {
  local label="$1"
  (( ++FAIL ))
  printf "FAIL: %s\n  at: %s:%s\n  reason: section missing (target heading not found in task-decomposer.md)\n" \
    "$label" "${BASH_SOURCE[1]:-?}" "${BASH_LINENO[0]:-?}" >&2
}

# ── _extract_db_case_section ──────────────────────────────────────────────────
# Awk-scope the db case section of task-decomposer.md — from the
# "### Case: `db`" header line through the line before the next '### ' or
# '## ' heading. This ensures markers elsewhere in the file (e.g., in the
# sweep case or flag-tag case) do NOT satisfy assertions scoped to the db case.
#
# The GREEN task fills in active db-case prose under this header. Until then,
# the extracted block contains only the RESERVED placeholder text, and each
# assertion that requires active prose will FAIL.
_extract_db_case_section() {
  awk '/^### Case: `db`/{found=1} found && /^(### |## )/ && !/^### Case: `db`/{exit} found{print}' \
    "$TASK_DECOMPOSER_AGENT"
}

# ── test_db_case_emits_rollback_task_pair ─────────────────────────────────────
# clause a: Verify the db case section declares BOTH required task roles —
# 'rollback' (the migration rollback task) AND 'rollback-verification' (the
# post-rollback assertion task) — as named pair halves.
#
# Awk-scoped to the db case section only: a `rollback` mention in the sweep
# case or pairing-tag vocabulary table DOES NOT satisfy this clause.
#
# RED: FAIL because the db case contains only RESERVED placeholder text with
# no active pair emission prose.
test_db_case_emits_rollback_task_pair() {
  _snapshot_fail
  local _section
  _section=$(_extract_db_case_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_db_case_emits_rollback_task_pair: db case section missing"
    return
  fi
  # Require the machine-readable pairing-tag assignment for each pair-half
  # task draft — NOT just a mention of the role names in passing.
  # The RESERVED placeholder text says "rollback / rollback-verification roles"
  # as a description of future content; it does NOT carry the pairing-tag
  # assignment syntax that the active db prose must specify per the Pairing
  # tag rule in the Migration-Class Pair Emission section header.
  # 'migration-role:rollback' must appear as a distinct tag (not as a prefix
  # of 'migration-role:rollback-verification'). We check for it on a line
  # that does NOT contain the longer '-verification' suffix.
  local _has_rollback=0 _has_rollback_verification=0
  # grep -v filters out any line that contains 'rollback-verification',
  # leaving only lines that have 'rollback' without the longer suffix.
  if echo "$_section" | grep -v 'rollback-verification' | grep -qF 'migration-role:rollback'; then
    _has_rollback=1
  fi
  if echo "$_section" | grep -qF 'migration-role:rollback-verification'; then
    _has_rollback_verification=1
  fi
  assert_eq "test_db_case_emits_rollback_task_pair: clause a — 'migration-role:rollback' pairing tag assigned on rollback task draft within db case section" \
    "1" "$_has_rollback"
  assert_eq "test_db_case_emits_rollback_task_pair: clause a — 'migration-role:rollback-verification' pairing tag assigned on rollback-verification task draft within db case section" \
    "1" "$_has_rollback_verification"
  assert_pass_if_clean "test_db_case_emits_rollback_task_pair"
}

# ── test_db_case_classification_tokens ────────────────────────────────────────
# clause b: Verify the db case section declares the rollback-classification
# vocabulary: 'safe-revert' (for reversible rollbacks) AND
# 'compensating-forward' (for irreversible rollbacks), PLUS the
# 'DATA LOSS RISK' annotation that must accompany the ambiguity-default
# compensating-forward ruling.
#
# Awk-scoped to the db case section only: these tokens exist in other
# contexts (e.g., the sprint orchestrator) but must appear in the db case
# prose to satisfy the contract.
#
# RED: FAIL because the db case contains only RESERVED placeholder text.
test_db_case_classification_tokens() {
  _snapshot_fail
  local _section
  _section=$(_extract_db_case_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_db_case_classification_tokens: db case section missing"
    return
  fi
  local _has_safe_revert=0 _has_compensating_forward=0 _has_data_loss_risk=0
  echo "$_section" | grep -qF 'safe-revert' && _has_safe_revert=1
  echo "$_section" | grep -qF 'compensating-forward' && _has_compensating_forward=1
  echo "$_section" | grep -qF 'DATA LOSS RISK' && _has_data_loss_risk=1
  assert_eq "test_db_case_classification_tokens: clause b — 'safe-revert' classification token within db case section" \
    "1" "$_has_safe_revert"
  assert_eq "test_db_case_classification_tokens: clause b — 'compensating-forward' classification token within db case section" \
    "1" "$_has_compensating_forward"
  assert_eq "test_db_case_classification_tokens: clause b — 'DATA LOSS RISK' ambiguity-default annotation within db case section" \
    "1" "$_has_data_loss_risk"
  assert_pass_if_clean "test_db_case_classification_tokens"
}

# ── test_db_case_rollback_verification_schema_state ───────────────────────────
# clause c: Verify the rollback-verification done-definition in the db case
# section asserts on SCHEMA STATE after rollback — not merely command exit 0.
# The done-definition must include wording that expresses a post-rollback
# schema assertion (e.g., 'schema state', 'resulting schema', 'post-rollback
# schema', 'expected schema').
#
# This guards against a weaker implementation that only checks exit codes:
# a rollback can "succeed" (exit 0) while leaving the schema in an incorrect
# intermediate state. The rollback-verification task must explicitly assert
# the schema reached the intended post-rollback shape.
#
# Awk-scoped to the db case section only.
#
# RED: FAIL because the db case contains only RESERVED placeholder text.
test_db_case_rollback_verification_schema_state() {
  _snapshot_fail
  local _section
  _section=$(_extract_db_case_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_db_case_rollback_verification_schema_state: db case section missing"
    return
  fi
  local _has_schema_state_assertion=0
  echo "$_section" | grep -qiE 'schema state|resulting schema|post-rollback schema|expected schema|schema.*assert|assert.*schema' \
    && _has_schema_state_assertion=1
  assert_eq "test_db_case_rollback_verification_schema_state: clause c — rollback-verification asserts post-rollback schema state (not merely exit 0) within db case section" \
    "1" "$_has_schema_state_assertion"
  assert_pass_if_clean "test_db_case_rollback_verification_schema_state"
}

# ── test_db_case_three_task_co_authoring ──────────────────────────────────────
# clause d (dd-1 three-task): Verify the db case section describes emitting
# the THREE tasks (forward migration + rollback + rollback-verification) as a
# CO-AUTHORED unit — not merely appending rollback tasks after the fact.
#
# The co-authoring wording must reference forward-migration involvement so a
# prose edit that only says "add rollback tasks alongside existing forward
# migrations" FAILS this clause. The clause requires explicit co-authoring
# semantics: the three tasks are designed and emitted together as a unit.
#
# Asserts:
#   (a) forward-migration wording present within the db section (so the
#       three-task unit is named), AND
#   (b) co-authoring / same-plan wording present within the db section
#       (so the tasks are named as jointly authored, not sequentially added).
#
# Awk-scoped to the db case section only.
#
# RED: FAIL because the db case contains only RESERVED placeholder text.
test_db_case_three_task_co_authoring() {
  _snapshot_fail
  local _section
  _section=$(_extract_db_case_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_db_case_three_task_co_authoring: db case section missing"
    return
  fi
  local _has_forward_migration=0 _has_co_authored=0
  echo "$_section" | grep -qiE 'forward.migration|forward migration' && _has_forward_migration=1
  echo "$_section" | grep -qiE 'co-author|co author|three-task|triple|same plan|unit of three|three tasks' && _has_co_authored=1
  assert_eq "test_db_case_three_task_co_authoring: clause d — forward-migration wording present within db case section (three-task unit named)" \
    "1" "$_has_forward_migration"
  assert_eq "test_db_case_three_task_co_authoring: clause d — co-authoring/three-task wording present within db case section (forward+rollback+verification emitted as a unit)" \
    "1" "$_has_co_authored"
  assert_pass_if_clean "test_db_case_three_task_co_authoring"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_db_case_emits_rollback_task_pair
test_db_case_classification_tokens
test_db_case_rollback_verification_schema_state
test_db_case_three_task_co_authoring

print_summary
