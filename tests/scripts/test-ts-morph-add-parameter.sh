#!/usr/bin/env bash
# tests/scripts/test-ts-morph-add-parameter.sh
# Behavioral tests for plugins/dso/scripts/recipe-adapters/ts-morph-add-parameter.mjs
#
# Tests skip gracefully if node is not installed.
# Tests are RED by design — ts-morph-add-parameter.mjs does not yet exist.
#
# Tests cover:
#   - Add parameter to a single TypeScript function
#   - Function signature is updated with the new parameter
#   - All cross-file callers are updated
#   - Output is valid JSON with required fields
#   - Idempotency: run twice produces same output
#
# Usage: bash tests/scripts/test-ts-morph-add-parameter.sh
# Returns: exit 0 if all tests pass or skipped, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MJS_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/recipe-adapters/ts-morph-add-parameter.mjs"
FIXTURE_DIR="$PLUGIN_ROOT/tests/fixtures/ts-morph-single"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ts-morph-add-parameter.sh ==="

# ── Skip if node not installed ────────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not installed — skipping all ts-morph-add-parameter tests"
    echo ""
    printf "PASSED: %d  FAILED: %d  SKIPPED: all (node not available)\n" "$PASS" "$FAIL"
    exit 0
fi

echo "node found: $(node --version)"

# ── Skip if ts-morph not available in fixture dir ────────────────────────────
# Try to find ts-morph: fixture dir or global node_modules
TS_MORPH_AVAILABLE=0
if node -e "require('ts-morph')" 2>/dev/null; then
    TS_MORPH_AVAILABLE=1
elif [[ -d "$FIXTURE_DIR/node_modules/ts-morph" ]]; then
    TS_MORPH_AVAILABLE=1
fi

if [[ $TS_MORPH_AVAILABLE -eq 0 ]]; then
    echo "SKIP: ts-morph not installed — skipping all ts-morph-add-parameter tests"
    echo "  Install with: cd $FIXTURE_DIR && npm install ts-morph"
    echo ""
    printf "PASSED: %d  FAILED: %d  SKIPPED: all (ts-morph not available)\n" "$PASS" "$FAIL"
    exit 0
fi

echo "ts-morph found"

# ── Skip if .mjs script not found ────────────────────────────────────────────
if [[ ! -f "$MJS_SCRIPT" ]]; then
    echo "SKIP: ts-morph-add-parameter.mjs not found at $MJS_SCRIPT"
    echo ""
    printf "PASSED: %d  FAILED: %d  SKIPPED: all (mjs script missing)\n" "$PASS" "$FAIL"
    exit 1  # RED: mjs must exist for tests to run; treat as failure not skip
fi

# ── Global Setup ─────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Copy fixture to a temp working dir so we don't mutate the original
WORK_DIR="$TMPDIR_TEST/project"

setup_fixture() {
    rm -rf "$WORK_DIR"
    cp -r "$FIXTURE_DIR" "$WORK_DIR"
    # If ts-morph is available globally but not in fixture, point to global
    if [[ ! -d "$WORK_DIR/node_modules/ts-morph" ]]; then
        # Create node_modules symlink or install inline
        mkdir -p "$WORK_DIR/node_modules"
        # Try to find ts-morph globally and link it
        global_ts_morph=$(node -e "console.log(require.resolve('ts-morph/package.json').replace('/package.json',''))" 2>/dev/null || echo "")
        if [[ -n "$global_ts_morph" && -d "$global_ts_morph" ]]; then
            ln -sf "$global_ts_morph" "$WORK_DIR/node_modules/ts-morph" 2>/dev/null || true
        fi
    fi
}

