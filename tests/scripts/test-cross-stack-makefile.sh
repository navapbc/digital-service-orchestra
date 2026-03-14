#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-cross-stack-makefile.sh
# TDD red-phase tests for Makefile zero-config cross-stack integration fixture.
#
# Usage: bash lockpick-workflow/tests/scripts/test-cross-stack-makefile.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until the Makefile integration fixture
# at lockpick-workflow/tests/fixtures/makefile-project/ is created with workflow-config.conf.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE="$REPO_ROOT/lockpick-workflow/tests/fixtures/makefile-project"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-cross-stack-makefile.sh ==="

# ── test_makefile_stack_detect_returns_convention_based ───────────────────────
# Running detect-stack.sh against the makefile-project fixture dir must output
# 'convention-based'. This test passes once the fixture dir exists with a
# Makefile; the workflow-config tests below still fail until
# workflow-config.conf is added.
detect_output=""
detect_exit=0
detect_output=$(bash "$REPO_ROOT/lockpick-workflow/scripts/detect-stack.sh" "$FIXTURE" 2>&1) || detect_exit=$?
assert_eq "test_makefile_stack_detect_returns_convention_based" "convention-based" "$detect_output"

# ── test_makefile_stack_workflow_config_has_make_test ─────────────────────────
# The fixture's workflow-config.conf must contain a 'test: make test' command
# so that the plugin knows how to run tests for the convention-based stack.
if [[ -f "$FIXTURE/workflow-config.conf" ]]; then
    config_contents="$(cat "$FIXTURE/workflow-config.conf")"
    assert_contains "test_makefile_stack_workflow_config_has_make_test" "test: make test" "$config_contents"
else
    assert_eq "test_makefile_stack_workflow_config_has_make_test: workflow-config.conf exists" "exists" "missing"
fi

# ── test_makefile_stack_workflow_config_has_make_lint ─────────────────────────
# The fixture's workflow-config.conf must contain a 'lint: make lint' command
# so that the plugin knows how to run linting for the convention-based stack.
if [[ -f "$FIXTURE/workflow-config.conf" ]]; then
    config_contents="$(cat "$FIXTURE/workflow-config.conf")"
    assert_contains "test_makefile_stack_workflow_config_has_make_lint" "lint: make lint" "$config_contents"
else
    assert_eq "test_makefile_stack_workflow_config_has_make_lint: workflow-config.conf exists" "exists" "missing"
fi

# ── test_makefile_stack_workflow_config_stack_value ───────────────────────────
# The fixture's workflow-config.conf must contain 'stack: convention-based' so
# that the plugin records the correct detected stack for the Makefile project.
if [[ -f "$FIXTURE/workflow-config.conf" ]]; then
    config_contents="$(cat "$FIXTURE/workflow-config.conf")"
    assert_contains "test_makefile_stack_workflow_config_stack_value" "stack: convention-based" "$config_contents"
else
    assert_eq "test_makefile_stack_workflow_config_stack_value: workflow-config.conf exists" "exists" "missing"
fi

print_summary
