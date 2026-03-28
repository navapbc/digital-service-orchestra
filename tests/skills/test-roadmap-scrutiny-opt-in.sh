#!/usr/bin/env bash
# tests/skills/test-roadmap-scrutiny-opt-in.sh
# Structural validation that roadmap SKILL.md implements scrutiny opt-in and
# caveat tag logic, and that the scrutiny:pending tag contract document exists
# and is complete.
#
# Task: feb8-a833 — RED: Tests for roadmap scrutiny opt-in and caveat tag
#
# These are RED tests — all assertions fail until roadmap SKILL.md is updated
# to reference the scrutiny opt-in question, shared pipeline, and tag-writing
# command, and until the scrutiny-pending-tag.md contract document is created.
#
# Usage: bash tests/skills/test-roadmap-scrutiny-opt-in.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ROADMAP_MD="${REPO_ROOT}/plugins/dso/skills/roadmap/SKILL.md"
CONTRACT_MD="${REPO_ROOT}/plugins/dso/docs/contracts/scrutiny-pending-tag.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: Roadmap SKILL.md contains scrutiny opt-in question text
# ---------------------------------------------------------------------------
test_roadmap_contains_scrutiny_opt_in_question() {
  echo "=== test_roadmap_contains_scrutiny_opt_in_question ==="

  if grep -qiE "apply full scrutiny" "$ROADMAP_MD" 2>/dev/null; then
    pass "Roadmap SKILL.md contains 'apply full scrutiny' opt-in question text"
  else
    fail "Roadmap SKILL.md missing 'apply full scrutiny' opt-in question text"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: Roadmap SKILL.md references shared scrutiny pipeline path
# ---------------------------------------------------------------------------
test_roadmap_references_shared_scrutiny_pipeline() {
  echo ""
  echo "=== test_roadmap_references_shared_scrutiny_pipeline ==="

  if grep -q "shared/workflows/epic-scrutiny-pipeline.md" "$ROADMAP_MD" 2>/dev/null; then
    pass "Roadmap SKILL.md references shared/workflows/epic-scrutiny-pipeline.md"
  else
    fail "Roadmap SKILL.md missing reference to shared/workflows/epic-scrutiny-pipeline.md"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: Roadmap SKILL.md writes scrutiny:pending tag on opt-out path
# ---------------------------------------------------------------------------
test_roadmap_writes_scrutiny_pending_tag_on_opt_out() {
  echo ""
  echo "=== test_roadmap_writes_scrutiny_pending_tag_on_opt_out ==="

  if grep -qiE "scrutiny:pending" "$ROADMAP_MD" 2>/dev/null; then
    pass "Roadmap SKILL.md references scrutiny:pending tag"
  else
    fail "Roadmap SKILL.md missing scrutiny:pending tag reference (expected on opt-out path)"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: Tag contract document exists at expected path
# ---------------------------------------------------------------------------
test_scrutiny_pending_tag_contract_exists() {
  echo ""
  echo "=== test_scrutiny_pending_tag_contract_exists ==="

  if [ -f "$CONTRACT_MD" ] && [ -s "$CONTRACT_MD" ]; then
    pass "Tag contract document exists at plugins/dso/docs/contracts/scrutiny-pending-tag.md and is non-empty"
  else
    fail "Tag contract document missing or empty at plugins/dso/docs/contracts/scrutiny-pending-tag.md"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: Tag contract defines field name, allowed values, writer, and reader
# ---------------------------------------------------------------------------
test_scrutiny_pending_tag_contract_completeness() {
  echo ""
  echo "=== test_scrutiny_pending_tag_contract_completeness ==="

  if [ ! -f "$CONTRACT_MD" ]; then
    fail "Tag contract document missing — cannot check for required sections"
    return
  fi

  local has_field_name=false
  local has_allowed_values=false
  local has_writer=false
  local has_reader=false

  grep -qiE "field.name|tag.name" "$CONTRACT_MD" && has_field_name=true
  grep -qiE "allowed.values|valid.values" "$CONTRACT_MD" && has_allowed_values=true
  grep -qiE "writer" "$CONTRACT_MD" && has_writer=true
  grep -qiE "reader" "$CONTRACT_MD" && has_reader=true

  if [ "$has_field_name" = "true" ] && [ "$has_allowed_values" = "true" ] && \
     [ "$has_writer" = "true" ] && [ "$has_reader" = "true" ]; then
    pass "Tag contract defines field name, allowed values, writer, and reader sections"
  else
    local missing=""
    [ "$has_field_name" = "false" ]    && missing="${missing} field_name"
    [ "$has_allowed_values" = "false" ] && missing="${missing} allowed_values"
    [ "$has_writer" = "false" ]        && missing="${missing} writer"
    [ "$has_reader" = "false" ]        && missing="${missing} reader"
    fail "Tag contract missing required sections:${missing}"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_roadmap_contains_scrutiny_opt_in_question
test_roadmap_references_shared_scrutiny_pipeline
test_roadmap_writes_scrutiny_pending_tag_on_opt_out
test_scrutiny_pending_tag_contract_exists
test_scrutiny_pending_tag_contract_completeness

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
