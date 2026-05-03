#!/usr/bin/env bash
# tests/scripts/test-commit-workflow-step-1-5.sh
# Tests that the changed-integration/E2E-tests step in
# commit-workflow-validation.md reads the changed-test command from
# dso-config.conf via read-config.sh instead of hardcoding
# scripts/run-changed-tests.sh.
#
# Step history: originally COMMIT-WORKFLOW.md Step 1.5 (pre-extraction);
# extracted to commit-workflow-validation.md as Step 1.5 (task 73af-f56e,
# 2026-05-01); renumbered to Step 1 of commit-workflow-validation.md as part
# of the sequential-whole-integer renumber (task 267e-a665, 2026-05-01).
#
# Usage: bash tests/scripts/test-commit-workflow-step-1-5.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
WORKFLOW_FILE="$DSO_PLUGIN_DIR/docs/workflows/commit-workflow-validation.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-commit-workflow-step-1-5.sh ==="

# ── test_step_1_heading_present ──────────────────────────────────────────────
# After the renumber, the changed-tests step must be labeled "Step 1" — a
# whole integer, no fractional or alphabetic suffix.
_snapshot_fail
step1_match=0
grep -qE '^## Step 1: Changed Integration/E2E Tests' "$WORKFLOW_FILE" 2>/dev/null && step1_match=1
assert_eq "test_step_1_heading_present: validation doc has '## Step 1: Changed Integration/E2E Tests' heading" "1" "$step1_match"
assert_pass_if_clean "test_step_1_heading_present"

# ── test_no_hardcoded_run_changed_tests ──────────────────────────────────────
# Step 1 must NOT contain a hardcoded reference to scripts/run-changed-tests.sh
_snapshot_fail
hardcoded_count=0
hardcoded_count=$(grep -v '(default:' "$WORKFLOW_FILE" | grep -c 'run-changed-tests\.sh' 2>/dev/null) || hardcoded_count=0
assert_eq "test_no_hardcoded_run_changed_tests: no hardcoded run-changed-tests.sh" "0" "$hardcoded_count"
assert_pass_if_clean "test_no_hardcoded_run_changed_tests"

# ── test_reads_from_config ────────────────────────────────────────────────────
# Step 1 MUST contain read-config.sh ... commands.test_changed
_snapshot_fail
config_match=0
grep -q 'read-config\.sh.*commands\.test_changed' "$WORKFLOW_FILE" 2>/dev/null && config_match=1
assert_eq "test_reads_from_config: contains read-config.sh commands.test_changed" "1" "$config_match"
assert_pass_if_clean "test_reads_from_config"

print_summary
