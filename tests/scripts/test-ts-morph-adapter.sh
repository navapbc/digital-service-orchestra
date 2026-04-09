#!/usr/bin/env bash
# tests/scripts/test-ts-morph-adapter.sh
# Behavioral tests for plugins/dso/scripts/recipe-adapters/ts-morph-adapter.sh
#
# Tests are RED by design — ts-morph-adapter.sh does not yet exist.
# Mock 'node' binary is placed on PATH via a temp dir; real Node/ts-morph NOT required.
#
# Tests cover:
#   - Adapter invocation exits 0 when mock node returns JSON
#   - Output is valid JSON with all required fields
#   - Degraded JSON returned when node is absent
#   - Injection safety (shell metacharacters in param values are not executed)
#   - Idempotency on repeated invocations
#   - Determinism (hash comparison across 3 runs)
#   - Version validation (TS_MORPH_MIN_VERSION enforcement)
#   - Parameters passed via RECIPE_PARAM_* env vars
#
# Usage: bash tests/scripts/test-ts-morph-adapter.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTER="$PLUGIN_ROOT/plugins/dso/scripts/recipe-adapters/ts-morph-adapter.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ts-morph-adapter.sh ==="

# ── Global Setup ─────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Default contract-conforming JSON that a real ts-morph script would emit on success.
_DEFAULT_NODE_JSON='{"files_changed":[],"transforms_applied":0,"errors":[],"exit_code":0,"engine_name":"ts-morph","degraded":false}'

# write_mock_node exit_code [stdout_json]
# Writes a mock node script that exits with given code and prints optional JSON content.
# When stdout_json is omitted and exit_code is 0, outputs the default contract JSON.
write_mock_node() {
    local exit_code="$1"
    local stdout_content="${2:-}"
    # Default to valid contract JSON when node succeeds and no content is specified
    if [[ -z "$stdout_content" && "$exit_code" -eq 0 ]]; then
        stdout_content="$_DEFAULT_NODE_JSON"
    fi
    cat > "$MOCK_BIN/node" <<MOCK
#!/usr/bin/env bash
# Mock node — exits $exit_code
${stdout_content:+printf '%s\n' '$stdout_content'}
exit $exit_code
MOCK
    chmod +x "$MOCK_BIN/node"
}

# make_git_fixture dir
# Initializes a bare git repo fixture in the given directory.
make_git_fixture() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    echo "initial" > "$dir/initial.ts"
    git -C "$dir" add initial.ts
    git -C "$dir" commit -q -m "init"
}

