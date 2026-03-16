#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-commit-workflow-step-1-5.sh
# Tests that COMMIT-WORKFLOW.md Step 1.5 reads the changed-test command from
# workflow-config.conf via read-config.sh instead of hardcoding
# scripts/run-changed-tests.sh.
#
# Usage: bash lockpick-workflow/tests/scripts/test-commit-workflow-step-1-5.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
WORKFLOW_FILE="$PLUGIN_ROOT/docs/workflows/COMMIT-WORKFLOW.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-commit-workflow-step-1-5.sh ==="

# ── test_no_hardcoded_run_changed_tests ──────────────────────────────────────
# Step 1.5 must NOT contain a hardcoded reference to scripts/run-changed-tests.sh
_snapshot_fail
hardcoded_count=0
hardcoded_count=$(grep -v '(default:' "$WORKFLOW_FILE" | grep -c 'run-changed-tests\.sh' 2>/dev/null) || hardcoded_count=0
assert_eq "test_no_hardcoded_run_changed_tests: no hardcoded run-changed-tests.sh" "0" "$hardcoded_count"
assert_pass_if_clean "test_no_hardcoded_run_changed_tests"

# ── test_reads_from_config ────────────────────────────────────────────────────
# Step 1.5 MUST contain read-config.sh ... commands.test_changed
_snapshot_fail
config_match=0
grep -q 'read-config\.sh.*commands\.test_changed' "$WORKFLOW_FILE" 2>/dev/null && config_match=1
assert_eq "test_reads_from_config: contains read-config.sh commands.test_changed" "1" "$config_match"
assert_pass_if_clean "test_reads_from_config"

# ── test_path_construction_is_valid ──────────────────────────────────────────
# The path constructed from $REPO_ROOT + config value must resolve to an
# executable file. Config value is ./scripts/run-changed-tests.sh.
_snapshot_fail
CONFIG="$REPO_ROOT/workflow-config.conf"
READ_CONFIG="$PLUGIN_ROOT/scripts/read-config.sh"
cmd_path=""
cmd_path=$(bash "$READ_CONFIG" "$CONFIG" "commands.test_changed" 2>/dev/null) || true
# Strip leading ./ so $REPO_ROOT/$CMD doesn't produce double-slash issues
cmd_path_clean="${cmd_path#./}"
full_path="$REPO_ROOT/$cmd_path_clean"
path_executable=0
[ -x "$full_path" ] && path_executable=1
assert_eq "test_path_construction_is_valid: \$REPO_ROOT/\$CMD is executable" "1" "$path_executable"
assert_pass_if_clean "test_path_construction_is_valid"

print_summary
