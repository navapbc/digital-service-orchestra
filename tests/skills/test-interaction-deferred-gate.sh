#!/usr/bin/env bash
# Structural validation for interaction:deferred gate in preplanning and implementation-plan skills.
# Tests: both SKILL.md files contain entry gate checks and halt messages for the interaction:deferred tag.
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
# Test 1: Preplanning SKILL.md contains an interaction:deferred tag check near the entry
# ---------------------------------------------------------------------------
test_preplanning_has_interaction_deferred_check() {
  echo "=== test_preplanning_has_interaction_deferred_check ==="

  if grep -q "interaction:deferred" "$PREPLANNING_MD"; then
    pass "Preplanning SKILL.md contains an interaction:deferred tag check"
  else
    fail "Preplanning SKILL.md missing interaction:deferred tag check — add an entry gate that reads ticket tags and blocks when tag is present"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: Preplanning SKILL.md contains a halt message referencing /dso:brainstorm
# ---------------------------------------------------------------------------
test_preplanning_halt_references_brainstorm() {
  echo ""
  echo "=== test_preplanning_halt_references_brainstorm ==="

  local has_deferred=false
  local has_brainstorm=false

  if grep -q "interaction:deferred" "$PREPLANNING_MD"; then
    has_deferred=true
  fi

  # Check that the same section that mentions interaction:deferred also references /dso:brainstorm
  if grep -qE "/dso:brainstorm" "$PREPLANNING_MD"; then
    has_brainstorm=true
  fi

  if [ "$has_deferred" = "true" ] && [ "$has_brainstorm" = "true" ]; then
    pass "Preplanning SKILL.md halt message references /dso:brainstorm when interaction:deferred tag is present"
  elif [ "$has_deferred" = "false" ]; then
    fail "Preplanning SKILL.md missing interaction:deferred gate — cannot verify brainstorm reference"
  else
    fail "Preplanning SKILL.md interaction:deferred gate does not reference /dso:brainstorm — halt message must direct practitioner to run /dso:brainstorm"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: Implementation-plan SKILL.md contains an interaction:deferred tag check near the entry
# ---------------------------------------------------------------------------
test_implementation_plan_has_interaction_deferred_check() {
  echo ""
  echo "=== test_implementation_plan_has_interaction_deferred_check ==="

  if grep -q "interaction:deferred" "$IMPL_PLAN_MD"; then
    pass "Implementation-plan SKILL.md contains an interaction:deferred tag check"
  else
    fail "Implementation-plan SKILL.md missing interaction:deferred tag check — add an entry gate that reads ticket tags and blocks when tag is present"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: Implementation-plan SKILL.md contains a halt message referencing /dso:brainstorm
# ---------------------------------------------------------------------------
test_implementation_plan_halt_references_brainstorm() {
  echo ""
  echo "=== test_implementation_plan_halt_references_brainstorm ==="

  local has_deferred=false
  local has_brainstorm=false

  if grep -q "interaction:deferred" "$IMPL_PLAN_MD"; then
    has_deferred=true
  fi

  if grep -qE "/dso:brainstorm" "$IMPL_PLAN_MD"; then
    has_brainstorm=true
  fi

  if [ "$has_deferred" = "true" ] && [ "$has_brainstorm" = "true" ]; then
    pass "Implementation-plan SKILL.md halt message references /dso:brainstorm when interaction:deferred tag is present"
  elif [ "$has_deferred" = "false" ]; then
    fail "Implementation-plan SKILL.md missing interaction:deferred gate — cannot verify brainstorm reference"
  else
    fail "Implementation-plan SKILL.md interaction:deferred gate does not reference /dso:brainstorm — halt message must direct practitioner to run /dso:brainstorm"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: Both skills use presence-based check (block when tag IS present)
#         Verify both SKILL.md files contain a section that references both
#         'interaction:deferred' and 'ticket show' — indicating the gate reads
#         the ticket tags and blocks on tag presence, not absence.
# ---------------------------------------------------------------------------
test_both_skills_use_presence_based_check() {
  echo ""
  echo "=== test_both_skills_use_presence_based_check ==="

  # The gate must contain both 'interaction:deferred' and a reference to 'ticket show'
  # within the same gate section. We check for a block of text in each SKILL.md that
  # has both patterns within 20 lines of each other — indicating the gate reads the tag
  # via ticket show and blocks when interaction:deferred is present in the output.

  local preplanning_gate_with_show=false
  local impl_plan_gate_with_show=false

  # Use awk to check if 'interaction:deferred' and 'ticket show' appear within 20 lines of each other
  if awk '
    /interaction:deferred/ { found_deferred = NR }
    /ticket show/ && found_deferred && (NR - found_deferred) <= 20 { found = 1; exit }
    END { exit (found ? 0 : 1) }
  ' "$PREPLANNING_MD" 2>/dev/null; then
    preplanning_gate_with_show=true
  fi

  if awk '
    /interaction:deferred/ { found_deferred = NR }
    /ticket show/ && found_deferred && (NR - found_deferred) <= 20 { found = 1; exit }
    END { exit (found ? 0 : 1) }
  ' "$IMPL_PLAN_MD" 2>/dev/null; then
    impl_plan_gate_with_show=true
  fi

  if [ "$preplanning_gate_with_show" = "true" ] && [ "$impl_plan_gate_with_show" = "true" ]; then
    pass "Both skills contain 'interaction:deferred' gate with 'ticket show' within 20 lines — presence-based check confirmed"
  elif [ "$preplanning_gate_with_show" = "false" ] && [ "$impl_plan_gate_with_show" = "false" ]; then
    fail "Neither preplanning nor implementation-plan SKILL.md has 'ticket show' within 20 lines of 'interaction:deferred' check — gate must read tags via ticket show and block when tag is present"
  elif [ "$preplanning_gate_with_show" = "false" ]; then
    fail "Preplanning SKILL.md does not have 'ticket show' within 20 lines of 'interaction:deferred' check — gate must read tags via ticket show and block when tag is present"
  else
    fail "Implementation-plan SKILL.md does not have 'ticket show' within 20 lines of 'interaction:deferred' check — gate must read tags via ticket show and block when tag is present"
  fi
}

# ---------------------------------------------------------------------------
# Test 6: Brainstorm SKILL.md contains the interaction halt mechanism (Step 2.27)
# ---------------------------------------------------------------------------
test_brainstorm_has_interaction_halt_mechanism() {
  echo ""
  echo "=== test_brainstorm_has_interaction_halt_mechanism ==="

  local brainstorm_md="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

  if grep -q "interaction:deferred" "$brainstorm_md"; then
    pass "Brainstorm SKILL.md contains interaction:deferred tag mechanism"
  else
    fail "Brainstorm SKILL.md missing interaction:deferred tag mechanism — add Step 2.27 that tags the epic and halts when cross-epic ambiguity/conflict signals are present"
  fi
}

# ---------------------------------------------------------------------------
# Test 7: Sprint SKILL.md contains the interaction:deferred batch filter
# ---------------------------------------------------------------------------
test_sprint_has_interaction_deferred_filter() {
  echo ""
  echo "=== test_sprint_has_interaction_deferred_filter ==="

  local sprint_md="${REPO_ROOT}/plugins/dso/skills/sprint/SKILL.md"

  if grep -q "interaction:deferred" "$sprint_md"; then
    pass "Sprint SKILL.md contains interaction:deferred batch filter"
  else
    fail "Sprint SKILL.md missing interaction:deferred batch filter — add filter in Phase 3 Batch Preparation to skip epics/stories with this tag"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_preplanning_has_interaction_deferred_check
test_preplanning_halt_references_brainstorm
test_implementation_plan_has_interaction_deferred_check
test_implementation_plan_halt_references_brainstorm
test_both_skills_use_presence_based_check
test_brainstorm_has_interaction_halt_mechanism
test_sprint_has_interaction_deferred_filter

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
