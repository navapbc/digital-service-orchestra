#!/usr/bin/env bash
# tests/scripts/test-read-config.sh
# Tests for scripts/read-config.sh
#
# Usage: bash tests/scripts/test-read-config.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/read-config.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-read-config.sh ==="

# Create a temp dir for fixture files used in tests
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# Write a valid .conf fixture config
FIXTURE_CONFIG="$TMPDIR_FIXTURE/workflow-config.conf"
cat > "$FIXTURE_CONFIG" <<'CONF'
test_command=make test-unit-only
lint_command=make lint
format_command=make format
issue_tracker=tk
CONF

# ── test_read_config_script_exists ────────────────────────────────────────────
# The script must exist at the expected path and be executable.
if [[ -f "$SCRIPT" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_read_config_script_exists: file exists" "exists" "$actual_exists"

if [[ -x "$SCRIPT" ]]; then
    actual_exec="executable"
else
    actual_exec="not_executable"
fi
assert_eq "test_read_config_script_exists: file is executable" "executable" "$actual_exec"

# ── test_read_config_yaml_support ──────────────────────────────────────────────
# read-config.sh must support YAML format (uses pure-Python parser, no pyyaml).
_fail_before_nyr=$FAIL
if grep -qi 'yaml' "$SCRIPT"; then
    actual_yaml_ref="found"
else
    actual_yaml_ref="none"
fi
assert_eq "test_read_config_yaml_support: has YAML support" "found" "$actual_yaml_ref"
if [[ "$FAIL" -eq "$_fail_before_nyr" ]]; then
    echo "test_read_config_yaml_support ... PASS"
fi

# ── test_read_config_uses_python3 ─────────────────────────────────────────────
# read-config.sh uses python3 for YAML parsing (pure-Python, no external deps).
_fail_before_npy=$FAIL
if grep -q 'python3' "$SCRIPT"; then
    actual_py_ref="found"
else
    actual_py_ref="none"
fi
assert_eq "test_read_config_uses_python3: uses python3 for YAML" "found" "$actual_py_ref"
if [[ "$FAIL" -eq "$_fail_before_npy" ]]; then
    echo "test_read_config_uses_python3 ... PASS"
fi

# ── test_read_config_references_config_paths ──────────────────────────────────
# read-config.sh references config-paths.sh (foundation layer relationship).
_fail_before_ncp=$FAIL
if grep -q 'config-paths' "$SCRIPT"; then
    actual_cp_ref="found"
else
    actual_cp_ref="none"
fi
assert_eq "test_read_config_references_config_paths: references config-paths.sh" "found" "$actual_cp_ref"
if [[ "$FAIL" -eq "$_fail_before_ncp" ]]; then
    echo "test_read_config_references_config_paths ... PASS"
fi

# ── test_read_config_no_in_progress_guard ─────────────────────────────────────
# read-config.sh must not contain _READ_CONFIG_IN_PROGRESS guard (YAML-only artifact).
_fail_before_ipg=$FAIL
if { grep -q "_READ_CONFIG_IN_PROGRESS" "$SCRIPT"; test $? -ne 0; }; then
    actual_ipg_ref="none"
else
    actual_ipg_ref="found"
fi
assert_eq "test_read_config_no_in_progress_guard: no _READ_CONFIG_IN_PROGRESS guard" "none" "$actual_ipg_ref"
if [[ "$FAIL" -eq "$_fail_before_ipg" ]]; then
    echo "test_read_config_no_in_progress_guard ... PASS"
fi

# ── test_read_config_missing_file_exits_gracefully ────────────────────────────
# Calling read-config.sh when no config file exists returns empty output and exits 0.
MISSING_DIR="$TMPDIR_FIXTURE/empty_dir"
mkdir -p "$MISSING_DIR"
missing_exit=0
missing_output=""
missing_output=$(bash "$SCRIPT" "$MISSING_DIR/workflow-config.conf" "test_command" 2>&1) || missing_exit=$?
if [[ "$missing_exit" -eq 0 ]]; then
    actual_graceful="graceful"
else
    actual_graceful="errored"
fi
assert_eq "test_read_config_missing_file_exits_gracefully: exits 0 when file missing" "graceful" "$actual_graceful"

if [[ -z "$missing_output" ]]; then
    actual_output_empty="empty"
else
    actual_output_empty="non_empty"
fi
assert_eq "test_read_config_missing_file_exits_gracefully: output is empty when file missing" "empty" "$actual_output_empty"

# ── test_read_config_returns_value_for_known_key ──────────────────────────────
# Given a valid .conf fixture, querying 'test_command' returns 'make test-unit-only'.
known_exit=0
known_output=""
known_output=$(bash "$SCRIPT" "$FIXTURE_CONFIG" "test_command" 2>&1) || known_exit=$?
assert_eq "test_read_config_returns_value_for_known_key: exit 0" "0" "$known_exit"
assert_eq "test_read_config_returns_value_for_known_key: correct value" "make test-unit-only" "$known_output"

# ── test_read_config_returns_empty_for_unknown_key ───────────────────────────
# An unknown key returns empty string and exits 0.
unknown_exit=0
unknown_output=""
unknown_output=$(bash "$SCRIPT" "$FIXTURE_CONFIG" "nonexistent_key_xyz" 2>&1) || unknown_exit=$?
assert_eq "test_read_config_returns_empty_for_unknown_key: exit 0" "0" "$unknown_exit"
assert_eq "test_read_config_returns_empty_for_unknown_key: output is empty" "" "$unknown_output"

# ── test_schema_allows_unknown_top_level_section ─────────────────────────────
# The schema must NOT have additionalProperties: false at root.
SCHEMA_FILE="$DSO_PLUGIN_DIR/docs/workflow-config-schema.json"
schema_additional=$(python3 -c "
import json, sys
s = json.load(open(sys.argv[1]))
v = s.get('additionalProperties', 'absent')
if v is False:
    print('blocked')
else:
    print('allowed')
" "$SCHEMA_FILE" 2>&1)
_fail_before_sau=$FAIL
assert_eq "test_schema_allows_unknown_top_level_section" "allowed" "$schema_additional"
if [[ "$FAIL" -eq "$_fail_before_sau" ]]; then
    echo "test_schema_allows_unknown_top_level_section ... PASS"
fi

# ── test_schema_validates_jira_section ───────────────────────────────────────
# The schema must define a `jira` property with a `project` key.
_fail_before_jira=$FAIL
jira_has_project=$(python3 -c "
import json, sys
s = json.load(open(sys.argv[1]))
props = s.get('properties', {})
jira = props.get('jira', {})
jira_props = jira.get('properties', {})
if 'project' in jira_props:
    print('has_project')
else:
    print('missing_project')
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_validates_jira_section" "has_project" "$jira_has_project"
if [[ "$FAIL" -eq "$_fail_before_jira" ]]; then
    echo "test_schema_validates_jira_section ... PASS"
fi

# ── test_schema_validates_issue_tracker_section ──────────────────────────────
# The schema must define an `issue_tracker` property with `search_cmd` and `create_cmd`.
_fail_before_it=$FAIL
it_has_keys=$(python3 -c "
import json, sys
s = json.load(open(sys.argv[1]))
props = s.get('properties', {})
it = props.get('issue_tracker', {})
it_props = it.get('properties', {})
if 'search_cmd' in it_props and 'create_cmd' in it_props:
    print('has_keys')
else:
    print('missing_keys')
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_validates_issue_tracker_section" "has_keys" "$it_has_keys"
if [[ "$FAIL" -eq "$_fail_before_it" ]]; then
    echo "test_schema_validates_issue_tracker_section ... PASS"
fi

# ── test_schema_jira_rejects_invalid_type ────────────────────────────────────
# The `jira` property must be type: object (not string, etc.).
_fail_before_jt=$FAIL
jira_type=$(python3 -c "
import json, sys
s = json.load(open(sys.argv[1]))
jira = s.get('properties', {}).get('jira', {})
print(jira.get('type', 'missing'))
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_jira_rejects_invalid_type: jira type is object" "object" "$jira_type"
if [[ "$FAIL" -eq "$_fail_before_jt" ]]; then
    echo "test_schema_jira_rejects_invalid_type ... PASS"
fi

# ── Nested key resolution tests (read-config.sh) ────────────────────────────

# Write a .conf fixture with nested (dot-notation) keys
NESTED_FIXTURE="$TMPDIR_FIXTURE/nested-config.conf"
cat > "$NESTED_FIXTURE" <<'CONF'
version=1.0.0
jira.project=DTL
issue_tracker.search_cmd=grep -rl
issue_tracker.create_cmd=tk create
tickets.prefix=myproject
CONF

# ── test_read_config_nested_jira_project ─────────────────────────────────────
_fail_before_njp=$FAIL
nested_jira_exit=0
nested_jira_output=""
nested_jira_output=$(bash "$SCRIPT" "$NESTED_FIXTURE" "jira.project" 2>&1) || nested_jira_exit=$?
assert_eq "test_read_config_nested_jira_project: exit 0" "0" "$nested_jira_exit"
assert_eq "test_read_config_nested_jira_project: correct value" "DTL" "$nested_jira_output"
if [[ "$FAIL" -eq "$_fail_before_njp" ]]; then
    echo "test_read_config_nested_jira_project ... PASS"
fi

# ── test_read_config_nested_issue_tracker_search_cmd ─────────────────────────
_fail_before_nits=$FAIL
nested_it_exit=0
nested_it_output=""
nested_it_output=$(bash "$SCRIPT" "$NESTED_FIXTURE" "issue_tracker.search_cmd" 2>&1) || nested_it_exit=$?
assert_eq "test_read_config_nested_issue_tracker_search_cmd: exit 0" "0" "$nested_it_exit"
assert_eq "test_read_config_nested_issue_tracker_search_cmd: correct value" "grep -rl" "$nested_it_output"
if [[ "$FAIL" -eq "$_fail_before_nits" ]]; then
    echo "test_read_config_nested_issue_tracker_search_cmd ... PASS"
fi

# ── test_read_config_nested_arbitrary_section ────────────────────────────────
_fail_before_nas=$FAIL
nested_arb_exit=0
nested_arb_output=""
nested_arb_output=$(bash "$SCRIPT" "$NESTED_FIXTURE" "tickets.prefix" 2>&1) || nested_arb_exit=$?
assert_eq "test_read_config_nested_arbitrary_section: exit 0" "0" "$nested_arb_exit"
assert_eq "test_read_config_nested_arbitrary_section: correct value" "myproject" "$nested_arb_output"
if [[ "$FAIL" -eq "$_fail_before_nas" ]]; then
    echo "test_read_config_nested_arbitrary_section ... PASS"
fi

# ── test_read_config_nested_missing_subkey ───────────────────────────────────
_fail_before_nms=$FAIL
nested_miss_exit=0
nested_miss_output=""
nested_miss_output=$(bash "$SCRIPT" "$NESTED_FIXTURE" "jira.nonexistent" 2>&1) || nested_miss_exit=$?
assert_eq "test_read_config_nested_missing_subkey: exit 0" "0" "$nested_miss_exit"
assert_eq "test_read_config_nested_missing_subkey: output is empty" "" "$nested_miss_output"
if [[ "$FAIL" -eq "$_fail_before_nms" ]]; then
    echo "test_read_config_nested_missing_subkey ... PASS"
fi

# ── test_example_config_contains_jira_section ────────────────────────────────
_fail_before_ecj=$FAIL
EXAMPLE_CONFIG="$DSO_PLUGIN_DIR/docs/workflow-config.example.conf"
if grep -q "^jira\." "$EXAMPLE_CONFIG" 2>/dev/null; then
    example_has_jira="has_jira"
else
    example_has_jira="missing_jira"
fi
assert_eq "test_example_config_contains_jira_section" "has_jira" "$example_has_jira"
if [[ "$FAIL" -eq "$_fail_before_ecj" ]]; then
    echo "test_example_config_contains_jira_section ... PASS"
fi

# ── test_example_config_jira_project_readable ────────────────────────────────
_fail_before_ejr=$FAIL
example_jira_exit=0
example_jira_output=""
example_jira_output=$(bash "$SCRIPT" "$EXAMPLE_CONFIG" "jira.project" 2>&1) || example_jira_exit=$?
assert_eq "test_example_config_jira_project_readable: exit 0" "0" "$example_jira_exit"
assert_ne "test_example_config_jira_project_readable: non-empty output" "" "$example_jira_output"
if [[ "$FAIL" -eq "$_fail_before_ejr" ]]; then
    echo "test_example_config_jira_project_readable ... PASS"
fi

# ── List mode tests (.conf format) ────────────────────────────────────────────

# Write a .conf fixture for list mode tests
BATCH_FIXTURE_DIR="$(mktemp -d)"
cat > "$BATCH_FIXTURE_DIR/workflow-config.conf" <<'CONF'
tickets.directory=.tickets
merge.visual_baseline_path=snapshots
merge.ci_workflow_name=CI
commands.format_check=make format-check
commands.lint=make lint
commands.test=make test-unit-only
CONF

# ── test_read_config_list_absent_key_exits_nonzero ───────────────────────────
# Absent key with --list should exit 1.
_fail_before_lake=$FAIL
list_absent_exit=0
list_absent_output=""
list_absent_output=$(bash "$SCRIPT" --list nonexistent_key "$BATCH_FIXTURE_DIR/workflow-config.conf" 2>&1) || list_absent_exit=$?
if [[ "$list_absent_exit" -ne 0 ]]; then
    actual_absent_exit="nonzero"
else
    actual_absent_exit="zero"
fi
assert_eq "test_read_config_list_absent_key_exits_nonzero: exits nonzero for missing key" "nonzero" "$actual_absent_exit"
if [[ "$FAIL" -eq "$_fail_before_lake" ]]; then
    echo "test_read_config_list_absent_key_exits_nonzero ... PASS"
fi

# ── test_read_config_list_scalar_degrades ─────────────────────────────────────
# Given a scalar key, --list outputs the scalar on one line, exits 0.
_fail_before_lsd=$FAIL
list_scalar_exit=0
list_scalar_output=""
list_scalar_output=$(bash "$SCRIPT" --list commands.lint "$BATCH_FIXTURE_DIR/workflow-config.conf" 2>&1) || list_scalar_exit=$?
assert_eq "test_read_config_list_scalar_degrades: exit 0" "0" "$list_scalar_exit"
assert_eq "test_read_config_list_scalar_degrades: scalar on one line" "make lint" "$list_scalar_output"
if [[ "$FAIL" -eq "$_fail_before_lsd" ]]; then
    echo "test_read_config_list_scalar_degrades ... PASS"
fi

# ── Batch mode tests ──────────────────────────────────────────────────────────

# ── test_batch_mode_returns_all_keys ─────────────────────────────────────────
# --batch should output KEY=value lines (uppercase, dots to underscores) for all keys.
_fail_before_bm=$FAIL
batch_exit=0
batch_output=""
batch_output=$(bash "$SCRIPT" --batch "$BATCH_FIXTURE_DIR/workflow-config.conf" 2>&1) || batch_exit=$?
assert_eq "test_batch_mode_returns_all_keys: exit 0" "0" "$batch_exit"
# Must contain KEY=value lines (uppercase, dots to underscores)
if echo "$batch_output" | grep -qE '^[A-Z_]+=.'; then
    actual_format="has_uppercase_kv"
else
    actual_format="no_uppercase_kv"
fi
assert_eq "test_batch_mode_returns_all_keys: KEY=value lines (uppercase, dots-to-underscores)" "has_uppercase_kv" "$actual_format"
# All 6 keys should appear
if echo "$batch_output" | grep -q '^TICKETS_DIRECTORY='; then
    actual_td="found"
else
    actual_td="missing"
fi
assert_eq "test_batch_mode_returns_all_keys: TICKETS_DIRECTORY key present" "found" "$actual_td"
if echo "$batch_output" | grep -q '^COMMANDS_LINT='; then
    actual_cl="found"
else
    actual_cl="missing"
fi
assert_eq "test_batch_mode_returns_all_keys: COMMANDS_LINT key present" "found" "$actual_cl"
if [[ "$FAIL" -eq "$_fail_before_bm" ]]; then
    echo "test_batch_mode_returns_all_keys ... PASS"
fi

# ── test_batch_mode_single_key_unchanged ─────────────────────────────────────
# Single-key mode must still work after --batch is added.
_fail_before_sk=$FAIL
sk_exit=0
sk_output=""
sk_output=$(bash "$SCRIPT" commands.lint "$BATCH_FIXTURE_DIR/workflow-config.conf" 2>&1) || sk_exit=$?
assert_eq "test_batch_mode_single_key_unchanged: exit 0" "0" "$sk_exit"
assert_eq "test_batch_mode_single_key_unchanged: correct value" "make lint" "$sk_output"
if [[ "$FAIL" -eq "$_fail_before_sk" ]]; then
    echo "test_batch_mode_single_key_unchanged ... PASS"
fi

# ── test_batch_mode_eval_safe ─────────────────────────────────────────────────
# eval of --batch output must set vars correctly in subshell.
_fail_before_be=$FAIL
eval_result=$(bash -c "
  eval \"\$(bash '$SCRIPT' --batch '$BATCH_FIXTURE_DIR/workflow-config.conf' 2>/dev/null)\"
  echo \"\$COMMANDS_LINT\"
" 2>&1) || true
assert_eq "test_batch_mode_eval_safe: eval sets COMMANDS_LINT" "make lint" "$eval_result"
if [[ "$FAIL" -eq "$_fail_before_be" ]]; then
    echo "test_batch_mode_eval_safe ... PASS"
fi

rm -rf "$BATCH_FIXTURE_DIR"

# ── YAML functional tests ─────────────────────────────────────────────────────
# These tests invoke read-config.sh against actual YAML fixture files to verify
# key lookup, nested keys, boolean handling, quote stripping, batch mode, list
# mode, and the _is_yaml heuristic.

YAML_FIXTURE="$TMPDIR_FIXTURE/test-config.yaml"
cat > "$YAML_FIXTURE" <<'YAML'
# Test YAML config
database:
  host: localhost
  port: 5432
  enabled: true
  debug: false

app:
  name: "my-app"
  version: '1.2.3'
  description: plain value

top_level_key: top_value
YAML

# ── test_yaml_simple_key_lookup ──────────────────────────────────────────────
_fail_before_ysk=$FAIL
yaml_sk_exit=0
yaml_sk_output=""
yaml_sk_output=$(bash "$SCRIPT" "$YAML_FIXTURE" "top_level_key" 2>&1) || yaml_sk_exit=$?
assert_eq "test_yaml_simple_key_lookup: exit 0" "0" "$yaml_sk_exit"
assert_eq "test_yaml_simple_key_lookup: correct value" "top_value" "$yaml_sk_output"
if [[ "$FAIL" -eq "$_fail_before_ysk" ]]; then
    echo "test_yaml_simple_key_lookup ... PASS"
fi

# ── test_yaml_nested_key_lookup ──────────────────────────────────────────────
_fail_before_ynk=$FAIL
yaml_nk_exit=0
yaml_nk_output=""
yaml_nk_output=$(bash "$SCRIPT" "$YAML_FIXTURE" "database.host" 2>&1) || yaml_nk_exit=$?
assert_eq "test_yaml_nested_key_lookup: exit 0" "0" "$yaml_nk_exit"
assert_eq "test_yaml_nested_key_lookup: correct value" "localhost" "$yaml_nk_output"
if [[ "$FAIL" -eq "$_fail_before_ynk" ]]; then
    echo "test_yaml_nested_key_lookup ... PASS"
fi

# ── test_yaml_nested_numeric_value ───────────────────────────────────────────
_fail_before_ynv=$FAIL
yaml_nv_exit=0
yaml_nv_output=""
yaml_nv_output=$(bash "$SCRIPT" "$YAML_FIXTURE" "database.port" 2>&1) || yaml_nv_exit=$?
assert_eq "test_yaml_nested_numeric_value: exit 0" "0" "$yaml_nv_exit"
assert_eq "test_yaml_nested_numeric_value: correct value" "5432" "$yaml_nv_output"
if [[ "$FAIL" -eq "$_fail_before_ynv" ]]; then
    echo "test_yaml_nested_numeric_value ... PASS"
fi

# ── test_yaml_boolean_true ───────────────────────────────────────────────────
_fail_before_ybt=$FAIL
yaml_bt_exit=0
yaml_bt_output=""
yaml_bt_output=$(bash "$SCRIPT" "$YAML_FIXTURE" "database.enabled" 2>&1) || yaml_bt_exit=$?
assert_eq "test_yaml_boolean_true: exit 0" "0" "$yaml_bt_exit"
assert_eq "test_yaml_boolean_true: returns True" "True" "$yaml_bt_output"
if [[ "$FAIL" -eq "$_fail_before_ybt" ]]; then
    echo "test_yaml_boolean_true ... PASS"
fi

# ── test_yaml_boolean_false ──────────────────────────────────────────────────
_fail_before_ybf=$FAIL
yaml_bf_exit=0
yaml_bf_output=""
yaml_bf_output=$(bash "$SCRIPT" "$YAML_FIXTURE" "database.debug" 2>&1) || yaml_bf_exit=$?
assert_eq "test_yaml_boolean_false: exit 0" "0" "$yaml_bf_exit"
assert_eq "test_yaml_boolean_false: returns False" "False" "$yaml_bf_output"
if [[ "$FAIL" -eq "$_fail_before_ybf" ]]; then
    echo "test_yaml_boolean_false ... PASS"
fi

# ── test_yaml_double_quote_stripping ─────────────────────────────────────────
_fail_before_ydq=$FAIL
yaml_dq_exit=0
yaml_dq_output=""
yaml_dq_output=$(bash "$SCRIPT" "$YAML_FIXTURE" "app.name" 2>&1) || yaml_dq_exit=$?
assert_eq "test_yaml_double_quote_stripping: exit 0" "0" "$yaml_dq_exit"
assert_eq "test_yaml_double_quote_stripping: quotes stripped" "my-app" "$yaml_dq_output"
if [[ "$FAIL" -eq "$_fail_before_ydq" ]]; then
    echo "test_yaml_double_quote_stripping ... PASS"
fi

# ── test_yaml_single_quote_stripping ─────────────────────────────────────────
_fail_before_ysq=$FAIL
yaml_sq_exit=0
yaml_sq_output=""
yaml_sq_output=$(bash "$SCRIPT" "$YAML_FIXTURE" "app.version" 2>&1) || yaml_sq_exit=$?
assert_eq "test_yaml_single_quote_stripping: exit 0" "0" "$yaml_sq_exit"
assert_eq "test_yaml_single_quote_stripping: quotes stripped" "1.2.3" "$yaml_sq_output"
if [[ "$FAIL" -eq "$_fail_before_ysq" ]]; then
    echo "test_yaml_single_quote_stripping ... PASS"
fi

# ── test_yaml_missing_key ────────────────────────────────────────────────────
_fail_before_ymk=$FAIL
yaml_mk_exit=0
yaml_mk_output=""
yaml_mk_output=$(bash "$SCRIPT" "$YAML_FIXTURE" "database.nonexistent" 2>&1) || yaml_mk_exit=$?
assert_eq "test_yaml_missing_key: exit 0" "0" "$yaml_mk_exit"
assert_eq "test_yaml_missing_key: output is empty" "" "$yaml_mk_output"
if [[ "$FAIL" -eq "$_fail_before_ymk" ]]; then
    echo "test_yaml_missing_key ... PASS"
fi

# ── test_yaml_list_mode ──────────────────────────────────────────────────────
_fail_before_ylm=$FAIL
yaml_lm_exit=0
yaml_lm_output=""
yaml_lm_output=$(bash "$SCRIPT" --list "$YAML_FIXTURE" "database.host" 2>&1) || yaml_lm_exit=$?
assert_eq "test_yaml_list_mode: exit 0" "0" "$yaml_lm_exit"
assert_eq "test_yaml_list_mode: correct value" "localhost" "$yaml_lm_output"
if [[ "$FAIL" -eq "$_fail_before_ylm" ]]; then
    echo "test_yaml_list_mode ... PASS"
fi

# ── test_yaml_list_mode_absent_key ───────────────────────────────────────────
_fail_before_ylma=$FAIL
yaml_lma_exit=0
yaml_lma_output=""
yaml_lma_output=$(bash "$SCRIPT" --list "$YAML_FIXTURE" "nonexistent.key" 2>&1) || yaml_lma_exit=$?
if [[ "$yaml_lma_exit" -ne 0 ]]; then
    actual_lma_exit="nonzero"
else
    actual_lma_exit="zero"
fi
assert_eq "test_yaml_list_mode_absent_key: exits nonzero" "nonzero" "$actual_lma_exit"
if [[ "$FAIL" -eq "$_fail_before_ylma" ]]; then
    echo "test_yaml_list_mode_absent_key ... PASS"
fi

# ── test_yaml_batch_mode ─────────────────────────────────────────────────────
_fail_before_ybm=$FAIL
yaml_bm_exit=0
yaml_bm_output=""
yaml_bm_output=$(bash "$SCRIPT" --batch "$YAML_FIXTURE" 2>&1) || yaml_bm_exit=$?
assert_eq "test_yaml_batch_mode: exit 0" "0" "$yaml_bm_exit"
# Must contain uppercase KEY=value lines
if echo "$yaml_bm_output" | grep -qE '^[A-Z_]+='; then
    actual_ybm_format="has_uppercase_kv"
else
    actual_ybm_format="no_uppercase_kv"
fi
assert_eq "test_yaml_batch_mode: KEY=value format" "has_uppercase_kv" "$actual_ybm_format"
# Check specific keys
if echo "$yaml_bm_output" | grep -q "^DATABASE_HOST="; then
    actual_ybm_host="found"
else
    actual_ybm_host="missing"
fi
assert_eq "test_yaml_batch_mode: DATABASE_HOST present" "found" "$actual_ybm_host"
if echo "$yaml_bm_output" | grep -q "^APP_NAME="; then
    actual_ybm_name="found"
else
    actual_ybm_name="missing"
fi
assert_eq "test_yaml_batch_mode: APP_NAME present" "found" "$actual_ybm_name"
if [[ "$FAIL" -eq "$_fail_before_ybm" ]]; then
    echo "test_yaml_batch_mode ... PASS"
fi

# ── test_yaml_heuristic_detection ────────────────────────────────────────────
# A file without .yaml/.yml extension but with YAML-style content (colon, no equals)
# should be detected as YAML by the _is_yaml heuristic.
YAML_HEURISTIC_FIXTURE="$TMPDIR_FIXTURE/config-no-ext"
cat > "$YAML_HEURISTIC_FIXTURE" <<'YAMLH'
server:
  host: 0.0.0.0
  port: 8080
YAMLH

_fail_before_yhd=$FAIL
yaml_hd_exit=0
yaml_hd_output=""
yaml_hd_output=$(bash "$SCRIPT" "$YAML_HEURISTIC_FIXTURE" "server.host" 2>&1) || yaml_hd_exit=$?
assert_eq "test_yaml_heuristic_detection: exit 0" "0" "$yaml_hd_exit"
assert_eq "test_yaml_heuristic_detection: correct value" "0.0.0.0" "$yaml_hd_output"
if [[ "$FAIL" -eq "$_fail_before_yhd" ]]; then
    echo "test_yaml_heuristic_detection ... PASS"
fi

# ── test_yaml_yml_extension ──────────────────────────────────────────────────
# .yml extension should also be recognized as YAML.
YML_FIXTURE="$TMPDIR_FIXTURE/test-config.yml"
cat > "$YML_FIXTURE" <<'YML'
feature:
  enabled: yes
YML

_fail_before_yye=$FAIL
yaml_ye_exit=0
yaml_ye_output=""
yaml_ye_output=$(bash "$SCRIPT" "$YML_FIXTURE" "feature.enabled" 2>&1) || yaml_ye_exit=$?
assert_eq "test_yaml_yml_extension: exit 0" "0" "$yaml_ye_exit"
assert_eq "test_yaml_yml_extension: yes is boolean True" "True" "$yaml_ye_output"
if [[ "$FAIL" -eq "$_fail_before_yye" ]]; then
    echo "test_yaml_yml_extension ... PASS"
fi

print_summary
