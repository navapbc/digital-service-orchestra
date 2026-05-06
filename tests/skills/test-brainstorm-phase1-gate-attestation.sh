#!/usr/bin/env bash
# shellcheck disable=SC2329
# GREEN tests for Phase 1 Gate completeness attestation in brainstorm SKILL.md.
# Tests: attestation field required, exhausted/open values, gate blocks without attestation,
# exhausted state definition, open state lists unresolved.
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
echo "=== test_attestation_field_required ==="
SECTION="test_attestation_field_required"

# Assert SKILL.md contains attestation field requirement
if grep -qiE 'attestation' "$SKILL_MD"; then
  pass "SKILL.md Phase 1 Gate contains attestation field"
else
  fail "SKILL.md Phase 1 Gate missing attestation field"
fi

# ============================================================
echo ""
echo "=== test_attestation_values_exhausted_and_open ==="
SECTION="test_attestation_values_exhausted_and_open"

# Assert both 'exhausted' and 'open' are documented attestation values
if grep -q 'exhausted' "$SKILL_MD" && grep -q '\bopen\b' "$SKILL_MD"; then
  pass "SKILL.md documents both 'exhausted' and 'open' as attestation values"
else
  fail "SKILL.md missing 'exhausted' or 'open' attestation values"
fi

# ============================================================
echo ""
echo "=== test_gate_blocks_without_attestation ==="
SECTION="test_gate_blocks_without_attestation"

# Assert gate CANNOT return passed without attestation field
if grep -qiE 'CANNOT return passed without.*attestation|attestation.*field.*CANNOT|missing.*attestation.*non-passing|absent.*attestation.*non-passing' "$SKILL_MD"; then
  pass "SKILL.md states gate CANNOT return passed without attestation field"
else
  fail "SKILL.md missing blocking rule: gate cannot return passed without attestation"
fi

# ============================================================
echo ""
echo "=== test_exhausted_state_defined ==="
SECTION="test_exhausted_state_defined"

# Assert 'exhausted' is defined as all questions resolved
if grep -qiE 'exhausted.*ALL.*gap|exhausted.*all.*question.*resolved|exhausted.*gap.*list.*empty|exhausted.*when.*gap.*list.*empty' "$SKILL_MD"; then
  pass "SKILL.md defines 'exhausted' as all gap questions resolved"
else
  fail "SKILL.md missing definition of 'exhausted' state (all gap questions resolved)"
fi

# ============================================================
echo ""
echo "=== test_open_state_lists_unresolved ==="
SECTION="test_open_state_lists_unresolved"

# Assert 'open' state lists unresolved questions with blocking_for fields
if grep -qiE 'open.*unresolved.*blocking_for|open.*lists.*unresolved|blocking_for.*open|open.*blocking_for' "$SKILL_MD"; then
  pass "SKILL.md documents 'open' state lists unresolved questions with blocking_for fields"
else
  fail "SKILL.md missing 'open' state definition with blocking_for fields for unresolved questions"
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
