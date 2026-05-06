#!/usr/bin/env bash
# shellcheck disable=SC2329
# GREEN tests for META_QUESTION signal routing in brainstorm SKILL.md.
# Tests: META_QUESTION signal exists, distinct from REPLAN_ESCALATE,
# blocking_for brainstorm trigger condition.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"
source "${REPO_ROOT}/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_CORPUS=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ============================================================
echo "=== test_meta_question_signal_exists ==="
SECTION="test_meta_question_signal_exists"

# Assert META_QUESTION appears in SKILL.md as a distinct signal type
if grep -q 'META_QUESTION' "$SKILL_MD"; then
  pass "SKILL.md contains META_QUESTION signal"
else
  fail "SKILL.md missing META_QUESTION signal"
fi

# ============================================================
echo ""
echo "=== test_meta_question_not_replan_escalate ==="
SECTION="test_meta_question_not_replan_escalate"

# Assert META_QUESTION is documented as distinct from REPLAN_ESCALATE
if grep -qiE 'META_QUESTION.*NOT REPLAN_ESCALATE|META_QUESTION.*not.*REPLAN_ESCALATE' "$SKILL_MD"; then
  pass "SKILL.md documents META_QUESTION as NOT REPLAN_ESCALATE"
else
  fail "SKILL.md missing distinction: META_QUESTION is NOT REPLAN_ESCALATE"
fi

# ============================================================
echo ""
echo "=== test_blocking_for_brainstorm_trigger ==="
SECTION="test_blocking_for_brainstorm_trigger"

# Assert blocking_for brainstorm as the trigger condition for META_QUESTION
if grep -qiE 'blocking_for.*brainstorm.*META_QUESTION|blocking_for.*resolves.*brainstorm.*META_QUESTION|blocking_for.*brainstorm' "$SKILL_MD"; then
  pass "SKILL.md documents blocking_for: brainstorm as META_QUESTION trigger condition"
else
  fail "SKILL.md missing blocking_for: brainstorm trigger condition for META_QUESTION"
fi

# ============================================================
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
