#!/usr/bin/env bash
# tests/skills/test-brainstorm-ux-probe-loop.sh
# Integration regression test for the brainstorm UX probe loop (SC8, epic fdeb-4c03).
#
# Follows codebase convention: structural SKILL.md corpus assertions (behavioral-testing-standard Rule 5).
# The test simulates a brainstorm run on seed "add a benefits-status dashboard for claimants"
# by asserting the SKILL.md corpus contains all the instructions required for:
#   (a) Surface dimension in Understanding Summary
#   (b) All three UX probes asked during Phase 1
#   (c) Probe answers stored in a structured location in the ticket
#
# The haiku classifier stub (BRAINSTORM_UI_CLASSIFIER_STUB=ui) is verified by asserting
# the env var interface is documented in the corpus — consistent with S2's mockable interface.
#
# Seed: "add a benefits-status dashboard for claimants"
# This seed does NOT pre-answer interaction criticality, non-happy-path state coverage,
# or flow entry/exit — so S4's anti-redundancy directive will not suppress any probe.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
source "${REPO_ROOT}/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_MD=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ============================================================
echo "=== test_classifier_stub_interface ==="
SECTION="test_classifier_stub_interface"

# BRAINSTORM_UI_CLASSIFIER_STUB documented — this is the mockable interface from S2
if grep -qiE 'BRAINSTORM_UI_CLASSIFIER_STUB' "$SKILL_MD"; then
  pass "SKILL corpus documents BRAINSTORM_UI_CLASSIFIER_STUB classifier stub interface"
else
  fail "SKILL corpus missing BRAINSTORM_UI_CLASSIFIER_STUB classifier stub interface (required by S2)"
fi

# ============================================================
echo ""
echo "=== test_surface_dimension_in_understanding_summary ==="
SECTION="test_surface_dimension_in_understanding_summary"

# Surface field in Understanding Summary schema (from S1 and progressive-validation story)
if grep -qE 'Surface:|Surface\*\*:|(\*\*Surface\*\*)' "$SKILL_MD"; then
  pass "SKILL corpus contains Surface field in Understanding Summary schema"
else
  fail "SKILL corpus missing Surface field in Understanding Summary schema"
fi

# Surface row in Phase 1 Step 2 probe table
if grep -q '| Surface |' "$SKILL_MD"; then
  pass "SKILL corpus contains Surface row in Phase 1 Step 2 probe table"
else
  fail "SKILL corpus missing Surface row in Phase 1 Step 2 probe table"
fi

# ============================================================
echo ""
echo "=== test_all_three_ux_probes_defined ==="
SECTION="test_all_three_ux_probes_defined"

# All 3 probe dimension IDs from ux-probe-set.md must be present.
# SKILL.md uses short-form IDs (criticality, non_happy_path, flow_entry_exit) as well as
# the long-form label "interaction criticality" — match against the short IDs present in
# the aggregate (the aggregate covers SKILL.md + phases/*.md).
for probe_id in "interaction criticality" "non_happy_path" "flow_entry_exit"; do
  if grep -q "$probe_id" "$SKILL_MD"; then
    pass "SKILL corpus contains UX probe dimension: $probe_id"
  else
    fail "SKILL corpus missing UX probe dimension: $probe_id"
  fi
done

# ============================================================
echo ""
echo "=== test_probe_answers_storage_instruction ==="
SECTION="test_probe_answers_storage_instruction"

# SKILL must instruct storing probe answers in the ticket description in a structured location
UX_PROBE_FILE="${REPO_ROOT}/plugins/dso/skills/brainstorm/prompts/ux-probe-set.md"
if [ -f "$UX_PROBE_FILE" ]; then
  pass "UX probe set file exists at expected path (brainstorm/prompts/ux-probe-set.md)"
else
  fail "UX probe set file missing at brainstorm/prompts/ux-probe-set.md"
fi

# Probe answers should be woven into the epic description (check for instruction)
if grep -qiE 'probe.*answer|answer.*probe|UX.*probe.*woven|probe.*epic.*description|ux-probe-set' "$SKILL_MD"; then
  pass "SKILL corpus contains instruction to incorporate probe answers into epic content"
else
  fail "SKILL corpus missing instruction to incorporate probe answers (structured location)"
fi

# ============================================================
echo ""
echo "=== test_noninteractive_probe_deferred_flag ==="
SECTION="test_noninteractive_probe_deferred_flag"

# ui_probes:deferred integration between S5 (emission) and S6 (preplanning gate)
if grep -q 'ui_probes:deferred' "$SKILL_MD"; then
  pass "SKILL corpus contains ui_probes:deferred tag (S5 non-interactive path)"
else
  fail "SKILL corpus missing ui_probes:deferred tag"
fi

if grep -q 'INTERACTIVITY_DEFERRED: UX probes require user input' "$SKILL_MD"; then
  pass "SKILL corpus contains INTERACTIVITY_DEFERRED emission for UX probes"
else
  fail "SKILL corpus missing INTERACTIVITY_DEFERRED: UX probes require user input"
fi

# ============================================================
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
