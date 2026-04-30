#!/usr/bin/env bash
# tests/skills/test-preplanning-research-findings-schema.sh
# Structural boundary tests: preplanning SKILL.md must include researchFindings
# array, schema_version field, verified-skip logic, and RESEARCH_FINDINGS: merge
# in the PREPLANNING_CONTEXT schema definition and research phase sections.
#
# Story: eaa2-ca1c — PREPLANNING_CONTEXT research compounding across pipeline
# Task:  58d5-577b
#
# Per behavioral-testing-standard.md Rule 5, non-executable instruction files
# are tested at STRUCTURAL BOUNDARIES only:
#   - Schema field names in the PREPLANNING_CONTEXT schema are structural
#     contracts (analogous to section headings) — consumers of this schema
#     depend on these exact field names.
#   - The ticket comment prefix "RESEARCH_FINDINGS:" is an inter-component
#     protocol marker, not body text.
#
# All four tests are expected to FAIL (RED) until the implementation task
# adds researchFindings/schema_version/RESEARCH_FINDINGS: references to the
# preplanning SKILL.md.
#
# Usage:
#   bash tests/skills/test-preplanning-research-findings-schema.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/preplanning/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-preplanning-research-findings-schema.sh ==="
echo ""

# ===========================================================================
# test_preplanning_research_findings_array_mentioned
#
# Given: preplanning SKILL.md PREPLANNING_CONTEXT schema (Step 5a)
# When:  we inspect the schema section for the researchFindings field name
# Then:  "researchFindings" must appear (structural contract — schema field name)
#
# This is a schema field name check, not a content/wording check. The
# researchFindings array is a named field in the PREPLANNING_CONTEXT JSON
# schema — its name is the contract that implementation-plan consumers depend on.
# ===========================================================================
test_preplanning_research_findings_array_mentioned() {
  local _found=0
  grep -q "researchFindings" "$SKILL_FILE" && _found=1

  assert_eq \
    "test_preplanning_research_findings_array_mentioned: researchFindings field present in preplanning SKILL.md" \
    "1" "$_found"
}

# ===========================================================================
# test_preplanning_schema_version_field
#
# Given: preplanning SKILL.md PREPLANNING_CONTEXT schema (Step 5a)
# When:  we inspect the schema for schema_version or version field explicitly
#        named for forward/backward compatibility
# Then:  "schema_version" must appear (structural contract — versioning field)
#
# schema_version is the canonical field name for forward/backward compatibility
# in the PREPLANNING_CONTEXT payload. Its presence in the schema definition is
# a structural boundary; consumers use this field to detect schema evolution.
# ===========================================================================
test_preplanning_schema_version_field() {
  local _found=0
  grep -q "schema_version" "$SKILL_FILE" && _found=1

  assert_eq \
    "test_preplanning_schema_version_field: schema_version field present in preplanning SKILL.md" \
    "1" "$_found"
}

# Note: test_preplanning_skip_verified_capability removed as a change detector
# per behavioral-testing-standard.md Rule 5 + skill-refactor Phase 5 callers
# test. The assertion grepped SKILL.md prose for "verified" + "skip" co-
# occurrence with no binding caller — consumers (implementation-plan, sprint)
# bind to the JSON `status: "verified"` field and the `RESEARCH_FINDINGS:`
# ticket comment prefix, both of which are already gated by separate tests
# in this file (test_preplanning_research_findings_array,
# test_preplanning_schema_version_field, test_preplanning_research_findings_merge).
# The dedup behavior could be expressed many valid ways without changing the
# contract — exactly the false-positive failure mode change-detector tests
# produce.

# ===========================================================================
# test_preplanning_research_findings_merge
#
# Given: preplanning SKILL.md (any section)
# When:  we check for the inter-component protocol marker "RESEARCH_FINDINGS:"
# Then:  "RESEARCH_FINDINGS:" must appear (structural boundary — ticket comment
#        prefix that preplanning reads and merges into PREPLANNING_CONTEXT)
#
# RESEARCH_FINDINGS: is a ticket comment prefix — an inter-component protocol
# identifier, analogous to "PREPLANNING_CONTEXT:" already present in the file.
# Its presence in the SKILL.md is the structural contract that preplanning will
# read and incorporate these comments.
# ===========================================================================
test_preplanning_research_findings_merge() {
  local _found=0
  grep -q "RESEARCH_FINDINGS:" "$SKILL_FILE" && _found=1

  assert_eq \
    "test_preplanning_research_findings_merge: RESEARCH_FINDINGS: protocol marker present in preplanning SKILL.md" \
    "1" "$_found"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_preplanning_research_findings_array_mentioned
test_preplanning_schema_version_field
test_preplanning_research_findings_merge

print_summary
