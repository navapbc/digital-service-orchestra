#!/usr/bin/env bash
# tests/scripts/test-tdd-workflow-removal.sh
# Assert that no tdd-workflow references remain in the in-scope codebase.
#
# This is a negative constraint test (RED phase for epic 9832-0fc4):
# It FAILS now because tdd-workflow references still exist in the codebase.
# It will PASS GREEN after task 7d1b-802b removes the skill and all references.
#
# Excluded from the scan:
#   .git/              — version control internals
#   .tickets-tracker/  — event-sourced ticket data (not in-scope codebase)
#   this file itself   — the test cannot exclude its own pattern from itself
#
# Usage: bash tests/scripts/test-tdd-workflow-removal.sh
# Returns: exit 0 if zero references found, exit 1 if references remain

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-tdd-workflow-removal.sh ==="

# ── test_no_tdd_workflow_references ──────────────────────────────────────────
# The codebase must contain zero references to "tdd-workflow" once the dead
# skill has been fully removed. We exclude:
#   - .git/              (version control, not codebase)
#   - .tickets-tracker/  (event-sourced ticket state, not codebase)
#   - this test file     (would self-reference the pattern being searched)
#
# RED: FAIL because plugins/dso/skills/tdd-workflow/, .claude/commands/tdd-workflow.md,
# CLAUDE.md, and other files still reference tdd-workflow.
_snapshot_fail
ref_count=0
ref_count=$(
  grep -r "tdd-workflow" "$REPO_ROOT" \
    --exclude-dir=.git \
    --exclude-dir=.tickets-tracker \
    --exclude="test-tdd-workflow-removal.sh" \
    -l 2>/dev/null | wc -l | tr -d ' '
)
assert_eq "test_no_tdd_workflow_references" "0" "$ref_count"
assert_pass_if_clean "test_no_tdd_workflow_references"

print_summary
