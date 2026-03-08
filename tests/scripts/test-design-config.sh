#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-design-config.sh
# Tests for the design: section in workflow-config.yaml
#
# Validates:
#   - Schema defines design: section with correct keys
#   - read-config.sh can read all design config values
#   - Example config contains design: section
#   - Project config contains design: section
#   - Default values are correct in schema
#
# Usage: bash lockpick-workflow/tests/scripts/test-design-config.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
READ_CONFIG="$REPO_ROOT/lockpick-workflow/scripts/read-config.sh"
SCHEMA_FILE="$REPO_ROOT/lockpick-workflow/docs/workflow-config-schema.json"
EXAMPLE_CONFIG="$REPO_ROOT/lockpick-workflow/docs/workflow-config.example.yaml"
PROJECT_CONFIG="$REPO_ROOT/workflow-config.yaml"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

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

echo "=== test-design-config.sh ==="

# Create temp dir for fixtures
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# ── Schema tests ────────────────────────────────────────────────────────────

# test_schema_has_design_section: schema defines a design property
_fail_before=$FAIL
design_in_schema=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
props = s.get('properties', {})
if 'design' in props:
    print('has_design')
else:
    print('missing_design')
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_has_design_section" "has_design" "$design_in_schema"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_has_design_section ... PASS"
fi

# test_schema_design_type_is_object: design must be type: object
_fail_before=$FAIL
design_type=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
design = s.get('properties', {}).get('design', {})
print(design.get('type', 'missing'))
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_design_type_is_object" "object" "$design_type"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_design_type_is_object ... PASS"
fi

# test_schema_design_has_system_name: design must have system_name property
_fail_before=$FAIL
has_system_name=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
design_props = s.get('properties', {}).get('design', {}).get('properties', {})
if 'system_name' in design_props:
    print('has_system_name')
else:
    print('missing_system_name')
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_design_has_system_name" "has_system_name" "$has_system_name"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_design_has_system_name ... PASS"
fi

# test_schema_design_has_component_library: design must have component_library property
_fail_before=$FAIL
has_component_library=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
design_props = s.get('properties', {}).get('design', {}).get('properties', {})
if 'component_library' in design_props:
    print('has_component_library')
else:
    print('missing_component_library')
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_design_has_component_library" "has_component_library" "$has_component_library"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_design_has_component_library ... PASS"
fi

# test_schema_design_has_template_engine: design must have template_engine property
_fail_before=$FAIL
has_template_engine=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
design_props = s.get('properties', {}).get('design', {}).get('properties', {})
if 'template_engine' in design_props:
    print('has_template_engine')
else:
    print('missing_template_engine')
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_design_has_template_engine" "has_template_engine" "$has_template_engine"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_design_has_template_engine ... PASS"
fi

# test_schema_design_has_design_notes_path: design must have design_notes_path property
_fail_before=$FAIL
has_design_notes_path=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
design_props = s.get('properties', {}).get('design', {}).get('properties', {})
if 'design_notes_path' in design_props:
    print('has_design_notes_path')
else:
    print('missing_design_notes_path')
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_design_has_design_notes_path" "has_design_notes_path" "$has_design_notes_path"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_design_has_design_notes_path ... PASS"
fi

# test_schema_design_notes_path_default: design_notes_path should default to "DESIGN_NOTES.md"
_fail_before=$FAIL
notes_default=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
design_props = s.get('properties', {}).get('design', {}).get('properties', {})
notes_path = design_props.get('design_notes_path', {})
print(notes_path.get('default', 'no_default'))
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_design_notes_path_default" "DESIGN_NOTES.md" "$notes_default"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_design_notes_path_default ... PASS"
fi

