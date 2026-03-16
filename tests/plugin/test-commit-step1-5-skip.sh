#!/usr/bin/env bash
# tests/plugin/test-commit-step1-5-skip.sh
# Tests the absent commands.test_changed skip path in COMMIT-WORKFLOW.md Step 1.5.
#
# Usage: bash tests/plugin/test-commit-step1-5-skip.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
WORKFLOW_FILE="$PLUGIN_ROOT/docs/workflows/COMMIT-WORKFLOW.md"
FIXTURE_CONFIG="$PLUGIN_ROOT/tests/fixtures/commit-workflow-skip/workflow-config-no-test-changed.yaml"
READ_CONFIG="$PLUGIN_ROOT/scripts/read-config.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-commit-step1-5-skip.sh ==="

# ── test_read_config_returns_empty_for_absent_key ────────────────────────────
# read-config.sh should return empty string and exit 0 for absent commands.test_changed
_snapshot_fail
result=$(bash "$READ_CONFIG" "$FIXTURE_CONFIG" "commands.test_changed" 2>/dev/null)
rc=$?
assert_eq "test_read_config_returns_empty_for_absent_key: exit code is 0" "0" "$rc"
assert_eq "test_read_config_returns_empty_for_absent_key: output is empty" "" "$result"
assert_pass_if_clean "test_read_config_returns_empty_for_absent_key"

# ── test_workflow_contains_skip_message ──────────────────────────────────────
# COMMIT-WORKFLOW.md Step 1.5 must contain the skip message for absent config
_snapshot_fail
skip_match=0
grep -q 'commands.test_changed not configured' "$WORKFLOW_FILE" 2>/dev/null && skip_match=1
assert_eq "test_workflow_contains_skip_message: contains skip message" "1" "$skip_match"
assert_pass_if_clean "test_workflow_contains_skip_message"

# ── test_workflow_reads_from_config ──────────────────────────────────────────
# Step 1.5 must use read-config.sh to get the command
_snapshot_fail
config_match=0
grep -q 'read-config\.sh.*commands\.test_changed' "$WORKFLOW_FILE" 2>/dev/null && config_match=1
assert_eq "test_workflow_reads_from_config: contains read-config.sh commands.test_changed" "1" "$config_match"
assert_pass_if_clean "test_workflow_reads_from_config"

print_summary
