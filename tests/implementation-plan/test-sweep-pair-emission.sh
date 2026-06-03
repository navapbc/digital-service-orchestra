#!/usr/bin/env bash
# tests/implementation-plan/test-sweep-pair-emission.sh
# STRUCTURAL BOUNDARY TEST (behavioral-testing-standard Rule 5): verify
# plugins/dso/agents/task-decomposer.md declares the "Migration-Class Pair
# Emission" contract section with all required contract markers.
#
# These are section-heading and structural-boundary assertions — they verify
# required contract structure exists in the producer artifact, not body-text
# phrasing. Per Rule 5, section-heading and key token checks against a
# non-executable LLM instruction file are the accepted structural boundary.
#
# TDD RED phase: all tests FAIL until the GREEN task (71e4) adds the
# "Migration-Class Pair Emission" section to task-decomposer.md.
#
# LITMUS (regression contract): reverting the GREEN task's prompt edit MUST
# return this suite to RED. The section absent => suite exits non-zero.
#
# Tests:
#  1. test_migration_class_pair_emission_section_exists
#     — "## Migration-Class Pair Emission" heading present (dispatch-point marker)
#  2. test_per_class_dispatch_keying
#     — section contains a per-class dispatch case keyed on migration-class
#  3. test_automated_sweep_and_manual_verification_tokens
#     — both reserved task-type tokens present: automated-sweep AND manual-verification
#  4. test_transform_descriptor_distinct_from_detection_query
#     — transform_descriptor AND detection_query both named separately (distinct tokens)
#  5. test_recipe_preferred_agent_fallback_encoded
#     — recipe task_type + recipe_id on registry match; agent-sweep fallback (code task_type)
#  6. test_mv_done_def_clause_a_zero_remaining_sites
#     — manual-verification done-def clause (a): re-run detection query AND assert zero remaining sites
#  7. test_mv_done_def_clause_b_un_automatable_sites
#     — clause (b): un_automatable_sites recorded as inline TODO(migration) markers
#  8. test_mv_done_def_clause_c_test_gate_passes
#     — clause (c): test gate must pass over the modified files
#  9. test_db_flag_tag_reserved_headers_present
#     — db AND flag-tag reserved headers present (named as reserved, not active)
# 10. test_migration_marker_placeholder_in_inputs
#     — Inputs section declares {migration-marker} placeholder (consumption mechanism)
# 11. test_parse_from_passed_in_arg_not_ticket
#     — Migration-Class Pair Emission section instructs parsing migration-class from
#       the PASSED-IN arg, never fetching from the ticket
# 12. test_skill_passes_migration_marker_to_task_args
#     — SKILL.md Step 3 'Pass the following as task arguments' list includes
#       {migration-marker} sourced from the LAST MIGRATION_CLASS: comment
# 13. test_inconclusive_branch_specified
#     — inconclusive migration-class branch defined distinctly (not silently dropped)
# 14. test_absent_unparseable_inert_noop
#     — absent/unparseable marker => inert no-op (no pair emitted, backward compat)
# 15. test_inconclusive_surfaces_decomposition_notes
#     — inconclusive branch instructs decomposition_notes entry (detection unavailable)
#
# Section-presence hardening: every awk-scoped assertion first verifies the
# target section header exists before scanning. An empty awk extraction emits
# FAIL: <label> and returns early — preventing vacuous-truth RED-pass from a
# typo'd section header.
#
# Usage: bash tests/implementation-plan/test-sweep-pair-emission.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

FAIL=0
PASS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TASK_DECOMPOSER_AGENT="$REPO_ROOT/plugins/dso/agents/task-decomposer.md"
IMPLEMENTATION_PLAN_SKILL="$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sweep-pair-emission.sh ==="
echo ""

# ── _fail_section_missing ─────────────────────────────────────────────────────
# Emit a FAIL line that matches the red-zone parser. Used when the target
# section header is absent — preventing vacuous-truth RED-pass.
_fail_section_missing() {
  local label="$1"
  (( ++FAIL ))
  printf "FAIL: %s\n  at: %s:%s\n  reason: section missing (target heading not found in task-decomposer.md)\n" \
    "$label" "${BASH_SOURCE[1]:-?}" "${BASH_LINENO[0]:-?}" >&2
}

