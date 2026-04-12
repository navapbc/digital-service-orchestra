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

# ── test_schema_ci_workflow_name_property_exists ──────────────────────────────
# ci.properties.workflow_name must exist with type: string
_snapshot_fail
cwn_exit=0
cwn_output=""
cwn_output=$(python3 -c "
import json, sys
d = json.load(open('$SCHEMA'))
props = d.get('properties', {}).get('ci', {}).get('properties', {})
if 'workflow_name' not in props:
    print('MISSING: workflow_name not found in ci.properties')
    sys.exit(1)
if props['workflow_name'].get('type') != 'string':
    print('WRONG_TYPE: expected string, got ' + str(props['workflow_name'].get('type')))
    sys.exit(1)
print('OK')
" 2>&1) || cwn_exit=$?
assert_eq "test_schema_ci_workflow_name_property_exists: exit 0" "0" "$cwn_exit"
assert_eq "test_schema_ci_workflow_name_property_exists: output is OK" "OK" "$cwn_output"
assert_pass_if_clean "test_schema_ci_workflow_name_property_exists"

# ── test_schema_ci_workflow_name_description_references_skip ─────────────────
# ci.workflow_name description must reference the skip-when-absent behavior
_snapshot_fail
cwnd_exit=0
cwnd_output=""
cwnd_output=$(python3 -c "
import json, sys
d = json.load(open('$SCHEMA'))
props = d.get('properties', {}).get('ci', {}).get('properties', {})
if 'workflow_name' not in props:
    print('MISSING')
    sys.exit(1)
desc = props['workflow_name'].get('description', '')
if 'absent' not in desc.lower() and 'skip' not in desc.lower():
    print('NO_SKIP_REF: description does not mention absent or skip')
    sys.exit(1)
print('OK')
" 2>&1) || cwnd_exit=$?
assert_eq "test_schema_ci_workflow_name_description_references_skip: exit 0" "0" "$cwnd_exit"
assert_eq "test_schema_ci_workflow_name_description_references_skip: output is OK" "OK" "$cwnd_output"
assert_pass_if_clean "test_schema_ci_workflow_name_description_references_skip"

# ── test_schema_review_section_exists ─────────────────────────────────────────
# review section must exist with max_resolution_attempts property
_snapshot_fail
rev_exit=0
rev_output=""
rev_output=$(python3 -c "
import json, sys
d = json.load(open('$SCHEMA'))
props = d.get('properties', {}).get('review', {}).get('properties', {})
if 'max_resolution_attempts' not in props:
    print('MISSING: max_resolution_attempts not found in review.properties')
    sys.exit(1)
if props['max_resolution_attempts'].get('type') != 'integer':
    print('WRONG_TYPE: expected integer, got ' + str(props['max_resolution_attempts'].get('type')))
    sys.exit(1)
if props['max_resolution_attempts'].get('default') != 5:
    print('WRONG_DEFAULT: expected 5, got ' + str(props['max_resolution_attempts'].get('default')))
    sys.exit(1)
print('OK')
" 2>&1) || rev_exit=$?
assert_eq "test_schema_review_section_exists: exit 0" "0" "$rev_exit"
assert_eq "test_schema_review_section_exists: output is OK" "OK" "$rev_output"
assert_pass_if_clean "test_schema_review_section_exists"

# ── test_schema_paths_section_exists ─────────────────────────────────────────
# paths section must exist with app_dir, src_dir, test_dir properties
_snapshot_fail
paths_exit=0
paths_output=""
paths_output=$(python3 -c "
import json, sys
d = json.load(open('$SCHEMA'))
props = d.get('properties', {}).get('paths', {}).get('properties', {})
for key in ('app_dir', 'src_dir', 'test_dir', 'test_unit_dir'):
    if key not in props:
        print(f'MISSING: {key} not found in paths.properties')
        sys.exit(1)
print('OK')
" 2>&1) || paths_exit=$?
assert_eq "test_schema_paths_section_exists: exit 0" "0" "$paths_exit"
assert_eq "test_schema_paths_section_exists: output is OK" "OK" "$paths_output"
assert_pass_if_clean "test_schema_paths_section_exists"

# ── test_schema_interpreter_section_exists ────────────────────────────────────
# interpreter section must exist with python_venv property
_snapshot_fail
interp_exit=0
interp_output=""
interp_output=$(python3 -c "
import json, sys
d = json.load(open('$SCHEMA'))
props = d.get('properties', {}).get('interpreter', {}).get('properties', {})
if 'python_venv' not in props:
    print('MISSING: python_venv not found in interpreter.properties')
    sys.exit(1)
print('OK')
" 2>&1) || interp_exit=$?
assert_eq "test_schema_interpreter_section_exists: exit 0" "0" "$interp_exit"
assert_eq "test_schema_interpreter_section_exists: output is OK" "OK" "$interp_output"
assert_pass_if_clean "test_schema_interpreter_section_exists"

# ── test_schema_persistence_section_exists ────────────────────────────────────
# persistence section must exist with source_patterns and test_patterns
_snapshot_fail
persist_exit=0
persist_output=""
persist_output=$(python3 -c "
import json, sys
d = json.load(open('$SCHEMA'))
props = d.get('properties', {}).get('persistence', {}).get('properties', {})
for key in ('source_patterns', 'test_patterns'):
    if key not in props:
        print(f'MISSING: {key} not found in persistence.properties')
        sys.exit(1)
print('OK')
" 2>&1) || persist_exit=$?
assert_eq "test_schema_persistence_section_exists: exit 0" "0" "$persist_exit"
assert_eq "test_schema_persistence_section_exists: output is OK" "OK" "$persist_output"
assert_pass_if_clean "test_schema_persistence_section_exists"

# ── test_schema_worktree_new_properties ───────────────────────────────────────
# worktree section must include branch_pattern and max_age_hours
_snapshot_fail
wt_exit=0
wt_output=""
wt_output=$(python3 -c "
import json, sys
d = json.load(open('$SCHEMA'))
props = d.get('properties', {}).get('worktree', {}).get('properties', {})
for key in ('branch_pattern', 'max_age_hours'):
    if key not in props:
        print(f'MISSING: {key} not found in worktree.properties')
        sys.exit(1)
print('OK')
" 2>&1) || wt_exit=$?
assert_eq "test_schema_worktree_new_properties: exit 0" "0" "$wt_exit"
assert_eq "test_schema_worktree_new_properties: output is OK" "OK" "$wt_output"
assert_pass_if_clean "test_schema_worktree_new_properties"

# ── test_schema_infrastructure_compose_db_file ────────────────────────────────
# infrastructure section must include compose_db_file
_snapshot_fail
cdf_exit=0
cdf_output=""
cdf_output=$(python3 -c "
import json, sys
d = json.load(open('$SCHEMA'))
props = d.get('properties', {}).get('infrastructure', {}).get('properties', {})
if 'compose_db_file' not in props:
    print('MISSING: compose_db_file not found in infrastructure.properties')
    sys.exit(1)
print('OK')
" 2>&1) || cdf_exit=$?
assert_eq "test_schema_infrastructure_compose_db_file: exit 0" "0" "$cdf_exit"
assert_eq "test_schema_infrastructure_compose_db_file: output is OK" "OK" "$cdf_output"
assert_pass_if_clean "test_schema_infrastructure_compose_db_file"

print_summary
