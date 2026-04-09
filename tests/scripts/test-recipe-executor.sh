#!/usr/bin/env bash
# tests/scripts/test-recipe-executor.sh
# Behavioral tests for recipe-executor.sh
#
# Tests use fake adapter scripts in temp directories — real Rope is NOT required.
# recipe-executor.sh reads TEST_REGISTRY_PATH and TEST_ADAPTERS_DIR env vars when set
# to override the default registry and adapter locations.
#
# Adapter filename convention:
#   The test registry entry's 'adapter' field must match the filename in TEST_ADAPTERS_DIR.
#   e.g., if registry entry has adapter='fake-adapter.sh', then TEST_ADAPTERS_DIR must
#   contain a script named 'fake-adapter.sh'.
#   Convention: executor reads adapter field from registry → looks for
#   '{TEST_ADAPTERS_DIR}/{adapter_field_value}'
#
# Usage: bash tests/scripts/test-recipe-executor.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/recipe-executor.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-recipe-executor.sh ==="

# ── Cleanup ───────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ── Helper: create a temp test registry with a fake recipe entry ──────────────
# Creates a registry YAML with one recipe entry using the given adapter filename.
# Prints the path to the registry file.
_make_registry() {
    local tmpdir="$1"
    local recipe_name="${2:-test-recipe}"
    local adapter_file="${3:-fake-adapter.sh}"
    local registry_path="$tmpdir/registry.yaml"

    cat > "$registry_path" <<YAML
recipes:
  ${recipe_name}:
    language: python
    engine: fake-engine
    engine_version_min: "0.0.1"
    adapter: ${adapter_file}
    description: "Fake recipe for testing"
    parameters: []
YAML
    echo "$registry_path"
}

# ── Helper: create a fake adapter that succeeds and prints JSON output ────────
# The adapter reads RECIPE_PARAM_* env vars and echoes them in its output.
_make_fake_adapter() {
    local adapters_dir="$1"
    local adapter_name="${2:-fake-adapter.sh}"
    local adapter_path="$adapters_dir/$adapter_name"

    cat > "$adapter_path" <<'ADAPTER'
#!/usr/bin/env bash
# Fake adapter: succeeds, outputs structured JSON, echoes RECIPE_PARAM_* env vars
set -e
params_json=""
while IFS='=' read -r key value; do
    case "$key" in
        RECIPE_PARAM_*)
            param_name="${key#RECIPE_PARAM_}"
            params_json="${params_json}\"${param_name}\":\"${value}\","
            ;;
    esac
done < <(env | grep '^RECIPE_PARAM_' 2>/dev/null || true)

# Output structured JSON
printf '{"files_changed":["src/example.py"],"transforms_applied":1,"errors":[],"exit_code":0,"params_received":{%s}}\n' \
    "${params_json%,}"
ADAPTER
    chmod +x "$adapter_path"
    echo "$adapter_path"
}

# ── Helper: create a fake adapter that simulates missing-engine failure ───────
_make_missing_engine_adapter() {
    local adapters_dir="$1"
    local adapter_name="${2:-fake-adapter.sh}"
    local adapter_path="$adapters_dir/$adapter_name"

    cat > "$adapter_path" <<'ADAPTER'
#!/usr/bin/env bash
# Fake adapter: simulates missing engine — exits with missing-engine signal
echo '{"degraded":true,"engine_name":"fake-engine","error":"engine not found","exit_code":1}' >&2
exit 127
ADAPTER
    chmod +x "$adapter_path"
    echo "$adapter_path"
}

# ── test_engine_resolution_from_registry ─────────────────────────────────────
# Given: a registry with a recipe entry using a fake adapter
# When:  recipe-executor.sh is called with that recipe name
# Then:  execution succeeds (exit 0) and output contains exit_code=0
_snapshot_fail
{
    _tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$_tmpdir")
    _adapters_dir="$_tmpdir/adapters"
    mkdir -p "$_adapters_dir"

    _registry="$(_make_registry "$_tmpdir" "my-recipe" "fake-adapter.sh")"
    _make_fake_adapter "$_adapters_dir" "fake-adapter.sh" >/dev/null

    exit_code=0
    output=$(TEST_REGISTRY_PATH="$_registry" TEST_ADAPTERS_DIR="$_adapters_dir" \
        bash "$SCRIPT" my-recipe 2>&1) || exit_code=$?

    # Assert: exits 0 and output contains exit_code indicator
    assert_eq "test_engine_resolution_from_registry: exits 0" "0" "$exit_code"
    has_exit_code=0
    echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('exit_code')==0" 2>/dev/null && has_exit_code=1 || true
    assert_eq "test_engine_resolution_from_registry: output has exit_code=0" "1" "$has_exit_code"
}
assert_pass_if_clean "test_engine_resolution_from_registry"