# ── _extract_sweep_pair_section ───────────────────────────────────────────────
# Awk-scope the "Migration-Class Pair Emission" section of task-decomposer.md
# — from the section header line through the line before the next '## ' heading.
_extract_sweep_pair_section() {
  awk '/^## Migration-Class Pair Emission/{found=1} found && /^## / && !/^## Migration-Class Pair Emission/{exit} found{print}' \
    "$TASK_DECOMPOSER_AGENT"
}

# ── _extract_inputs_section ───────────────────────────────────────────────────
# Awk-scope the "## Inputs" section of task-decomposer.md.
_extract_inputs_section() {
  awk '/^## Inputs/{found=1} found && /^## / && !/^## Inputs/{exit} found{print}' \
    "$TASK_DECOMPOSER_AGENT"
}

# ── test_migration_class_pair_emission_section_exists ─────────────────────────
# Assert "## Migration-Class Pair Emission" heading is present in
# task-decomposer.md — the dispatch-point marker for the contract.
# RED: FAIL because the section does not yet exist.
test_migration_class_pair_emission_section_exists() {
  _snapshot_fail
  local _has_heading=0
  grep -qF '## Migration-Class Pair Emission' "$TASK_DECOMPOSER_AGENT" && _has_heading=1
  assert_eq "test_migration_class_pair_emission_section_exists: '## Migration-Class Pair Emission' heading present" \
    "1" "$_has_heading"
  assert_pass_if_clean "test_migration_class_pair_emission_section_exists"
}

