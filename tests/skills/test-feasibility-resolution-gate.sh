#!/usr/bin/env bash
# Behavioral tests for the feasibility-resolution gate changes.
#
# INSTRUCTION DOCUMENT TESTING RATIONALE:
# Pipeline and preplanning SKILL.md are non-executable instruction documents.
# Their text constitutes the behavioral contract — the exact wording determines
# what the LLM agent will do when it reads the document. For instruction documents,
# the established testing pattern (precedent: tests/skills/test-epic-scrutiny-pipeline.sh)
# is to grep the document for the required behavioral contract terms. This is NOT
# a change-detector test against implementation internals; it is verification that
# the behavioral contract text is present. The distinction is that these documents
# ARE the interface — there is no separate "observable output" to test, because the
# output is the document content that the LLM agent ingests and follows.
#
# All 6 tests FAIL in RED state because:
#   - Pipeline line 204 currently says "spike task" not FEASIBILITY_GAP annotation
#   - Preplanning Phase 2.25 currently recommends spike-task creation
#   - brainstorm.max_feasibility_cycles key absent from dso-config.conf
#   - feasibility_cycle_count state variable not referenced in preplanning
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PIPELINE_MD="${REPO_ROOT}/plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"
PREPLANNING_MD="${REPO_ROOT}/plugins/dso/skills/preplanning/SKILL.md"
CONFIG_CONF="${REPO_ROOT}/.claude/dso-config.conf"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: Pipeline feasibility critical findings clause uses FEASIBILITY_GAP
#         annotation instead of spike recommendation
# ---------------------------------------------------------------------------
test_pipeline_feasibility_gap_annotation() {
  echo "=== test_pipeline_feasibility_gap_annotation ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check for FEASIBILITY_GAP annotation"
    return
  fi

  if grep -q "FEASIBILITY_GAP" "$PIPELINE_MD"; then
    pass "Pipeline feasibility critical findings clause uses FEASIBILITY_GAP annotation"
  else
    fail "Pipeline feasibility critical findings clause missing FEASIBILITY_GAP annotation (expected near line 204)"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: Negative constraint — pipeline feasibility critical findings clause
#         does NOT contain a spike task recommendation
# ---------------------------------------------------------------------------
test_pipeline_no_spike_recommendation() {
  echo ""
  echo "=== test_pipeline_no_spike_recommendation ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check for spike recommendation absence"
    return
  fi

  if grep -iE "recommend.*spike|spike.*task.*de.risk|recommending a spike" "$PIPELINE_MD"; then
    fail "Pipeline feasibility critical findings clause still contains spike task recommendation — must be replaced with FEASIBILITY_GAP annotation"
  else
    pass "Pipeline feasibility critical findings clause does NOT contain spike task recommendation"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: Preplanning Phase 2.25 emits REPLAN_ESCALATE: brainstorm instead of
#         recommending spike task creation for unverified capabilities
# ---------------------------------------------------------------------------
test_preplanning_replan_escalate() {
  echo ""
  echo "=== test_preplanning_replan_escalate ==="

  if [ ! -f "$PREPLANNING_MD" ]; then
    fail "Preplanning SKILL.md missing — cannot check for REPLAN_ESCALATE signal"
    return
  fi

  if grep -q "REPLAN_ESCALATE: brainstorm" "$PREPLANNING_MD"; then
    pass "Preplanning Phase 2.25 emits REPLAN_ESCALATE: brainstorm for unverified capabilities"
  else
    fail "Preplanning Phase 2.25 missing REPLAN_ESCALATE: brainstorm signal in Phase 2.25 unverified-capability branch"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: Negative constraint — preplanning Phase 2.25 does NOT recommend
#         spike-task creation for unverified capabilities
# ---------------------------------------------------------------------------
test_preplanning_no_spike_recommendation() {
  echo ""
  echo "=== test_preplanning_no_spike_recommendation ==="

  if [ ! -f "$PREPLANNING_MD" ]; then
    fail "Preplanning SKILL.md missing — cannot check for spike recommendation absence"
    return
  fi

  if grep -iE "recommend.*spike.task|spike.task.*creation|spike.task.*before.*implementation" "$PREPLANNING_MD"; then
    fail "Preplanning still recommends spike-task creation for unverified capabilities — must emit REPLAN_ESCALATE: brainstorm instead"
  else
    pass "Preplanning does NOT recommend spike-task creation for unverified capabilities"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: dso-config.conf contains brainstorm.max_feasibility_cycles key
#         with default value 2
# ---------------------------------------------------------------------------
test_config_max_feasibility_cycles() {
  echo ""
  echo "=== test_config_max_feasibility_cycles ==="

  if [ ! -f "$CONFIG_CONF" ]; then
    fail "dso-config.conf missing — cannot check for brainstorm.max_feasibility_cycles"
    return
  fi

  if grep -q "brainstorm.max_feasibility_cycles=2" "$CONFIG_CONF"; then
    pass "dso-config.conf contains brainstorm.max_feasibility_cycles=2"
  else
    fail "dso-config.conf missing brainstorm.max_feasibility_cycles=2 key (required for feasibility cycle cap)"
  fi
}

# ---------------------------------------------------------------------------
# Test 6: Preplanning references feasibility_cycle_count state variable for
#         planning-intelligence log
# ---------------------------------------------------------------------------
test_feasibility_cycle_count_exposed() {
  echo ""
  echo "=== test_feasibility_cycle_count_exposed ==="

  if [ ! -f "$PREPLANNING_MD" ]; then
    fail "Preplanning SKILL.md missing — cannot check for feasibility_cycle_count reference"
    return
  fi

  if grep -q "feasibility_cycle_count" "$PREPLANNING_MD"; then
    pass "Preplanning references feasibility_cycle_count state variable for planning-intelligence log"
  else
    fail "Preplanning missing feasibility_cycle_count state variable reference (required for planning-intelligence observability)"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_pipeline_feasibility_gap_annotation
test_pipeline_no_spike_recommendation
test_preplanning_replan_escalate
test_preplanning_no_spike_recommendation
test_config_max_feasibility_cycles
test_feasibility_cycle_count_exposed

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo "VALIDATION FAILED"
  exit 1
fi

echo "ALL VALIDATIONS PASSED"
exit 0