# ── test_structured_json_output_format ───────────────────────────────────────
# Given: a registry with a recipe entry using a fake adapter
# When:  recipe-executor.sh executes the recipe
# Then:  output is valid JSON with all required fields: files_changed (array),
#        transforms_applied (integer), errors (array), exit_code (integer)
_snapshot_fail
{
    _tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$_tmpdir")
    _adapters_dir="$_tmpdir/adapters"
    mkdir -p "$_adapters_dir"

    _registry="$(_make_registry "$_tmpdir" "format-recipe" "fake-adapter.sh")"
    _make_fake_adapter "$_adapters_dir" "fake-adapter.sh" >/dev/null

    output=$(TEST_REGISTRY_PATH="$_registry" TEST_ADAPTERS_DIR="$_adapters_dir" \
        bash "$SCRIPT" format-recipe 2>&1) || true

    # Assert: valid JSON with all required fields
    valid_schema=0
    echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
required = ['files_changed', 'transforms_applied', 'errors', 'exit_code']
missing = [k for k in required if k not in d]
assert not missing, f'Missing fields: {missing}'
assert isinstance(d['files_changed'], list), 'files_changed must be array'
assert isinstance(d['transforms_applied'], int), 'transforms_applied must be integer'
assert isinstance(d['errors'], list), 'errors must be array'
assert isinstance(d['exit_code'], int), 'exit_code must be integer'
" 2>/dev/null && valid_schema=1 || true

    assert_eq "test_structured_json_output_format: output has all required fields with correct types" "1" "$valid_schema"
}
assert_pass_if_clean "test_structured_json_output_format"

# ── test_missing_engine_returns_degraded_status ───────────────────────────────
# Given: a registry entry whose adapter signals missing-engine (exits 127)
# When:  recipe-executor.sh executes that recipe
# Then:  executor returns JSON with degraded=true and engine_name populated, exit_code=1
_snapshot_fail
{
    _tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$_tmpdir")
    _adapters_dir="$_tmpdir/adapters"
    mkdir -p "$_adapters_dir"

    _registry="$(_make_registry "$_tmpdir" "degraded-recipe" "fake-adapter.sh")"
    _make_missing_engine_adapter "$_adapters_dir" "fake-adapter.sh" >/dev/null

    exit_code=0
    output=$(TEST_REGISTRY_PATH="$_registry" TEST_ADAPTERS_DIR="$_adapters_dir" \
        bash "$SCRIPT" degraded-recipe 2>&1) || exit_code=$?

    # Assert: exits non-zero and JSON has degraded=true with engine_name
    assert_ne "test_missing_engine_returns_degraded_status: exits non-zero" "0" "$exit_code"
    degraded_correct=0
    echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('degraded') == True, 'degraded must be true'
assert d.get('engine_name'), 'engine_name must be non-empty'
assert d.get('exit_code', 0) == 1, 'exit_code must be 1'
" 2>/dev/null && degraded_correct=1 || true

    assert_eq "test_missing_engine_returns_degraded_status: JSON has degraded=true and engine_name" "1" "$degraded_correct"
}
assert_pass_if_clean "test_missing_engine_returns_degraded_status"

# ── test_unknown_recipe_returns_error ─────────────────────────────────────────
# Given: a registry with no entry for "nonexistent-recipe"
# When:  recipe-executor.sh is called with "nonexistent-recipe"
# Then:  exits non-zero and JSON output has non-empty errors field
_snapshot_fail
{
    _tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$_tmpdir")
    _adapters_dir="$_tmpdir/adapters"
    mkdir -p "$_adapters_dir"

    _registry="$(_make_registry "$_tmpdir" "known-recipe" "fake-adapter.sh")"
    _make_fake_adapter "$_adapters_dir" "fake-adapter.sh" >/dev/null

    exit_code=0
    output=$(TEST_REGISTRY_PATH="$_registry" TEST_ADAPTERS_DIR="$_adapters_dir" \
        bash "$SCRIPT" nonexistent-recipe 2>&1) || exit_code=$?

    # Assert: exits non-zero
    assert_ne "test_unknown_recipe_returns_error: exits non-zero" "0" "$exit_code"

    # Assert: errors field non-empty in JSON output
    errors_nonempty=0
    echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
errors = d.get('errors', [])
assert len(errors) > 0, 'errors array must be non-empty for unknown recipe'
" 2>/dev/null && errors_nonempty=1 || true
    assert_eq "test_unknown_recipe_returns_error: JSON errors field non-empty" "1" "$errors_nonempty"
}
assert_pass_if_clean "test_unknown_recipe_returns_error"

