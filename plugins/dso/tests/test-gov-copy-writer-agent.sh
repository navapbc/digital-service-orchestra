#!/usr/bin/env bash
# tests/test-gov-copy-writer-agent.sh
# Behavioral tests for the gov-copy-writer agent file.
#
# Covers story 074b-c6f1-174a-4832, task a7d9-a126-d50d-4c9f.
# DDs tested:
#   dd-1 (074b): agent file exists, has correct frontmatter, and prompt documents
#                the precedence ladder, top-K cap, and structured rationale schema
#
# Test plan:
#   1. Agent file exists at expected path
#   2. File has YAML frontmatter delimiters (--- ... ---)
#   3. Frontmatter declares name: gov-copy-writer
#   4. Frontmatter declares model: sonnet
#   5. Frontmatter description is non-empty
#   6. Prompt documents precedence ladder verbatim
#   7. Prompt documents top-K cap K<=20
#   8. Prompt references gov-copy-artifact schema (values/rationale/checks blocks)
#   9. Prompt instructs agent NOT to populate checks block (post-processor boundary)
#  10. Prompt documents hard_constraint immutability rule
#  11. Prompt references ref-query.sh canon retrieval CLI
#  12. Prompt references copy-needs-section contract fields (stable_id)
#  13. Prompt defines GOV_COPY_WRITER_RESULT output format

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

AGENT_FILE="$_PLUGIN_ROOT/agents/gov-copy-writer.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== gov-copy-writer agent behavioral tests ==="

# ---------------------------------------------------------------------------
# Test 1: Agent file exists
# ---------------------------------------------------------------------------
echo ""
echo "--- test 1: agent file exists ---"
if [[ -f "$AGENT_FILE" ]]; then
  pass "gov-copy-writer.md exists at $AGENT_FILE"
else
  fail "gov-copy-writer.md NOT FOUND at $AGENT_FILE"
fi

# ---------------------------------------------------------------------------
# Test 2: File has YAML frontmatter delimiters
# ---------------------------------------------------------------------------
echo ""
echo "--- test 2: YAML frontmatter delimiters ---"
first_line=$(head -1 "$AGENT_FILE" 2>/dev/null || true)
if [[ "$first_line" == "---" ]]; then
  pass "File starts with YAML frontmatter opening delimiter '---'"
else
  fail "File does not start with '---' (got: '$first_line')"
fi

closing_delim=$(head -20 "$AGENT_FILE" 2>/dev/null | grep -c '^---$' || true)
if [[ "$closing_delim" -ge 2 ]]; then
  pass "File has at least two '---' delimiters (opening and closing frontmatter)"
else
  fail "File has fewer than 2 '---' delimiters; frontmatter may be malformed (found: $closing_delim)"
fi

# ---------------------------------------------------------------------------
# Test 3: Frontmatter declares name: gov-copy-writer
# ---------------------------------------------------------------------------
echo ""
echo "--- test 3: frontmatter name field ---"
if grep -qE '^name: gov-copy-writer$' "$AGENT_FILE"; then
  pass "Frontmatter has 'name: gov-copy-writer'"
else
  fail "Frontmatter missing 'name: gov-copy-writer'"
fi

# ---------------------------------------------------------------------------
# Test 4: Frontmatter declares model: sonnet
# ---------------------------------------------------------------------------
echo ""
echo "--- test 4: frontmatter model field ---"
if grep -qE '^model: sonnet$' "$AGENT_FILE"; then
  pass "Frontmatter has 'model: sonnet'"
else
  fail "Frontmatter missing 'model: sonnet'"
fi

# ---------------------------------------------------------------------------
# Test 5: Frontmatter description is non-empty
# ---------------------------------------------------------------------------
echo ""
echo "--- test 5: frontmatter description non-empty ---"
desc_line=$(grep -E '^description:' "$AGENT_FILE" | head -1 || true)
if [[ -n "$desc_line" ]] && [[ "$desc_line" != "description:" ]]; then
  pass "Frontmatter has non-empty 'description' field"
else
  fail "Frontmatter 'description' is missing or empty"
fi

# ---------------------------------------------------------------------------
# Test 6: Prompt documents precedence ladder verbatim
# ---------------------------------------------------------------------------
echo ""
echo "--- test 6: precedence ladder verbatim ---"
if grep -q 'canon-rule > Copy Needs constraint > Users archetype > design-notes voice' "$AGENT_FILE"; then
  pass "Prompt contains verbatim precedence ladder"
