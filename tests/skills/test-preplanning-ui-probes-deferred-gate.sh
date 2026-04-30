#!/usr/bin/env bash
# shellcheck disable=SC2329
# RED tests for UI Probes Deferred Gate in preplanning SKILL.md.
# Tests FAIL until the GREEN task adds the gate section to SKILL.md.
# Per behavioral-testing-standard.md Rule 5: test the structural boundary.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_FILE="${REPO_ROOT}/plugins/dso/skills/preplanning/SKILL.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ============================================================
echo "=== test_ui_probes_deferred_gate_halts ==="
SECTION="test_ui_probes_deferred_gate_halts"

if grep -qiE 'UI Probes Deferred Gate|ui_probes:deferred.*HALT|HALT.*ui_probes:deferred' "$SKILL_FILE"; then
  pass "preplanning SKILL.md contains UI Probes Deferred Gate halt directive"
else
  fail "preplanning SKILL.md missing UI Probes Deferred Gate halt directive"
fi

# ============================================================
echo ""
echo "=== test_ui_probes_deferred_gate_passthrough ==="
SECTION="test_ui_probes_deferred_gate_passthrough"

if grep -qiE 'ui_probes:deferred.*absent|ui_probes:deferred.*NOT present|ui_probes:deferred.*proceed' "$SKILL_FILE"; then
  pass "preplanning SKILL.md contains UI Probes Deferred Gate pass-through for absent tag"
else
  fail "preplanning SKILL.md missing UI Probes Deferred Gate pass-through for absent tag"
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