# ── test_executor_passes_params_via_env ──────────────────────────────────────
# Given: a registry entry and a fake adapter that echoes RECIPE_PARAM_* env vars
# When:  recipe-executor.sh is called with --param function_name=add_item
# Then:  adapter receives RECIPE_PARAM_function_name=add_item in its environment
#        (no shell interpolation of param values in the command string)
_snapshot_fail
{
    _tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$_tmpdir")
    _adapters_dir="$_tmpdir/adapters"
    mkdir -p "$_adapters_dir"

    _registry="$(_make_registry "$_tmpdir" "param-recipe" "fake-adapter.sh")"
    _make_fake_adapter "$_adapters_dir" "fake-adapter.sh" >/dev/null

    exit_code=0
    output=$(TEST_REGISTRY_PATH="$_registry" TEST_ADAPTERS_DIR="$_adapters_dir" \
        bash "$SCRIPT" param-recipe --param function_name=add_item 2>&1) || exit_code=$?

    # Assert: adapter received the RECIPE_PARAM_function_name env var
    param_received=0
    echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
params = d.get('params_received', {})
assert params.get('function_name') == 'add_item', \
    f'Expected function_name=add_item in params_received, got: {params}'
" 2>/dev/null && param_received=1 || true

    assert_eq "test_executor_passes_params_via_env: RECIPE_PARAM_function_name=add_item received" "1" "$param_received"
}
assert_pass_if_clean "test_executor_passes_params_via_env"

# ── test_generative_recipe_rollback ──────────────────────────────────────────
# Given: a registry entry with recipe_type=generative and an adapter that creates a
#        file (tracked in CREATED_FILES) then fails
# When:  recipe-executor.sh executes the recipe
# Then:  the adapter's own EXIT trap deletes the created file on failure
_snapshot_fail
{
    _tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$_tmpdir")
    _adapters_dir="$_tmpdir/adapters"
    mkdir -p "$_adapters_dir"

    # Registry with recipe_type=generative
    _registry_path="$_tmpdir/registry.yaml"
    cat > "$_registry_path" <<YAML
recipes:
  - name: generative-fail-recipe
    language: python
    engine: scaffold
    engine_version_min: "0.0.0"
    adapter: generative-fail-adapter.sh
    recipe_type: generative
    description: "Generative recipe that creates a file then fails"
    parameters: []
YAML

    # Adapter that creates a tracked file then exits non-zero.
    # Uses the same CREATED_FILES + EXIT-trap pattern as scaffold-adapter.sh so that
    # the adapter's own cleanup removes the file on failure (executor no longer uses
    # find-based rollback).
    _created_file="$_tmpdir/created-by-adapter.txt"
    _adapter_path="$_adapters_dir/generative-fail-adapter.sh"
    cat > "$_adapter_path" <<ADAPTER
#!/usr/bin/env bash
set -euo pipefail
CREATED_FILES=()
ADAPTER_FAILED=0
cleanup() {
    if [[ \$ADAPTER_FAILED -eq 1 ]]; then
        for f in "\${CREATED_FILES[@]:-}"; do
            [[ -n "\$f" ]] && rm -f "\$f" 2>/dev/null || true
        done
    fi
}
trap cleanup EXIT
# Create a real file and track it for rollback
touch "$_created_file"
CREATED_FILES+=("$_created_file")
# Now deliberately fail — EXIT trap must delete the file
ADAPTER_FAILED=1
echo '{"degraded":false,"engine_name":"scaffold","error":"deliberate failure","exit_code":1}' >&2
exit 1
ADAPTER
    chmod +x "$_adapter_path"

    rollback_exit=0
    rollback_output=$(TEST_REGISTRY_PATH="$_registry_path" TEST_ADAPTERS_DIR="$_adapters_dir" \
        bash "$SCRIPT" generative-fail-recipe 2>&1) || rollback_exit=$?

    # Executor should exit non-zero
    assert_ne "test_generative_recipe_rollback: executor exits non-zero" "0" "$rollback_exit"

    # The created file should have been cleaned up by the adapter's EXIT trap
    file_exists=0
    [[ -f "$_created_file" ]] && file_exists=1 || true
    assert_eq "test_generative_recipe_rollback: created file deleted by adapter EXIT trap" "0" "$file_exists"
}
assert_pass_if_clean "test_generative_recipe_rollback"

print_summary
