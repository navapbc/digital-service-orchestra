#!/usr/bin/env bash
# tests/scripts/test-claude-md-replan-safety.sh
# Tests: assert CLAUDE.md documents re-invocation safety mechanics.
#
# Verifies that CLAUDE.md contains documentation for 4 re-invocation safety items:
#   1. Re-invocation guard (prevents recursive/unsafe re-invocation)
#   2. REPLAN_ESCALATE signal with brainstorm context
#   3. GAP_CLASSIFICATION signal with intent_gap or gap classification patterns
#   4. Cascade protocol with max_replan_cycles or replan cycle limits
#
# These are agent-awareness requirements — agents reading CLAUDE.md must know the
# safety mechanics for re-invocation and re-planning scenarios.
#
# This test is expected to FAIL (RED) against an unmodified CLAUDE.md that
# does not yet contain re-invocation safety documentation.
#
# Usage: bash tests/scripts/test-claude-md-replan-safety.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-claude-md-replan-safety.sh ==="
echo ""

claude_md_content="$(cat "$CLAUDE_MD")"

# ── test_claude_md_contains_replan_escalate ───────────────────────────────────
# CLAUDE.md must document the REPLAN_ESCALATE signal and associate it with
# brainstorm context so agents know when re-planning should trigger escalation
# to the brainstorm workflow rather than proceeding autonomously.
_snapshot_fail
_tmp="$claude_md_content"
if [[ "$_tmp" == *"REPLAN_ESCALATE"* ]]; then
    _replan_context=$(echo "$claude_md_content" | grep -A5 -B5 "REPLAN_ESCALATE")
    _tmp2="$_replan_context"; shopt -s nocasematch
    if [[ "$_tmp2" == *"brainstorm"* ]]; then
        shopt -u nocasematch
        echo "PASS: test_claude_md_contains_replan_escalate: CLAUDE.md documents REPLAN_ESCALATE signal with brainstorm context"
        (( ++PASS ))
    else
        shopt -u nocasematch
        echo "FAIL: test_claude_md_contains_replan_escalate: CLAUDE.md documents REPLAN_ESCALATE signal with brainstorm context"
        echo "  expected: 'brainstorm' within 5 lines of REPLAN_ESCALATE"
        echo "  actual:   REPLAN_ESCALATE found but no nearby brainstorm context"
        (( ++FAIL ))
    fi
else
    echo "FAIL: test_claude_md_contains_replan_escalate: CLAUDE.md documents REPLAN_ESCALATE signal with brainstorm context"
    echo "  expected: 'REPLAN_ESCALATE' present in CLAUDE.md"
    echo "  actual:   REPLAN_ESCALATE not found in CLAUDE.md"
    (( ++FAIL ))
fi
echo ""

# ── test_claude_md_contains_gap_classification ────────────────────────────────
# CLAUDE.md must document the GAP_CLASSIFICATION signal and its relationship to
# intent gaps or gap classification patterns so agents can correctly categorize
# planning gaps during re-invocation scenarios.
_tmp="$claude_md_content"
if [[ "$_tmp" == *"GAP_CLASSIFICATION"* ]]; then
    shopt -s nocasematch
    if [[ "$_tmp" =~ intent_gap|gap.*classification ]]; then
        shopt -u nocasematch
        echo "PASS: test_claude_md_contains_gap_classification: CLAUDE.md documents GAP_CLASSIFICATION with intent_gap or gap classification patterns"
        (( ++PASS ))
    else
        shopt -u nocasematch
        echo "FAIL: test_claude_md_contains_gap_classification: CLAUDE.md documents GAP_CLASSIFICATION with intent_gap or gap classification patterns"
        echo "  expected: 'intent_gap' or gap.*classification pattern alongside GAP_CLASSIFICATION"
        echo "  actual:   GAP_CLASSIFICATION found but no intent_gap or gap classification pattern"
        (( ++FAIL ))
    fi
else
    echo "FAIL: test_claude_md_contains_gap_classification: CLAUDE.md documents GAP_CLASSIFICATION with intent_gap or gap classification patterns"
    echo "  expected: 'GAP_CLASSIFICATION' present in CLAUDE.md"
    echo "  actual:   GAP_CLASSIFICATION not found in CLAUDE.md"
    (( ++FAIL ))
fi
echo ""

# ── test_claude_md_contains_cascade_protocol ─────────────────────────────────
# CLAUDE.md must document a cascade protocol for re-planning cycles, including
# cycle limits (max_replan_cycles) or cascade/replan cycle terminology to prevent
# unbounded re-planning loops.
_tmp="$claude_md_content"; shopt -s nocasematch
if [[ "$_tmp" =~ max_replan_cycles|cascade.*replan|replan.*cycle ]]; then
    shopt -u nocasematch
    echo "PASS: test_claude_md_contains_cascade_protocol: CLAUDE.md documents cascade protocol with replan cycle limits"
    (( ++PASS ))
else
    shopt -u nocasematch
    echo "FAIL: test_claude_md_contains_cascade_protocol: CLAUDE.md documents cascade protocol with replan cycle limits"
    echo "  expected: 'max_replan_cycles', 'cascade.*replan', or 'replan.*cycle' in CLAUDE.md"
    echo "  actual:   no cascade/replan cycle limit pattern found in CLAUDE.md"
    (( ++FAIL ))
fi
echo ""

print_summary
