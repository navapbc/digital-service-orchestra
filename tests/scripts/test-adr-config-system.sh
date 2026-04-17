#!/usr/bin/env bash
# tests/scripts/test-adr-config-system.sh
# Verify that the ADR for the config system exists and contains required sections.
#
# Usage: bash tests/scripts/test-adr-config-system.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
ADR_PATH="$REPO_ROOT/docs/adr/0009-config-system.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-adr-config-system.sh ==="

# ── test_adr_config_system_exists ─────────────────────────────────────────────
if [ -f "$ADR_PATH" ]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_adr_config_system_exists" "exists" "$actual"

# ── test_adr_documents_resolution_order ───────────────────────────────────────
if grep -qi "resolution order\|fallback" "$ADR_PATH" 2>/dev/null; then
    actual="found"
else
    actual="missing"
fi
assert_eq "test_adr_documents_resolution_order" "found" "$actual"

# ── test_adr_documents_yaml_parser_choice ─────────────────────────────────────
if grep -q "python3\|yq" "$ADR_PATH" 2>/dev/null; then
    actual="found"
else
    actual="missing"
fi
assert_eq "test_adr_documents_yaml_parser_choice" "found" "$actual"

# ── test_adr_documents_approach_a ─────────────────────────────────────────────
if grep -qi "workflow-config.yaml\|Approach A\|config file" "$ADR_PATH" 2>/dev/null; then
    actual="found"
else
    actual="missing"
fi
assert_eq "test_adr_documents_approach_a" "found" "$actual"

# ── test_adr_documents_status_accepted ────────────────────────────────────────
if grep -qi "Status.*accepted\|accepted" "$ADR_PATH" 2>/dev/null; then
    actual="found"
else
    actual="missing"
fi
assert_eq "test_adr_documents_status_accepted" "found" "$actual"

# ── test_adr_documents_stack_priority ─────────────────────────────────────────
if grep -qi "python-poetry\|rust-cargo\|multi-marker\|priority" "$ADR_PATH" 2>/dev/null; then
    actual="found"
else
    actual="missing"
fi
assert_eq "test_adr_documents_stack_priority" "found" "$actual"

print_summary
