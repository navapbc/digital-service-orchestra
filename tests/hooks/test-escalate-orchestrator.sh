#!/usr/bin/env bash
# tests/hooks/test-escalate-orchestrator.sh
# Structural contract tests for escalate_to_epic orchestrator handling and
# max_replan_cycles cycle bound in the preplanning SKILL.md.
#
# Per Rule 5 of behavioral-testing-standard.md, for non-executable LLM
# instruction files we test ONLY the structural boundary — the machine-readable
# contract fields that the sprint orchestrator parses, not prose body text.
#
# What we test (structural contract):
#   1. preplanning/SKILL.md declares an `escalate_to_epic` orchestrator handler
#      — this is the routing signal the sprint orchestrator dispatches on when
#        the red/blue team returns a finding of type escalate_to_epic.
#   2. preplanning/SKILL.md declares a `max_replan_cycles` cycle bound check
#      — this is the guard that prevents infinite escalation loops; without it
#        an escalate_to_epic finding could recur without bound.
#
# What we do NOT test:
#   - Prose text describing what escalate_to_epic or max_replan_cycles mean
#   - Implementation details of how the orchestrator processes findings
#   - Body text wording beyond the structural contract markers
#
# Usage:
#   bash tests/hooks/test-escalate-orchestrator.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PREPLANNING_SKILL="$REPO_ROOT/plugins/dso/skills/preplanning/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-escalate-orchestrator.sh ==="

# ===========================================================================
# test_preplanning_handles_escalate_to_epic
# The preplanning SKILL.md must declare an `escalate_to_epic` orchestrator
# handler. This string is the machine-readable routing key: the sprint
# orchestrator matches this exact token to decide how to route red/blue team
# findings of type escalate_to_epic back into the preplanning cycle.
# Without this marker, the orchestrator has no defined escalation path and
# findings of that type are silently lost.
# ===========================================================================
echo "--- test_preplanning_handles_escalate_to_epic ---"
if grep -q "escalate_to_epic" "$PREPLANNING_SKILL" 2>/dev/null; then
    assert_eq "test_preplanning_handles_escalate_to_epic: escalate_to_epic handler present in preplanning SKILL.md" "present" "present"
else
    assert_eq "test_preplanning_handles_escalate_to_epic: escalate_to_epic handler present in preplanning SKILL.md" "present" "missing"
fi

# ===========================================================================
# test_preplanning_has_max_replan_cycles_bound
# The preplanning SKILL.md must declare a `max_replan_cycles` cycle bound.
# This guard token is the structural contract that caps the number of times
# the orchestrator may re-enter preplanning in response to escalate_to_epic
# findings. Without this cap the escalation loop has no termination condition
# and can recurse without bound.
# ===========================================================================
echo "--- test_preplanning_has_max_replan_cycles_bound ---"
if grep -q "max_replan_cycles" "$PREPLANNING_SKILL" 2>/dev/null; then
    assert_eq "test_preplanning_has_max_replan_cycles_bound: max_replan_cycles bound present in preplanning SKILL.md" "present" "present"
else
    assert_eq "test_preplanning_has_max_replan_cycles_bound: max_replan_cycles bound present in preplanning SKILL.md" "present" "missing"
fi

print_summary
