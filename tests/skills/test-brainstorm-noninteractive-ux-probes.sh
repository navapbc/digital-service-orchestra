#!/usr/bin/env bash
# shellcheck disable=SC2329
# RED tests: non-interactive UX probe skip and loop-back bypass path in brainstorm SKILL.md.
# These tests FAIL until the SKILL.md amendment (task 128e-a0e7) adds the non-interactive path.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"
source "${REPO_ROOT}/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_MD=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ============================================================
echo "=== test_brainstorm_interactive_probe_skip ==="
SECTION="test_brainstorm_interactive_probe_skip"

if grep -qiE 'BRAINSTORM_INTERACTIVE.*false.*skip|non.interactive.*skip.*probe|skip.*probe.*non.interactive|non.interactive.*path.*probe' "$SKILL_MD"; then
  pass "SKILL.md contains non-interactive probe-skip text"
else
  fail "SKILL.md missing non-interactive probe-skip text (BRAINSTORM_INTERACTIVE=false skip path)"
fi

# ============================================================
echo ""
echo "=== test_interactivity_deferred_emit ==="
SECTION="test_interactivity_deferred_emit"

if grep -q 'INTERACTIVITY_DEFERRED: UX probes require user input' "$SKILL_MD"; then
  pass "SKILL.md contains INTERACTIVITY_DEFERRED: UX probes require user input"
else
  fail "SKILL.md missing INTERACTIVITY_DEFERRED: UX probes require user input emission"
fi

# ============================================================
echo ""
echo "=== test_ui_probes_deferred_tag ==="
SECTION="test_ui_probes_deferred_tag"

if grep -q 'ui_probes:deferred' "$SKILL_MD"; then
  pass "SKILL.md contains ui_probes:deferred tag"
else
  fail "SKILL.md missing ui_probes:deferred tag"
fi

# ============================================================
echo ""
echo "=== test_loopback_bypass_noninteractive ==="
SECTION="test_loopback_bypass_noninteractive"

if grep -qiE 'non.interactive.*exception|non.interactive.*do not loop|BRAINSTORM_INTERACTIVE.*false.*loop|non.interactive.*UX.probe.*gap' "$SKILL_MD"; then
  pass "SKILL.md contains non-interactive loop-back bypass/exception text"
else
  fail "SKILL.md missing non-interactive loop-back bypass/exception (loop-back does not apply when BRAINSTORM_INTERACTIVE=false)"
fi

# ============================================================
echo ""
echo "=== test_phase1_terminates_on_ux_probe_gap ==="
SECTION="test_phase1_terminates_on_ux_probe_gap"

if grep -qiE 'terminate.*gap.*deferred|terminat.*ui_probes|gap.*deferred.*ui_probes|non.interactive.*gap.*terminat|ui_probes:deferred.*gap|deferred.*tag.*terminat' "$SKILL_MD"; then
  pass "SKILL.md contains phase1 termination on UX probe gap (non-interactive)"
else
  fail "SKILL.md missing phase1 termination on UX probe gap for non-interactive path"
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
