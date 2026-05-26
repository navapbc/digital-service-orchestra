#!/usr/bin/env bash
# tests/skills/test-implementation-plan-step4-step6-hardgate.sh
# Structural boundary tests: implementation-plan SKILL.md must protect Step 4
# (Plan Review) and Step 6 (Gap Analysis) with <HARD-GATE> structural markers,
# and the OUTPUT Protocol must emit audit marker tokens that sprint can verify.
#
# Per behavioral-testing-standard.md Rule 5: instruction-file tests assert only
# on structural boundary tokens — not on prose content or specific rationale
# enumeration strings. The binding contract is:
#   - <HARD-GATE> tag presence in the Step 4 execution region
#   - <HARD-GATE> tag presence in the Step 6 execution region (already exists,
#     verified here for completeness)
#   - Audit marker tokens (plan_review:pass, gap_analysis:complete) in the
#     OUTPUT Protocol so the sprint orchestrator can verify steps ran
#
# Bug: 2c4d-cac7-40a4-40e2
# Root cause: Instruction Locality (failure mode #16) — Step 4 lacked a
# HARD-GATE entirely; Step 6 HARD-GATE lacked anti-rationalization prohibition;
# STATUS:complete did not emit audit markers for sprint verification.
#
# Usage:
#   bash tests/skills/test-implementation-plan-step4-step6-hardgate.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-step4-step6-hardgate.sh ==="
echo ""

# ============================================================================
# test_step4_region_has_hard_gate
#
# Binding caller: the sprint orchestrator trusts that SKILL.md enforces Step 4
# execution. <HARD-GATE> is the structural marker that signals a mandatory gate
# cannot be bypassed. Step 4 (Plan Review) must carry this marker.
# ============================================================================
test_step4_region_has_hard_gate() {
  STEP4_LINE=$(grep -n "^## Step 4:" "$SKILL_FILE" | head -1 | cut -d: -f1)
  STEP5_LINE=$(grep -n "^## Step 5:" "$SKILL_FILE" | head -1 | cut -d: -f1)
  STEP6_LINE=$(grep -n "^## Step 6:" "$SKILL_FILE" | head -1 | cut -d: -f1)

  # Use Step 5 as the boundary if present; fall back to Step 6
  BOUNDARY_LINE="${STEP5_LINE:-${STEP6_LINE:-9999}}"

  if [ -z "$STEP4_LINE" ]; then
    assert_eq \
      "test_step4_region_has_hard_gate: Step 4 heading must exist in SKILL.md" \
      "found" "not-found"
    return
  fi

  HARD_GATE_COUNT=$(awk "NR>=$STEP4_LINE && NR<=$BOUNDARY_LINE" "$SKILL_FILE" \
    | grep -c "<HARD-GATE>" || true)

  assert_eq \
    "test_step4_region_has_hard_gate: Step 4 region must contain at least one <HARD-GATE> marker" \
    "1" "$([ "$HARD_GATE_COUNT" -ge 1 ] && echo 1 || echo 0)"
}

echo "--- test_step4_region_has_hard_gate ---"
test_step4_region_has_hard_gate
echo ""

# ============================================================================
# test_step6_region_has_hard_gate
#
# Binding caller: same as Step 4 — sprint trusts Step 6 is enforced. Verifies
# the already-existing Step 6 HARD-GATE is still present after any changes.
# ============================================================================
test_step6_region_has_hard_gate() {
  STEP6_LINE=$(grep -n "^## Step 6:" "$SKILL_FILE" | head -1 | cut -d: -f1)
  # Use end-of-relevant-section (Common Mistakes or next ## heading)
  NEXT_HEADING=$(awk "NR>$STEP6_LINE && /^## /" "$SKILL_FILE" | head -1)
  NEXT_LINE=$(grep -n "^## " "$SKILL_FILE" | awk -F: "NR>1{print prev} {prev=\$1}" \
    | head -1 || echo "9999")
  # Simpler: just check the whole file from Step 6 onward
  HARD_GATE_COUNT=$(awk "NR>=$STEP6_LINE" "$SKILL_FILE" \
    | grep -c "<HARD-GATE>" || true)

  assert_eq \
    "test_step6_region_has_hard_gate: Step 6 region must contain at least one <HARD-GATE> marker" \
    "1" "$([ "$HARD_GATE_COUNT" -ge 1 ] && echo 1 || echo 0)"
}

echo "--- test_step6_region_has_hard_gate ---"
test_step6_region_has_hard_gate
echo ""

# ============================================================================
# test_output_protocol_plan_review_audit_marker
#
# Binding caller: sprint SKILL.md STATUS:complete handler must verify that
# plan_review:pass tag was set on the story before accepting it. The token
# must appear in the OUTPUT Protocol (or audit-marker section) so the contract
# is explicit. The tag literal is a machine-read key — string identity is
# the contract.
# ============================================================================
test_output_protocol_plan_review_audit_marker() {
  local _found=0
  grep -q "plan_review:pass" "$SKILL_FILE" 2>/dev/null && _found=1

  assert_eq \
    "test_output_protocol_plan_review_audit_marker: SKILL.md must reference plan_review:pass audit marker token" \
    "1" "$_found"
}

echo "--- test_output_protocol_plan_review_audit_marker ---"
test_output_protocol_plan_review_audit_marker
echo ""

# ============================================================================
# test_output_protocol_gap_analysis_audit_marker
#
# Binding caller: sprint SKILL.md STATUS:complete handler must verify that
# gap_analysis:complete tag was set on the story before accepting it.
# ============================================================================
test_output_protocol_gap_analysis_audit_marker() {
  local _found=0
  grep -q "gap_analysis:complete" "$SKILL_FILE" 2>/dev/null && _found=1

  assert_eq \
    "test_output_protocol_gap_analysis_audit_marker: SKILL.md must reference gap_analysis:complete audit marker token" \
    "1" "$_found"
}

echo "--- test_output_protocol_gap_analysis_audit_marker ---"
test_output_protocol_gap_analysis_audit_marker
echo ""

print_summary
