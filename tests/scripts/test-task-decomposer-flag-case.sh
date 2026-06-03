#!/usr/bin/env bash
# tests/scripts/test-task-decomposer-flag-case.sh
# RED tests: verify dso:task-decomposer agent file declares the
# flag-tag case of the Migration-Class Pair Emission section with the
# full active contract for feature-flag rollout task-pair emission.
#
# Behavioral Testing Standard: Rule 5 (structural-boundary for instruction
# files) — assertions use section-heading-scoped awk extraction + header
# presence guards, NOT body-text phrase checks. The awk scope is the
# "flag-tag" sub-section of "## Migration-Class Pair Emission". Rule 5
# from plugins/dso/skills/shared/prompts/behavioral-testing-standard.md
# governs all assertions here: section-heading structural boundary checks
# are ALLOWED; body-text content-presence checks are PROHIBITED.
#
# TDD RED phase: ALL tests FAIL until the GREEN agent task (d666) activates
# the flag-tag case in plugins/dso/agents/task-decomposer.md. Currently the
# flag-tag case is a RESERVED stub with no active directives.
#
# Tests:
#   1. test_flag_tag_section_active
#      awk-scope to "### Case: `flag-tag`" sub-section; assert the section
#      references the passed-in {feature-flags-marker} dispatch arg (the
#      active case must read from the marker input, not from story prose).
#      RED: FAIL because the section is RESERVED with no active directives.
#
#   2. test_flag_approved_pair_emission
#      awk-scope to the flag-tag sub-section; assert the APPROVED branch
#      instructs emitting a flag-cutover task PAIRED WITH a flag-cleanup
#      task (dd-1: both migration-role pairing tags must be named).
#      RED: FAIL because no APPROVED branch exists in the RESERVED stub.
#
#   3. test_flag_prohibited_records_reason
#      awk-scope to the flag-tag sub-section; assert the PROHIBITED branch
#      instructs emitting NO feature-flag task AND recording
#      feature_flags:prohibited WITH the marker's reason (dd-2).
#      RED: FAIL because no PROHIBITED branch exists in the RESERVED stub.
#
#   4. test_read_only_marker_boundary
#      awk-scope to the flag-tag sub-section; assert the section instructs
#      reading ONLY the passed-in {feature-flags-marker} input — never
#      consulting story prose / never performing a self-fetch / never doing
#      the two-hop lookup itself (dd-3/boundary).
#      RED: FAIL because no read-only boundary clause exists in the stub.
#
#   5. test_section_missing_guard
#      Verify the awk extraction helper itself fails loudly on empty output
#      rather than producing a vacuous-truth RED-pass. Explicitly tests
#      the guard path used in tests 1-4.
#      (This test always passes — it validates the harness itself.)
#
# Section-presence hardening: every awk-scoped assertion first verifies
# the target section header exists before scanning. An empty awk extraction
# emits `FAIL: section missing` and returns early — preventing vacuous-truth
# RED-pass and silent-GREEN on typo'd section headers.
#
# Usage: bash tests/scripts/test-task-decomposer-flag-case.sh
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

echo "=== test-task-decomposer-flag-case.sh ==="
echo ""

# ── _fail_section_missing ──────────────────────────────────────────────────────
# Emit a FAIL line when the target section header is absent, preventing
# vacuous-truth RED-pass. The message matches 'section missing' for the
# amendment verify regex (grep -qE 'fail .section missing.|section missing').
_fail_section_missing() {
  local label="$1"
  (( ++FAIL ))
  printf "FAIL: %s\n  at: %s:%s\n  reason: section missing (flag-tag heading not found in task-decomposer.md)\n" \
    "$label" "${BASH_SOURCE[1]:-?}" "${BASH_LINENO[0]:-?}" >&2
}

