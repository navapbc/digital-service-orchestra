#!/usr/bin/env bash
# tests/test-gov-copy-writer-checks-isolation.sh
# Structural (RED-mode) tests for the gov-copy-writer post-processor boundary.
#
# Covers story 074b-c6f1-174a-4832, task f5ea-2c9e-7364-4c74.
# DDs tested:
#   dd-5 (074b): the agent does not populate the checks block (leaves fields
#                null or unset) so the deterministic post-processor owns those
#                values exclusively
#   dd-6 (074b): when the agent produces an item it expects to fail an sc-7
#                threshold, it populates rationale.deviations[] with
#                {rule_id, reason} at authoring time
#
# Test strategy: structural / prompt-inspection tests (no live LLM dispatch).
# These tests assert that the agent file's prompt language enforces the
# post-processor boundary contract. This guards against future edits that
# inadvertently relax the boundary.
#
# Test plan:
#   1. Agent file contains explicit prohibition on populating checks fields
#   2. Agent file identifies deterministic post-processor (story 67c1) as owner
#   3. Agent file contains a "Prohibited Outputs" section
#   4. Prohibited Outputs section lists all four forbidden fields
#   5. Agent instructs to emit checks:null or omit checks key
#   6. Agent instructs agent to populate rationale.deviations with {rule_id, reason}
#   7. Agent clarifies that deviations.reason is LLM-authored (not post-processor)
#   8. YAML example in artifact section shows checks block absent or null

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../../plugins/dso" && pwd)"

AGENT_FILE="$_PLUGIN_ROOT/agents/gov-copy-writer.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== gov-copy-writer checks-isolation tests (post-processor boundary) ==="

# Guard: agent file must exist before any assertion
if [[ ! -f "$AGENT_FILE" ]]; then
  echo "  FATAL: agent file not found at $AGENT_FILE"
  exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: Explicit prohibition on populating checks fields
# ---------------------------------------------------------------------------
echo ""
echo "--- test 1: explicit prohibition on populating checks fields ---"
if grep -qiE 'do not populate (these fields|checks)|do not self-attest' "$AGENT_FILE"; then
  pass "Agent prompt explicitly prohibits populating checks fields"
else
  fail "Agent prompt missing explicit prohibition on populating checks fields"
fi

# ---------------------------------------------------------------------------
# Test 2: Deterministic post-processor (story 67c1) named as owner
# ---------------------------------------------------------------------------
echo ""
echo "--- test 2: deterministic post-processor (story 67c1) named as checks owner ---"
if grep -q 'deterministic post-processor' "$AGENT_FILE" && grep -q 'story 67c1' "$AGENT_FILE"; then
  pass "Agent prompt names deterministic post-processor (story 67c1) as checks owner"
else
  fail "Agent prompt does not name deterministic post-processor (story 67c1) as checks owner"
fi

# ---------------------------------------------------------------------------
# Test 3: "Prohibited Outputs" section exists
# ---------------------------------------------------------------------------
echo ""
echo "--- test 3: Prohibited Outputs section exists ---"
if grep -q 'Prohibited Outputs' "$AGENT_FILE"; then
  pass "Agent prompt has a 'Prohibited Outputs' section"
else
  fail "Agent prompt missing 'Prohibited Outputs' section"
fi

# ---------------------------------------------------------------------------
# Test 4: All four forbidden fields listed in Prohibited Outputs
# ---------------------------------------------------------------------------
echo ""
echo "--- test 4: all four forbidden fields listed ---"
for field in fk_grade banned_words_found active_voice source; do
  if grep -q "checks\.$field" "$AGENT_FILE"; then
    pass "Prohibited Outputs lists forbidden field: checks.$field"
  else
    fail "Prohibited Outputs missing forbidden field: checks.$field"
  fi
done

# ---------------------------------------------------------------------------
# Test 5: Agent instructs to emit checks:null or omit checks key
# ---------------------------------------------------------------------------
echo ""
echo "--- test 5: instruction to emit checks:null or omit checks key ---"
if grep -qE 'checks: null|omit.*checks|checks.*omit|checks.*absent|absent.*checks' "$AGENT_FILE"; then
  pass "Agent prompt instructs to emit checks:null or omit checks key"
else
  fail "Agent prompt does not instruct to emit checks:null or omit checks key"
fi

# ---------------------------------------------------------------------------
# Test 6: Agent instructs to populate rationale.deviations with {rule_id, reason}
# ---------------------------------------------------------------------------
echo ""
echo "--- test 6: rationale.deviations populated at authoring time ---"
if grep -qE 'deviations|rationale.*deviations' "$AGENT_FILE"; then
  pass "Agent prompt references deviations block"
else
  fail "Agent prompt does not reference deviations block"
fi

if grep -qE 'rule_id.*reason|reason.*rule_id' "$AGENT_FILE"; then
  pass "Agent prompt shows {rule_id, reason} shape for deviations entries"
else
  fail "Agent prompt does not show {rule_id, reason} shape for deviations entries"
fi

# ---------------------------------------------------------------------------
# Test 7: deviations.reason is LLM-authored (not synthesized by post-processor)
# ---------------------------------------------------------------------------
echo ""
echo "--- test 7: deviations.reason is LLM-authored not post-processor ---"
if grep -qiE 'reason.*not synthesized|not synthesized.*post-processor|LLM-authored|your own reasoning' "$AGENT_FILE"; then
  pass "Agent prompt clarifies deviations.reason is LLM-authored, not post-processor output"
else
  fail "Agent prompt does not clarify that deviations.reason is LLM-authored"
fi

# ---------------------------------------------------------------------------
# Test 8: YAML artifact example shows checks block absent
# ---------------------------------------------------------------------------
echo ""
echo "--- test 8: YAML example shows checks block absent or commented out ---"
if grep -qE 'checks block intentionally absent|# checks|checks: null' "$AGENT_FILE"; then
  pass "YAML example indicates checks block is absent or null"
else
  fail "YAML example does not show checks block as absent or null"
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
