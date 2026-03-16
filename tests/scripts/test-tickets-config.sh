#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-tickets-config.sh
# Tests for the tickets: section in workflow-config.conf
#
# Validates:
#   - Schema defines tickets: section with correct keys
#   - read-config.sh can read all ticket config values
#   - tk script reads prefix and directory from config (falls back to defaults)
#   - Example config contains tickets: section
#   - Backward compatibility (no config = same behavior as before)
#
# Usage: bash lockpick-workflow/tests/scripts/test-tickets-config.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
READ_CONFIG="$PLUGIN_ROOT/scripts/read-config.sh"
SCHEMA_FILE="$PLUGIN_ROOT/docs/workflow-config-schema.json"
EXAMPLE_CONFIG="$PLUGIN_ROOT/docs/workflow-config.example.conf"
TK_SCRIPT="$PLUGIN_ROOT/scripts/tk"

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

echo "=== test-tickets-config.sh ==="

# Create temp dir for fixtures
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# ── Schema tests ────────────────────────────────────────────────────────────

# test_schema_has_tickets_section: schema defines a tickets property
_fail_before=$FAIL
tickets_in_schema=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
props = s.get('properties', {})
if 'tickets' in props:
    print('has_tickets')
else:
    print('missing_tickets')
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_has_tickets_section" "has_tickets" "$tickets_in_schema"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_has_tickets_section ... PASS"
fi

# test_schema_tickets_type_is_object: tickets must be type: object
_fail_before=$FAIL
tickets_type=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
tickets = s.get('properties', {}).get('tickets', {})
print(tickets.get('type', 'missing'))
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_tickets_type_is_object" "object" "$tickets_type"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_tickets_type_is_object ... PASS"
fi

# test_schema_tickets_has_prefix_key: tickets must have prefix property
_fail_before=$FAIL
has_prefix=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
tickets_props = s.get('properties', {}).get('tickets', {}).get('properties', {})
if 'prefix' in tickets_props:
    print('has_prefix')
else:
    print('missing_prefix')
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_tickets_has_prefix_key" "has_prefix" "$has_prefix"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_tickets_has_prefix_key ... PASS"
fi

# test_schema_tickets_has_directory_key: tickets must have directory property
_fail_before=$FAIL
has_directory=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
tickets_props = s.get('properties', {}).get('tickets', {}).get('properties', {})
if 'directory' in tickets_props:
    print('has_directory')
else:
    print('missing_directory')
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_tickets_has_directory_key" "has_directory" "$has_directory"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_tickets_has_directory_key ... PASS"
fi

# test_schema_tickets_has_sync_section: tickets must have sync sub-object
_fail_before=$FAIL
has_sync=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
tickets_props = s.get('properties', {}).get('tickets', {}).get('properties', {})
sync = tickets_props.get('sync', {})
sync_props = sync.get('properties', {})
if 'jira_project_key' in sync_props and 'bidirectional_comments' in sync_props:
    print('has_sync_keys')
else:
    print('missing_sync_keys')
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_tickets_has_sync_section" "has_sync_keys" "$has_sync"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_tickets_has_sync_section ... PASS"
fi

# test_schema_tickets_directory_default: directory should have default ".tickets"
_fail_before=$FAIL
dir_default=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
tickets_props = s.get('properties', {}).get('tickets', {}).get('properties', {})
directory = tickets_props.get('directory', {})
print(directory.get('default', 'no_default'))
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_tickets_directory_default" ".tickets" "$dir_default"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_tickets_directory_default ... PASS"
fi

# test_schema_tickets_sync_bidir_default: bidirectional_comments default true
_fail_before=$FAIL
bidir_default=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
tickets_props = s.get('properties', {}).get('tickets', {}).get('properties', {})
sync_props = tickets_props.get('sync', {}).get('properties', {})
bidir = sync_props.get('bidirectional_comments', {})
print(str(bidir.get('default', 'no_default')))
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_tickets_sync_bidir_default" "True" "$bidir_default"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_tickets_sync_bidir_default ... PASS"
fi

# ── read-config.sh tests ────────────────────────────────────────────────────

# Write a fixture config with full tickets section
TICKETS_FIXTURE="$TMPDIR_FIXTURE/tickets-config.yaml"
cat > "$TICKETS_FIXTURE" <<'YAML'
version: "1.0.0"
tickets:
  prefix: my-cool-project
  directory: .issues
  sync:
    jira_project_key: MCP
    bidirectional_comments: false
YAML

# test_read_config_tickets_prefix: read tickets.prefix
_fail_before=$FAIL
prefix_exit=0
prefix_output=""
prefix_output=$(bash "$READ_CONFIG" "$TICKETS_FIXTURE" "tickets.prefix" 2>&1) || prefix_exit=$?
assert_eq "test_read_config_tickets_prefix: exit 0" "0" "$prefix_exit"
assert_eq "test_read_config_tickets_prefix: correct value" "my-cool-project" "$prefix_output"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_read_config_tickets_prefix ... PASS"
fi

# test_read_config_tickets_directory: read tickets.directory
_fail_before=$FAIL
dir_exit=0
dir_output=""
dir_output=$(bash "$READ_CONFIG" "$TICKETS_FIXTURE" "tickets.directory" 2>&1) || dir_exit=$?
assert_eq "test_read_config_tickets_directory: exit 0" "0" "$dir_exit"
assert_eq "test_read_config_tickets_directory: correct value" ".issues" "$dir_output"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_read_config_tickets_directory ... PASS"
fi

