#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-read-config.sh
# TDD red-phase tests for lockpick-workflow/scripts/read-config.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-read-config.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until read-config.sh is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/read-config.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Resolve a Python with pyyaml (same logic as read-config.sh)
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

echo "=== test-read-config.sh ==="

# Create a temp dir for fixture files used in tests
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# Write a valid fixture config
FIXTURE_CONFIG="$TMPDIR_FIXTURE/workflow-config.yaml"
cat > "$FIXTURE_CONFIG" <<'YAML'
test_command: make test-unit-only
lint_command: make lint
format_command: make format
issue_tracker: tk
YAML

# Write a malformed YAML fixture
MALFORMED_CONFIG="$TMPDIR_FIXTURE/malformed.yaml"
cat > "$MALFORMED_CONFIG" <<'YAML'
key: [unclosed bracket
  bad: : indentation ::
YAML

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

# ── test_read_config_missing_file_exits_nonzero ───────────────────────────────
# Calling read-config.sh when no workflow-config.yaml exists returns empty
# output and exits 0 (graceful degradation — missing config is not an error).
MISSING_DIR="$TMPDIR_FIXTURE/empty_dir"
mkdir -p "$MISSING_DIR"
missing_exit=0
missing_output=""
missing_output=$(bash "$SCRIPT" "$MISSING_DIR/workflow-config.yaml" "test_command" 2>&1) || missing_exit=$?
if [[ "$missing_exit" -eq 0 ]]; then
    actual_graceful="graceful"
else
    actual_graceful="errored"
fi
assert_eq "test_read_config_missing_file_exits_nonzero: exits 0 when file missing" "graceful" "$actual_graceful"

if [[ -z "$missing_output" ]]; then
    actual_output_empty="empty"
else
    actual_output_empty="non_empty"
fi
assert_eq "test_read_config_missing_file_exits_nonzero: output is empty when file missing" "empty" "$actual_output_empty"

# ── test_read_config_returns_value_for_known_key ──────────────────────────────
# Given a valid fixture config, querying 'test_command' returns 'make test-unit-only'.
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

# ── test_read_config_malformed_yaml_exits_nonzero ────────────────────────────
# A malformed YAML file must cause the script to exit 1 with an error message.
malformed_exit=0
malformed_output=""
malformed_output=$(bash "$SCRIPT" "$MALFORMED_CONFIG" "key" 2>&1) || malformed_exit=$?
if [[ "$malformed_exit" -ne 0 ]]; then
    actual_malformed_exit="nonzero"
else
    actual_malformed_exit="zero"
fi
assert_eq "test_read_config_malformed_yaml_exits_nonzero: exits nonzero" "nonzero" "$actual_malformed_exit"

if [[ -n "$malformed_output" ]]; then
    actual_malformed_msg="has_message"
else
    actual_malformed_msg="no_message"
fi
assert_eq "test_read_config_malformed_yaml_exits_nonzero: prints error message" "has_message" "$actual_malformed_msg"

# ── test_schema_allows_unknown_top_level_section ─────────────────────────────
# The schema must NOT have additionalProperties: false at root, allowing
# new top-level sections to be added without schema errors.
SCHEMA_FILE="$REPO_ROOT/lockpick-workflow/docs/workflow-config-schema.json"
schema_additional=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
v = s.get('additionalProperties', 'absent')
# Should NOT be False (Python bool) — either True or absent
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
jira_has_project=$("$PYTHON" -c "
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
it_has_keys=$("$PYTHON" -c "
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
jira_type=$("$PYTHON" -c "
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

# Write a fixture config with nested sections
NESTED_FIXTURE="$TMPDIR_FIXTURE/nested-config.yaml"
cat > "$NESTED_FIXTURE" <<'YAML'
version: "1.0.0"
jira:
  project: DTL
issue_tracker:
  search_cmd: "grep -rl"
  create_cmd: "tk create"
tickets:
  prefix: myproject
YAML

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
EXAMPLE_CONFIG="$REPO_ROOT/lockpick-workflow/docs/workflow-config.example.conf"
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

# ── List mode fixtures ────────────────────────────────────────────────────────

LIST_FIXTURE="$TMPDIR_FIXTURE/list-config.yaml"
cat > "$LIST_FIXTURE" <<'YAML'
items:
  - alpha
  - bravo
  - charlie
scalar_key: just_a_string
empty_list: []
persistence:
  source_patterns:
    - "*.pdf"
    - "*.docx"
YAML

# ── test_read_config_list_absent_key_exits_nonzero ───────────────────────────
# TDD RED: absent key with --list should exit 1 (currently exits 0).
# This test is expected to FAIL until the empty-list vs absent-key fix lands.
_fail_before_lake=$FAIL
list_absent_exit=0
list_absent_output=""
list_absent_output=$(bash "$SCRIPT" --list nonexistent_key "$LIST_FIXTURE" 2>&1) || list_absent_exit=$?
if [[ "$list_absent_exit" -ne 0 ]]; then
    actual_absent_exit="nonzero"
else
    actual_absent_exit="zero"
fi
assert_eq "test_read_config_list_absent_key_exits_nonzero: exits nonzero for missing key" "nonzero" "$actual_absent_exit"
if [[ "$FAIL" -eq "$_fail_before_lake" ]]; then
    echo "test_read_config_list_absent_key_exits_nonzero ... PASS"
fi

# ── test_read_config_list_returns_items ───────────────────────────────────────
# Given items: [alpha, bravo, charlie], --list items outputs one per line, exits 0.
_fail_before_lri=$FAIL
list_items_exit=0
list_items_output=""
list_items_output=$(bash "$SCRIPT" --list items "$LIST_FIXTURE" 2>&1) || list_items_exit=$?
assert_eq "test_read_config_list_returns_items: exit 0" "0" "$list_items_exit"
expected_items="alpha
bravo
charlie"
assert_eq "test_read_config_list_returns_items: correct output" "$expected_items" "$list_items_output"
if [[ "$FAIL" -eq "$_fail_before_lri" ]]; then
    echo "test_read_config_list_returns_items ... PASS"
fi

# ── test_read_config_list_scalar_degrades ─────────────────────────────────────
# Given a scalar key, --list outputs the scalar on one line, exits 0.
_fail_before_lsd=$FAIL
list_scalar_exit=0
list_scalar_output=""
list_scalar_output=$(bash "$SCRIPT" --list scalar_key "$LIST_FIXTURE" 2>&1) || list_scalar_exit=$?
assert_eq "test_read_config_list_scalar_degrades: exit 0" "0" "$list_scalar_exit"
assert_eq "test_read_config_list_scalar_degrades: scalar on one line" "just_a_string" "$list_scalar_output"
if [[ "$FAIL" -eq "$_fail_before_lsd" ]]; then
    echo "test_read_config_list_scalar_degrades ... PASS"
fi

# ── test_read_config_list_empty_list ──────────────────────────────────────────
# Given items: [], --list items outputs nothing, exits 0.
_fail_before_lel=$FAIL
list_empty_exit=0
list_empty_output=""
list_empty_output=$(bash "$SCRIPT" --list empty_list "$LIST_FIXTURE" 2>&1) || list_empty_exit=$?
assert_eq "test_read_config_list_empty_list: exit 0" "0" "$list_empty_exit"
assert_eq "test_read_config_list_empty_list: output is empty" "" "$list_empty_output"
if [[ "$FAIL" -eq "$_fail_before_lel" ]]; then
    echo "test_read_config_list_empty_list ... PASS"
fi

# ── test_read_config_list_nested ──────────────────────────────────────────────
# Given persistence.source_patterns: [*.pdf, *.docx], --list outputs them, exits 0.
_fail_before_ln=$FAIL
list_nested_exit=0
list_nested_output=""
list_nested_output=$(bash "$SCRIPT" --list persistence.source_patterns "$LIST_FIXTURE" 2>&1) || list_nested_exit=$?
assert_eq "test_read_config_list_nested: exit 0" "0" "$list_nested_exit"
expected_nested="*.pdf
*.docx"
assert_eq "test_read_config_list_nested: correct output" "$expected_nested" "$list_nested_output"
if [[ "$FAIL" -eq "$_fail_before_ln" ]]; then
    echo "test_read_config_list_nested ... PASS"
fi

# ── test_read_config_list_without_flag_errors ─────────────────────────────────
# Reading a list-valued key without --list should exit 1 with an error.
_fail_before_lwf=$FAIL
list_noflag_exit=0
list_noflag_output=""
list_noflag_output=$(bash "$SCRIPT" "$LIST_FIXTURE" items 2>&1) || list_noflag_exit=$?
if [[ "$list_noflag_exit" -ne 0 ]]; then
    actual_noflag_exit="nonzero"
else
    actual_noflag_exit="zero"
fi
assert_eq "test_read_config_list_without_flag_errors: exits nonzero" "nonzero" "$actual_noflag_exit"
assert_contains "test_read_config_list_without_flag_errors: error message" "non-scalar" "$list_noflag_output"
if [[ "$FAIL" -eq "$_fail_before_lwf" ]]; then
    echo "test_read_config_list_without_flag_errors ... PASS"
fi

# ── YAML-isolation smoke tests ────────────────────────────────────────────────
# These tests run against a YAML-only temp directory (no .conf sibling) to
# verify the Python/pyyaml parser handles lists, nesting, and malformed YAML
# correctly when the .conf fallback is unavailable. This is the exact scenario
# that caused 22 CI failures when config masking hid YAML parser bugs locally.

YAML_ONLY_DIR="$(mktemp -d)"

# Write a YAML config with lists and nested sections — NO .conf sibling
cat > "$YAML_ONLY_DIR/workflow-config.yaml" <<'YAML'
commands:
  test: make test-unit-only
  lint: make lint-ruff
tickets:
  sync:
    jira_project_key: LLD2L
ci:
  paths_ignore:
    - "docs/**"
    - "*.md"
    - ".tickets/**"
YAML

# ── test_yaml_isolation_scalar ───────────────────────────────────────────────
_fail_before_yis=$FAIL
yis_exit=0
yis_output=""
yis_output=$(bash "$SCRIPT" "$YAML_ONLY_DIR/workflow-config.yaml" "commands.test" 2>&1) || yis_exit=$?
assert_eq "test_yaml_isolation_scalar: exit 0" "0" "$yis_exit"
assert_eq "test_yaml_isolation_scalar: correct value" "make test-unit-only" "$yis_output"
if [[ "$FAIL" -eq "$_fail_before_yis" ]]; then
    echo "test_yaml_isolation_scalar ... PASS"
fi

# ── test_yaml_isolation_3level_nesting ───────────────────────────────────────
_fail_before_yi3=$FAIL
yi3_exit=0
yi3_output=""
yi3_output=$(bash "$SCRIPT" "$YAML_ONLY_DIR/workflow-config.yaml" "tickets.sync.jira_project_key" 2>&1) || yi3_exit=$?
assert_eq "test_yaml_isolation_3level_nesting: exit 0" "0" "$yi3_exit"
assert_eq "test_yaml_isolation_3level_nesting: correct value" "LLD2L" "$yi3_output"
if [[ "$FAIL" -eq "$_fail_before_yi3" ]]; then
    echo "test_yaml_isolation_3level_nesting ... PASS"
fi

# ── test_yaml_isolation_list ─────────────────────────────────────────────────
_fail_before_yil=$FAIL
yil_exit=0
yil_output=""
yil_output=$(bash "$SCRIPT" --list ci.paths_ignore "$YAML_ONLY_DIR/workflow-config.yaml" 2>&1) || yil_exit=$?
assert_eq "test_yaml_isolation_list: exit 0" "0" "$yil_exit"
expected_yil="docs/**
*.md
.tickets/**"
assert_eq "test_yaml_isolation_list: correct items" "$expected_yil" "$yil_output"
if [[ "$FAIL" -eq "$_fail_before_yil" ]]; then
    echo "test_yaml_isolation_list ... PASS"
fi

# ── test_yaml_isolation_malformed ────────────────────────────────────────────
YAML_MALFORMED_DIR="$(mktemp -d)"
cat > "$YAML_MALFORMED_DIR/workflow-config.yaml" <<'YAML'
key: [unclosed bracket
  bad: : indentation ::
YAML

_fail_before_yim=$FAIL
yim_exit=0
yim_output=""
yim_output=$(bash "$SCRIPT" "$YAML_MALFORMED_DIR/workflow-config.yaml" "key" 2>&1) || yim_exit=$?
if [[ "$yim_exit" -ne 0 ]]; then
    actual_yim_exit="nonzero"
else
    actual_yim_exit="zero"
fi
assert_eq "test_yaml_isolation_malformed: exits nonzero" "nonzero" "$actual_yim_exit"
assert_contains "test_yaml_isolation_malformed: error message" "malformed" "$yim_output"
if [[ "$FAIL" -eq "$_fail_before_yim" ]]; then
    echo "test_yaml_isolation_malformed ... PASS"
fi

rm -rf "$YAML_ONLY_DIR" "$YAML_MALFORMED_DIR"

print_summary
