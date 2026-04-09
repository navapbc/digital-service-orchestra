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
# (redirect stub no longer dispatches sub-agents or reviews)
if grep -q 'Invoke.*/dso:review-protocol' "$DESIGN_WF"; then
    fail "design-wireframe invokes /dso:review-protocol via Skill tool (creates 3+ level nesting)"
else
    pass "design-wireframe does not invoke /dso:review-protocol via Skill tool"
fi

# Test 5: design-wireframe must be a redirect stub (no longer contains full skill logic)
# The skill was replaced with a redirect stub pointing to dso:ui-designer via preplanning.
if grep -q 'dso:ui-designer' "$DESIGN_WF" && grep -q 'preplanning' "$DESIGN_WF"; then
    pass "design-wireframe is a redirect stub pointing to dso:ui-designer via preplanning"
else
    fail "design-wireframe is not a redirect stub (must reference dso:ui-designer and preplanning)"
fi

# Test 6: design-wireframe redirect stub must NOT have a sub-agent guard
# (redirect stubs do not dispatch sub-agents, so the guard is not needed)
if grep -q 'SUB-AGENT-GUARD' "$DESIGN_WF"; then
    fail "design-wireframe redirect stub has SUB-AGENT-GUARD (should be removed from redirect stubs)"
else
    pass "design-wireframe redirect stub has no sub-agent guard (correct for redirect stubs)"
fi

# --- preplanning Step 6 agent dispatch tests ---

PREPLANNING="$REPO_ROOT/plugins/dso/skills/preplanning/SKILL.md"

echo ""
echo "-- preplanning Step 6 agent dispatch --"

# Test 7: preplanning Step 6 must dispatch dso:ui-designer via Agent tool
# (not /dso:design-wireframe via Skill tool)
if grep -qF '/dso:design-wireframe' "$PREPLANNING"; then
    fail "preplanning Step 6 still references /dso:design-wireframe via Skill tool (3-level nesting risk)"
else
    pass "preplanning Step 6 does not invoke /dso:design-wireframe via Skill tool"
fi

# Test 8: preplanning must reference dso:ui-designer Agent tool dispatch
if grep -q 'dso:ui-designer' "$PREPLANNING" && grep -q 'Agent tool' "$PREPLANNING"; then
    pass "preplanning Step 6 dispatches dso:ui-designer via Agent tool"
else
    fail "preplanning Step 6 does not dispatch dso:ui-designer via Agent tool"
fi

# Test 9: preplanning must reference the dispatch protocol (external protocol file)
if grep -q 'ui-designer-dispatch-protocol.md' "$PREPLANNING"; then
    pass "preplanning Step 6 references ui-designer-dispatch-protocol.md"
else
    fail "preplanning Step 6 does not reference ui-designer-dispatch-protocol.md"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