# test_read_config_tickets_sync_jira_key: read tickets.sync.jira_project_key
_fail_before=$FAIL
jira_exit=0
jira_output=""
jira_output=$(bash "$READ_CONFIG" "$TICKETS_FIXTURE" "tickets.sync.jira_project_key" 2>&1) || jira_exit=$?
assert_eq "test_read_config_tickets_sync_jira_key: exit 0" "0" "$jira_exit"
assert_eq "test_read_config_tickets_sync_jira_key: correct value" "MCP" "$jira_output"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_read_config_tickets_sync_jira_key ... PASS"
fi

# test_read_config_tickets_sync_bidir: read tickets.sync.bidirectional_comments
_fail_before=$FAIL
bidir_exit=0
bidir_output=""
bidir_output=$(bash "$READ_CONFIG" "$TICKETS_FIXTURE" "tickets.sync.bidirectional_comments" 2>&1) || bidir_exit=$?
assert_eq "test_read_config_tickets_sync_bidir: exit 0" "0" "$bidir_exit"
assert_eq "test_read_config_tickets_sync_bidir: correct value" "False" "$bidir_output"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_read_config_tickets_sync_bidir ... PASS"
fi

# ── Example config tests ────────────────────────────────────────────────────

# test_example_config_has_tickets_section
_fail_before=$FAIL
if grep -q "^tickets\." "$EXAMPLE_CONFIG" 2>/dev/null; then
    example_has_tickets="has_tickets"
else
    example_has_tickets="missing_tickets"
fi
assert_eq "test_example_config_has_tickets_section" "has_tickets" "$example_has_tickets"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_example_config_has_tickets_section ... PASS"
fi

# test_example_config_tickets_prefix_readable
_fail_before=$FAIL
ex_prefix_exit=0
ex_prefix_output=""
ex_prefix_output=$(bash "$READ_CONFIG" "$EXAMPLE_CONFIG" "tickets.prefix" 2>&1) || ex_prefix_exit=$?
assert_eq "test_example_config_tickets_prefix_readable: exit 0" "0" "$ex_prefix_exit"
assert_ne "test_example_config_tickets_prefix_readable: non-empty" "" "$ex_prefix_output"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_example_config_tickets_prefix_readable ... PASS"
fi

# ── tk integration tests ────────────────────────────────────────────────────

# test_tk_generate_id_uses_config_prefix: when tickets.prefix is set in config,
# generate_id should use it instead of deriving from directory name
_fail_before=$FAIL

# Create a temp project with a git repo and workflow-config.conf
TK_TEST_DIR="$TMPDIR_FIXTURE/test-project"
mkdir -p "$TK_TEST_DIR/.tickets"
(cd "$TK_TEST_DIR" && git init -q -b main)
cat > "$TK_TEST_DIR/workflow-config.conf" <<'CONF'
tickets.prefix=custom-prefix
CONF

# Source tk functions via _TK_SOURCE_ONLY and test generate_id
# Note: set +o pipefail is needed because generate_id uses tr|head which
# causes SIGPIPE; with set -e + pipefail (from tk), this kills the shell.
tk_id_output=$(cd "$TK_TEST_DIR" && CLAUDE_PLUGIN_PYTHON="$PYTHON" bash -c '
    _TK_SOURCE_ONLY=1
    . "'"$TK_SCRIPT"'"
    set +o pipefail
    generate_id
' 2>/dev/null) || true

# The ID should start with the custom prefix (not derived from 'test-project')
if [[ "$tk_id_output" == custom-prefix-* ]]; then
    tk_prefix_result="uses_config"
else
    tk_prefix_result="ignores_config"
fi
assert_eq "test_tk_generate_id_uses_config_prefix" "uses_config" "$tk_prefix_result"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_tk_generate_id_uses_config_prefix ... PASS"
fi

# test_tk_uses_config_directory: when tickets.directory is set in config,
# find_tickets_dir should use it
_fail_before=$FAIL
TK_DIR_TEST="$TMPDIR_FIXTURE/dir-test-project"
mkdir -p "$TK_DIR_TEST/.custom-tickets"
(cd "$TK_DIR_TEST" && git init -q -b main)
cat > "$TK_DIR_TEST/workflow-config.conf" <<'CONF'
tickets.directory=.custom-tickets
CONF

# Test that find_tickets_dir finds the custom directory
tk_dir_output=$(cd "$TK_DIR_TEST" && CLAUDE_PLUGIN_PYTHON="$PYTHON" bash -c '
    _TK_SOURCE_ONLY=1
    . "'"$TK_SCRIPT"'"
    find_tickets_dir
' 2>/dev/null) || true

if [[ "$tk_dir_output" == *".custom-tickets"* ]]; then
    tk_dir_result="uses_config"
else
    tk_dir_result="ignores_config"
fi
assert_eq "test_tk_uses_config_directory" "uses_config" "$tk_dir_result"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_tk_uses_config_directory ... PASS"
fi

# test_tk_backward_compat_no_config: without workflow-config.conf,
# tk should still work with .tickets directory (existing behavior)
_fail_before=$FAIL
TK_NOCONFIG_DIR="$TMPDIR_FIXTURE/noconfig-project"
mkdir -p "$TK_NOCONFIG_DIR/.tickets"
(cd "$TK_NOCONFIG_DIR" && git init -q -b main)
# No workflow-config.conf

tk_noconfig_output=$(cd "$TK_NOCONFIG_DIR" && CLAUDE_PLUGIN_PYTHON="$PYTHON" bash -c '
    _TK_SOURCE_ONLY=1
    . "'"$TK_SCRIPT"'"
    find_tickets_dir
' 2>/dev/null) || true

if [[ "$tk_noconfig_output" == *".tickets"* ]]; then
    tk_noconfig_result="backward_compat"
else
    tk_noconfig_result="broken"
fi
assert_eq "test_tk_backward_compat_no_config" "backward_compat" "$tk_noconfig_result"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_tk_backward_compat_no_config ... PASS"
fi

print_summary