# test_schema_design_no_additional_properties: design section should not allow extra keys
_fail_before=$FAIL
design_additional=$("$PYTHON" -c "
import json, sys
s = json.load(open(sys.argv[1]))
design = s.get('properties', {}).get('design', {})
v = design.get('additionalProperties', 'absent')
if v is False:
    print('blocked')
else:
    print('allowed')
" "$SCHEMA_FILE" 2>&1)
assert_eq "test_schema_design_no_additional_properties" "blocked" "$design_additional"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_schema_design_no_additional_properties ... PASS"
fi

# ── read-config.sh tests ────────────────────────────────────────────────────

# Write a fixture config with full design section
DESIGN_FIXTURE="$TMPDIR_FIXTURE/design-config.yaml"
cat > "$DESIGN_FIXTURE" <<'YAML'
version: "1.0.0"
design:
  system_name: "USWDS 3.x"
  component_library: uswds
  template_engine: jinja2
  design_notes_path: DESIGN_NOTES.md
YAML

# test_read_config_design_system_name: read design.system_name
_fail_before=$FAIL
sn_exit=0
sn_output=""
sn_output=$(bash "$READ_CONFIG" "$DESIGN_FIXTURE" "design.system_name" 2>&1) || sn_exit=$?
assert_eq "test_read_config_design_system_name: exit 0" "0" "$sn_exit"
assert_eq "test_read_config_design_system_name: correct value" "USWDS 3.x" "$sn_output"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_read_config_design_system_name ... PASS"
fi

# test_read_config_design_component_library: read design.component_library
_fail_before=$FAIL
cl_exit=0
cl_output=""
cl_output=$(bash "$READ_CONFIG" "$DESIGN_FIXTURE" "design.component_library" 2>&1) || cl_exit=$?
assert_eq "test_read_config_design_component_library: exit 0" "0" "$cl_exit"
assert_eq "test_read_config_design_component_library: correct value" "uswds" "$cl_output"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_read_config_design_component_library ... PASS"
fi

# test_read_config_design_template_engine: read design.template_engine
_fail_before=$FAIL
te_exit=0
te_output=""
te_output=$(bash "$READ_CONFIG" "$DESIGN_FIXTURE" "design.template_engine" 2>&1) || te_exit=$?
assert_eq "test_read_config_design_template_engine: exit 0" "0" "$te_exit"
assert_eq "test_read_config_design_template_engine: correct value" "jinja2" "$te_output"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_read_config_design_template_engine ... PASS"
fi

# test_read_config_design_notes_path: read design.design_notes_path
_fail_before=$FAIL
dnp_exit=0
dnp_output=""
dnp_output=$(bash "$READ_CONFIG" "$DESIGN_FIXTURE" "design.design_notes_path" 2>&1) || dnp_exit=$?
assert_eq "test_read_config_design_notes_path: exit 0" "0" "$dnp_exit"
assert_eq "test_read_config_design_notes_path: correct value" "DESIGN_NOTES.md" "$dnp_output"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_read_config_design_notes_path ... PASS"
fi

# ── Example config tests ────────────────────────────────────────────────────

# test_example_config_has_design_section
_fail_before=$FAIL
if grep -q "^design:" "$EXAMPLE_CONFIG" 2>/dev/null; then
    example_has_design="has_design"
else
    example_has_design="missing_design"
fi
assert_eq "test_example_config_has_design_section" "has_design" "$example_has_design"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_example_config_has_design_section ... PASS"
fi

# test_example_config_design_system_name_readable
_fail_before=$FAIL
ex_sn_exit=0
ex_sn_output=""
ex_sn_output=$(bash "$READ_CONFIG" "$EXAMPLE_CONFIG" "design.system_name" 2>&1) || ex_sn_exit=$?
assert_eq "test_example_config_design_system_name_readable: exit 0" "0" "$ex_sn_exit"
assert_ne "test_example_config_design_system_name_readable: non-empty" "" "$ex_sn_output"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_example_config_design_system_name_readable ... PASS"
fi

# test_example_config_design_template_engine_readable
_fail_before=$FAIL
ex_te_exit=0
ex_te_output=""
ex_te_output=$(bash "$READ_CONFIG" "$EXAMPLE_CONFIG" "design.template_engine" 2>&1) || ex_te_exit=$?
assert_eq "test_example_config_design_template_engine_readable: exit 0" "0" "$ex_te_exit"
assert_ne "test_example_config_design_template_engine_readable: non-empty" "" "$ex_te_output"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_example_config_design_template_engine_readable ... PASS"
fi

# ── Project config tests ────────────────────────────────────────────────────

# test_project_config_has_design_section
_fail_before=$FAIL
if grep -q "^design:" "$PROJECT_CONFIG" 2>/dev/null; then
    project_has_design="has_design"
else
    project_has_design="missing_design"
fi
assert_eq "test_project_config_has_design_section" "has_design" "$project_has_design"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_project_config_has_design_section ... PASS"
fi

# test_project_config_design_system_name_readable
_fail_before=$FAIL
proj_sn_exit=0
proj_sn_output=""
proj_sn_output=$(bash "$READ_CONFIG" "$PROJECT_CONFIG" "design.system_name" 2>&1) || proj_sn_exit=$?
assert_eq "test_project_config_design_system_name_readable: exit 0" "0" "$proj_sn_exit"
assert_ne "test_project_config_design_system_name_readable: non-empty" "" "$proj_sn_output"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_project_config_design_system_name_readable ... PASS"
fi

print_summary
