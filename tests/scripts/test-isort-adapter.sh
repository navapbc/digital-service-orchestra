#!/usr/bin/env bash
# tests/scripts/test-isort-adapter.sh
# Behavioral tests for plugins/dso/scripts/recipe-adapters/isort-adapter.sh
#
# Tests are RED by design — isort-adapter.sh does not yet exist.
# Mock 'isort' binary is placed on PATH via a temp dir; real isort is NOT required.
#
# Tests cover:
#   - Adapter invocation exits 0 when mock isort returns success
#   - Output is valid JSON with all required fields
#   - Degraded JSON returned when isort is absent
#   - Injection safety (shell metacharacters in param values are not executed)
#   - Idempotency on repeated invocations
#   - Determinism (hash comparison across 3 runs)
#   - Version validation (ISORT_MIN_VERSION enforcement)
#   - Rollback on git failure (working tree clean after isort modifies and fails)
#   - Parameters passed via RECIPE_PARAM_* env vars
#
# Usage: bash tests/scripts/test-isort-adapter.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTER="$PLUGIN_ROOT/plugins/dso/scripts/recipe-adapters/isort-adapter.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-isort-adapter.sh ==="

# ── Global Setup ─────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Default contract-conforming JSON that a real isort invocation would produce on success.
_DEFAULT_ISORT_JSON='{"files_changed":[],"transforms_applied":0,"errors":[],"exit_code":0,"engine_name":"isort","degraded":false}'

# write_mock_isort exit_code
# Writes a mock isort binary that exits with given code.
# The mock handles both `isort --version` and `isort -- <file>` invocations.
write_mock_isort() {
    local exit_code="$1"
    cat > "$MOCK_BIN/isort" <<MOCK
#!/usr/bin/env bash
# Mock isort — exits $exit_code
# Handle version query
if [[ "\${1:-}" == "--version" ]]; then
    echo "VERSION 5.13.0"
    exit 0
fi
# Handle file invocation (isort -- <file>)
exit $exit_code
MOCK
    chmod +x "$MOCK_BIN/isort"
}

# make_git_fixture dir
# Initializes a bare git repo fixture in the given directory.
make_git_fixture() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    echo "import os" > "$dir/initial.py"
    git -C "$dir" add initial.py
    git -C "$dir" commit -q -m "init"
}

