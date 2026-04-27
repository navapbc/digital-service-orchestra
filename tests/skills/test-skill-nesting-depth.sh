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

# --- preplanning Step 6 agent dispatch tests ---

PREPLANNING="$REPO_ROOT/plugins/dso/skills/preplanning/SKILL.md"

echo ""
echo "-- preplanning Step 6 agent dispatch --"

# Test 4: preplanning Step 6 must dispatch dso:ui-designer via Agent tool
# (not /dso:design-wireframe via Skill tool)
if grep -qF '/dso:design-wireframe' "$PREPLANNING"; then
    fail "preplanning Step 6 still references /dso:design-wireframe via Skill tool (3-level nesting risk)"
else
    pass "preplanning Step 6 does not invoke /dso:design-wireframe via Skill tool"
fi

# Test 5: preplanning must reference dso:ui-designer Agent tool dispatch
if grep -q 'dso:ui-designer' "$PREPLANNING" && grep -q 'Agent tool' "$PREPLANNING"; then
    pass "preplanning Step 6 dispatches dso:ui-designer via Agent tool"
else
    fail "preplanning Step 6 does not dispatch dso:ui-designer via Agent tool"
fi

# Test 6: preplanning must reference the dispatch protocol (external protocol file)
if grep -q 'ui-designer-dispatch-protocol.md' "$PREPLANNING"; then
    pass "preplanning Step 6 references ui-designer-dispatch-protocol.md"
else
    fail "preplanning Step 6 does not reference ui-designer-dispatch-protocol.md"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