run_mjs() {
    local work_dir="$1"
    node "$MJS_SCRIPT"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_single_project_add_parameter
#
# Given: TypeScript project with greet(name: string) function
# When:  ts-morph-add-parameter.mjs is invoked to add 'prefix' param
# Then:  exits 0 and callers are updated
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_single_project_add_parameter ---"
_snapshot_fail

setup_fixture

rc=0
output=$(RECIPE_WORKING_DIR="$WORK_DIR" \
    RECIPE_PARAM_FILE="$WORK_DIR/src/greet.ts" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    RECIPE_PARAM_TYPE="string" \
    RECIPE_PARAM_DEFAULT="'Hello'" \
    run_mjs "$WORK_DIR" 2>&1) || rc=$?

assert_eq "test_single_project_add_parameter exit code" "0" "$rc"

# Output must be valid JSON
json_valid=0
echo "$output" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid=$?
assert_eq "test_single_project_add_parameter output is valid JSON" "0" "$json_valid"

assert_pass_if_clean "test_single_project_add_parameter"

# ─────────────────────────────────────────────────────────────────────────────
# test_function_signature_updated
#
# Given: TypeScript project with greet(name: string) function
# When:  ts-morph-add-parameter.mjs adds 'prefix' parameter
# Then:  greet.ts contains the new parameter in the function signature
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_function_signature_updated ---"
_snapshot_fail

setup_fixture

rc=0
output=$(RECIPE_WORKING_DIR="$WORK_DIR" \
    RECIPE_PARAM_FILE="$WORK_DIR/src/greet.ts" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    RECIPE_PARAM_TYPE="string" \
    RECIPE_PARAM_DEFAULT="'Hello'" \
    run_mjs "$WORK_DIR" 2>&1) || rc=$?

assert_eq "test_function_signature_updated exit code" "0" "$rc"

# Check greet.ts was modified to include the new parameter
if [[ -f "$WORK_DIR/src/greet.ts" ]]; then
    greet_content=$(cat "$WORK_DIR/src/greet.ts")
    assert_contains "test_function_signature_updated new param in signature" "prefix" "$greet_content"
else
    (( ++FAIL ))
    echo "FAIL: test_function_signature_updated — greet.ts not found at $WORK_DIR/src/greet.ts" >&2
fi

assert_pass_if_clean "test_function_signature_updated"

# ─────────────────────────────────────────────────────────────────────────────
# test_cross_file_callers_updated
#
# Given: 3 caller files (caller1.ts, caller2.ts, caller3.ts) that call greet()
# When:  ts-morph-add-parameter.mjs adds a required parameter to greet()
# Then:  all 3 caller files are updated (transforms_applied >= 3)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_cross_file_callers_updated ---"
_snapshot_fail

setup_fixture

rc=0
output=$(RECIPE_WORKING_DIR="$WORK_DIR" \
    RECIPE_PARAM_FILE="$WORK_DIR/src/greet.ts" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    RECIPE_PARAM_TYPE="string" \
    run_mjs "$WORK_DIR" 2>&1) || rc=$?

assert_eq "test_cross_file_callers_updated exit code" "0" "$rc"

# Check transforms_applied >= 3 (one for each caller + the function def)
transforms=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('transforms_applied', 0))" 2>/dev/null || echo "0")
if [[ "$transforms" -ge 3 ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: test_cross_file_callers_updated — transforms_applied=%s (expected >=3)\n" "$transforms" >&2
fi

assert_pass_if_clean "test_cross_file_callers_updated"

# ─────────────────────────────────────────────────────────────────────────────
# test_outputs_json_to_stdout
#
# Given: ts-morph-add-parameter.mjs invoked
# When:  output captured
# Then:  output is valid JSON with files_changed, transforms_applied, exit_code fields
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_outputs_json_to_stdout ---"
_snapshot_fail

setup_fixture

rc=0
output=$(RECIPE_WORKING_DIR="$WORK_DIR" \
    RECIPE_PARAM_FILE="$WORK_DIR/src/greet.ts" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    RECIPE_PARAM_TYPE="string" \
    RECIPE_PARAM_DEFAULT="'Hello'" \
    run_mjs "$WORK_DIR" 2>&1) || rc=$?

json_check=0
echo "$output" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
assert isinstance(data.get('files_changed'), list),     'files_changed must be an array'
assert isinstance(data.get('transforms_applied'), int), 'transforms_applied must be an int'
assert isinstance(data.get('exit_code'), int),          'exit_code must be an int'
assert isinstance(data.get('errors'), list),            'errors must be an array'
" 2>/dev/null || json_check=$?

assert_eq "test_outputs_json_to_stdout all required fields present and typed correctly" "0" "$json_check"

assert_pass_if_clean "test_outputs_json_to_stdout"

# ─────────────────────────────────────────────────────────────────────────────
# test_idempotency_ts
#
# Given: ts-morph-add-parameter.mjs invoked on same project twice
# When:  second run has same parameters
# Then:  second run exits 0 and produces no additional changes
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_idempotency_ts ---"
_snapshot_fail

setup_fixture

# First run
rc1=0
output1=$(RECIPE_WORKING_DIR="$WORK_DIR" \
    RECIPE_PARAM_FILE="$WORK_DIR/src/greet.ts" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    RECIPE_PARAM_TYPE="string" \
    RECIPE_PARAM_DEFAULT="'Hello'" \
    run_mjs "$WORK_DIR" 2>&1) || rc1=$?

# Second run (same params, same project — parameter already exists)
rc2=0
output2=$(RECIPE_WORKING_DIR="$WORK_DIR" \
    RECIPE_PARAM_FILE="$WORK_DIR/src/greet.ts" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    RECIPE_PARAM_TYPE="string" \
    RECIPE_PARAM_DEFAULT="'Hello'" \
    run_mjs "$WORK_DIR" 2>&1) || rc2=$?

assert_eq "test_idempotency_ts first run exit code" "0" "$rc1"
assert_eq "test_idempotency_ts second run exit code" "0" "$rc2"

# Second run should have 0 transforms_applied (param already exists, no-op)
transforms2=$(echo "$output2" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('transforms_applied', -1))" 2>/dev/null || echo "-1")
assert_eq "test_idempotency_ts second run is no-op (0 transforms)" "0" "$transforms2"

assert_pass_if_clean "test_idempotency_ts"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
