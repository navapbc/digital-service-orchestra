#!/usr/bin/env bash
# tests/skills/test-sprint-step20-no-scope-narrowing.sh
# Structural boundary test: assert that sprint SKILL.md Phase F Step 20
# (Continuation Decision) contains a HARD-GATE prohibiting mid-sprint
# scope-narrowing AskUserQuestion prompts.
#
# Background (bug 15a4-5150-91dd-4737): the orchestrator was presenting
# scope-reduction menus between batches despite no documented phase step
# authorizing this. Root cause: Instruction Locality (failure mode #16) —
# the constraint "don't ask for scope-narrowing between batches" was only
# in memory files, not co-located with the Step 20 execution site.
#
# These are structural boundary checks per the behavioral testing standard.
# Tests verify the gate block exists and anchors to the bug ID, NOT content prose.
#
# Usage: bash tests/skills/test-sprint-step20-no-scope-narrowing.sh
# Returns: exit 0 on PASS, non-zero on FAIL

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

PASS=0
FAIL=0

if [[ ! -f "$SKILL_MD" ]]; then
    echo "FAIL: SKILL.md not found at $SKILL_MD" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Extract Step 20 section (from ### Step 20 to the next ### heading or EOF)
# ---------------------------------------------------------------------------
step20_content=$(awk '/^### Step 20:/{flag=1; next} flag && /^### /{flag=0} flag' "$SKILL_MD")

# ---------------------------------------------------------------------------
# Test 1: Step 20 contains a HARD-GATE block
# ---------------------------------------------------------------------------
if echo "$step20_content" | grep -q '<HARD-GATE>'; then
    echo "PASS: test_step20_has_hard_gate — Step 20 contains a HARD-GATE block"
    (( ++PASS ))
else
    echo "FAIL: test_step20_has_hard_gate — Step 20 is missing a HARD-GATE block (bug 15a4-5150-91dd-4737 fix not present)" >&2
    (( ++FAIL ))
fi

# ---------------------------------------------------------------------------
# Test 2: HARD-GATE references bug 15a4-5150-91dd-4737 (structural anchor)
# ---------------------------------------------------------------------------
if echo "$step20_content" | grep -q '15a4-5150'; then
    echo "PASS: test_step20_hard_gate_references_bug_15a4 — HARD-GATE references anti-pattern bug 15a4-5150-91dd-4737"
    (( ++PASS ))
else
    echo "FAIL: test_step20_hard_gate_references_bug_15a4 — HARD-GATE does not reference bug 15a4-5150-91dd-4737" >&2
    (( ++FAIL ))
fi

# ---------------------------------------------------------------------------
# Test 3: Step 20 Standard Continuation Decision section exists
# (regression guard — the section must not be deleted or renamed)
# ---------------------------------------------------------------------------
if echo "$step20_content" | grep -q 'Standard Continuation Decision'; then
    echo "PASS: test_step20_has_standard_continuation_decision — Standard Continuation Decision section present"
    (( ++PASS ))
else
    echo "FAIL: test_step20_has_standard_continuation_decision — Standard Continuation Decision section missing from Step 20" >&2
    (( ++FAIL ))
fi

# ---------------------------------------------------------------------------
# Test 4: HARD-GATE appears before the decision tree (the Decision: flowchart)
# (structural ordering — gate must precede the continuation decision logic)
# ---------------------------------------------------------------------------
hard_gate_line=$(echo "$step20_content" | grep -n '<HARD-GATE>' | head -1 | cut -d: -f1)
decision_tree_line=$(echo "$step20_content" | grep -n '^Decision:' | head -1 | cut -d: -f1)

if [[ -n "$hard_gate_line" && -n "$decision_tree_line" && "$hard_gate_line" -lt "$decision_tree_line" ]]; then
    echo "PASS: test_step20_gate_before_decision_tree — HARD-GATE appears before the Decision: flowchart"
    (( ++PASS ))
else
    echo "FAIL: test_step20_gate_before_decision_tree — HARD-GATE does not appear before the Decision: flowchart (ordering violated)" >&2
    (( ++FAIL ))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
