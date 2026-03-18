#!/usr/bin/env bash
# tests/scripts/test-workflow-config-schema.sh
# Tests that workflow-config-schema.json contains expected properties.
#
# Usage: bash tests/scripts/test-workflow-config-schema.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCHEMA="$DSO_PLUGIN_DIR/docs/workflow-config-schema.json"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-workflow-config-schema.sh ==="

# ── test_schema_is_valid_json ─────────────────────────────────────────────────
# Schema must be valid JSON
_snapshot_fail
valid_exit=0
python3 -c "import json; json.load(open('$SCHEMA'))" 2>&1 || valid_exit=$?
assert_eq "test_schema_is_valid_json: exit 0" "0" "$valid_exit"
assert_pass_if_clean "test_schema_is_valid_json"

# ── test_schema_commands_test_changed_property_exists ────────────────────────
# commands.properties.test_changed must exist and have type: string
_snapshot_fail
tc_exit=0
tc_output=""
tc_output=$(python3 -c "
import json, sys
d = json.load(open('$SCHEMA'))
props = d.get('properties', {}).get('commands', {}).get('properties', {})
if 'test_changed' not in props:
    print('MISSING: test_changed not found in commands.properties')
    sys.exit(1)
if props['test_changed'].get('type') != 'string':
    print('WRONG_TYPE: expected string, got ' + str(props['test_changed'].get('type')))
    sys.exit(1)
print('OK')
" 2>&1) || tc_exit=$?
assert_eq "test_schema_commands_test_changed_property_exists: exit 0" "0" "$tc_exit"
assert_eq "test_schema_commands_test_changed_property_exists: output is OK" "OK" "$tc_output"
assert_pass_if_clean "test_schema_commands_test_changed_property_exists"

# ── test_schema_commands_test_changed_description_references_skip ─────────────
# test_changed description must reference the commit workflow skip behavior
_snapshot_fail
desc_exit=0
desc_output=""
desc_output=$(python3 -c "
import json, sys
d = json.load(open('$SCHEMA'))
props = d.get('properties', {}).get('commands', {}).get('properties', {})
if 'test_changed' not in props:
    print('MISSING')
    sys.exit(1)
desc = props['test_changed'].get('description', '')
if 'absent' not in desc.lower() and 'skip' not in desc.lower():
    print('NO_SKIP_REF: description does not mention absent or skip')
    sys.exit(1)
print('OK')
" 2>&1) || desc_exit=$?
assert_eq "test_schema_commands_test_changed_description_references_skip: exit 0" "0" "$desc_exit"
assert_eq "test_schema_commands_test_changed_description_references_skip: output is OK" "OK" "$desc_output"
assert_pass_if_clean "test_schema_commands_test_changed_description_references_skip"

print_summary
