#!/usr/bin/env bash
# tests/skills/test-sprint-phase8-end-session-gate.sh
# Asserts Phase 8 of sprint SKILL.md contains:
#   1. An ORCHESTRATOR_RESUME anchor within Phase 8 that warns against stopping after
#      merge-to-main.sh (bug 89fe-bad1 fix)
#   2. A HARD-GATE in step 5 that references the specific anti-pattern (89fe-bad1)
#   3. A MULTI-SPRINT-ROUTING gate that offers the user a next-epic branch before
#      invoking /dso:end-session (bug 3513-8abc fix)
#
# These are structural boundary checks per the behavioral testing standard.
# Tests the structure of the instruction, not its prose content.

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
# Extract Phase 8 section (from ## Phase 8 to the next ## heading or EOF)
# ---------------------------------------------------------------------------
phase8_content=$(awk '/^## Phase 8:/{flag=1; next} flag && /^## /{flag=0} flag' "$SKILL_MD")

# ---------------------------------------------------------------------------
# Test 2: Phase 8 references merge-to-main.sh returning
# ---------------------------------------------------------------------------
if echo "$phase8_content" | grep -q 'merge-to-main\.sh returning\|merge-to-main\.sh.*does NOT\|merge-to-main\.sh.*NOT.*signal'; then
    echo "PASS: test_orchestrator_resume_references_merge_to_main"
    (( ++PASS ))
else
    echo "FAIL: test_orchestrator_resume_references_merge_to_main — ORCHESTRATOR_RESUME does not warn against stopping after merge-to-main.sh" >&2
    (( ++FAIL ))
fi

# ---------------------------------------------------------------------------
# Test 3: HARD-GATE in step 4 references 89fe-bad1
# ---------------------------------------------------------------------------
if echo "$phase8_content" | grep -q '89fe-bad1'; then
    echo "PASS: test_phase8_hard_gate_references_89fe_bad1"
    (( ++PASS ))
else
    echo "FAIL: test_phase8_hard_gate_references_89fe_bad1 — Phase 8 HARD-GATE does not reference anti-pattern bug 89fe-bad1" >&2
    (( ++FAIL ))
fi

# ---------------------------------------------------------------------------
# Test 4: HARD-GATE still requires Skill tool invocation (regression guard)
# ---------------------------------------------------------------------------
if echo "$phase8_content" | grep -q 'Skill.*dso:end-session\|skill.*end-session'; then
    echo "PASS: test_phase8_hard_gate_requires_skill_tool"
    (( ++PASS ))
else
    echo "FAIL: test_phase8_hard_gate_requires_skill_tool — Phase 8 HARD-GATE no longer requires Skill tool invocation" >&2
    (( ++FAIL ))
fi

# ---------------------------------------------------------------------------
# Test 5: Phase 8 On Success contains a MULTI-SPRINT-ROUTING gate (bug 3513-8abc fix)
# ---------------------------------------------------------------------------
if echo "$phase8_content" | grep -q '<MULTI-SPRINT-ROUTING>'; then
    echo "PASS: test_phase8_has_multi_sprint_routing"
    (( ++PASS ))
else
    echo "FAIL: test_phase8_has_multi_sprint_routing — Phase 8 is missing <MULTI-SPRINT-ROUTING> gate (bug 3513-8abc fix)" >&2
    (( ++FAIL ))
fi

# ---------------------------------------------------------------------------
# Test 6: MULTI-SPRINT-ROUTING gate offers the user a next-epic branch
# ---------------------------------------------------------------------------
if echo "$phase8_content" | grep -q 'another epic\|next.*epic\|next-epic'; then
    echo "PASS: test_multi_sprint_routing_offers_next_epic"
    (( ++PASS ))
else
    echo "FAIL: test_multi_sprint_routing_offers_next_epic — MULTI-SPRINT-ROUTING gate does not offer a next-epic branch" >&2
    (( ++FAIL ))
fi

# ---------------------------------------------------------------------------
# Test 7: MULTI-SPRINT-ROUTING gate includes an EXIT path that skips end-session
# ---------------------------------------------------------------------------
if echo "$phase8_content" | grep -q 'EXIT Phase 8\|do NOT invoke.*end-session\|Do NOT invoke.*end-session'; then
    echo "PASS: test_multi_sprint_routing_has_exit_without_end_session"
    (( ++PASS ))
else
    echo "FAIL: test_multi_sprint_routing_has_exit_without_end_session — MULTI-SPRINT-ROUTING gate does not include an EXIT path that skips /dso:end-session" >&2
    (( ++FAIL ))
fi

# ---------------------------------------------------------------------------
# Test 10: Phase 8 continuation handling at step 2 explicitly handles the
# ticket-transition REMINDER message that causes agents to stop prematurely.
# The REMINDER "Epic closed — run /dso:end-session..." triggers sycophantic
# stop behavior unless the ORCHESTRATOR_RESUME explicitly neutralizes it.
# (bug 4add-0acd fix)
#
# Structural boundary: the ORCHESTRATOR_RESUME block must reference the REMINDER
# message and clarify it does NOT mean "stop here".
# ---------------------------------------------------------------------------
if echo "$phase8_content" | grep -qiE 'REMINDER.*informational|REMINDER.*does not|REMINDER.*do not stop|REMINDER.*not.*stop|ticket.transition.*REMINDER|REMINDER.*Epic closed'; then
    echo "PASS: test_orchestrator_resume_neutralizes_transition_reminder"
    (( ++PASS ))
else
    echo "FAIL: test_orchestrator_resume_neutralizes_transition_reminder — Phase 8 ORCHESTRATOR_RESUME does not address the ticket-transition REMINDER message (bug 4add-0acd)" >&2
    (( ++FAIL ))
fi

# REVIEW-DEFENSE: Tests 8 and 9 (test_phase8_has_orchestrator_resume_after_epic_close
# and test_a711_resume_warns_closure_is_not_done) were change-detector tests that
# grepped for the literal <ORCHESTRATOR_RESUME> XML tag and the bug reference
# "a711-bd7e" inside it. They were removed because the ORCHESTRATOR_RESUME blocks
# themselves were removed (8006-c7fc fix: MANDATORY CONTINUATION blocks were
# replaced with inline "When X completes, proceed to step N" continuations).
# The behavioral contract — that Phase 8 warns against stopping after epic ticket
# closure — is preserved in the SKILL.md prose; the tests were testing the
# implementation mechanism, not the behavior. User explicitly requested removal
# without replacement (not fixing the change-detector pattern).

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