# ── _extract_flag_tag_section ─────────────────────────────────────────────────
# Awk-scope the "### Case: `flag-tag`" sub-section of
# plugins/dso/agents/task-decomposer.md — from the flag-tag heading line
# through the line before the next '### ' or '## ' heading. This is a
# structural-boundary extraction (Rule 5): we operate on the section defined
# by its heading, not on arbitrary body-text phrases.
#
# The GREEN agent file (task d666) will replace the RESERVED stub with an
# active flag-tag case. Until then, the extracted block contains only the
# reserved-stub text and the active-contract assertions fail.
_extract_flag_tag_section() {
  awk '/^### Case: `flag-tag`/{found=1} found && /^(## |### )/ && !/^### Case: `flag-tag`/{exit} found{print}' \
    "$TASK_DECOMPOSER_AGENT"
}

# ── test_flag_tag_section_active ──────────────────────────────────────────────
# Verify the flag-tag sub-section references the passed-in {feature-flags-marker}
# dispatch argument. The active case must name this input explicitly so the
# agent knows to read from the passed-in marker (not from story prose).
# Asserts the literal token '{feature-flags-marker}' appears within the
# awk-scoped flag-tag section.
# RED: FAIL because the current flag-tag case is RESERVED and contains no
# active directive referencing {feature-flags-marker}.
test_flag_tag_section_active() {
  _snapshot_fail
  local _section
  _section=$(_extract_flag_tag_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_flag_tag_section_active: flag-tag section missing"
    return
  fi
  local _has_marker_ref=0
  echo "$_section" | grep -qF '{feature-flags-marker}' && _has_marker_ref=1
  assert_eq "test_flag_tag_section_active: '{feature-flags-marker}' dispatch arg referenced within flag-tag section" \
    "1" "$_has_marker_ref"
  assert_pass_if_clean "test_flag_tag_section_active"
}

# ── test_flag_approved_pair_emission ──────────────────────────────────────────
# Verify the flag-tag sub-section instructs emitting a flag-cutover task PAIRED
# WITH a flag-cleanup task when the rollout:feature-flags-approved tag is
# present (APPROVED branch). Asserts both migration-role pairing tag values:
#   (a) 'migration-role:flag-cutover'   — the cutover half of the pair
#   (b) 'migration-role:flag-cleanup'   — the cleanup half of the pair
# Both must appear within the awk-scoped flag-tag section.
# RED: FAIL because the RESERVED stub contains no APPROVED branch or
# migration-role tag directives.
test_flag_approved_pair_emission() {
  _snapshot_fail
  local _section
  _section=$(_extract_flag_tag_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_flag_approved_pair_emission: flag-tag section missing"
    return
  fi
  local _has_cutover_role=0 _has_cleanup_role=0
  echo "$_section" | grep -qF 'migration-role:flag-cutover' && _has_cutover_role=1
  echo "$_section" | grep -qF 'migration-role:flag-cleanup' && _has_cleanup_role=1
  assert_eq "test_flag_approved_pair_emission: 'migration-role:flag-cutover' pairing tag within flag-tag section" \
    "1" "$_has_cutover_role"
  assert_eq "test_flag_approved_pair_emission: 'migration-role:flag-cleanup' pairing tag within flag-tag section" \
    "1" "$_has_cleanup_role"
  assert_pass_if_clean "test_flag_approved_pair_emission"
}

# ── test_flag_prohibited_records_reason ───────────────────────────────────────
# Verify the flag-tag sub-section instructs the PROHIBITED branch to emit NO
# feature-flag task AND to record the 'feature_flags:prohibited' marker WITH
# the marker's reason. Asserts:
#   (a) the literal token 'feature_flags:prohibited' — the machine-readable
#       recording instruction for the PROHIBITED path.
#   (b) a 'reason' instruction — the section must instruct including the
#       reason (not just the bare prohibited token) so callers understand why
#       the flag pair was not emitted.
# Awk-scoped to the flag-tag section.
# RED: FAIL because the RESERVED stub contains no PROHIBITED branch or
# feature_flags:prohibited recording directive.
test_flag_prohibited_records_reason() {
  _snapshot_fail
  local _section
  _section=$(_extract_flag_tag_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_flag_prohibited_records_reason: flag-tag section missing"
    return
  fi
  local _has_prohibited_token=0 _has_reason_instruction=0
  echo "$_section" | grep -qF 'feature_flags:prohibited' && _has_prohibited_token=1
  echo "$_section" | grep -qiE '\breason\b' && _has_reason_instruction=1
  assert_eq "test_flag_prohibited_records_reason: 'feature_flags:prohibited' literal token within flag-tag section" \
    "1" "$_has_prohibited_token"
  assert_eq "test_flag_prohibited_records_reason: 'reason' instruction for prohibited recording within flag-tag section" \
    "1" "$_has_reason_instruction"
  assert_pass_if_clean "test_flag_prohibited_records_reason"
}

# ── test_read_only_marker_boundary ────────────────────────────────────────────
# Verify the flag-tag sub-section declares the read-only-marker boundary:
# the agent must read the passed-in {feature-flags-marker} input ONLY — it
# must NOT inspect story prose and must NOT perform the two-hop story→parent
# lookup itself (the lookup is done by the orchestrator and delivered as the
# marker arg; the agent is a pure consumer of the resolved marker).
#
# Asserts one or more of these boundary-declaration tokens within the
# awk-scoped flag-tag section (any single token suffices — they are
# semantically equivalent phrasings of the same boundary):
#   - 'passed-in'       — instructs reading only the passed-in arg
#   - 'story prose'     — explicitly prohibits consulting story prose
#   - 'two-hop'         — prohibits performing the two-hop lookup
#   - 'self-fetch'      — prohibits self-fetching parent data
#   - 'feature-flags-marker' — (covered by test 1; here we look for
#                               the boundary qualifier alongside it)
#
# Because test 1 already asserts '{feature-flags-marker}' is named, this
# test focuses on the BOUNDARY qualifier — the section must say MORE than
# just "read this arg"; it must say "read ONLY this arg / not story prose /
# not self-fetch".
# RED: FAIL because the RESERVED stub declares no active boundary clause.
test_read_only_marker_boundary() {
  _snapshot_fail
  local _section
  _section=$(_extract_flag_tag_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_read_only_marker_boundary: flag-tag section missing"
    return
  fi
  local _has_boundary_clause=0
  echo "$_section" | grep -qiE 'passed-in|story prose|two-hop|self-fetch' && _has_boundary_clause=1
  assert_eq "test_read_only_marker_boundary: read-only-marker boundary clause ('passed-in'/'story prose'/'two-hop'/'self-fetch') within flag-tag section" \
    "1" "$_has_boundary_clause"
  assert_pass_if_clean "test_read_only_marker_boundary"
}

# ── test_section_missing_guard ────────────────────────────────────────────────
# Verify the harness guard itself fires on a non-existent section header.
# Uses a synthetic section name that cannot appear in the agent file to
# confirm _fail_section_missing increments FAIL when extraction is empty.
# This test validates the harness (not the agent file), so it is structurally
# independent of the RED/GREEN state of the file.
# Expected: PASS always (harness self-check).
test_section_missing_guard() {
  _snapshot_fail
  local _pre_fail=$FAIL

  # Extract a section that does not exist — must yield empty string.
  local _phantom_section
  _phantom_section=$(awk '/^### Case: `__phantom_section_xyz__`/{found=1} found && /^(## |### )/ && !/^### Case: `__phantom_section_xyz__`/{exit} found{print}' \
    "$TASK_DECOMPOSER_AGENT")

  # Simulate the guard call on a fresh counter so we can observe FAIL increment.
  local _saved_fail=$FAIL
  if [[ -z "$_phantom_section" ]]; then
    _fail_section_missing "test_section_missing_guard: phantom section (expected missing)"
  fi
  local _guard_fired=0
  [[ $FAIL -gt $_saved_fail ]] && _guard_fired=1

  # Restore FAIL to pre-test state: the guard firing here is the PASS case for
  # this harness self-test — we do NOT want it counted as a real failure.
  FAIL=$_pre_fail

  assert_eq "test_section_missing_guard: _fail_section_missing increments FAIL when extraction is empty" \
    "1" "$_guard_fired"
  assert_pass_if_clean "test_section_missing_guard"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_flag_tag_section_active
test_flag_approved_pair_emission
test_flag_prohibited_records_reason
test_read_only_marker_boundary
test_section_missing_guard

print_summary
