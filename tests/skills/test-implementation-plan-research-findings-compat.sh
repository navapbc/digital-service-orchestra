#!/usr/bin/env bash
# tests/skills/test-implementation-plan-research-findings-compat.sh
# Structural boundary test: implementation-plan SKILL.md "### Context File Check"
# section must mention researchFindings, fail-open behavior, and schema_version.
#
# Regression guard for story eaa2-ca1c (PREPLANNING_CONTEXT research compounding):
# The Context File Check section must document backward-compatible handling of the
# new researchFindings field — agents reading contexts without this field must
# not fail, and forward compatibility via schema_version must be declared.
#
# Per behavioral-testing-standard.md Rule 5, instruction-file tests check ONLY the
# STRUCTURAL BOUNDARY — section-heading presence and co-located structural markers.
# Body-text content-phrase assertions are prohibited.
#
# What we test (structural boundary — section-heading level):
#   1. The "### Context File Check" section mentions "researchFindings" (field name
#      referenced as a structural identifier for the new context field)
#   2. The "### Context File Check" section mentions fail-open behavior keywords
#      (structural contract: agents must not hard-fail on missing/corrupt fields)
#   3. The "### Context File Check" section mentions "schema_version" (structural
#      marker for forward/backward compatibility)
#
# All 3 tests FAIL (RED) until the SKILL.md Context File Check section is updated.
#
# Usage:
#   bash tests/skills/test-implementation-plan-research-findings-compat.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-research-findings-compat.sh ==="
echo ""

# Extract the "### Context File Check" section to the next "### " heading.
# This is the shared fixture for all three tests below.
_CONTEXT_SECTION=$(awk '
  /^### Context File Check/ { found=1 }
  found && /^### / && !/^### Context File Check/ { exit }
  found { print }
' "$SKILL_FILE")

# ===========================================================================
# test_impl_plan_context_check_handles_missing_research_findings
#
# Given: implementation-plan/SKILL.md "### Context File Check" section
# When: we extract the section and scan for the field name "researchFindings"
# Then: the section must reference "researchFindings" — indicating it documents
#       how to handle contexts that do or do not carry this field
#
# Structural boundary: the field name itself is the integration contract between
# the preplanning skill (which writes it) and implementation-plan (which reads it).
# Its presence in the Context File Check section is the minimum structural signal
# that the backward-compat clause was authored.
# RED: field name absent → agents silently skip the field or fail on old contexts.
# GREEN: field name present → backward-compat handling is documented.
# ===========================================================================
test_impl_plan_context_check_handles_missing_research_findings() {
  local _found=0
  echo "$_CONTEXT_SECTION" | grep -q "researchFindings" && _found=1

  assert_eq \
    "test_impl_plan_context_check_handles_missing_research_findings: Context File Check section must reference 'researchFindings'" \
    "1" "$_found"
}

# ===========================================================================
# test_impl_plan_context_check_fail_open
#
# Given: implementation-plan/SKILL.md "### Context File Check" section
# When: we extract the section and scan for fail-open behavior keywords
# Then: the section must mention at least one of: "fail-open", "absent",
#       "treat as empty", "missing" — indicating the contract for graceful
#       degradation when the field is not present
#
# Structural boundary: a fail-open policy marker is the contract that distinguishes
# a safe upgrade (old context → new reader) from a hard failure. Its absence means
# the section does not document the degradation path.
# RED: no fail-open keyword → ambiguous behavior for agents reading old contexts.
# GREEN: keyword present → degradation path is structurally documented.
# ===========================================================================
test_impl_plan_context_check_fail_open() {
  local _found=0
  echo "$_CONTEXT_SECTION" | grep -qiE "fail.open|absent|treat as empty|missing" && _found=1

  assert_eq \
    "test_impl_plan_context_check_fail_open: Context File Check section must document fail-open behavior for missing/absent fields" \
    "1" "$_found"
}

# ===========================================================================
# test_impl_plan_context_check_schema_version_aware
#
# Given: implementation-plan/SKILL.md "### Context File Check" section
# When: we extract the section and scan for "schema_version"
# Then: the section must reference "schema_version" — the structural marker
#       that enables forward/backward compatibility checks
#
# Structural boundary: schema_version is the field that allows readers to detect
# context payload version mismatches. Its presence in the Context File Check
# section is the structural contract that version-aware parsing was specified.
# RED: schema_version absent → no version-aware degradation path.
# GREEN: schema_version present → version-aware forward/backward compat declared.
# ===========================================================================
test_impl_plan_context_check_schema_version_aware() {
  local _found=0
  echo "$_CONTEXT_SECTION" | grep -q "schema_version" && _found=1

  assert_eq \
    "test_impl_plan_context_check_schema_version_aware: Context File Check section must reference 'schema_version' for compatibility" \
    "1" "$_found"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_impl_plan_context_check_handles_missing_research_findings
test_impl_plan_context_check_fail_open
test_impl_plan_context_check_schema_version_aware

print_summary
