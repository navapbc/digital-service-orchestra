#!/usr/bin/env bash
# tests/skills/test-implementation-plan-retry-budget.sh
# Structural boundary test: implementation-plan SKILL.md must publish the
# MAX_ATTEMPTS structural marker used by sprint task-execution to determine
# the per-tier retry cap.
#
# Per behavioral-testing-standard.md Rule 5: instruction-file tests assert
# only on binding tokens. MAX_ATTEMPTS is a binding caller —
# plugins/dso/skills/sprint/prompts/task-execution.md parses it.
#
# Story: d853-bf07 — Sub-agent retry budget with model escalation
#
# Usage:
#   bash tests/skills/test-implementation-plan-retry-budget.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-retry-budget.sh ==="
echo ""

# ===========================================================================
# test_retry_budget_max_attempts_token_present
#
# Binding caller: sprint task-execution.md parses MAX_ATTEMPTS from the task
# description as the per-tier attempt cap. The token literal must appear in
# the SKILL.md retry-budget block so generated task descriptions include it.
# ===========================================================================
test_retry_budget_max_attempts_token_present() {
  local _found_max_attempts=0
  grep -q "MAX_ATTEMPTS" "$SKILL_FILE" 2>/dev/null && _found_max_attempts=1

  assert_eq \
    "test_retry_budget_max_attempts_token_present: SKILL.md must publish the MAX_ATTEMPTS structural marker" \
    "1" "$_found_max_attempts"
}

test_retry_budget_max_attempts_token_present

print_summary
