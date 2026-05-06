#!/usr/bin/env bash
# shellcheck disable=SC2329
# GREEN tests for PRECONDITIONS decisions_log write and workflow_completion_checklist
# in brainstorm SKILL.md Phase 1 Gate.
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
echo "=== test_decisions_log_in_phase1_gate ==="
SECTION="test_decisions_log_in_phase1_gate"

# Assert decisions_log or PRECONDITIONS write in the Phase 1 Gate section
if grep -qiE 'decisions_log|PRECONDITIONS.*decisions|write.*preconditions|preconditions-record.*phase1' "$SKILL_MD"; then
  pass "SKILL.md Phase 1 Gate contains decisions_log / PRECONDITIONS write"
else
  fail "SKILL.md Phase 1 Gate missing decisions_log or PRECONDITIONS write"
fi

# ============================================================
echo ""
echo "=== test_workflow_completion_checklist ==="
SECTION="test_workflow_completion_checklist"

# Assert workflow_completion_checklist appears in SKILL.md
if grep -q 'workflow_completion_checklist' "$SKILL_MD"; then
  pass "SKILL.md contains workflow_completion_checklist field reference"
else
  fail "SKILL.md missing workflow_completion_checklist field reference"
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
