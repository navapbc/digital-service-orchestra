#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-cross-stack-go.sh
# TDD red-phase integration tests for Go cross-stack fixture.
#
# Usage: bash lockpick-workflow/tests/scripts/test-cross-stack-go.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: Tests 2-4 are expected to FAIL until lockpick-workflow/tests/fixtures/go-project/
#       workflow-config.conf is created (GREEN phase task: lockpick-doc-to-logic-ias2v).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

FIXTURE="$REPO_ROOT/lockpick-workflow/tests/fixtures/go-project"
DETECT_STACK="$REPO_ROOT/lockpick-workflow/scripts/detect-stack.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-cross-stack-go.sh ==="

# ── test_go_stack_detect_returns_golang ───────────────────────────────────────
# Running detect-stack.sh against the Go fixture must output 'golang'.
# The fixture must contain go.mod for detection to work.
go_detect_output=""
go_detect_exit=0
go_detect_output=$(bash "$DETECT_STACK" "$FIXTURE" 2>&1) || go_detect_exit=$?
assert_eq "test_go_stack_detect_returns_golang: outputs golang" "golang" "$go_detect_output"

# ── test_go_stack_workflow_config_has_go_test ─────────────────────────────────
# The fixture's workflow-config.conf must exist and contain the go test command.
CONFIG="$FIXTURE/workflow-config.conf"
if [[ -f "$CONFIG" ]]; then
    config_content=$(cat "$CONFIG")
    assert_contains "test_go_stack_workflow_config_has_go_test: config contains go test" "commands.test=go test ./..." "$config_content"
else
    assert_eq "test_go_stack_workflow_config_has_go_test: workflow-config.conf exists" "exists" "missing"
fi

# ── test_go_stack_workflow_config_has_golangci_lint ───────────────────────────
# The fixture's workflow-config.conf must contain the golangci-lint command.
if [[ -f "$CONFIG" ]]; then
    config_content=$(cat "$CONFIG")
    assert_contains "test_go_stack_workflow_config_has_golangci_lint: config contains golangci-lint" "commands.lint=golangci-lint run" "$config_content"
else
    assert_eq "test_go_stack_workflow_config_has_golangci_lint: workflow-config.conf exists" "exists" "missing"
fi

# ── test_go_stack_workflow_config_has_gofmt ───────────────────────────────────
# The fixture's workflow-config.conf must contain the gofmt format command.
if [[ -f "$CONFIG" ]]; then
    config_content=$(cat "$CONFIG")
    assert_contains "test_go_stack_workflow_config_has_gofmt: config contains gofmt" "commands.format=gofmt -l ." "$config_content"
else
    assert_eq "test_go_stack_workflow_config_has_gofmt: workflow-config.conf exists" "exists" "missing"
fi

print_summary
