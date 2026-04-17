#!/usr/bin/env bash
# Structural validation for cross-epic interaction scan integration.
# Tests: classifier agent existence, scan prompt existence, SKILL.md reference,
# N=0 behavior, batch size reference, and four-tier classification names.
# REVIEW-DEFENSE: Behavioral testing standard rule 5 — instruction files (SKILL.md, agent .md, prompt .md)
# are tested at the structural boundary: presence, section ordering, required content. Dispatching a live
# classifier agent in tests would require mocking the LLM — see fixture-based tests in
# tests/scripts/test-cross-epic-classifier-fixture.sh for input/output contract coverage.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_DIR="${REPO_ROOT}/plugins/dso/skills/brainstorm"
AGENTS_DIR="${REPO_ROOT}/plugins/dso/agents"
SCAN_PROMPT="$SKILL_DIR/prompts/cross-epic-scan.md"
CLASSIFIER="$AGENTS_DIR/cross-epic-interaction-classifier.md"
SKILL_MD="$SKILL_DIR/SKILL.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ============================================================
echo "=== test_classifier_agent_exists ==="
SECTION="test_classifier_agent_exists"

if [ -f "$CLASSIFIER" ]; then
  pass "cross-epic-interaction-classifier.md agent file exists"
else
  fail "cross-epic-interaction-classifier.md agent file missing at $CLASSIFIER"
fi

# ============================================================
echo "=== test_scan_prompt_exists ==="
SECTION="test_scan_prompt_exists"

if [ -f "$SCAN_PROMPT" ]; then
  pass "cross-epic-scan.md prompt file exists"
else
  fail "cross-epic-scan.md prompt file missing at $SCAN_PROMPT"
fi

# ============================================================
echo "=== test_skill_md_reference ==="
SECTION="test_skill_md_reference"

if grep -q "cross-epic-scan.md" "$SKILL_MD" 2>/dev/null; then
  pass "SKILL.md references cross-epic-scan.md"
else
  fail "SKILL.md does not reference cross-epic-scan.md"
fi

# Verify reference appears between Step 2 and Step 2.5 markers
STEP2_LINE=$(grep -n "### Step 2:" "$SKILL_MD" | grep -v "Step 2\." | head -1 | cut -d: -f1)
STEP25_LINE=$(grep -n "Steps 2\.5" "$SKILL_MD" | head -1 | cut -d: -f1)
SCAN_REF_LINE=$(grep -n "cross-epic-scan.md" "$SKILL_MD" | head -1 | cut -d: -f1)

if [ -n "$STEP2_LINE" ] && [ -n "$STEP25_LINE" ] && [ -n "$SCAN_REF_LINE" ]; then
  if [ "$SCAN_REF_LINE" -gt "$STEP2_LINE" ] && [ "$SCAN_REF_LINE" -lt "$STEP25_LINE" ]; then
    pass "cross-epic-scan.md reference is between Step 2 and Steps 2.5 markers"
  else
    fail "cross-epic-scan.md reference is NOT between Step 2 (line $STEP2_LINE) and Steps 2.5 (line $STEP25_LINE); found at line $SCAN_REF_LINE"
  fi
else
  fail "Could not locate Step 2 (line $STEP2_LINE), Steps 2.5 (line $STEP25_LINE), or scan ref (line $SCAN_REF_LINE) in SKILL.md"
fi

# ============================================================
echo "=== test_n_zero_behavior ==="
SECTION="test_n_zero_behavior"

if grep -q "No open epics" "$SCAN_PROMPT" 2>/dev/null; then
  pass "cross-epic-scan.md contains 'No open epics' N=0 behavior text"
else
  fail "cross-epic-scan.md missing 'No open epics' N=0 behavior text"
fi

# ============================================================
echo "=== test_batch_size_reference ==="
SECTION="test_batch_size_reference"

if grep -q "20" "$SCAN_PROMPT" 2>/dev/null; then
  pass "cross-epic-scan.md contains batch size reference '20'"
else
  fail "cross-epic-scan.md missing batch size reference '20'"
fi

# ============================================================
echo "=== test_four_tier_classification ==="
SECTION="test_four_tier_classification"

for tier in benign consideration ambiguity conflict; do
  if grep -q "$tier" "$CLASSIFIER" 2>/dev/null; then
    pass "cross-epic-interaction-classifier.md contains tier: $tier"
  else
    fail "cross-epic-interaction-classifier.md missing tier: $tier"
  fi
done

# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
