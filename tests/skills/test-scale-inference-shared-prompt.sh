#!/usr/bin/env bash
# Structural validation for scale-inference shared prompt integration.
# Tests: scale-inference.md file existence, required sections (Scale Signal Sources,
#        Inference Protocol, Default Assumption, upward interpolation prohibition),
#        and brainstorm/SKILL.md reference.
# These are RED tests — all assertions fail until scale-inference.md is created
# (task 334f-f7ab) and brainstorm/SKILL.md is updated to reference it (task 8f37-ddb2).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCALE_INFERENCE_MD="${REPO_ROOT}/plugins/dso/skills/shared/prompts/scale-inference.md"
BRAINSTORM_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: scale-inference.md exists and is non-empty
# ---------------------------------------------------------------------------
test_scale_inference_file_exists() {
  echo "=== test_scale_inference_file_exists ==="

  if [ -s "$SCALE_INFERENCE_MD" ] && grep -q "^## Scale Signal Sources" "$SCALE_INFERENCE_MD"; then
    pass "scale-inference.md exists and has required '## Scale Signal Sources' section"
  else
    fail "scale-inference.md missing or does not contain required '## Scale Signal Sources' heading"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: scale-inference.md contains required sections and content
# ---------------------------------------------------------------------------
test_scale_inference_required_sections() {
  echo ""
  echo "=== test_scale_inference_required_sections ==="

  if [ ! -f "$SCALE_INFERENCE_MD" ]; then
    fail "scale-inference.md missing — cannot check '## Inference Protocol' heading"
    fail "scale-inference.md missing — cannot check '## Default Assumption' heading"
    fail "scale-inference.md missing — cannot check prohibition section heading"
    return
  fi

  # Must have "## Inference Protocol" heading with a multi-step protocol (Step 1, Step 2, Step 3)
  if grep -q "^## Inference Protocol" "$SCALE_INFERENCE_MD" && \
     grep -qE "Step 1|Step 2|Step 3" "$SCALE_INFERENCE_MD"; then
    pass "scale-inference.md has '## Inference Protocol' heading with multi-step protocol (Step 1/2/3)"
  else
    fail "scale-inference.md missing '## Inference Protocol' heading or multi-step protocol"
  fi

  # Must have "## Default Assumption" heading
  if grep -q "^## Default Assumption" "$SCALE_INFERENCE_MD"; then
    pass "scale-inference.md has '## Default Assumption' section heading"
  else
    fail "scale-inference.md missing '## Default Assumption' section heading"
  fi

  # Must have a prohibition section heading (## Prohibition on Upward Interpolation or similar)
  if grep -qiE "^## Prohibition|^## Upward" "$SCALE_INFERENCE_MD"; then
    pass "scale-inference.md has prohibition section heading"
  else
    fail "scale-inference.md missing prohibition section heading (e.g., '## Prohibition on Upward Interpolation')"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: brainstorm/SKILL.md references shared/prompts/scale-inference.md
# ---------------------------------------------------------------------------
test_brainstorm_phase1_references_scale_inference() {
  echo ""
  echo "=== test_brainstorm_phase1_references_scale_inference ==="

  if grep -q "shared/prompts/scale-inference.md" "$BRAINSTORM_MD"; then
    pass "Brainstorm SKILL.md references shared/prompts/scale-inference.md"
  else
    fail "Brainstorm SKILL.md missing reference to shared/prompts/scale-inference.md"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_scale_inference_file_exists
test_scale_inference_required_sections
test_brainstorm_phase1_references_scale_inference

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
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
