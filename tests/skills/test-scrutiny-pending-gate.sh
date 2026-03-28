#!/usr/bin/env bash
# Structural validation for scrutiny:pending gate in preplanning and implementation-plan skills.
# Tests: both SKILL.md files contain entry gate checks and halt messages for the scrutiny:pending tag.
# These are RED tests — all assertions fail until the gate is added to both SKILL.md files.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PREPLANNING_MD="${REPO_ROOT}/plugins/dso/skills/preplanning/SKILL.md"
IMPL_PLAN_MD="${REPO_ROOT}/plugins/dso/skills/implementation-plan/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: Preplanning SKILL.md contains a scrutiny:pending tag check near the entry
# ---------------------------------------------------------------------------
test_preplanning_has_scrutiny_pending_check() {
  echo "=== test_preplanning_has_scrutiny_pending_check ==="

  if grep -q "scrutiny:pending" "$PREPLANNING_MD"; then
    pass "Preplanning SKILL.md contains a scrutiny:pending tag check"
  else
    fail "Preplanning SKILL.md missing scrutiny:pending tag check — add an entry gate that reads ticket tags and blocks when tag is present"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: Preplanning SKILL.md contains a halt message referencing /dso:brainstorm
# ---------------------------------------------------------------------------
test_preplanning_halt_references_brainstorm() {
  echo ""
  echo "=== test_preplanning_halt_references_brainstorm ==="

  local has_scrutiny=false
  local has_brainstorm=false

  if grep -q "scrutiny:pending" "$PREPLANNING_MD"; then
    has_scrutiny=true
  fi

  # Check that the same section that mentions scrutiny:pending also references /dso:brainstorm
  # Look for both patterns in the file — if the gate is there, it should direct to brainstorm
  if grep -qE "/dso:brainstorm" "$PREPLANNING_MD"; then
    has_brainstorm=true
  fi

  if [ "$has_scrutiny" = "true" ] && [ "$has_brainstorm" = "true" ]; then
    pass "Preplanning SKILL.md halt message references /dso:brainstorm when scrutiny:pending tag is present"
  elif [ "$has_scrutiny" = "false" ]; then
    fail "Preplanning SKILL.md missing scrutiny:pending gate — cannot verify brainstorm reference"
  else
    fail "Preplanning SKILL.md scrutiny:pending gate does not reference /dso:brainstorm — halt message must direct practitioner to run /dso:brainstorm"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: Implementation-plan SKILL.md contains a scrutiny:pending tag check near the entry
# ---------------------------------------------------------------------------
test_implementation_plan_has_scrutiny_pending_check() {
  echo ""
  echo "=== test_implementation_plan_has_scrutiny_pending_check ==="

  if grep -q "scrutiny:pending" "$IMPL_PLAN_MD"; then
    pass "Implementation-plan SKILL.md contains a scrutiny:pending tag check"
  else
    fail "Implementation-plan SKILL.md missing scrutiny:pending tag check — add an entry gate that reads ticket tags and blocks when tag is present"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: Implementation-plan SKILL.md contains a halt message referencing /dso:brainstorm
# ---------------------------------------------------------------------------
test_implementation_plan_halt_references_brainstorm() {
  echo ""
  echo "=== test_implementation_plan_halt_references_brainstorm ==="

  local has_scrutiny=false
  local has_brainstorm=false

  if grep -q "scrutiny:pending" "$IMPL_PLAN_MD"; then
    has_scrutiny=true
  fi

  if grep -qE "/dso:brainstorm" "$IMPL_PLAN_MD"; then
    has_brainstorm=true
  fi

  if [ "$has_scrutiny" = "true" ] && [ "$has_brainstorm" = "true" ]; then
    pass "Implementation-plan SKILL.md halt message references /dso:brainstorm when scrutiny:pending tag is present"
  elif [ "$has_scrutiny" = "false" ]; then
    fail "Implementation-plan SKILL.md missing scrutiny:pending gate — cannot verify brainstorm reference"
  else
    fail "Implementation-plan SKILL.md scrutiny:pending gate does not reference /dso:brainstorm — halt message must direct practitioner to run /dso:brainstorm"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: Both skills use presence-based check (block when tag IS present)
#         Verify both SKILL.md files contain a section that references both
#         'scrutiny:pending' and 'ticket show' — indicating the gate reads the
#         ticket tags and blocks on tag presence, not absence.
# ---------------------------------------------------------------------------
test_both_skills_use_presence_based_check() {
  echo ""
  echo "=== test_both_skills_use_presence_based_check ==="

  # The gate must contain both 'scrutiny:pending' and a reference to 'ticket show'
  # within the same gate section. We check for a block of text in each SKILL.md that
  # has both patterns within 20 lines of each other — indicating the gate reads the tag
  # via ticket show and blocks when scrutiny:pending is present in the output.

  local preplanning_gate_with_show=false
  local impl_plan_gate_with_show=false

  # Use awk to check if 'scrutiny:pending' and 'ticket show' appear within 20 lines of each other
  if awk '
    /scrutiny:pending/ { found_scrutiny = NR }
    /ticket show/ && found_scrutiny && (NR - found_scrutiny) <= 20 { exit 0 }
    END { exit 1 }
  ' "$PREPLANNING_MD" 2>/dev/null; then
    preplanning_gate_with_show=true
  fi

  if awk '
    /scrutiny:pending/ { found_scrutiny = NR }
    /ticket show/ && found_scrutiny && (NR - found_scrutiny) <= 20 { exit 0 }
    END { exit 1 }
  ' "$IMPL_PLAN_MD" 2>/dev/null; then
    impl_plan_gate_with_show=true
  fi

  if [ "$preplanning_gate_with_show" = "true" ] && [ "$impl_plan_gate_with_show" = "true" ]; then
    pass "Both skills contain 'scrutiny:pending' gate with 'ticket show' within 20 lines — presence-based check confirmed"
  elif [ "$preplanning_gate_with_show" = "false" ] && [ "$impl_plan_gate_with_show" = "false" ]; then
    fail "Neither preplanning nor implementation-plan SKILL.md has 'ticket show' within 20 lines of 'scrutiny:pending' check — gate must read tags via ticket show and block when tag is present"
  elif [ "$preplanning_gate_with_show" = "false" ]; then
    fail "Preplanning SKILL.md does not have 'ticket show' within 20 lines of 'scrutiny:pending' check — gate must read tags via ticket show and block when tag is present"
  else
    fail "Implementation-plan SKILL.md does not have 'ticket show' within 20 lines of 'scrutiny:pending' check — gate must read tags via ticket show and block when tag is present"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_preplanning_has_scrutiny_pending_check
test_preplanning_halt_references_brainstorm
test_implementation_plan_has_scrutiny_pending_check
test_implementation_plan_halt_references_brainstorm
test_both_skills_use_presence_based_check

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
