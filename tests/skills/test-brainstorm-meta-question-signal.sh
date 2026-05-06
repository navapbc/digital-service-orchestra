#!/usr/bin/env bash
# shellcheck disable=SC2329
# RED/GREEN tests for Phase 1 Gate META_QUESTION signal.
# Tests: META_QUESTION signal defined, distinct from REPLAN_ESCALATE,
# blocking_for condition documented, REPLAN_ESCALATE mid-workflow preserved.
# NOTE: Tests 1-3 are intentionally RED — SKILL.md sections don't exist yet.
# Test 4 checks the META_QUESTION distinction in Phase 1 Gate section (RED).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"
source "${REPO_ROOT}/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_CORPUS=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT

source "${REPO_ROOT}/tests/lib/assert.sh"

# ============================================================
# test_meta_question_signal_defined
# Grep SKILL.md for META_QUESTION signal name.
# RED: META_QUESTION signal not defined yet.
# ============================================================
echo "=== test_meta_question_signal_defined ==="

if grep -q 'META_QUESTION' "$SKILL_CORPUS"; then
    actual=present
else
    actual=missing
fi
assert_eq "SKILL.md must define META_QUESTION signal" "present" "$actual"

# ============================================================
# test_meta_question_not_replan_escalate
# Grep for pattern showing META_QUESTION is distinct from REPLAN_ESCALATE.
# RED: distinction not documented yet.
# ============================================================
echo ""
echo "=== test_meta_question_not_replan_escalate ==="

if grep -qiE 'META_QUESTION.*NOT.*REPLAN_ESCALATE|not.*REPLAN_ESCALATE.*META_QUESTION|META_QUESTION.*instead.*REPLAN|use META_QUESTION.*not REPLAN' "$SKILL_CORPUS"; then
    actual=present
else
    actual=missing
fi
assert_eq "SKILL.md must document that META_QUESTION is NOT REPLAN_ESCALATE" "present" "$actual"

# ============================================================
# test_meta_question_blocking_for_condition
# Grep for blocking_for referencing brainstorm in META_QUESTION context.
# RED: blocking_for condition not documented yet.
# ============================================================
echo ""
echo "=== test_meta_question_blocking_for_condition ==="

if grep -qiE 'blocking_for.*brainstorm|META_QUESTION.*blocking_for' "$SKILL_CORPUS"; then
    actual=present
else
    actual=missing
fi
assert_eq "SKILL.md META_QUESTION must document blocking_for brainstorm condition" "present" "$actual"

# ============================================================
# test_replan_escalate_mid_workflow_preserved
# REPLAN_ESCALATE exists for mid-workflow discovery (later phases).
# This tests that:
#   (a) REPLAN_ESCALATE is still documented in SKILL.md corpus (should PASS)
#   (b) Phase 1 Gate section has the META_QUESTION distinction (RED: not yet)
# ============================================================
echo ""
echo "=== test_replan_escalate_mid_workflow_preserved ==="

# Part (a): REPLAN_ESCALATE must still exist in the corpus (GREEN — pre-existing)
if grep -q 'REPLAN_ESCALATE' "$SKILL_CORPUS"; then
    replan_present=present
else
    replan_present=missing
fi
assert_eq "SKILL.md corpus must still document REPLAN_ESCALATE for mid-workflow use" "present" "$replan_present"

# Part (b): Phase 1 Gate section must distinguish META_QUESTION from REPLAN_ESCALATE (RED)
if grep -qiE 'Phase 1.*META_QUESTION|META_QUESTION.*Phase 1|Phase 1 Gate.*META_QUESTION' "$SKILL_CORPUS"; then
    phase1_distinction=present
else
    phase1_distinction=missing
fi
assert_eq "Phase 1 Gate section must contain META_QUESTION distinction from REPLAN_ESCALATE" "present" "$phase1_distinction"

# ============================================================
print_summary