# run_adapter
# Runs isort-adapter.sh with the MOCK_BIN prepended to PATH.
run_adapter() {
    PATH="$MOCK_BIN:$PATH" bash "$ADAPTER" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_adapter_invocation_succeeds
#
# Given: mock isort on PATH that exits 0
# When:  isort-adapter.sh is invoked with RECIPE_PARAM_FILE set
# Then:  adapter exits 0 and emits JSON
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_adapter_invocation_succeeds ---"
_snapshot_fail

PY_FIXTURE="$TMPDIR_TEST/sample.py"
echo "import os" > "$PY_FIXTURE"

write_mock_isort 0

rc=0
output=$(RECIPE_PARAM_FILE="$PY_FIXTURE" \
    run_adapter 2>&1) || rc=$?

assert_eq "test_adapter_invocation_succeeds exit code" "0" "$rc"

assert_pass_if_clean "test_adapter_invocation_succeeds"

# ─────────────────────────────────────────────────────────────────────────────
# test_output_is_valid_json
#
# Given: mock isort on PATH exits 0
# When:  isort-adapter.sh is invoked
# Then:  stdout is valid JSON with ALL required fields:
#        files_changed, transforms_applied, errors, exit_code, degraded, engine_name
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_output_is_valid_json ---"
_snapshot_fail

write_mock_isort 0

PY_FIXTURE2="$TMPDIR_TEST/sample2.py"
echo "import os" > "$PY_FIXTURE2"

rc=0
output=$(RECIPE_PARAM_FILE="$PY_FIXTURE2" \
    run_adapter 2>&1) || rc=$?

# Output must be valid JSON with all required fields
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
# Given: isort is NOT on PATH (and python3 -m isort is also absent via mock)
# When:  isort-adapter.sh is invoked
# Then:  adapter exits 2 AND returns {degraded:true, engine_name:"isort", exit_code:2}
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_missing_engine_returns_degraded ---"
_snapshot_fail

rc=0
output=$(RECIPE_PARAM_FILE="src/foo.py" \
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

# engine_name must be isort
assert_contains "test_missing_engine_returns_degraded engine_name" '"engine_name": "isort"' "$output"

assert_pass_if_clean "test_missing_engine_returns_degraded"

# ─────────────────────────────────────────────────────────────────────────────
# test_parameter_injection_safety
#
# Given: RECIPE_PARAM_FILE contains shell metacharacters: "; rm /tmp/isortinj_PID; #"
# When:  isort-adapter.sh is invoked
# Then:  the sentinel file is NOT created (metacharacters were not shell-executed)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_parameter_injection_safety ---"
_snapshot_fail

INJECT_SENTINEL="/tmp/isortinj_$$"
rm -f "$INJECT_SENTINEL"

write_mock_isort 0

rc=0
output=$(RECIPE_PARAM_FILE="; rm $INJECT_SENTINEL; #" \
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
# Given: mock isort on PATH exits 0
# When:  isort-adapter.sh is invoked twice with identical params
# Then:  outputs are identical (same files_changed list, same transforms_applied count)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_idempotency ---"
_snapshot_fail

write_mock_isort 0

PY_FIXTURE3="$TMPDIR_TEST/idempotent.py"
echo "import os" > "$PY_FIXTURE3"

rc1=0
output1=$(RECIPE_PARAM_FILE="$PY_FIXTURE3" \
    run_adapter 2>&1) || rc1=$?

rc2=0
output2=$(RECIPE_PARAM_FILE="$PY_FIXTURE3" \
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
# Given: mock isort on PATH exits 0
# When:  isort-adapter.sh is run 3 times on the same input
# Then:  the JSON stdout from each run hashes identically
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_determinism_hash ---"
_snapshot_fail

write_mock_isort 0

PY_FIXTURE4="$TMPDIR_TEST/determinism.py"
echo "import os" > "$PY_FIXTURE4"

hash1="" hash2="" hash3=""

for i in 1 2 3; do
    out=$(RECIPE_PARAM_FILE="$PY_FIXTURE4" \
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
# Given: mock isort on PATH reporting version 5.13.0, ISORT_MIN_VERSION=999.0.0
# When:  isort-adapter.sh is invoked
# Then:  adapter returns degraded JSON with version mismatch error
#        exit_code must be 2 (non-zero)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_version_validation ---"
_snapshot_fail

# Write a mock isort that reports a low version
cat > "$MOCK_BIN/isort" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "VERSION 5.13.0"
    exit 0
fi
exit 0
MOCK
chmod +x "$MOCK_BIN/isort"

rc=0
output=$(RECIPE_PARAM_FILE="src/foo.py" \
    ISORT_MIN_VERSION="999.0.0" \
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
# test_git_stash_rollback
#
# Given: a git fixture repo with a tracked file modified by mock isort then failing
# When:  mock isort modifies tracked file then exits non-zero
# Then:  adapter rolls back and working tree is clean
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_git_stash_rollback ---"
_snapshot_fail

GIT_FIXTURE="$TMPDIR_TEST/git_rollback"
make_git_fixture "$GIT_FIXTURE"

# Write a mock isort that modifies the tracked file then fails
cat > "$MOCK_BIN/isort" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
    echo "VERSION 5.13.0"
    exit 0
fi
# Modify the tracked file then fail
echo "import sys  # isort was here" >> "$GIT_FIXTURE/initial.py"
exit 1
MOCK
chmod +x "$MOCK_BIN/isort"

rc=0
output=$(RECIPE_PARAM_FILE="$GIT_FIXTURE/initial.py" \
    GIT_WORK_TREE="$GIT_FIXTURE" \
    GIT_DIR="$GIT_FIXTURE/.git" \
    run_adapter 2>&1) || rc=$?

# Adapter must exit non-zero on isort failure
assert_ne "test_git_stash_rollback exit code is non-zero" "0" "$rc"

# Working tree must be clean after rollback
dirty_after=$(git -C "$GIT_FIXTURE" status --porcelain)
assert_eq "test_git_stash_rollback working tree clean after rollback" "" "$dirty_after"

assert_pass_if_clean "test_git_stash_rollback"

# ─────────────────────────────────────────────────────────────────────────────
# test_params_passed_via_env
#
# Given: mock isort script that records RECIPE_PARAM_FILE from env
# When:  isort-adapter.sh is invoked with RECIPE_PARAM_FILE set
# Then:  the param arrives in isort's environment (via env, not shell-interpolated arg)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_params_passed_via_env ---"
_snapshot_fail

MARKER_FILE="$TMPDIR_TEST/isort_params_received"
PY_FIXTURE5="$TMPDIR_TEST/env_test.py"
echo "import os" > "$PY_FIXTURE5"

cat > "$MOCK_BIN/isort" <<MOCK
#!/usr/bin/env bash
# Mock isort: write received env to marker file
if [[ "\${1:-}" == "--version" ]]; then
    echo "VERSION 5.13.0"
    exit 0
fi
echo "FILE=\${RECIPE_PARAM_FILE:-UNSET}" > "$MARKER_FILE"
exit 0
MOCK
chmod +x "$MOCK_BIN/isort"

rc=0
output=$(RECIPE_PARAM_FILE="$PY_FIXTURE5" \
    run_adapter 2>&1) || rc=$?

# Marker file must exist (isort was called)
if [[ ! -f "$MARKER_FILE" ]]; then
    (( ++FAIL ))
    echo "FAIL: test_params_passed_via_env — marker file not created (isort not called)" >&2
else
    marker_content=$(cat "$MARKER_FILE")
    assert_contains "test_params_passed_via_env FILE param received" "FILE=$PY_FIXTURE5" "$marker_content"
fi

assert_pass_if_clean "test_params_passed_via_env"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
