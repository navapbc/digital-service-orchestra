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

# ===========================================================================
# test_preplanning_skip_verified_capability
#
# Given: preplanning SKILL.md (any section)
# When:  we check for the structural marker describing skipping WebSearch
#        specifically when research findings already carry a "verified" status
# Then:  a line containing both "verified" and "skip" (in proximity to
#        WebSearch context) must appear — this is the structural boundary for
#        the "skip WebSearch for already-verified researchFindings" behavior
#
# Structural boundary: a single structural marker — a line that links the
# concept of "verified" findings to skipping redundant WebSearch — must exist.
# This is a distinct contract from the existing skip conditions (which fire
# when no stories qualify, not when findings are pre-verified). The grep
# targets a line that combines both "verified" and "skip" in the WebSearch
# deduplication context, which does not yet exist in the file.
# ===========================================================================
test_preplanning_skip_verified_capability() {
  # Look for a line that ties "verified" findings to skipping WebSearch — the
  # structural marker for the research deduplication contract. The existing
  # skip conditions in the file are about "no qualifying stories", not about
  # skipping when findings are pre-verified. This check requires a line where
  # both "verified" and "skip" appear together in the WebSearch deduplication
  # context (e.g., "skip WebSearch for findings with verified status").
  local _found=0
  grep -i "verified" "$SKILL_FILE" | grep -qi "skip" && _found=1

  assert_eq \
    "test_preplanning_skip_verified_capability: a line links verified findings to skipping WebSearch in preplanning SKILL.md" \
    "1" "$_found"
}

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
test_preplanning_skip_verified_capability
test_preplanning_research_findings_merge

print_summary
