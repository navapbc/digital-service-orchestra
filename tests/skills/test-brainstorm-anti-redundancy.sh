#!/usr/bin/env bash
# shellcheck disable=SC2329
# RED tests for anti-redundancy directive in brainstorm SKILL.md.
# Tests: top-level gate exists, semantic check requirement, codebase check requirement,
# probe suppression rule.
# NOTE: These tests are intentionally RED — SKILL.md sections they check do not exist yet.
# They will turn GREEN when the implementation task adds the <ANTI-REDUNDANCY-GATE> block.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# NOTE: Use $SKILL_MD directly for top-level placement assertions (directive must live
# in SKILL.md root, not phase files — direct path enforces placement requirement).
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"
# Use $SKILL_CORPUS for content assertions (robustness against future phase-file extraction).
source "${REPO_ROOT}/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_CORPUS=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ============================================================
echo "=== test_anti_redundancy_gate_exists ==="
SECTION="test_anti_redundancy_gate_exists"

# Assert top-level placement in SKILL.md root (not phase files)
if grep -q 'ANTI-REDUNDANCY-GATE\|Anti-Redundancy.*[Gg]ate\|anti.redundancy.*directive' "$SKILL_MD"; then
  pass "SKILL.md contains anti-redundancy gate or directive at top level"
else
  fail "SKILL.md missing anti-redundancy gate or directive at top level"
fi

# ============================================================
echo ""
echo "=== test_semantic_check_requirement ==="
SECTION="test_semantic_check_requirement"

# Assert semantic duplicate check (paraphrase and negative signals)
if grep -qiE 'I told you|I answered that|paraphrase|negative signal|semantic.*check|prior.*turn' "$SKILL_CORPUS"; then
  pass "SKILL.md documents semantic duplicate check (paraphrase and negative signals)"
else
  fail "SKILL.md missing semantic duplicate check requirement (expected: paraphrase detection, negative signals)"
fi

# ============================================================
echo ""
echo "=== test_codebase_check_requirement ==="
SECTION="test_codebase_check_requirement"

# Assert codebase check in anti-redundancy context
if grep -qiE 'Read.*Grep.*Glob|Grep.*Read.*Glob|Glob.*Read.*Grep|codebase.*before.*question|before.*forming.*any.*question|before.*any.*question.*codebase' "$SKILL_CORPUS" && \
   grep -qiE 'anti.redundancy|ANTI-REDUNDANCY' "$SKILL_CORPUS"; then
  pass "SKILL.md documents codebase check (Read/Grep/Glob) in anti-redundancy context"
else
  fail "SKILL.md missing codebase check in anti-redundancy directive"
fi

# ============================================================
echo ""
echo "=== test_probe_suppression_rule ==="
SECTION="test_probe_suppression_rule"

# Assert probe suppression when prior answers cover probe topics
if grep -qiE 'suppress.*probe|probe.*suppress|skip.*probe|probe.*skip' "$SKILL_CORPUS"; then
  pass "SKILL.md documents probe suppression when prior answers cover probe topics"
else
  fail "SKILL.md missing probe suppression rule for prior answers covering probe topics"
fi

# Assert probe suppression references probe dimension IDs from ux-probe-set.md
UX_PROBE_FILE="${REPO_ROOT}/plugins/dso/skills/brainstorm/prompts/ux-probe-set.md"
for probe_id in criticality non_happy_path flow_entry_exit; do
  if grep -q "$probe_id" "$SKILL_MD"; then
    pass "SKILL.md gate references probe ID: $probe_id"
  else
    fail "SKILL.md gate missing probe ID: $probe_id (must match ux-probe-set.md dimension IDs)"
  fi
done

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
