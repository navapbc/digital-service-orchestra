#!/usr/bin/env bash
# tests/skills/test-preplanning-design-review-loop.sh
# RED test for SC5 of epic 28cb-a23a:
#   dispatch-protocol.md Section 4 must implement an orchestrator-managed
#   design review loop (max 3 cycles) with INTERACTIVITY_DEFERRED escalation.
#
# Assertions (all must pass):
#   1. Section 4 has a heading ('## 4.' prefix)
#   2. Section 4 contains a review cycle counter variable
#   3. Section 4 references max_review_cycles (= 3)
#   4. Section 4 references REVIEW_PASS or review pass branching
#   5. Section 4 references REVIEW_FAIL or review fail branching
#   6. Section 4 references /dso:review-protocol (or review-protocol invocation)
#   7. Section 4 contains INTERACTIVITY_DEFERRED escalation text
#
# Usage: bash tests/skills/test-preplanning-design-review-loop.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DISPATCH_PROTOCOL="${REPO_ROOT}/plugins/dso/skills/preplanning/prompts/ui-designer-dispatch-protocol.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Extract Section 4 from dispatch-protocol.md:
#   from the "## 4." heading to the next "## " heading (or EOF).
# Returns empty string if the heading is not found.
# ---------------------------------------------------------------------------
extract_section_4() {
  python3 - "$DISPATCH_PROTOCOL" <<'PYEOF'
import sys, re

text = open(sys.argv[1]).read()
# Match "## 4." heading (with any suffix after "4.")
start = re.search(r'^## 4\.', text, re.MULTILINE)
if not start:
    sys.exit(0)
rest = text[start.start():]
# Find the next ## heading after the first line
end_match = re.search(r'\n## ', rest[1:])
if end_match:
    section = rest[:end_match.start() + 1]
else:
    section = rest
print(section)
PYEOF
}

SECTION4="$(extract_section_4)"

# ---------------------------------------------------------------------------
# Test 1: Section 4 heading exists
# ---------------------------------------------------------------------------
echo "=== test_section4_heading ==="
SECTION="test_section4_heading"
if grep -qE "^## 4\." "$DISPATCH_PROTOCOL"; then
  pass "dispatch-protocol.md has a '## 4.' section heading"
else
  fail "dispatch-protocol.md missing '## 4.' section heading"
fi

# ---------------------------------------------------------------------------
# Test 2: Section 4 contains a review cycle counter variable
# ---------------------------------------------------------------------------
echo ""
echo "=== test_review_cycle_counter ==="
SECTION="test_review_cycle_counter"
if grep -qiE "review_cycle_count|cycle_count|review.*cycle.*=.*0|cycle.*counter" <<< "$SECTION4"; then
  pass "Section 4 contains a review cycle counter variable"
else
  fail "Section 4 missing review cycle counter variable (expected: review_cycle_count = 0 or similar)"
fi

# ---------------------------------------------------------------------------
# Test 3: Section 4 references max_review_cycles with value 3
# ---------------------------------------------------------------------------
echo ""
echo "=== test_max_review_cycles ==="
SECTION="test_max_review_cycles"
if grep -qiE "max_review_cycles|max.*cycles.*3|3.*max.*cycle|maximum.*3.*cycle|cycle.*maximum.*3|max.*3" <<< "$SECTION4"; then
  pass "Section 4 references max_review_cycles (3)"
else
  fail "Section 4 missing max_review_cycles = 3 (or equivalent maximum cycle count)"
fi

# ---------------------------------------------------------------------------
# Test 4: Section 4 references REVIEW_PASS branching
# ---------------------------------------------------------------------------
echo ""
echo "=== test_review_pass_branch ==="
SECTION="test_review_pass_branch"
if grep -qiE "REVIEW_PASS|review.*pass|pass.*review|review.*succeed|review.*approved|review.*accept" <<< "$SECTION4"; then
  pass "Section 4 contains REVIEW_PASS (or equivalent) branching"
else
  fail "Section 4 missing REVIEW_PASS branch — expected REVIEW_PASS signal or equivalent pass/approval path"
fi

# ---------------------------------------------------------------------------
# Test 5: Section 4 references REVIEW_FAIL branching
# ---------------------------------------------------------------------------
echo ""
echo "=== test_review_fail_branch ==="
SECTION="test_review_fail_branch"
if grep -qiE "REVIEW_FAIL|review.*fail|fail.*review|review.*reject|reject.*review|review.*did not pass|review.*not.*pass" <<< "$SECTION4"; then
  pass "Section 4 contains REVIEW_FAIL (or equivalent) branching"
else
  fail "Section 4 missing REVIEW_FAIL branch — expected REVIEW_FAIL signal or equivalent failure/rejection path"
fi

# ---------------------------------------------------------------------------
# Test 6: Section 4 invokes /dso:review-protocol (or review-protocol)
# ---------------------------------------------------------------------------
echo ""
echo "=== test_review_protocol_invocation ==="
SECTION="test_review_protocol_invocation"
if grep -qiE "review-protocol|/dso:review-protocol|dso:review-protocol|review_protocol" <<< "$SECTION4"; then
  pass "Section 4 references /dso:review-protocol invocation"
else
  fail "Section 4 missing /dso:review-protocol invocation — must invoke review-protocol on design artifacts"
fi

# ---------------------------------------------------------------------------
# Test 7: Section 4 contains INTERACTIVITY_DEFERRED escalation
# ---------------------------------------------------------------------------
echo ""
echo "=== test_interactivity_deferred ==="
SECTION="test_interactivity_deferred"
if grep -qE "INTERACTIVITY_DEFERRED" <<< "$SECTION4"; then
  pass "Section 4 contains INTERACTIVITY_DEFERRED escalation for non-interactive sessions"
else
  fail "Section 4 missing INTERACTIVITY_DEFERRED escalation — required for non-interactive mode at max cycles"
fi

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