else
  fail "Prompt missing verbatim precedence ladder 'canon-rule > Copy Needs constraint > Users archetype > design-notes voice'"
fi

# ---------------------------------------------------------------------------
# Test 7: Prompt documents top-K cap K<=20
# ---------------------------------------------------------------------------
echo ""
echo "--- test 7: top-K cap K<=20 ---"
if grep -qE 'K\s*<=\s*20|top-n 20|top_n.*20|cap.*20.*canon' "$AGENT_FILE"; then
  pass "Prompt documents top-K cap K<=20 canon entries"
else
  fail "Prompt missing top-K cap documentation (K<=20)"
fi

# ---------------------------------------------------------------------------
# Test 8: Prompt references gov-copy-artifact schema blocks
# ---------------------------------------------------------------------------
echo ""
echo "--- test 8: artifact schema blocks (values/rationale/checks) ---"
if grep -q 'values' "$AGENT_FILE" && grep -q 'rationale' "$AGENT_FILE" && grep -q 'checks' "$AGENT_FILE"; then
  pass "Prompt references values, rationale, and checks blocks"
else
  fail "Prompt missing one or more schema blocks (values/rationale/checks)"
fi

if grep -q 'gov-copy-artifact' "$AGENT_FILE"; then
  pass "Prompt references gov-copy-artifact contract"
else
  fail "Prompt does not reference gov-copy-artifact contract"
fi

# ---------------------------------------------------------------------------
# Test 9: Prompt instructs agent NOT to populate checks block
# ---------------------------------------------------------------------------
echo ""
echo "--- test 9: checks block owned by post-processor ---"
if grep -q 'deterministic post-processor' "$AGENT_FILE" && grep -q 'fk_grade' "$AGENT_FILE"; then
  pass "Prompt mentions deterministic post-processor owns fk_grade (checks boundary)"
else
  fail "Prompt does not clearly instruct agent to leave checks block for post-processor"
fi

if grep -qiE 'do not (self-attest|populate)|leave the checks|checks block.*absent|omit.*checks' "$AGENT_FILE"; then
  pass "Prompt explicitly instructs agent to omit/not self-attest checks fields"
else
  fail "Prompt does not explicitly instruct agent to leave checks block unset"
fi

# ---------------------------------------------------------------------------
# Test 10: Prompt documents hard_constraint immutability rule
# ---------------------------------------------------------------------------
echo ""
echo "--- test 10: hard_constraint immutability ---"
if grep -q 'hard_constraint' "$AGENT_FILE"; then
  pass "Prompt references hard_constraint canon entries"
else
  fail "Prompt does not mention hard_constraint"
fi

if grep -qiE 'immutable|IMMUTABLE' "$AGENT_FILE"; then
  pass "Prompt uses the word 'immutable' for hard_constraint entries"
else
  fail "Prompt does not describe hard_constraint entries as immutable"
fi

# ---------------------------------------------------------------------------
# Test 11: Prompt references ref-query.sh for canon retrieval
# ---------------------------------------------------------------------------
echo ""
echo "--- test 11: ref-query.sh canon retrieval ---"
if grep -q 'ref-query.sh' "$AGENT_FILE"; then
  pass "Prompt references ref-query.sh"
else
  fail "Prompt does not reference ref-query.sh"
fi

if grep -q 'namespace=canon' "$AGENT_FILE"; then
  pass "Prompt shows --namespace=canon flag for ref-query.sh"
else
  fail "Prompt does not show --namespace=canon flag"
fi

# ---------------------------------------------------------------------------
# Test 12: Prompt references Copy Needs contract fields (stable_id)
# ---------------------------------------------------------------------------
echo ""
echo "--- test 12: copy-needs-section stable_id ---"
if grep -q 'stable_id' "$AGENT_FILE"; then
  pass "Prompt references 'stable_id' from Copy Needs contract"
else
  fail "Prompt does not reference 'stable_id' from Copy Needs contract"
fi

# ---------------------------------------------------------------------------
# Test 13: Prompt defines GOV_COPY_WRITER_RESULT output format
# ---------------------------------------------------------------------------
echo ""
echo "--- test 13: GOV_COPY_WRITER_RESULT output format ---"
if grep -q 'GOV_COPY_WRITER_RESULT' "$AGENT_FILE"; then
  pass "Prompt defines GOV_COPY_WRITER_RESULT structured output format"
else
  fail "Prompt missing GOV_COPY_WRITER_RESULT output format"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
