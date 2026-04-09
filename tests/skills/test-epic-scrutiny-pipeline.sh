#!/usr/bin/env bash
# Structural validation for shared epic scrutiny pipeline extraction.
# Tests: pipeline file existence, brainstorm SKILL.md step removal and reference update,
#        and shared pipeline content completeness (gap analysis, web research,
#        scenario analysis, fidelity review with feasibility trigger).
# These are RED tests — all assertions fail until the shared pipeline is extracted
# and brainstorm SKILL.md is updated to reference it.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PIPELINE_MD="${REPO_ROOT}/plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"
BRAINSTORM_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: Shared pipeline file exists and is non-empty
# ---------------------------------------------------------------------------
test_shared_pipeline_file_exists() {
  echo "=== test_shared_pipeline_file_exists ==="

  if [ -f "$PIPELINE_MD" ] && [ -s "$PIPELINE_MD" ]; then
    pass "Shared pipeline file exists at plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md and is non-empty"
  else
    fail "Shared pipeline file missing or empty at plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: Brainstorm SKILL.md does NOT contain inline 'Step 2.5: Gap Analysis' header
#         (negative constraint — inline scrutiny steps must be extracted to shared pipeline)
# ---------------------------------------------------------------------------
test_brainstorm_no_inline_scrutiny_step() {
  echo ""
  echo "=== test_brainstorm_no_inline_scrutiny_step ==="

  if grep -qiE "^### Step 2\.5:.*Gap Analysis" "$BRAINSTORM_MD"; then
    fail "Brainstorm SKILL.md still contains inline 'Step 2.5: Gap Analysis' header — must be extracted to shared pipeline"
  else
    pass "Brainstorm SKILL.md does not contain inline 'Step 2.5: Gap Analysis' header (successfully extracted)"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: Brainstorm SKILL.md references the shared pipeline path
# ---------------------------------------------------------------------------
test_brainstorm_references_shared_pipeline() {
  echo ""
  echo "=== test_brainstorm_references_shared_pipeline ==="

  if grep -q "shared/workflows/epic-scrutiny-pipeline.md" "$BRAINSTORM_MD"; then
    pass "Brainstorm SKILL.md references shared/workflows/epic-scrutiny-pipeline.md"
  else
    fail "Brainstorm SKILL.md missing reference to shared/workflows/epic-scrutiny-pipeline.md"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: Shared pipeline contains gap analysis step
# ---------------------------------------------------------------------------
test_pipeline_contains_gap_analysis() {
  echo ""
  echo "=== test_pipeline_contains_gap_analysis ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Shared pipeline file missing — cannot check for gap analysis step"
    return
  fi

  if grep -qiE "gap.analysis" "$PIPELINE_MD"; then
    pass "Shared pipeline contains gap analysis step"
  else
    fail "Shared pipeline missing gap analysis step (grep: 'gap.analysis' case-insensitive)"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: Shared pipeline contains web research step
# ---------------------------------------------------------------------------
test_pipeline_contains_web_research() {
  echo ""
  echo "=== test_pipeline_contains_web_research ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Shared pipeline file missing — cannot check for web research step"
    return
  fi

  if grep -qiE "web.research" "$PIPELINE_MD"; then
    pass "Shared pipeline contains web research step"
  else
    fail "Shared pipeline missing web research step (grep: 'web.research' case-insensitive)"
  fi
}

# ---------------------------------------------------------------------------
# Test 6: Shared pipeline contains scenario analysis step
# ---------------------------------------------------------------------------
test_pipeline_contains_scenario_analysis() {
  echo ""
  echo "=== test_pipeline_contains_scenario_analysis ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Shared pipeline file missing — cannot check for scenario analysis step"
    return
  fi

  if grep -qiE "scenario.analysis" "$PIPELINE_MD"; then
    pass "Shared pipeline contains scenario analysis step"
  else
    fail "Shared pipeline missing scenario analysis step (grep: 'scenario.analysis' case-insensitive)"
  fi
}

# ---------------------------------------------------------------------------
# Test 7: Shared pipeline contains fidelity review step with feasibility trigger
# ---------------------------------------------------------------------------
test_pipeline_contains_fidelity_review_with_feasibility() {
  echo ""
  echo "=== test_pipeline_contains_fidelity_review_with_feasibility ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Shared pipeline file missing — cannot check for fidelity review step"
    return
  fi

  local has_fidelity=false
  local has_feasibility=false

  if grep -qiE "fidelity.review" "$PIPELINE_MD"; then
    has_fidelity=true
  fi

  if grep -qiE "feasibility" "$PIPELINE_MD"; then
    has_feasibility=true
  fi

  if [ "$has_fidelity" = "true" ] && [ "$has_feasibility" = "true" ]; then
    pass "Shared pipeline contains fidelity review step with feasibility trigger"
  elif [ "$has_fidelity" = "false" ]; then
    fail "Shared pipeline missing fidelity review step (grep: 'fidelity.review' case-insensitive)"
  else
    fail "Shared pipeline fidelity review step missing feasibility trigger (grep: 'feasibility' case-insensitive)"
  fi
}

# ---------------------------------------------------------------------------
# Test 8: Shared pipeline contains a Part C section
# (Rule 5 boundary test — asserts structural section existence, not content)
# ---------------------------------------------------------------------------
test_pipeline_contains_part_c_section() {
  echo ""
  echo "=== test_pipeline_contains_part_c_section ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Shared pipeline file missing — cannot check for Part C section"
    return
  fi

  if grep -q "^### Part C" "$PIPELINE_MD"; then
    pass "Shared pipeline contains '### Part C' section header"
  else
    fail "Shared pipeline missing '### Part C' section header (grep: '^### Part C')"
  fi
}

# ---------------------------------------------------------------------------
# Test 9: Part C output format references covered_by_SC
# (Rule 5 boundary test — asserts output format marker is present)
# ---------------------------------------------------------------------------
test_pipeline_part_c_output_format() {
  echo ""
  echo "=== test_pipeline_part_c_output_format ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Shared pipeline file missing — cannot check for Part C output format"
    return
  fi

  if grep -q "covered_by_SC" "$PIPELINE_MD"; then
    pass "Shared pipeline contains output format marker 'covered_by_SC' in Part C"
  else
    fail "Shared pipeline missing output format marker 'covered_by_SC' (Part C output format)"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_shared_pipeline_file_exists
test_brainstorm_no_inline_scrutiny_step
test_brainstorm_references_shared_pipeline
test_pipeline_contains_gap_analysis
test_pipeline_contains_web_research
test_pipeline_contains_scenario_analysis
test_pipeline_contains_fidelity_review_with_feasibility
test_pipeline_contains_part_c_section
test_pipeline_part_c_output_format

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
