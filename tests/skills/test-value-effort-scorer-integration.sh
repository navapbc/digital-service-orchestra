#!/usr/bin/env bash
# Structural validation for value/effort scorer integration.
# Tests: scorer prompt file existence, priority matrix boundary conditions,
#        brainstorm integration, roadmap integration, scale definition,
#        and roadmap example values use 1-5 scale.
# These are RED tests — all assertions fail until value-effort-scorer.md is created
# and brainstorm/roadmap SKILL.md files are updated to reference it.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCORER_MD="${REPO_ROOT}/plugins/dso/skills/shared/prompts/value-effort-scorer.md"
BRAINSTORM_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"
ROADMAP_MD="${REPO_ROOT}/plugins/dso/skills/roadmap/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: Scorer prompt file exists and is non-empty
# ---------------------------------------------------------------------------
test_scorer_file_exists() {
  echo "=== test_scorer_file_exists ==="

  if [ -f "$SCORER_MD" ] && [ -s "$SCORER_MD" ]; then
    pass "Scorer prompt file exists at plugins/dso/skills/shared/prompts/value-effort-scorer.md and is non-empty"
  else
    fail "Scorer prompt file missing or empty at plugins/dso/skills/shared/prompts/value-effort-scorer.md"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: Scorer prompt contains parseable priority matrix covering boundary conditions
# ---------------------------------------------------------------------------
test_scorer_priority_matrix_boundary_conditions() {
  echo ""
  echo "=== test_scorer_priority_matrix_boundary_conditions ==="

  if [ ! -f "$SCORER_MD" ]; then
    fail "Scorer prompt file missing — cannot check priority matrix"
    return
  fi

  SCORER_CONTENT="$(cat "$SCORER_MD")"

  # Priority matrix must be present
  if echo "$SCORER_CONTENT" | grep -qiE "priority matrix|P0|P1|P2|P3|P4"; then
    pass "Scorer prompt contains priority matrix with P-level labels"
  else
    fail "Scorer prompt missing priority matrix with P0/P1/P2/P3/P4 labels"
  fi

  # High-value, low-effort boundary: (5,1) → P0 or P1
  if echo "$SCORER_CONTENT" | grep -qiE "5.*1|high.*value.*low.*effort|low.*effort.*high.*value|P0|P1"; then
    pass "Scorer prompt covers high-value/low-effort boundary (5,1) → P0/P1"
  else
    fail "Scorer prompt missing high-value/low-effort boundary condition (5,1) → P0/P1"
  fi

  # Low-value, high-effort boundary: (1,5) → P3 or P4
  if echo "$SCORER_CONTENT" | grep -qiE "1.*5|low.*value.*high.*effort|high.*effort.*low.*value|P3|P4"; then
    pass "Scorer prompt covers low-value/high-effort boundary (1,5) → P3/P4"
  else
    fail "Scorer prompt missing low-value/high-effort boundary condition (1,5) → P3/P4"
  fi

  # High-value, high-effort boundary: (5,5) → P1 or P2
  if echo "$SCORER_CONTENT" | grep -qiE "P2|strategic|high.*value.*high.*effort|high.*effort.*high.*value"; then
    pass "Scorer prompt covers high-value/high-effort boundary (5,5) → P1/P2"
  else
    fail "Scorer prompt missing high-value/high-effort boundary condition (5,5) → P1/P2"
  fi

  # Low-value, low-effort boundary: (1,1) → P3 or P4
  if echo "$SCORER_CONTENT" | grep -qiE "fill.in|low.*value.*low.*effort|low.*effort.*low.*value|backlog|P3|P4"; then
    pass "Scorer prompt covers low-value/low-effort boundary (1,1) → P3/P4"
  else
    fail "Scorer prompt missing low-value/low-effort boundary condition (1,1) → P3/P4"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: Brainstorm SKILL.md references shared/prompts/value-effort-scorer.md
#         AND ticket create uses -p with a variable
# ---------------------------------------------------------------------------
test_brainstorm_scorer_integration() {
  echo ""
  echo "=== test_brainstorm_scorer_integration ==="

  if grep -q "shared/prompts/value-effort-scorer.md" "$BRAINSTORM_MD"; then
    pass "Brainstorm SKILL.md references shared/prompts/value-effort-scorer.md"
  else
    fail "Brainstorm SKILL.md missing reference to shared/prompts/value-effort-scorer.md"
  fi

  # ticket create must use -p with a variable (not a hardcoded literal)
  # Pattern: -p $var or -p <var> or -p ${var}
  if grep -qE "\-p[[:space:]]+(\\\$[a-zA-Z_]|<[a-zA-Z_])" "$BRAINSTORM_MD"; then
    pass "Brainstorm SKILL.md ticket create uses -p with a variable"
  else
    fail "Brainstorm SKILL.md ticket create missing -p with a variable (found hardcoded priority or missing -p)"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: Roadmap SKILL.md references shared/prompts/value-effort-scorer.md
#         AND uses 1-5 scale (not 1-10)
# ---------------------------------------------------------------------------
test_roadmap_scorer_integration() {
  echo ""
  echo "=== test_roadmap_scorer_integration ==="

  if grep -q "shared/prompts/value-effort-scorer.md" "$ROADMAP_MD"; then
    pass "Roadmap SKILL.md references shared/prompts/value-effort-scorer.md"
  else
    fail "Roadmap SKILL.md missing reference to shared/prompts/value-effort-scorer.md"
  fi

  # Must use 1-5 scale
  if grep -qE "Value \(1-5\)|Effort \(1-5\)|1-5 scale|scale.*1.*5|value.*1.*5|effort.*1.*5" "$ROADMAP_MD"; then
    pass "Roadmap SKILL.md uses 1-5 scale for value/effort scoring"
  else
    fail "Roadmap SKILL.md not using 1-5 scale (may still use 1-10)"
  fi

  # Must NOT use 1-10 scale for value/effort
  if grep -qE "Value \(1-10\)|Effort \(1-10\)" "$ROADMAP_MD"; then
    fail "Roadmap SKILL.md still uses legacy 1-10 scale for value/effort (must be updated to 1-5)"
  else
    pass "Roadmap SKILL.md does not use legacy 1-10 scale"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: Scorer defines value scale (1-5) and effort scale (1-5) with 5 distinct levels each
# ---------------------------------------------------------------------------
test_scorer_scale_definitions() {
  echo ""
  echo "=== test_scorer_scale_definitions ==="

  if [ ! -f "$SCORER_MD" ]; then
    fail "Scorer prompt file missing — cannot check scale definitions"
    return
  fi

  SCORER_CONTENT="$(cat "$SCORER_MD")"

  # Value scale 1-5 must be defined
  if echo "$SCORER_CONTENT" | grep -qiE "value.*scale|value.*1.*5|1.*=.*value|value.*1\b"; then
    pass "Scorer defines value scale with 1-5 range"
  else
    fail "Scorer missing value scale definition (1-5)"
  fi

  # Effort scale 1-5 must be defined
  if echo "$SCORER_CONTENT" | grep -qiE "effort.*scale|effort.*1.*5|1.*=.*effort|effort.*1\b"; then
    pass "Scorer defines effort scale with 1-5 range"
  else
    fail "Scorer missing effort scale definition (1-5)"
  fi

  # Count distinct numeric levels 1-5 in value section
  VALUE_LEVELS=$(python3 -c "
import re, sys
content = open(sys.argv[1]).read()
match = re.search(r'(?i)(value[^\n]*scale.*?)(?=effort[^\n]*scale|\Z)', content, re.DOTALL)
if not match:
    match = re.search(r'(?i)(#+\s*value.*?)(?=#+\s*effort|\Z)', content, re.DOTALL)
if match:
    section = match.group(1)
    levels = set(re.findall(r'\b([1-5])\b', section))
    print(len(levels))
else:
    levels = set(re.findall(r'\b([1-5])\b', content))
    print(len(levels))
" "$SCORER_MD" 2>/dev/null || echo "0")

  if [ "$VALUE_LEVELS" -ge 5 ] 2>/dev/null; then
    pass "Scorer value scale contains 5 distinct levels (1-5)"
  else
    fail "Scorer value scale missing 5 distinct levels (found $VALUE_LEVELS level(s))"
  fi

  # Count distinct numeric levels 1-5 in effort section
  EFFORT_LEVELS=$(python3 -c "
import re, sys
content = open(sys.argv[1]).read()
match = re.search(r'(?i)(effort[^\n]*scale.*?)(?=#+|\Z)', content, re.DOTALL)
if not match:
    match = re.search(r'(?i)(#+\s*effort.*?)(?=#+|\Z)', content, re.DOTALL)
if match:
    section = match.group(1)
    levels = set(re.findall(r'\b([1-5])\b', section))
    print(len(levels))
else:
    levels = set(re.findall(r'\b([1-5])\b', content))
    print(len(levels))
" "$SCORER_MD" 2>/dev/null || echo "0")

  if [ "$EFFORT_LEVELS" -ge 5 ] 2>/dev/null; then
    pass "Scorer effort scale contains 5 distinct levels (1-5)"
  else
    fail "Scorer effort scale missing 5 distinct levels (found $EFFORT_LEVELS level(s))"
  fi
}

# ---------------------------------------------------------------------------
# Test 6: Roadmap Phase 3 example output and Enabler Logic examples all use 1-5 scale values
# ---------------------------------------------------------------------------
test_roadmap_phase3_examples_use_1_5_scale() {
  echo ""
  echo "=== test_roadmap_phase3_examples_use_1_5_scale ==="

  PHASE3_LENGTH=$(python3 -c "
import re, sys
content = open(sys.argv[1]).read()
match = re.search(r'(?m)(### Phase 3:.*?)(?=^### |\Z)', content, re.DOTALL)
print(len(match.group(1)) if match else 0)
" "$ROADMAP_MD" 2>/dev/null || echo "0")

  if [ "$PHASE3_LENGTH" -eq 0 ] 2>/dev/null; then
    fail "Roadmap SKILL.md missing Phase 3 section — cannot check example values"
    return
  fi

  # All Value: and Effort: annotations in Phase 3 must be 1-5 (not 6-10)
  OUT_OF_RANGE=$(python3 -c "
import re, sys
content = open(sys.argv[1]).read()
match = re.search(r'(?m)(### Phase 3:.*?)(?=^### |\Z)', content, re.DOTALL)
section = match.group(1) if match else ''
matches = re.findall(r'(?:Value|Effort):\s*(\d+)', section)
out_of_range = [int(m) for m in matches if int(m) > 5 or int(m) < 1]
print(len(out_of_range))
" "$ROADMAP_MD" 2>/dev/null || echo "error")

  if [ "$OUT_OF_RANGE" = "error" ]; then
    fail "Roadmap Phase 3 example check failed (script error)"
  elif [ "$OUT_OF_RANGE" -eq 0 ] 2>/dev/null; then
    pass "All Value/Effort example annotations in Roadmap Phase 3 use 1-5 scale"
  else
    fail "Roadmap Phase 3 examples contain $OUT_OF_RANGE out-of-range Value/Effort annotation(s) (must be 1-5)"
  fi

  # Enabler Logic example must also use 1-5 scale
  ENABLER_OUT_OF_RANGE=$(python3 -c "
import re, sys
content = open(sys.argv[1]).read()
match = re.search(r'(?m)(### Phase 3:.*?)(?=^### |\Z)', content, re.DOTALL)
section = match.group(1) if match else ''
ematch = re.search(r'(?i)(enabler.*?logic.*?)(?=\n#+|\Z)', section, re.DOTALL)
esection = ematch.group(1) if ematch else section
matches = re.findall(r'(?:Value|Effort):\s*(\d+)', esection)
out_of_range = [int(m) for m in matches if int(m) > 5 or int(m) < 1]
print(len(out_of_range))
" "$ROADMAP_MD" 2>/dev/null || echo "error")

  if [ "$ENABLER_OUT_OF_RANGE" = "error" ]; then
    fail "Enabler Logic example check failed (script error)"
  elif [ "$ENABLER_OUT_OF_RANGE" -eq 0 ] 2>/dev/null; then
    pass "Enabler Logic examples in Roadmap Phase 3 use 1-5 scale"
  else
    fail "Enabler Logic examples contain $ENABLER_OUT_OF_RANGE out-of-range Value/Effort annotation(s) (must be 1-5)"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_scorer_file_exists
test_scorer_priority_matrix_boundary_conditions
test_brainstorm_scorer_integration
test_roadmap_scorer_integration
test_scorer_scale_definitions
test_roadmap_phase3_examples_use_1_5_scale

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
