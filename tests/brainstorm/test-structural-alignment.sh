#!/usr/bin/env bash
# test-structural-alignment.sh: Structural alignment assertions for all 8 markers from S1-S6.
# Verifies that key structural elements introduced across stories are present
# in their respective files — a GREEN regression guard.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== test_all_8_markers_present ==="

# Marker 1: SKILL.md contains "Inputs" in the progressive validation probe table
if grep -q "Inputs" "$REPO_ROOT/plugins/dso/skills/brainstorm/SKILL.md"; then
  pass "Marker 1: SKILL.md contains 'Inputs' (probe table)"
else
  fail "Marker 1: SKILL.md missing 'Inputs' (probe table)"
fi

# Marker 2: SKILL.md contains "Inputs" as a non-optional Understanding Summary bullet
# (same file, confirmed present in Understanding Summary section)
if grep -q "Inputs" "$REPO_ROOT/plugins/dso/skills/brainstorm/SKILL.md"; then
  pass "Marker 2: SKILL.md contains 'Inputs' (Understanding Summary)"
else
  fail "Marker 2: SKILL.md missing 'Inputs' (Understanding Summary)"
fi

# Marker 3a: epic-scrutiny-pipeline.md Part B contains "Inference-Signal Scan"
if grep -q "Inference-Signal Scan" "$REPO_ROOT/plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"; then
  pass "Marker 3a: epic-scrutiny-pipeline.md contains 'Inference-Signal Scan'"
else
  fail "Marker 3a: epic-scrutiny-pipeline.md missing 'Inference-Signal Scan'"
fi

# Marker 3b: epic-scrutiny-pipeline.md Part B contains "5-second"
if grep -q "5-second" "$REPO_ROOT/plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"; then
  pass "Marker 3b: epic-scrutiny-pipeline.md contains '5-second'"
else
  fail "Marker 3b: epic-scrutiny-pipeline.md missing '5-second'"
fi

# Marker 4a: inferred-source-marker.md contract file exists
if test -f "$REPO_ROOT/plugins/dso/docs/contracts/inferred-source-marker.md"; then
  pass "Marker 4a: inferred-source-marker.md contract exists"
else
  fail "Marker 4a: inferred-source-marker.md contract missing"
fi

# Marker 4b: SKILL.md references <<inferred:...>> markers
if grep -q "inferred" "$REPO_ROOT/plugins/dso/skills/brainstorm/SKILL.md"; then
  pass "Marker 4b: SKILL.md references 'inferred' markers"
else
  fail "Marker 4b: SKILL.md missing 'inferred' marker reference"
fi

# Marker 5: scenario-red-team.md contains "assumption" category
if grep -q "assumption" "$REPO_ROOT/plugins/dso/skills/brainstorm/prompts/scenario-red-team.md"; then
  pass "Marker 5: scenario-red-team.md contains 'assumption' category"
else
  fail "Marker 5: scenario-red-team.md missing 'assumption' category"
fi

# Marker 6a: scenario-red-team.md contains '"assumption"' enum value
if grep -q '"assumption"' "$REPO_ROOT/plugins/dso/skills/brainstorm/prompts/scenario-red-team.md"; then
  pass "Marker 6a: scenario-red-team.md contains '\"assumption\"' enum value"
else
  fail "Marker 6a: scenario-red-team.md missing '\"assumption\"' enum value"
fi

# Marker 6b: post-scrutiny-handlers.md contains "assumption" (schema consumer consistency)
if grep -q "assumption" "$REPO_ROOT/plugins/dso/skills/brainstorm/phases/post-scrutiny-handlers.md"; then
  pass "Marker 6b: post-scrutiny-handlers.md contains 'assumption' (schema consumer)"
else
  fail "Marker 6b: post-scrutiny-handlers.md missing 'assumption' (schema consumer)"
fi

# Marker 7: approval-gate.md contains <<inferred bold rendering rule
if grep -q "<<inferred" "$REPO_ROOT/plugins/dso/skills/brainstorm/phases/approval-gate.md"; then
  pass "Marker 7: approval-gate.md contains '<<inferred' rendering rule"
else
  fail "Marker 7: approval-gate.md missing '<<inferred' rendering rule"
fi

# Marker 8: post-scrutiny-handlers.md contains "Premise to confirm"
if grep -q "Premise to confirm" "$REPO_ROOT/plugins/dso/skills/brainstorm/phases/post-scrutiny-handlers.md"; then
  pass "Marker 8: post-scrutiny-handlers.md contains 'Premise to confirm'"
else
  fail "Marker 8: post-scrutiny-handlers.md missing 'Premise to confirm'"
fi

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL VALIDATIONS PASSED" && exit 0
echo "VALIDATION FAILED"
exit 1
