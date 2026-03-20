#!/usr/bin/env bash
# tests/scripts/test-cross-stack-node.sh
# TDD red-phase tests for Node.js cross-stack integration fixture.
#
# Usage: bash tests/scripts/test-cross-stack-node.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until the Node.js integration fixture
# at tests/fixtures/node-project/ is created with dso-config.conf.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
FIXTURE="$PLUGIN_ROOT/tests/fixtures/node-project"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-cross-stack-node.sh ==="

# ── test_node_stack_detect_returns_node_npm ───────────────────────────────────
# Running detect-stack.sh against the node-project fixture dir must output
# 'node-npm'. This test passes once the fixture dir exists with package.json;
# the workflow-config tests below still fail until dso-config.conf is added.
detect_output=""
detect_exit=0
detect_output=$(bash "$DSO_PLUGIN_DIR/scripts/detect-stack.sh" "$FIXTURE" 2>&1) || detect_exit=$?
assert_eq "test_node_stack_detect_returns_node_npm" "node-npm" "$detect_output"

# ── test_node_stack_workflow_config_has_npm_test ──────────────────────────────
# The fixture's dso-config.conf must contain a 'test: npm test' command
# so that the plugin knows how to run tests for the Node.js stack.
if [[ -f "$FIXTURE/dso-config.conf" ]]; then
    config_contents="$(cat "$FIXTURE/dso-config.conf")"
    assert_contains "test_node_stack_workflow_config_has_npm_test" "commands.test=npm test" "$config_contents"
else
    assert_eq "test_node_stack_workflow_config_has_npm_test: dso-config.conf exists" "exists" "missing"
fi

# ── test_node_stack_workflow_config_has_npm_lint ──────────────────────────────
# The fixture's dso-config.conf must contain a 'lint: npm run lint' command
# so that the plugin knows how to run linting for the Node.js stack.
if [[ -f "$FIXTURE/dso-config.conf" ]]; then
    config_contents="$(cat "$FIXTURE/dso-config.conf")"
    assert_contains "test_node_stack_workflow_config_has_npm_lint" "commands.lint=npm run lint" "$config_contents"
else
    assert_eq "test_node_stack_workflow_config_has_npm_lint: dso-config.conf exists" "exists" "missing"
fi

# ── test_node_stack_auto_format_processes_ts ─────────────────────────────────
# When CLAUDE_PLUGIN_ROOT points to the node fixture, auto-format.sh should
# process .ts files (because the fixture's dso-config.conf declares
# format.extensions: ['.ts']). The hook must exit 0 (non-blocking).
HOOK="$DSO_PLUGIN_DIR/hooks/auto-format.sh"
TEMP_TS="/tmp/test_fixture_$$.ts"

# Create a temp .ts file to reference in the Edit JSON
touch "$TEMP_TS"

auto_format_exit=0
INPUT="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEMP_TS\"}}"
CLAUDE_PLUGIN_ROOT="$FIXTURE" echo "$INPUT" | bash "$HOOK" 2>/dev/null || auto_format_exit=$?
assert_eq "test_node_stack_auto_format_processes_ts" "0" "$auto_format_exit"

rm -f "$TEMP_TS"

print_summary