# ── test_per_class_dispatch_keying ────────────────────────────────────────────
# Assert the section contains a per-class dispatch case keyed on migration-class
# (the dispatch point is parametric, not a hardcoded one-shot path).
# RED: FAIL because the section does not yet exist.
test_per_class_dispatch_keying() {
  _snapshot_fail
  local _section
  _section=$(_extract_sweep_pair_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_per_class_dispatch_keying: Migration-Class Pair Emission section missing"
    return
  fi
  local _has_per_class=0
  echo "$_section" | grep -qiE 'migration.class|migration_class' && _has_per_class=1
  assert_eq "test_per_class_dispatch_keying: migration-class dispatch key present within section" \
    "1" "$_has_per_class"
  assert_pass_if_clean "test_per_class_dispatch_keying"
}

# ── test_automated_sweep_and_manual_verification_tokens ───────────────────────
# Assert both reserved task-type namespace tokens appear in the section:
#   automated-sweep AND manual-verification.
# RED: FAIL because the section does not yet exist.
test_automated_sweep_and_manual_verification_tokens() {
  _snapshot_fail
  local _section
  _section=$(_extract_sweep_pair_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_automated_sweep_and_manual_verification_tokens: Migration-Class Pair Emission section missing"
    return
  fi
  local _has_automated_sweep=0 _has_manual_verification=0
  echo "$_section" | grep -qF 'automated-sweep' && _has_automated_sweep=1
  echo "$_section" | grep -qF 'manual-verification' && _has_manual_verification=1
  assert_eq "test_automated_sweep_and_manual_verification_tokens: 'automated-sweep' token within section" \
    "1" "$_has_automated_sweep"
  assert_eq "test_automated_sweep_and_manual_verification_tokens: 'manual-verification' token within section" \
    "1" "$_has_manual_verification"
  assert_pass_if_clean "test_automated_sweep_and_manual_verification_tokens"
}

# ── test_transform_descriptor_distinct_from_detection_query ───────────────────
# Assert both transform_descriptor AND detection_query appear as separately
# named tokens within the section (they must be distinct, not aliased).
# RED: FAIL because the section does not yet exist.
test_transform_descriptor_distinct_from_detection_query() {
  _snapshot_fail
  local _section
  _section=$(_extract_sweep_pair_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_transform_descriptor_distinct_from_detection_query: Migration-Class Pair Emission section missing"
    return
  fi
  local _has_transform_descriptor=0 _has_detection_query=0
  echo "$_section" | grep -qF 'transform_descriptor' && _has_transform_descriptor=1
  echo "$_section" | grep -qF 'detection_query' && _has_detection_query=1
  assert_eq "test_transform_descriptor_distinct_from_detection_query: 'transform_descriptor' token within section" \
    "1" "$_has_transform_descriptor"
  assert_eq "test_transform_descriptor_distinct_from_detection_query: 'detection_query' token distinct and present within section" \
    "1" "$_has_detection_query"
  assert_pass_if_clean "test_transform_descriptor_distinct_from_detection_query"
}

# ── test_recipe_preferred_agent_fallback_encoded ──────────────────────────────
# Assert the automated-sweep case specifies recipe-preferred / agent-sweep
# fallback encoding:
#   (a) recipe task_type + recipe_id on registry match (recipe preferred path)
#   (b) code task_type with the agent-sweep token OR reference to
#       translate-recipe-to-llm-task.sh (agent-sweep fallback path)
# RED: FAIL because the section does not yet exist.
test_recipe_preferred_agent_fallback_encoded() {
  _snapshot_fail
  local _section
  _section=$(_extract_sweep_pair_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_recipe_preferred_agent_fallback_encoded: Migration-Class Pair Emission section missing"
    return
  fi
  local _has_recipe_type=0 _has_agent_fallback=0
  # recipe preferred: recipe task_type or recipe_id
  echo "$_section" | grep -qE 'recipe.*task.type|task.type.*recipe|recipe_id' && _has_recipe_type=1
  # agent fallback: agent-sweep token or translate-recipe-to-llm-task reference
  echo "$_section" | grep -qE 'agent-sweep|translate-recipe-to-llm-task' && _has_agent_fallback=1
  assert_eq "test_recipe_preferred_agent_fallback_encoded: recipe task_type / recipe_id token within section" \
    "1" "$_has_recipe_type"
  assert_eq "test_recipe_preferred_agent_fallback_encoded: agent-sweep fallback token (or translate-recipe-to-llm-task ref) within section" \
    "1" "$_has_agent_fallback"
  assert_pass_if_clean "test_recipe_preferred_agent_fallback_encoded"
}

# ── test_mv_done_def_clause_a_zero_remaining_sites ────────────────────────────
# Assert the manual-verification done-definition specifies clause (a):
# re-run the detection query AND assert zero remaining sites.
# Asserts tokens: 'detection_query' AND a zero-remaining-sites phrasing.
# RED: FAIL because the section does not yet exist.
test_mv_done_def_clause_a_zero_remaining_sites() {
  _snapshot_fail
  local _section
  _section=$(_extract_sweep_pair_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_mv_done_def_clause_a_zero_remaining_sites: Migration-Class Pair Emission section missing"
    return
  fi
  local _has_detection_query=0 _has_zero_remaining=0
  echo "$_section" | grep -qF 'detection_query' && _has_detection_query=1
  echo "$_section" | grep -qiE 'zero.*(remaining|result|match|site)|remaining.*(zero|0)|assert.*zero' && _has_zero_remaining=1
  assert_eq "test_mv_done_def_clause_a_zero_remaining_sites: 'detection_query' re-run clause within section" \
    "1" "$_has_detection_query"
  assert_eq "test_mv_done_def_clause_a_zero_remaining_sites: zero remaining sites assertion clause within section" \
    "1" "$_has_zero_remaining"
  assert_pass_if_clean "test_mv_done_def_clause_a_zero_remaining_sites"
}

# ── test_mv_done_def_clause_b_un_automatable_sites ────────────────────────────
# Assert the manual-verification done-definition specifies clause (b):
# un-automatable sites recorded as inline TODO(migration) markers enumerated
# in an un_automatable_sites field.
# RED: FAIL because the section does not yet exist.
test_mv_done_def_clause_b_un_automatable_sites() {
  _snapshot_fail
  local _section
  _section=$(_extract_sweep_pair_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_mv_done_def_clause_b_un_automatable_sites: Migration-Class Pair Emission section missing"
    return
  fi
  local _has_un_automatable=0 _has_todo_migration=0
  echo "$_section" | grep -qF 'un_automatable_sites' && _has_un_automatable=1
  echo "$_section" | grep -qF 'TODO(migration)' && _has_todo_migration=1
  assert_eq "test_mv_done_def_clause_b_un_automatable_sites: 'un_automatable_sites' field token within section" \
    "1" "$_has_un_automatable"
  assert_eq "test_mv_done_def_clause_b_un_automatable_sites: 'TODO(migration)' inline marker token within section" \
    "1" "$_has_todo_migration"
  assert_pass_if_clean "test_mv_done_def_clause_b_un_automatable_sites"
}

# ── test_mv_done_def_clause_c_test_gate_passes ────────────────────────────────
# Assert the manual-verification done-definition specifies clause (c):
# the test gate must pass over the modified files (zero detection count
# WITHOUT a passing test gate is NOT complete).
# RED: FAIL because the section does not yet exist.
test_mv_done_def_clause_c_test_gate_passes() {
  _snapshot_fail
  local _section
  _section=$(_extract_sweep_pair_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_mv_done_def_clause_c_test_gate_passes: Migration-Class Pair Emission section missing"
    return
  fi
  local _has_test_gate=0
  echo "$_section" | grep -qiE 'test.gate' && _has_test_gate=1
  assert_eq "test_mv_done_def_clause_c_test_gate_passes: test-gate clause present within section" \
    "1" "$_has_test_gate"
  assert_pass_if_clean "test_mv_done_def_clause_c_test_gate_passes"
}

# ── test_db_flag_tag_reserved_headers_present ─────────────────────────────────
# Assert db AND flag-tag reserved headers are present in the section,
# named as RESERVED (not active dispatch cases).
# RED: FAIL because the section does not yet exist.
test_db_flag_tag_reserved_headers_present() {
  _snapshot_fail
  local _section
  _section=$(_extract_sweep_pair_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_db_flag_tag_reserved_headers_present: Migration-Class Pair Emission section missing"
    return
  fi
  local _has_db=0 _has_flag_tag=0
  echo "$_section" | grep -qiE '\bdb\b' && _has_db=1
  echo "$_section" | grep -qF 'flag-tag' && _has_flag_tag=1
  assert_eq "test_db_flag_tag_reserved_headers_present: 'db' reserved header token within section" \
    "1" "$_has_db"
  assert_eq "test_db_flag_tag_reserved_headers_present: 'flag-tag' reserved header token within section" \
    "1" "$_has_flag_tag"
  assert_pass_if_clean "test_db_flag_tag_reserved_headers_present"
}

# ── test_migration_marker_placeholder_in_inputs ───────────────────────────────
# Assert the Inputs section declares a {migration-marker} placeholder, so
# the marker arrives as a verbatim passed-in input block (like {testing-mode}
# or {selected-approach}) — the consumption mechanism contract.
# RED: FAIL because the {migration-marker} placeholder has not been added yet.
test_migration_marker_placeholder_in_inputs() {
  _snapshot_fail
  local _inputs_section
  _inputs_section=$(_extract_inputs_section)
  if [[ -z "$_inputs_section" ]]; then
    _fail_section_missing "test_migration_marker_placeholder_in_inputs: Inputs section missing"
    return
  fi
  local _has_migration_marker=0
  echo "$_inputs_section" | grep -qF 'migration-marker' && _has_migration_marker=1
  assert_eq "test_migration_marker_placeholder_in_inputs: '{migration-marker}' placeholder in Inputs section" \
    "1" "$_has_migration_marker"
  assert_pass_if_clean "test_migration_marker_placeholder_in_inputs"
}

# ── test_parse_from_passed_in_arg_not_ticket ──────────────────────────────────
# Assert the Migration-Class Pair Emission section instructs parsing
# migration-class from the PASSED-IN argument, NOT by fetching from the ticket.
# RED: FAIL because the section does not yet exist.
test_parse_from_passed_in_arg_not_ticket() {
  _snapshot_fail
  local _section
  _section=$(_extract_sweep_pair_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_parse_from_passed_in_arg_not_ticket: Migration-Class Pair Emission section missing"
    return
  fi
  # The section should instruct parsing from the passed-in block AND must NOT
  # instruct fetching from the ticket.
  local _has_passed_in=0 _fetches_from_ticket=0
  echo "$_section" | grep -qiE 'passed.in|{migration-marker}|input block' && _has_passed_in=1
  # Check for explicit anti-pattern — instructions to fetch from the ticket
  echo "$_section" | grep -qiE 'fetch.*ticket|ticket.*fetch|dso ticket show|ticket show' && _fetches_from_ticket=1
  assert_eq "test_parse_from_passed_in_arg_not_ticket: migration-class parsed from passed-in arg (not ticket)" \
    "1" "$_has_passed_in"
  assert_eq "test_parse_from_passed_in_arg_not_ticket: no ticket-fetch instruction (must be 0 occurrences)" \
    "0" "$_fetches_from_ticket"
  assert_pass_if_clean "test_parse_from_passed_in_arg_not_ticket"
}

# ── test_skill_passes_migration_marker_to_task_args ───────────────────────────
# Assert the implementation-plan SKILL.md Step 3 "Pass the following as task
# arguments" list includes a {migration-marker} bullet sourced from the LAST
# MIGRATION_CLASS: comment on the story.
# RED: FAIL because the SKILL.md has not been updated yet.
test_skill_passes_migration_marker_to_task_args() {
  _snapshot_fail
  if [[ ! -f "$IMPLEMENTATION_PLAN_SKILL" ]]; then
    _fail_section_missing "test_skill_passes_migration_marker_to_task_args: implementation-plan SKILL.md not found"
    return
  fi
  local _has_migration_marker=0
  grep -qF 'migration-marker' "$IMPLEMENTATION_PLAN_SKILL" && _has_migration_marker=1
  assert_eq "test_skill_passes_migration_marker_to_task_args: 'migration-marker' in implementation-plan SKILL.md task arguments" \
    "1" "$_has_migration_marker"
  assert_pass_if_clean "test_skill_passes_migration_marker_to_task_args"
}

# ── test_inconclusive_branch_specified ────────────────────────────────────────
# Assert the Migration-Class Pair Emission section specifies the inconclusive
# branch as a distinct named action (not silently dropped). When migration-class
# is inconclusive, the section must NOT emit the sweep pair AND must surface
# a decomposition_notes entry stating detection was unavailable.
# RED: FAIL because the section does not yet exist.
test_inconclusive_branch_specified() {
  _snapshot_fail
  local _section
  _section=$(_extract_sweep_pair_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_inconclusive_branch_specified: Migration-Class Pair Emission section missing"
    return
  fi
  local _has_inconclusive=0
  echo "$_section" | grep -qiE 'inconclusive' && _has_inconclusive=1
  assert_eq "test_inconclusive_branch_specified: 'inconclusive' branch named within section" \
    "1" "$_has_inconclusive"
  assert_pass_if_clean "test_inconclusive_branch_specified"
}

# ── test_absent_unparseable_inert_noop ────────────────────────────────────────
# Assert the Migration-Class Pair Emission section specifies that an absent or
# unparseable marker results in an inert no-op (no pair emitted), preserving
# backward compatibility.
# RED: FAIL because the section does not yet exist.
test_absent_unparseable_inert_noop() {
  _snapshot_fail
  local _section
  _section=$(_extract_sweep_pair_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_absent_unparseable_inert_noop: Migration-Class Pair Emission section missing"
    return
  fi
  local _has_absent_noop=0
  # Accept: absent, unparseable, no-op, inert, backward compat, omit
  echo "$_section" | grep -qiE 'absent|unparseable|no.op|inert|backward.compat' && _has_absent_noop=1
  assert_eq "test_absent_unparseable_inert_noop: absent/unparseable marker => inert no-op clause within section" \
    "1" "$_has_absent_noop"
  assert_pass_if_clean "test_absent_unparseable_inert_noop"
}

# ── test_inconclusive_surfaces_decomposition_notes ────────────────────────────
# Assert the section specifies that the inconclusive branch surfaces a
# decomposition_notes entry indicating detection was unavailable.
# RED: FAIL because the section does not yet exist.
test_inconclusive_surfaces_decomposition_notes() {
  _snapshot_fail
  local _section
  _section=$(_extract_sweep_pair_section)
  if [[ -z "$_section" ]]; then
    _fail_section_missing "test_inconclusive_surfaces_decomposition_notes: Migration-Class Pair Emission section missing"
    return
  fi
  local _has_decomp_notes=0
  echo "$_section" | grep -qF 'decomposition_notes' && _has_decomp_notes=1
  assert_eq "test_inconclusive_surfaces_decomposition_notes: 'decomposition_notes' entry for inconclusive branch within section" \
    "1" "$_has_decomp_notes"
  assert_pass_if_clean "test_inconclusive_surfaces_decomposition_notes"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_migration_class_pair_emission_section_exists
test_per_class_dispatch_keying
test_automated_sweep_and_manual_verification_tokens
test_transform_descriptor_distinct_from_detection_query
test_recipe_preferred_agent_fallback_encoded
test_mv_done_def_clause_a_zero_remaining_sites
test_mv_done_def_clause_b_un_automatable_sites
test_mv_done_def_clause_c_test_gate_passes
test_db_flag_tag_reserved_headers_present
test_migration_marker_placeholder_in_inputs
test_parse_from_passed_in_arg_not_ticket
test_skill_passes_migration_marker_to_task_args
test_inconclusive_branch_specified
test_absent_unparseable_inert_noop
test_inconclusive_surfaces_decomposition_notes

print_summary
