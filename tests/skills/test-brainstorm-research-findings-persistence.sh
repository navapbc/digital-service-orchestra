#!/usr/bin/env bash
# tests/skills/test-brainstorm-research-findings-persistence.sh
# Structural boundary test: brainstorm SKILL.md must declare the RESEARCH_FINDINGS:
# ticket comment format used to persist integration research across the pipeline.
#
# Regression guard for story eaa2-ca1c (PREPLANNING_CONTEXT research compounding):
# The brainstorm skill must document the RESEARCH_FINDINGS: comment prefix and
# structured researchFindings schema (including the 'capability' field and status
# enum values) so that downstream agents (preplanning, sprint) can consume them.
#
# Per behavioral-testing-standard.md Rule 5, instruction-file tests check the
# STRUCTURAL BOUNDARY — the presence of specific schema/format markers — not
# wording or general content assertions.
#
# What we test (structural boundary):
#   1. The SKILL.md contains the RESEARCH_FINDINGS: ticket comment prefix (the
#      structured comment format that persists integration research to the ticket)
#   2. The SKILL.md describes a 'capability' field in the researchFindings schema
#      (required field in the structured output format)
#   3. The SKILL.md mentions at least one status enum value from the defined set
#      (verified | partially_verified | unverified | contradicted)
#
# All 3 tests are expected to FAIL (RED) until the SKILL.md is updated.
#
# Usage:
#   bash tests/skills/test-brainstorm-research-findings-persistence.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/brainstorm/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-brainstorm-research-findings-persistence.sh ==="
echo ""

# ===========================================================================
# test_brainstorm_research_findings_comment_format
#
# Given: plugins/dso/skills/brainstorm/SKILL.md
# When:  we search for the RESEARCH_FINDINGS: ticket comment prefix
# Then:  the prefix must be present as a structural schema marker
#
# Structural boundary: RESEARCH_FINDINGS: is the defined ticket comment format
# string that agents use to write/read persistent research across the pipeline.
# Its presence in SKILL.md is a contract requirement — without it, agents have
# no authoritative format to follow.
# RED before fix: marker absent → agents cannot persist research findings.
# GREEN after fix: marker present → agents know the required comment prefix.
# ===========================================================================
test_brainstorm_research_findings_comment_format() {
  local _found=0
  grep -qF "RESEARCH_FINDINGS:" "$SKILL_FILE" && _found=1

  assert_eq \
    "test_brainstorm_research_findings_comment_format: SKILL.md must declare RESEARCH_FINDINGS: ticket comment prefix" \
    "1" "$_found"
}

# ===========================================================================
# test_brainstorm_research_findings_capability_field
#
# Given: plugins/dso/skills/brainstorm/SKILL.md
# When:  we search for the 'capability' field in the researchFindings schema
# Then:  the field name must appear as a schema key in the structured format
#
# Structural boundary: 'capability' is a required field in the researchFindings
# JSON/structured output format. Its presence as a schema key in SKILL.md is a
# contract requirement — downstream agents that parse RESEARCH_FINDINGS: comments
# depend on this field being defined.
# RED before fix: field absent → schema is incomplete; parsers will miss the field.
# GREEN after fix: field present → schema is complete and parseable.
# ===========================================================================
test_brainstorm_research_findings_capability_field() {
  local _found=0
  grep -qE '"?capability"?\s*[:\|]|capability:' "$SKILL_FILE" && _found=1

  assert_eq \
    "test_brainstorm_research_findings_capability_field: SKILL.md must define 'capability' field in researchFindings schema" \
    "1" "$_found"
}

# ===========================================================================
# test_brainstorm_research_findings_status_enum
#
# Given: plugins/dso/skills/brainstorm/SKILL.md
# When:  we search for status enum values for research findings
# Then:  at least one of the defined enum values must be present
#        (verified | partially_verified | unverified | contradicted)
#
# Structural boundary: the status enum (verified/partially_verified/unverified/
# contradicted) is the contract for how research confidence is communicated.
# At least one enum value must appear in SKILL.md to confirm the status field
# contract is documented.
# RED before fix: enum values absent → no status contract documented.
# GREEN after fix: at least one enum value present → status contract established.
# ===========================================================================
test_brainstorm_research_findings_status_enum() {
  local _found=0
  # Use unambiguous enum values (partially_verified, unverified, contradicted)
  # that cannot appear in other contexts — 'verified' alone is too generic.
  grep -qE "partially_verified|unverified|contradicted" "$SKILL_FILE" && _found=1

  assert_eq \
    "test_brainstorm_research_findings_status_enum: SKILL.md must mention at least one unambiguous research findings status enum value (partially_verified|unverified|contradicted)" \
    "1" "$_found"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_brainstorm_research_findings_comment_format
test_brainstorm_research_findings_capability_field
test_brainstorm_research_findings_status_enum

print_summary
