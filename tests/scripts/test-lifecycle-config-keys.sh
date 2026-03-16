#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-lifecycle-config-keys.sh
# Tests that workflow-config.conf contains database, infrastructure, and session
# sections with all keys needed by agent-batch-lifecycle.sh subcommands.
#
# Also validates workflow-config-schema.json documents these new sections.
#
# Usage: bash lockpick-workflow/tests/scripts/test-lifecycle-config-keys.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$PLUGIN_ROOT/scripts/read-config.sh"
CONFIG="$REPO_ROOT/workflow-config.conf"
SCHEMA="$PLUGIN_ROOT/docs/workflow-config-schema.json"
EXAMPLE="$PLUGIN_ROOT/docs/workflow-config.example.conf"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Resolve Python with pyyaml
PYTHON=""
for candidate in \
    "$REPO_ROOT/app/.venv/bin/python3" \
    "$REPO_ROOT/.venv/bin/python3" \
    "python3"; do
    [[ "$candidate" != "python3" ]] && [[ ! -f "$candidate" ]] && continue
    if "$candidate" -c "import yaml" 2>/dev/null; then
        PYTHON="$candidate"
        break
    fi
done
if [[ -z "$PYTHON" ]]; then
    echo "Error: no python3 with pyyaml found" >&2
    exit 1
fi

echo "=== test-lifecycle-config-keys.sh ==="

# ── test_config_database_ensure_cmd ─────────────────────────────────────────
# database.ensure_cmd must be readable and non-empty
_snapshot_fail
db_ensure_exit=0
db_ensure_output=""
db_ensure_output=$(bash "$SCRIPT" "$CONFIG" "database.ensure_cmd" 2>&1) || db_ensure_exit=$?
assert_eq "test_config_database_ensure_cmd: exit 0" "0" "$db_ensure_exit"
assert_ne "test_config_database_ensure_cmd: non-empty" "" "$db_ensure_output"
assert_pass_if_clean "test_config_database_ensure_cmd"

# ── test_config_database_status_cmd ─────────────────────────────────────────
_snapshot_fail
db_status_exit=0
db_status_output=""
db_status_output=$(bash "$SCRIPT" "$CONFIG" "database.status_cmd" 2>&1) || db_status_exit=$?
assert_eq "test_config_database_status_cmd: exit 0" "0" "$db_status_exit"
assert_ne "test_config_database_status_cmd: non-empty" "" "$db_status_output"
assert_pass_if_clean "test_config_database_status_cmd"

# ── test_config_database_port_cmd ───────────────────────────────────────────
_snapshot_fail
db_port_exit=0
db_port_output=""
db_port_output=$(bash "$SCRIPT" "$CONFIG" "database.port_cmd" 2>&1) || db_port_exit=$?
assert_eq "test_config_database_port_cmd: exit 0" "0" "$db_port_exit"
assert_ne "test_config_database_port_cmd: non-empty" "" "$db_port_output"
assert_pass_if_clean "test_config_database_port_cmd"

# ── test_config_infrastructure_container_prefix ─────────────────────────────
_snapshot_fail
infra_prefix_exit=0
infra_prefix_output=""
infra_prefix_output=$(bash "$SCRIPT" "$CONFIG" "infrastructure.container_prefix" 2>&1) || infra_prefix_exit=$?
assert_eq "test_config_infrastructure_container_prefix: exit 0" "0" "$infra_prefix_exit"
assert_ne "test_config_infrastructure_container_prefix: non-empty" "" "$infra_prefix_output"
assert_pass_if_clean "test_config_infrastructure_container_prefix"

# ── test_config_infrastructure_compose_project ──────────────────────────────
_snapshot_fail
infra_compose_exit=0
infra_compose_output=""
infra_compose_output=$(bash "$SCRIPT" "$CONFIG" "infrastructure.compose_project" 2>&1) || infra_compose_exit=$?
assert_eq "test_config_infrastructure_compose_project: exit 0" "0" "$infra_compose_exit"
assert_ne "test_config_infrastructure_compose_project: non-empty" "" "$infra_compose_output"
assert_pass_if_clean "test_config_infrastructure_compose_project"

# ── test_config_session_usage_check_cmd ─────────────────────────────────────
_snapshot_fail
session_exit=0
session_output=""
session_output=$(bash "$SCRIPT" "$CONFIG" "session.usage_check_cmd" 2>&1) || session_exit=$?
assert_eq "test_config_session_usage_check_cmd: exit 0" "0" "$session_exit"
assert_ne "test_config_session_usage_check_cmd: non-empty" "" "$session_output"
assert_pass_if_clean "test_config_session_usage_check_cmd"

