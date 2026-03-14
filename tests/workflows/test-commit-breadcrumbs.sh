#!/usr/bin/env bash
# lockpick-workflow/tests/workflows/test-commit-breadcrumbs.sh
# Tests that COMMIT-WORKFLOW.md contains breadcrumb echo calls and truncation.
#
# Usage: bash lockpick-workflow/tests/workflows/test-commit-breadcrumbs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/lockpick-workflow/docs/workflows/COMMIT-WORKFLOW.md"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-commit-breadcrumbs.sh ==="

# ── test_commit_workflow_has_breadcrumb_calls ────────────────────────────────
# At least 8 breadcrumb echo lines must exist (one per major step)
_snapshot_fail
breadcrumb_count=0
breadcrumb_count=$(grep -c 'commit-breadcrumbs.log' "$WORKFLOW_FILE" 2>/dev/null) || breadcrumb_count=0
has_enough=0
[[ "$breadcrumb_count" -ge 8 ]] && has_enough=1
assert_eq "test_commit_workflow_has_breadcrumb_calls: at least 8 breadcrumb lines (got $breadcrumb_count)" "1" "$has_enough"
assert_pass_if_clean "test_commit_workflow_has_breadcrumb_calls"

# ── test_breadcrumb_truncation_exists ────────────────────────────────────────
# The truncation line `: > "$ARTIFACTS_DIR/commit-breadcrumbs.log"` must exist
_snapshot_fail
truncation_found=0
grep -q ': > .*commit-breadcrumbs.log' "$WORKFLOW_FILE" 2>/dev/null && truncation_found=1
assert_eq "test_breadcrumb_truncation_exists: truncation line present" "1" "$truncation_found"
assert_pass_if_clean "test_breadcrumb_truncation_exists"

# ── test_breadcrumb_has_iso8601_timestamp ────────────────────────────────────
# Each breadcrumb echo must include ISO8601 timestamp format
_snapshot_fail
timestamp_found=0
grep 'commit-breadcrumbs' "$WORKFLOW_FILE" | grep -q '%Y-%m-%dT%H:%M:%SZ' 2>/dev/null && timestamp_found=1
assert_eq "test_breadcrumb_has_iso8601_timestamp: ISO8601 format present" "1" "$timestamp_found"
assert_pass_if_clean "test_breadcrumb_has_iso8601_timestamp"

# ── test_breadcrumb_echo_lines_per_step ──────────────────────────────────────
# Breadcrumb echo calls must reference step names
_snapshot_fail
echo_count=0
echo_count=$(grep -c 'echo.*step-.*commit-breadcrumbs.log' "$WORKFLOW_FILE" 2>/dev/null) || echo_count=0
has_echo_lines=0
[[ "$echo_count" -ge 8 ]] && has_echo_lines=1
assert_eq "test_breadcrumb_echo_lines_per_step: at least 8 echo lines with step names (got $echo_count)" "1" "$has_echo_lines"
assert_pass_if_clean "test_breadcrumb_echo_lines_per_step"

print_summary
