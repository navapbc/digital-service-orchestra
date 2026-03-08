#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-cross-stack-lockpick-snapshot.sh
# TDD red-phase tests for the Lockpick snapshot fixture used in cross-stack
# integration testing.
#
# Usage: bash lockpick-workflow/tests/scripts/test-cross-stack-lockpick-snapshot.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until the Lockpick snapshot fixture
# is created (lockpick-workflow/tests/fixtures/lockpick-snapshot/ does not exist yet).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE="$REPO_ROOT/lockpick-workflow/tests/fixtures/lockpick-snapshot"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-cross-stack-lockpick-snapshot.sh ==="

# ── test_lockpick_snapshot_fixture_dir_exists ─────────────────────────────────
# The lockpick-snapshot fixture directory must exist.
# FAILS until Task (GREEN) creates lockpick-workflow/tests/fixtures/lockpick-snapshot/
if [ -d "$FIXTURE" ]; then
    assert_eq "test_lockpick_snapshot_fixture_dir_exists" "exists" "exists"
else
    assert_eq "test_lockpick_snapshot_fixture_dir_exists" "exists" "missing"
fi

# ── test_lockpick_snapshot_detect_returns_python_poetry ───────────────────────
# Running detect-stack.sh against the lockpick-snapshot fixture must output
# 'python-poetry' (the fixture contains a pyproject.toml).
# Guard: if the fixture directory does not exist, detect-stack.sh will error;
# catch that and report a graceful failure instead.
detect_output=""
detect_exit=0
if [ -d "$FIXTURE" ]; then
    detect_output=$(bash "$REPO_ROOT/lockpick-workflow/scripts/detect-stack.sh" "$FIXTURE" 2>/dev/null) || detect_exit=$?
else
    detect_output="missing"
    detect_exit=1
fi
assert_eq "test_lockpick_snapshot_detect_returns_python_poetry" "python-poetry" "$detect_output"

# ── test_lockpick_snapshot_workflow_config_exists ────────────────────────────
# The lockpick-snapshot fixture must contain a workflow-config.yaml file.
# FAILS until the GREEN task creates lockpick-workflow/tests/fixtures/lockpick-snapshot/workflow-config.yaml
if [ -f "$FIXTURE/workflow-config.yaml" ]; then
    assert_eq "test_lockpick_snapshot_workflow_config_exists" "exists" "exists"
else
    assert_eq "test_lockpick_snapshot_workflow_config_exists" "exists" "missing"
fi

# ── test_lockpick_snapshot_workflow_config_stack ──────────────────────────────
# Reading the 'stack' key from the fixture's workflow-config.yaml must return
# 'python-poetry'.
config_output=""
config_exit=0
config_output=$(bash "$REPO_ROOT/lockpick-workflow/scripts/read-config.sh" stack "$FIXTURE/workflow-config.yaml" 2>/dev/null) || config_exit=$?
assert_eq "test_lockpick_snapshot_workflow_config_stack" "python-poetry" "$config_output"

print_summary
