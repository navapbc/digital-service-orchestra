#!/usr/bin/env bash
# Test: Skill tool nesting depth safety
# Bug: 335b-c846 — 3-level Skill tool nesting fails to return control
#
# Verifies that skills invoked from within sprint (2nd level) do NOT invoke
# other skills via the Skill tool (which would create 3+ levels).
# They must use "read and execute ... inline" for review workflows.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

pass() { ((PASS++)); echo "  PASS: $1"; }
fail() { ((FAIL++)); echo "  FAIL: $1"; }

echo "=== Skill Nesting Depth Tests ==="

# --- implementation-plan tests ---

IMPL_PLAN="$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

echo ""
echo "-- implementation-plan checklist labels --"

# Test 1: Checklist must NOT reference "via /dso:review-protocol"
if grep -q 'via /dso:review-protocol' "$IMPL_PLAN"; then
    fail "implementation-plan checklist references 'via /dso:review-protocol' (Skill tool invocation risk)"
else
    pass "implementation-plan checklist does not reference 'via /dso:review-protocol'"
fi

# Test 2: Checklist should reference the inline workflow pattern
if grep -q 'REVIEW-PROTOCOL-WORKFLOW.md' "$IMPL_PLAN"; then
    pass "implementation-plan references REVIEW-PROTOCOL-WORKFLOW.md"
else
    fail "implementation-plan does not reference REVIEW-PROTOCOL-WORKFLOW.md"
fi

# Test 3: implementation-plan must NOT contain Skill( invocations
if grep -qE 'Skill\(' "$IMPL_PLAN"; then
    fail "implementation-plan contains Skill() invocation — creates 3-level nesting from sprint"
else
    pass "implementation-plan contains no Skill() invocations"
fi

# --- design-wireframe tests ---

DESIGN_WF="$REPO_ROOT/plugins/dso/skills/design-wireframe/SKILL.md"

echo ""
echo "-- design-wireframe review-protocol invocation --"

# Test 4: design-wireframe must NOT say "Invoke /dso:review-protocol"
if grep -q 'Invoke.*/dso:review-protocol' "$DESIGN_WF"; then
    fail "design-wireframe invokes /dso:review-protocol via Skill tool (creates 3+ level nesting)"
else
    pass "design-wireframe does not invoke /dso:review-protocol via Skill tool"
fi

# Test 5: design-wireframe must reference REVIEW-PROTOCOL-WORKFLOW.md for its review
if grep -q 'REVIEW-PROTOCOL-WORKFLOW.md' "$DESIGN_WF"; then
    pass "design-wireframe references REVIEW-PROTOCOL-WORKFLOW.md (inline pattern)"
else
    fail "design-wireframe does not reference REVIEW-PROTOCOL-WORKFLOW.md"
fi

# Test 6: design-wireframe Phase 5 must use "read and execute ... inline" pattern
if grep -iq 'read and execute.*REVIEW-PROTOCOL-WORKFLOW' "$DESIGN_WF"; then
    pass "design-wireframe Phase 5 uses 'read and execute ... inline' pattern"
else
    fail "design-wireframe Phase 5 does not use 'read and execute ... inline' pattern"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
