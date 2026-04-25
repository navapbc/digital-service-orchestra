#!/usr/bin/env bash
# tests/scripts/test-cross-stack-regression.sh
# Cross-stack regression tests: verifies detect-stack.sh produces the correct
# stack identifier for each integration fixture directory.
#
# Usage: bash tests/scripts/test-cross-stack-regression.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED phase: test_cross_stack_lockpick_snapshot_detected is expected to FAIL
# until tests/fixtures/lockpick-snapshot is created (Task uf64v/GREEN).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

DETECT="$DSO_PLUGIN_DIR/scripts/detect-stack.sh"

echo "=== test-cross-stack-regression.sh ==="

# ── test_cross_stack_node_fixture_detected ────────────────────────────────────
# detect-stack.sh on tests/fixtures/node-project must output 'node-npm'.
# Guard: if fixture dir doesn't exist, force a fail with explicit assert.
NODE_FIXTURE="$PLUGIN_ROOT/tests/fixtures/node-project"
if [[ ! -d "$NODE_FIXTURE" ]]; then
    assert_eq "test_cross_stack_node_fixture_detected: fixture dir exists" "exists" "missing"
else
    node_output=""
    node_exit=0
    node_output=$(bash "$DETECT" "$NODE_FIXTURE" 2>&1) || node_exit=$?
    assert_eq "test_cross_stack_node_fixture_detected: exit 0" "0" "$node_exit"
    assert_eq "test_cross_stack_node_fixture_detected: outputs node-npm" "node-npm" "$node_output"
fi

# ── test_cross_stack_go_fixture_detected ─────────────────────────────────────
# detect-stack.sh on tests/fixtures/go-project must output 'golang'.
# Guard: if fixture dir doesn't exist, force a fail with explicit assert.
GO_FIXTURE="$PLUGIN_ROOT/tests/fixtures/go-project"
if [[ ! -d "$GO_FIXTURE" ]]; then
    assert_eq "test_cross_stack_go_fixture_detected: fixture dir exists" "exists" "missing"
else
    go_output=""
    go_exit=0
    go_output=$(bash "$DETECT" "$GO_FIXTURE" 2>&1) || go_exit=$?
    assert_eq "test_cross_stack_go_fixture_detected: exit 0" "0" "$go_exit"
    assert_eq "test_cross_stack_go_fixture_detected: outputs golang" "golang" "$go_output"
fi

# ── test_cross_stack_makefile_fixture_detected ───────────────────────────────
# detect-stack.sh on tests/fixtures/makefile-project must output
# 'convention-based'.
# Guard: if fixture dir doesn't exist, force a fail with explicit assert.
MAKE_FIXTURE="$PLUGIN_ROOT/tests/fixtures/makefile-project"
if [[ ! -d "$MAKE_FIXTURE" ]]; then
    assert_eq "test_cross_stack_makefile_fixture_detected: fixture dir exists" "exists" "missing"
else
    make_output=""
    make_exit=0
    make_output=$(bash "$DETECT" "$MAKE_FIXTURE" 2>&1) || make_exit=$?
    assert_eq "test_cross_stack_makefile_fixture_detected: exit 0" "0" "$make_exit"
    assert_eq "test_cross_stack_makefile_fixture_detected: outputs convention-based" "convention-based" "$make_output"
fi

# ── test_cross_stack_lockpick_snapshot_detected ───────────────────────────────
# detect-stack.sh on tests/fixtures/lockpick-snapshot must output
# 'python-poetry'.
# Guard: if fixture dir doesn't exist, force a fail with explicit assert.
# NOTE: This test FAILS in RED phase until lockpick-snapshot fixture is created.
LOCKPICK_FIXTURE="$PLUGIN_ROOT/tests/fixtures/lockpick-snapshot"
if [[ ! -d "$LOCKPICK_FIXTURE" ]]; then
    assert_eq "test_cross_stack_lockpick_snapshot_detected: fixture dir exists" "exists" "missing"
else
    lockpick_output=""
    lockpick_exit=0
    lockpick_output=$(bash "$DETECT" "$LOCKPICK_FIXTURE" 2>&1) || lockpick_exit=$?
    assert_eq "test_cross_stack_lockpick_snapshot_detected: exit 0" "0" "$lockpick_exit"
    assert_eq "test_cross_stack_lockpick_snapshot_detected: outputs python-poetry" "python-poetry" "$lockpick_output"
fi

# ── test_cross_stack_multi_marker_python_priority ────────────────────────────
# detect-stack.sh on tests/fixtures/multi-marker-project
# (has both pyproject.toml and package.json) must output 'python-poetry'
# because Python takes priority over Node.
MULTI_FIXTURE="$PLUGIN_ROOT/tests/fixtures/multi-marker-project"
if [[ ! -d "$MULTI_FIXTURE" ]]; then
    assert_eq "test_cross_stack_multi_marker_python_priority: fixture dir exists" "exists" "missing"
else
    multi_output=""
    multi_exit=0
    multi_output=$(bash "$DETECT" "$MULTI_FIXTURE" 2>&1) || multi_exit=$?
    assert_eq "test_cross_stack_multi_marker_python_priority: exit 0" "0" "$multi_exit"
    assert_eq "test_cross_stack_multi_marker_python_priority: python-poetry takes priority" "python-poetry" "$multi_output"
fi

print_summary