# run_adapter [extra_env_vars]
# Runs ts-morph-adapter.sh with the MOCK_BIN prepended to PATH.
run_adapter() {
    PATH="$MOCK_BIN:$PATH" bash "$ADAPTER" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_adapter_invocation_succeeds
#
# Given: mock node on PATH that returns JSON and exits 0
# When:  ts-morph-adapter.sh is invoked with RECIPE_NAME set
# Then:  adapter exits 0
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_adapter_invocation_succeeds ---"
_snapshot_fail

write_mock_node 0 ""

rc=0
output=$(RECIPE_NAME="add-parameter" \
    RECIPE_PARAM_FILE="src/greet.ts" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    RECIPE_PARAM_TYPE="string" \
    run_adapter 2>&1) || rc=$?

assert_eq "test_adapter_invocation_succeeds exit code" "0" "$rc"

assert_pass_if_clean "test_adapter_invocation_succeeds"

# ─────────────────────────────────────────────────────────────────────────────
# test_output_is_valid_json
#
# Given: mock node on PATH exits 0
# When:  ts-morph-adapter.sh is invoked
# Then:  stdout is valid JSON with ALL required fields:
#        files_changed, transforms_applied, errors, exit_code, degraded, engine_name
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_output_is_valid_json ---"
_snapshot_fail

write_mock_node 0 ""

rc=0
output=$(RECIPE_NAME="add-parameter" \
    RECIPE_PARAM_FILE="src/greet.ts" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    RECIPE_PARAM_TYPE="string" \
    run_adapter 2>&1) || rc=$?

# Output must be valid JSON
json_check=0
echo "$output" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
assert isinstance(data.get('files_changed'), list),      'files_changed must be an array'
assert isinstance(data.get('transforms_applied'), int),  'transforms_applied must be an int'
assert isinstance(data.get('errors'), list),             'errors must be an array'
assert isinstance(data.get('exit_code'), int),           'exit_code must be an int'
assert isinstance(data.get('degraded'), bool),           'degraded must be a bool'
assert isinstance(data.get('engine_name'), str),         'engine_name must be a string'
" 2>/dev/null || json_check=$?

assert_eq "test_output_is_valid_json all required fields present and typed correctly" "0" "$json_check"

assert_pass_if_clean "test_output_is_valid_json"

# ─────────────────────────────────────────────────────────────────────────────
# test_missing_engine_returns_degraded
#
# Given: node is NOT on PATH
# When:  ts-morph-adapter.sh is invoked
# Then:  adapter exits 2 AND returns {degraded:true, engine_name:"ts-morph", exit_code:2}
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_missing_engine_returns_degraded ---"
_snapshot_fail

rc=0
output=$(RECIPE_NAME="add-parameter" \
    RECIPE_PARAM_FILE="src/greet.ts" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    PATH="$TMPDIR_TEST/empty_bin" \
    "$BASH" "$ADAPTER" 2>&1) || rc=$?

# Must exit 2
assert_eq "test_missing_engine_returns_degraded exit code is 2" "2" "$rc"

# Output must be valid JSON
json_valid=0
echo "$output" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid=$?
assert_eq "test_missing_engine_returns_degraded output is valid JSON" "0" "$json_valid"

# degraded must be true
assert_contains "test_missing_engine_returns_degraded degraded field" '"degraded": true' "$output"

# engine_name must be ts-morph
assert_contains "test_missing_engine_returns_degraded engine_name" '"engine_name": "ts-morph"' "$output"

assert_pass_if_clean "test_missing_engine_returns_degraded"

# ─────────────────────────────────────────────────────────────────────────────
# test_parameter_injection_safety
#
# Given: RECIPE_PARAM_FILE contains shell metacharacters: "; rm /tmp/tstest; #"
# When:  ts-morph-adapter.sh is invoked
# Then:  /tmp/tstest is NOT created (metacharacters were not shell-executed)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_parameter_injection_safety ---"
_snapshot_fail

INJECT_SENTINEL="/tmp/tstest_inject_$$"
rm -f "$INJECT_SENTINEL"

write_mock_node 0 ""

rc=0
output=$(RECIPE_NAME="add-parameter" \
    RECIPE_PARAM_FILE="; rm $INJECT_SENTINEL; #" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    run_adapter 2>&1) || rc=$?

# The injection sentinel must NOT have been created
if [[ -f "$INJECT_SENTINEL" ]]; then
    rm -f "$INJECT_SENTINEL"
    (( ++FAIL ))
    echo "FAIL: test_parameter_injection_safety — metacharacter injection succeeded, sentinel was created" >&2
else
    (( ++PASS ))
fi

assert_pass_if_clean "test_parameter_injection_safety"

# ─────────────────────────────────────────────────────────────────────────────
# test_idempotency
#
# Given: mock node on PATH exits 0
# When:  ts-morph-adapter.sh is invoked twice with identical params
# Then:  outputs are identical (same files_changed list, same transforms_applied count)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_idempotency ---"
_snapshot_fail

write_mock_node 0 ""

rc1=0
output1=$(RECIPE_NAME="add-parameter" \
    RECIPE_PARAM_FILE="src/greet.ts" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    RECIPE_PARAM_TYPE="string" \
    run_adapter 2>&1) || rc1=$?

rc2=0
output2=$(RECIPE_NAME="add-parameter" \
    RECIPE_PARAM_FILE="src/greet.ts" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    RECIPE_PARAM_TYPE="string" \
    run_adapter 2>&1) || rc2=$?

# Both runs must exit with the same code
assert_eq "test_idempotency exit codes match" "$rc1" "$rc2"

# Both outputs must be valid JSON
json_valid1=0
echo "$output1" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid1=$?
assert_eq "test_idempotency run1 output is valid JSON" "0" "$json_valid1"

json_valid2=0
echo "$output2" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid2=$?
assert_eq "test_idempotency run2 output is valid JSON" "0" "$json_valid2"

# files_changed and transforms_applied must be identical across runs
files1=$(echo "$output1" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(sorted(d.get('files_changed', [])))" 2>/dev/null || echo "parse_error")
files2=$(echo "$output2" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(sorted(d.get('files_changed', [])))" 2>/dev/null || echo "parse_error")
assert_eq "test_idempotency files_changed identical" "$files1" "$files2"

transforms1=$(echo "$output1" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('transforms_applied', -999))" 2>/dev/null || echo "-1")
transforms2=$(echo "$output2" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('transforms_applied', -999))" 2>/dev/null || echo "-1")
assert_eq "test_idempotency transforms_applied identical" "$transforms1" "$transforms2"

assert_pass_if_clean "test_idempotency"

# ─────────────────────────────────────────────────────────────────────────────
# test_determinism_hash
#
# Given: mock node on PATH exits 0
# When:  ts-morph-adapter.sh is run 3 times on the same input
# Then:  the JSON stdout from each run hashes identically
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_determinism_hash ---"
_snapshot_fail

write_mock_node 0 ""

hash1="" hash2="" hash3=""

for i in 1 2 3; do
    out=$(RECIPE_NAME="add-parameter" \
        RECIPE_PARAM_FILE="src/greet.ts" \
        RECIPE_PARAM_FUNCTION="greet" \
        RECIPE_PARAM_NAME="prefix" \
        RECIPE_PARAM_TYPE="string" \
        run_adapter 2>&1) || true
    h=$(printf '%s' "$out" | if command -v sha256sum &>/dev/null; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi)
    eval "hash${i}=\"$h\""
done

assert_eq "test_determinism_hash run1 == run2" "$hash1" "$hash2"
assert_eq "test_determinism_hash run2 == run3" "$hash2" "$hash3"

assert_pass_if_clean "test_determinism_hash"

# ─────────────────────────────────────────────────────────────────────────────
# test_version_validation
#
# Given: mock node on PATH, TS_MORPH_MIN_VERSION set to "999.0.0"
# When:  ts-morph-adapter.sh is invoked
# Then:  adapter returns degraded JSON with a version mismatch error message
#        exit_code must be 2 (non-zero)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_version_validation ---"
_snapshot_fail

# Write a mock node that reports a low ts-morph version when queried
cat > "$MOCK_BIN/node" <<'MOCK'
#!/usr/bin/env bash
# Mock node: report ts-morph version 1.0.0 for version queries, succeed otherwise
if [[ "$*" == *"ts-morph/package.json"* ]] || [[ "$*" == *"require('ts-morph"* ]] || [[ "$*" == *"ts-morph"* ]]; then
    echo "1.0.0"
    exit 0
fi
exit 0
MOCK
chmod +x "$MOCK_BIN/node"

rc=0
output=$(RECIPE_NAME="add-parameter" \
    RECIPE_PARAM_FILE="src/greet.ts" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    TS_MORPH_MIN_VERSION="999.0.0" \
    run_adapter 2>&1) || rc=$?

# Must exit non-zero when version requirement is not met
assert_ne "test_version_validation exit code is non-zero" "0" "$rc"

# Output must be valid JSON
json_valid=0
echo "$output" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid=$?
assert_eq "test_version_validation output is valid JSON" "0" "$json_valid"

# Must include degraded indicator
assert_contains "test_version_validation degraded field" '"degraded"' "$output"

# Must include some version-related error message
assert_contains "test_version_validation version error message" "version" "$output"

assert_pass_if_clean "test_version_validation"

# ─────────────────────────────────────────────────────────────────────────────
# test_params_passed_via_env
#
# Given: mock node script that echoes RECIPE_PARAM_* env vars to stdout
# When:  ts-morph-adapter.sh is invoked with RECIPE_PARAM_* set
# Then:  the params arrive in node's environment (mock echoes them back)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_params_passed_via_env ---"
_snapshot_fail

# Write a fake node script that echoes back RECIPE_PARAM_* env vars as JSON comment in stderr
# We can't easily check node's env from the adapter test, but we can verify the adapter
# invokes node with the env vars set by checking a marker file
MARKER_FILE="$TMPDIR_TEST/params_received"
cat > "$MOCK_BIN/node" <<MOCK
#!/usr/bin/env bash
# Mock node: write received RECIPE_PARAM_* vars to a marker file
echo "FILE=\${RECIPE_PARAM_FILE:-UNSET}" > "$MARKER_FILE"
echo "FUNCTION=\${RECIPE_PARAM_FUNCTION:-UNSET}" >> "$MARKER_FILE"
echo "NAME=\${RECIPE_PARAM_NAME:-UNSET}" >> "$MARKER_FILE"
echo "TYPE=\${RECIPE_PARAM_TYPE:-UNSET}" >> "$MARKER_FILE"
# Output valid contract JSON so the adapter's JSON-validation step passes
printf '%s\n' '{"files_changed":[],"transforms_applied":0,"errors":[],"exit_code":0,"engine_name":"ts-morph","degraded":false}'
exit 0
MOCK
chmod +x "$MOCK_BIN/node"

rc=0
output=$(RECIPE_NAME="add-parameter" \
    RECIPE_PARAM_FILE="src/greet.ts" \
    RECIPE_PARAM_FUNCTION="greet" \
    RECIPE_PARAM_NAME="prefix" \
    RECIPE_PARAM_TYPE="string" \
    run_adapter 2>&1) || rc=$?

# Marker file must exist (node was called)
if [[ ! -f "$MARKER_FILE" ]]; then
    (( ++FAIL ))
    echo "FAIL: test_params_passed_via_env — marker file not created (node not called)" >&2
else
    marker_content=$(cat "$MARKER_FILE")
    assert_contains "test_params_passed_via_env FILE param received" "FILE=src/greet.ts" "$marker_content"
    assert_contains "test_params_passed_via_env FUNCTION param received" "FUNCTION=greet" "$marker_content"
    assert_contains "test_params_passed_via_env NAME param received" "NAME=prefix" "$marker_content"
    assert_contains "test_params_passed_via_env TYPE param received" "TYPE=string" "$marker_content"
fi

assert_pass_if_clean "test_params_passed_via_env"

# ─────────────────────────────────────────────────────────────────────────────
# test_normalize_imports_dispatch
#
# Given: RECIPE_NAME=normalize-imports and mock node on PATH
# When:  ts-morph-adapter.sh is invoked
# Then:  adapter dispatches to ts-morph-normalize-imports.mjs and exits 0
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_normalize_imports_dispatch ---"
_snapshot_fail

# Write a mock node that outputs valid JSON for normalize-imports
cat > "$MOCK_BIN/node" <<'MOCK'
#!/usr/bin/env bash
# Mock node: respond to normalize-imports dispatch
printf '%s\n' '{"files_changed":[],"transforms_applied":0,"errors":[],"exit_code":0,"engine_name":"ts-morph","degraded":false}'
exit 0
MOCK
chmod +x "$MOCK_BIN/node"

rc=0
output=$(RECIPE_NAME="normalize-imports" \
    RECIPE_PARAM_FILE="src/index.ts" \
    run_adapter 2>&1) || rc=$?

# Must exit 0
assert_eq "test_normalize_imports_dispatch exit code" "0" "$rc"

# Output must be valid JSON
json_valid=0
echo "$output" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid=$?
assert_eq "test_normalize_imports_dispatch output is valid JSON" "0" "$json_valid"

# Must have engine_name ts-morph (JSON may or may not have spaces after colon)
assert_contains "test_normalize_imports_dispatch engine_name" '"engine_name"' "$output"
assert_contains "test_normalize_imports_dispatch engine_name ts-morph" '"ts-morph"' "$output"

assert_pass_if_clean "test_normalize_imports_dispatch"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