# ── test_read_config_absent_database_section ────────────────────────────────
# When database section is absent, read-config.sh returns empty string and exit 0
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

MINIMAL_CONFIG="$TMPDIR_FIXTURE/minimal.yaml"
cat > "$MINIMAL_CONFIG" <<'YAML'
version: "1.0.0"
stack: python-poetry
YAML

_snapshot_fail
absent_db_exit=0
absent_db_output=""
absent_db_output=$(bash "$SCRIPT" "$MINIMAL_CONFIG" "database.ensure_cmd" 2>&1) || absent_db_exit=$?
assert_eq "test_read_config_absent_database: exit 0" "0" "$absent_db_exit"
assert_eq "test_read_config_absent_database: empty output" "" "$absent_db_output"
assert_pass_if_clean "test_read_config_absent_database"

# ── test_read_config_absent_infrastructure_section ──────────────────────────
_snapshot_fail
absent_infra_exit=0
absent_infra_output=""
absent_infra_output=$(bash "$SCRIPT" "$MINIMAL_CONFIG" "infrastructure.container_prefix" 2>&1) || absent_infra_exit=$?
assert_eq "test_read_config_absent_infrastructure: exit 0" "0" "$absent_infra_exit"
assert_eq "test_read_config_absent_infrastructure: empty output" "" "$absent_infra_output"
assert_pass_if_clean "test_read_config_absent_infrastructure"

# ── test_read_config_absent_session_section ─────────────────────────────────
_snapshot_fail
absent_session_exit=0
absent_session_output=""
absent_session_output=$(bash "$SCRIPT" "$MINIMAL_CONFIG" "session.usage_check_cmd" 2>&1) || absent_session_exit=$?
assert_eq "test_read_config_absent_session: exit 0" "0" "$absent_session_exit"
assert_eq "test_read_config_absent_session: empty output" "" "$absent_session_output"
assert_pass_if_clean "test_read_config_absent_session"

# ── test_schema_database_section ────────────────────────────────────────────
# Schema must document database section with ensure_cmd, status_cmd, port_cmd
_snapshot_fail
schema_db=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
props = s.get('properties', {})
db = props.get('database', {})
db_props = db.get('properties', {})
keys = sorted(db_props.keys())
if 'ensure_cmd' in db_props and 'status_cmd' in db_props and 'port_cmd' in db_props:
    print('has_keys')
else:
    print('missing_keys: ' + ','.join(keys))
" "$SCHEMA" 2>&1)
assert_eq "test_schema_database_section: has all keys" "has_keys" "$schema_db"
assert_pass_if_clean "test_schema_database_section"

# ── test_schema_infrastructure_section ──────────────────────────────────────
_snapshot_fail
schema_infra=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
props = s.get('properties', {})
infra = props.get('infrastructure', {})
infra_props = infra.get('properties', {})
if 'container_prefix' in infra_props and 'compose_project' in infra_props:
    print('has_keys')
else:
    print('missing_keys: ' + ','.join(sorted(infra_props.keys())))
" "$SCHEMA" 2>&1)
assert_eq "test_schema_infrastructure_section: has all keys" "has_keys" "$schema_infra"
assert_pass_if_clean "test_schema_infrastructure_section"

# ── test_schema_session_section ─────────────────────────────────────────────
_snapshot_fail
schema_session=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
props = s.get('properties', {})
sess = props.get('session', {})
sess_props = sess.get('properties', {})
if 'usage_check_cmd' in sess_props:
    print('has_keys')
else:
    print('missing_keys: ' + ','.join(sorted(sess_props.keys())))
" "$SCHEMA" 2>&1)
assert_eq "test_schema_session_section: has usage_check_cmd" "has_keys" "$schema_session"
assert_pass_if_clean "test_schema_session_section"

# ── test_schema_all_new_sections_optional ───────────────────────────────────
# None of database, infrastructure, session should be in the schema's required array
_snapshot_fail
schema_required=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
required = s.get('required', [])
new_sections = ['database', 'infrastructure', 'session']
found = [k for k in new_sections if k in required]
if found:
    print('required: ' + ','.join(found))
else:
    print('all_optional')
" "$SCHEMA" 2>&1)
assert_eq "test_schema_all_new_sections_optional" "all_optional" "$schema_required"
assert_pass_if_clean "test_schema_all_new_sections_optional"

# ── test_example_config_has_new_sections ────────────────────────────────────
_snapshot_fail
for section in database infrastructure session; do
    if grep -q "^${section}\." "$EXAMPLE" 2>/dev/null; then
        assert_eq "test_example_config_has_${section}" "found" "found"
    else
        assert_eq "test_example_config_has_${section}" "found" "missing"
    fi
done
assert_pass_if_clean "test_example_config_has_new_sections"

print_summary
