#!/usr/bin/env bash
# tests/scripts/test-review-workflow-dispatch-pattern.sh
# Tests for correct inline dispatch pattern in REVIEW-WORKFLOW.md.
#
# Covers:
#   1. (a541-0ad7) Deep tier Task blocks do NOT show invalid dso: subagent_type values.
#      The Agent tool only accepts built-in types (general-purpose, Explore, etc.).
#      dso:* labels are agent file identifiers, NOT valid subagent_type values.
#   2. (c703-29b2) Deep tier section contains explicit SERIAL DISPATCH PROHIBITED gate.
#      All 3 sonnet reviewers must be launched in a single parallel message.
#   3. (a541-0ad7) Inline dispatch guidance present: workflow instructs reading agent file
#      inline and using subagent_type: "general-purpose" + agent's model.
#
# Usage: bash tests/scripts/test-review-workflow-dispatch-pattern.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$PLUGIN_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-review-workflow-dispatch-pattern.sh ==="

# ── Test 1: No invalid dso: subagent_type values in Task tool blocks ──────────
# The Agent tool only accepts built-in subagent types (general-purpose, Explore, etc.).
# dso:* values are agent file identifiers — using them as subagent_type is invalid
# and produces "Unknown skill" or similar errors at runtime.
echo "Test 1: Deep tier Task blocks do not use invalid subagent_type: \"dso:\" values"
if grep -E '^[[:space:]]+subagent_type:[[:space:]]+"dso:' "$WORKFLOW_FILE" >/dev/null 2>&1; then
    echo "  FAIL: REVIEW-WORKFLOW.md contains invalid subagent_type: \"dso:*\" values" >&2
    echo "        These must be replaced with subagent_type: \"general-purpose\" + inline agent prompt" >&2
    (( FAIL++ ))
else
    echo "  PASS: no invalid dso: subagent_type values found"
    (( PASS++ ))
fi

# ── Test 2: Deep tier section prohibits serial dispatch ────────────────────────
# The 3 deep-tier sonnet agents must be launched in a single parallel Agent dispatch.
# Serial dispatch (one agent per message) triples review time unnecessarily.
# The workflow must contain an explicit SERIAL DISPATCH PROHIBITED gate.
echo "Test 2: Deep tier section contains explicit serial dispatch prohibition"
if grep -qi "SERIAL.*DISPATCH.*PROHIBITED\|PROHIBITED.*SERIAL.*DISPATCH" "$WORKFLOW_FILE" 2>/dev/null; then
    echo "  PASS: REVIEW-WORKFLOW.md contains serial dispatch prohibition"
    (( PASS++ ))
else
    echo "  FAIL: REVIEW-WORKFLOW.md missing SERIAL DISPATCH PROHIBITED gate" >&2
    echo "        Deep tier must explicitly forbid dispatching 3 sonnet agents one at a time" >&2
    (( FAIL++ ))
fi

# ── Test 3: Inline dispatch guidance present ──────────────────────────────────
# The workflow must instruct the orchestrator to read the agent file inline and
# use subagent_type: "general-purpose" with the agent's specified model.
# This is the only valid pattern for dispatching dso:* named agents.
echo "Test 3: Workflow contains inline agent dispatch guidance (general-purpose + model)"
_has_inline_guidance=0
if grep -q "subagent_type.*general-purpose" "$WORKFLOW_FILE" 2>/dev/null && \
   grep -q "agent.*inline\|inline.*agent\|read.*agent.*md\|agent.*file.*content\|content.*agent.*file" "$WORKFLOW_FILE" 2>/dev/null; then
    _has_inline_guidance=1
fi
if [[ "$_has_inline_guidance" -eq 1 ]]; then
    echo "  PASS: workflow contains inline agent dispatch guidance"
    (( PASS++ ))
else
    echo "  FAIL: workflow missing inline agent dispatch guidance" >&2
    echo "        Must instruct: read plugins/dso/agents/<name>.md inline, use subagent_type: \"general-purpose\"" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
