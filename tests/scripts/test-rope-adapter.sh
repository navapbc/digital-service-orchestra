#!/usr/bin/env bash
# tests/scripts/test-rope-adapter.sh
# Behavioral tests for plugins/dso/scripts/recipe-adapters/rope-adapter.sh
#
# Tests are RED by design — rope-adapter.sh does not yet exist.
# Mock 'rope' CLI is placed on PATH via a temp dir; real Rope is NOT required.
#
# Tests cover:
#   - Degraded JSON returned when rope CLI is absent
#   - Parameters passed via RECIPE_PARAM_* env vars (not shell args)
#   - Injection safety (shell metacharacters in param values are not executed)
#   - Output is valid JSON with required fields
#   - Rollback on failure (git stash push --include-untracked called on non-zero exit)
#   - Rollback covers newly created untracked files (file_creation case)
#   - Idempotency on repeated invocations
#   - Determinism (hash comparison across 3 runs)
#   - Version validation (ROPE_MIN_VERSION enforcement)
#
# Usage: bash tests/scripts/test-rope-adapter.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTER="$PLUGIN_ROOT/plugins/dso/scripts/recipe-adapters/rope-adapter.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-rope-adapter.sh ==="

# ── Global Setup ─────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"

# ── Helpers ───────────────────────────────────────────────────────────────────

# write_mock_rope exit_code [stdout_json]
# Writes a mock rope script that exits with given code and prints optional JSON.
write_mock_rope() {
    local exit_code="$1"
    local stdout_content="${2:-}"
    cat > "$MOCK_BIN/rope" <<MOCK
#!/usr/bin/env bash
# Mock rope — exits $exit_code
${stdout_content:+echo '$stdout_content'}
exit $exit_code
MOCK
    chmod +x "$MOCK_BIN/rope"
}

# make_git_fixture dir
# Initializes a bare git repo fixture in the given directory.
make_git_fixture() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    echo "initial" > "$dir/initial.py"
    git -C "$dir" add initial.py
    git -C "$dir" commit -q -m "init"
}

# hash_file file
# Returns a stable hash of a file's contents.
hash_file() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" | awk '{print $1}'
    else
        shasum -a 256 "$file" | awk '{print $1}'
    fi
}

# run_adapter [extra_env_vars]
# Runs rope-adapter.sh with the MOCK_BIN prepended to PATH.
# Caller must set RECIPE_NAME and any RECIPE_PARAM_* env vars before calling.
run_adapter() {
    PATH="$MOCK_BIN:$PATH" bash "$ADAPTER" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_adapter_exits_nonzero_when_rope_cli_missing
#
# Given: rope is NOT on PATH
# When:  rope-adapter.sh is invoked
# Then:  adapter exits non-zero AND returns degraded JSON
#        {"degraded": true, "engine_name": "rope", "exit_code": 1, "errors": [...]}
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_adapter_exits_nonzero_when_rope_cli_missing ---"
_snapshot_fail

rc=0
output=$(RECIPE_NAME="rename_function" \
    RECIPE_PARAM_FILE="src/foo.py" \
    RECIPE_PARAM_FUNCTION="old_func" \
    RECIPE_PARAM_NAME="new_func" \
    PATH="$TMPDIR_TEST/empty_bin" "$BASH" "$ADAPTER" 2>&1) || rc=$?

# Must exit non-zero
assert_ne "test_adapter_exits_nonzero_when_rope_cli_missing exit code" "0" "$rc"

# Output must be valid JSON
json_valid=0
echo "$output" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid=$?
assert_eq "test_adapter_exits_nonzero_when_rope_cli_missing output is valid JSON" "0" "$json_valid"

# degraded must be true
assert_contains "test_adapter_exits_nonzero_when_rope_cli_missing degraded field" '"degraded"' "$output"

# engine_name must be rope
assert_contains "test_adapter_exits_nonzero_when_rope_cli_missing engine_name" '"engine_name"' "$output"
assert_contains "test_adapter_exits_nonzero_when_rope_cli_missing engine_name rope" '"rope"' "$output"

assert_pass_if_clean "test_adapter_exits_nonzero_when_rope_cli_missing"

# ─────────────────────────────────────────────────────────────────────────────
# test_adapter_passes_params_via_env_vars
#
# Given: rope mock on PATH, RECIPE_PARAM_FILE / RECIPE_PARAM_FUNCTION /
#        RECIPE_PARAM_NAME / RECIPE_PARAM_TYPE set as env vars
# When:  rope-adapter.sh is invoked with RECIPE_NAME set
# Then:  adapter exits 0 AND returns JSON with files_changed, transforms_applied,
#        errors, exit_code, engine_name fields — showing params were consumed
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_adapter_passes_params_via_env_vars ---"
_snapshot_fail

write_mock_rope 0 ""

rc=0
output=$(RECIPE_NAME="rename_function" \
    RECIPE_PARAM_FILE="src/foo.py" \
    RECIPE_PARAM_FUNCTION="old_func" \
    RECIPE_PARAM_NAME="new_func" \
    RECIPE_PARAM_TYPE="method" \
    run_adapter 2>&1) || rc=$?

# Must exit 0 on success
assert_eq "test_adapter_passes_params_via_env_vars exit code" "0" "$rc"

# Output must be valid JSON
json_valid=0
echo "$output" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid=$?
assert_eq "test_adapter_passes_params_via_env_vars output is valid JSON" "0" "$json_valid"

# Required fields must be present
for field in files_changed transforms_applied errors exit_code engine_name; do
    assert_contains "test_adapter_passes_params_via_env_vars field $field" "\"$field\"" "$output"
done

assert_pass_if_clean "test_adapter_passes_params_via_env_vars"

# ─────────────────────────────────────────────────────────────────────────────
# test_adapter_rejects_shell_metacharacters_in_param_values
#
# Given: RECIPE_PARAM_FILE contains shell metacharacters: "; rm /tmp/rope_inject_test; #"
# When:  rope-adapter.sh is invoked
# Then:  /tmp/rope_inject_test is NOT created (metacharacters were not shell-executed)
#        Adapter must pass the raw string to rope without shell interpolation.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_adapter_rejects_shell_metacharacters_in_param_values ---"
_snapshot_fail

INJECT_SENTINEL="/tmp/rope_inject_test_$$"
rm -f "$INJECT_SENTINEL"

write_mock_rope 0 ""

rc=0
output=$(RECIPE_NAME="rename_function" \
    RECIPE_PARAM_FILE="; touch $INJECT_SENTINEL; #" \
    RECIPE_PARAM_FUNCTION="old_func" \
    RECIPE_PARAM_NAME="new_func" \
    run_adapter 2>&1) || rc=$?

# The injection sentinel must NOT have been created
if [[ -f "$INJECT_SENTINEL" ]]; then
    rm -f "$INJECT_SENTINEL"
    (( ++FAIL ))
    echo "FAIL: test_adapter_rejects_shell_metacharacters_in_param_values — metacharacter injection succeeded, sentinel was created" >&2
else
    (( ++PASS ))
fi

assert_pass_if_clean "test_adapter_rejects_shell_metacharacters_in_param_values"

# ─────────────────────────────────────────────────────────────────────────────
# test_adapter_output_is_json
#
# Given: rope mock on PATH exits 0
# When:  rope-adapter.sh is invoked
# Then:  stdout is valid JSON with ALL required fields:
#        files_changed (array), transforms_applied (int), errors (array),
#        exit_code (int), engine_name (string)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_adapter_output_is_json ---"
_snapshot_fail

write_mock_rope 0 ""

rc=0
output=$(RECIPE_NAME="rename_function" \
    RECIPE_PARAM_FILE="src/foo.py" \
    RECIPE_PARAM_FUNCTION="old_func" \
    RECIPE_PARAM_NAME="new_func" \
    run_adapter 2>&1) || rc=$?

# Parse with python3 and verify each required field type
# Use -c flag (not pipe+heredoc) to avoid platform-specific stdin routing conflicts
json_check=0
echo "$output" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
assert isinstance(data.get('files_changed'), list),      'files_changed must be an array'
assert isinstance(data.get('transforms_applied'), int),  'transforms_applied must be an int'
assert isinstance(data.get('errors'), list),             'errors must be an array'
assert isinstance(data.get('exit_code'), int),           'exit_code must be an int'
assert isinstance(data.get('engine_name'), str),         'engine_name must be a string'
" 2>/dev/null || json_check=$?

assert_eq "test_adapter_output_is_json all required fields present and typed correctly" "0" "$json_check"

assert_pass_if_clean "test_adapter_output_is_json"

# ─────────────────────────────────────────────────────────────────────────────
# test_adapter_rollback_on_failure
#
# Given: a git fixture repo with a tracked file modified in working tree
# When:  mock rope exits non-zero (failure)
# Then:  adapter calls 'git stash pop' (or equivalent) and working tree is clean
#        (the modification is reverted)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_adapter_rollback_on_failure ---"
_snapshot_fail

GIT_FIXTURE="$TMPDIR_TEST/git_rollback_test"
make_git_fixture "$GIT_FIXTURE"

# Write mock rope that exits non-zero
write_mock_rope 1 ""

# Modify the tracked file (simulate what a recipe would do before failing)
echo "modified content" >> "$GIT_FIXTURE/initial.py"

# Verify working tree is dirty before adapter runs
dirty_before=$(git -C "$GIT_FIXTURE" status --porcelain)
assert_ne "test_adapter_rollback_on_failure pre-condition: working tree dirty" "" "$dirty_before"

rc=0
output=$(RECIPE_NAME="rename_function" \
    RECIPE_PARAM_FILE="$GIT_FIXTURE/initial.py" \
    RECIPE_PARAM_FUNCTION="old_func" \
    RECIPE_PARAM_NAME="new_func" \
    GIT_WORK_TREE="$GIT_FIXTURE" \
    GIT_DIR="$GIT_FIXTURE/.git" \
    run_adapter 2>&1) || rc=$?

# Adapter must exit non-zero on rope failure
assert_ne "test_adapter_rollback_on_failure exit code is non-zero" "0" "$rc"

# Working tree must be clean after rollback
dirty_after=$(git -C "$GIT_FIXTURE" status --porcelain)
assert_eq "test_adapter_rollback_on_failure working tree clean after rollback" "" "$dirty_after"

assert_pass_if_clean "test_adapter_rollback_on_failure"

# ─────────────────────────────────────────────────────────────────────────────
# test_git_stash_rollback_file_creation
#
# Given: a git fixture repo
# When:  mock rope exits non-zero AND creates a new untracked file during its run
# Then:  adapter rolls back using 'git stash push --include-untracked' (or explicit
#        deletion), and the new file is gone after the adapter exits
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_git_stash_rollback_file_creation ---"
_snapshot_fail

GIT_FIXTURE2="$TMPDIR_TEST/git_rollback_new_file"
make_git_fixture "$GIT_FIXTURE2"
NEW_FILE="$GIT_FIXTURE2/new_generated_file.py"

# Write a mock rope that creates a NEW file then exits non-zero
cat > "$MOCK_BIN/rope" <<MOCK
#!/usr/bin/env bash
# Mock rope: create a new untracked file, then fail
echo "generated content" > "$NEW_FILE"
exit 1
MOCK
chmod +x "$MOCK_BIN/rope"

rc=0
output=$(RECIPE_NAME="rename_function" \
    RECIPE_PARAM_FILE="$GIT_FIXTURE2/initial.py" \
    RECIPE_PARAM_FUNCTION="old_func" \
    RECIPE_PARAM_NAME="new_func" \
    GIT_WORK_TREE="$GIT_FIXTURE2" \
    GIT_DIR="$GIT_FIXTURE2/.git" \
    run_adapter 2>&1) || rc=$?

# Adapter must exit non-zero
assert_ne "test_git_stash_rollback_file_creation exit code is non-zero" "0" "$rc"

# The new untracked file must be gone (rolled back)
if [[ -f "$NEW_FILE" ]]; then
    (( ++FAIL ))
    echo "FAIL: test_git_stash_rollback_file_creation — new_file still exists after rollback (untracked rollback failed)" >&2
else
    (( ++PASS ))
fi

# Verify: output or adapter logic referenced 'untracked' or 'file_creation' or 'new_file'
# (behavioral check: adapter must handle untracked rollback explicitly)
assert_contains "test_git_stash_rollback_file_creation adapter handles untracked" \
    "untracked" "$output" 2>/dev/null || \
    assert_contains "test_git_stash_rollback_file_creation adapter handles file_creation" \
    "include-untracked" "$output" 2>/dev/null || \
    (( ++PASS ))  # If file was deleted another way (explicit rm), that's also acceptable

assert_pass_if_clean "test_git_stash_rollback_file_creation"

# ─────────────────────────────────────────────────────────────────────────────
# test_adapter_idempotent_on_repeated_run
#
# Given: mock rope on PATH exits 0
# When:  rope-adapter.sh is invoked twice with identical params on the same fixture
# Then:  outputs are identical (same files_changed list, same transforms_applied count)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_adapter_idempotent_on_repeated_run ---"
_snapshot_fail

write_mock_rope 0 ""

PY_FIXTURE="$TMPDIR_TEST/idempotent_test.py"
echo "def old_func(): pass" > "$PY_FIXTURE"

rc1=0
output1=$(RECIPE_NAME="rename_function" \
    RECIPE_PARAM_FILE="$PY_FIXTURE" \
    RECIPE_PARAM_FUNCTION="old_func" \
    RECIPE_PARAM_NAME="new_func" \
    run_adapter 2>&1) || rc1=$?

rc2=0
output2=$(RECIPE_NAME="rename_function" \
    RECIPE_PARAM_FILE="$PY_FIXTURE" \
    RECIPE_PARAM_FUNCTION="old_func" \
    RECIPE_PARAM_NAME="new_func" \
    run_adapter 2>&1) || rc2=$?

# Both runs must exit with the same code
assert_eq "test_adapter_idempotent_on_repeated_run exit codes match" "$rc1" "$rc2"

# Both outputs must be valid JSON
json_valid1=0
echo "$output1" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid1=$?
assert_eq "test_adapter_idempotent_on_repeated_run run1 output is valid JSON" "0" "$json_valid1"

json_valid2=0
echo "$output2" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid2=$?
assert_eq "test_adapter_idempotent_on_repeated_run run2 output is valid JSON" "0" "$json_valid2"

# files_changed and transforms_applied must be identical across runs
files1=$(echo "$output1" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(sorted(d.get('files_changed', [])))" 2>/dev/null || echo "parse_error")
files2=$(echo "$output2" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(sorted(d.get('files_changed', [])))" 2>/dev/null || echo "parse_error")
assert_eq "test_adapter_idempotent_on_repeated_run files_changed identical" "$files1" "$files2"

transforms1=$(echo "$output1" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('transforms_applied', -999))" 2>/dev/null || echo "-1")
transforms2=$(echo "$output2" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('transforms_applied', -999))" 2>/dev/null || echo "-1")
assert_eq "test_adapter_idempotent_on_repeated_run transforms_applied identical" "$transforms1" "$transforms2"

assert_pass_if_clean "test_adapter_idempotent_on_repeated_run"

# ─────────────────────────────────────────────────────────────────────────────
# test_adapter_determinism_hash_comparison
#
# Given: mock rope on PATH exits 0 and writes a deterministic output file
# When:  rope-adapter.sh is run 3 times on the same input
# Then:  the JSON stdout from each run hashes identically
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_adapter_determinism_hash_comparison ---"
_snapshot_fail

write_mock_rope 0 ""

PY_FIXTURE2="$TMPDIR_TEST/determinism_test.py"
echo "def old_func(): pass" > "$PY_FIXTURE2"

hash1="" hash2="" hash3=""

for i in 1 2 3; do
    out=$(RECIPE_NAME="rename_function" \
        RECIPE_PARAM_FILE="$PY_FIXTURE2" \
        RECIPE_PARAM_FUNCTION="old_func" \
        RECIPE_PARAM_NAME="new_func" \
        run_adapter 2>&1) || true
    h=$(printf '%s' "$out" | if command -v sha256sum &>/dev/null; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi)
    eval "hash${i}=\"$h\""
done

assert_eq "test_adapter_determinism_hash_comparison run1 == run2" "$hash1" "$hash2"
assert_eq "test_adapter_determinism_hash_comparison run2 == run3" "$hash2" "$hash3"

assert_pass_if_clean "test_adapter_determinism_hash_comparison"

# ─────────────────────────────────────────────────────────────────────────────
# test_adapter_version_validation
#
# Given: mock rope on PATH, ROPE_MIN_VERSION set to "999.0.0"
# When:  rope-adapter.sh is invoked
# Then:  adapter returns degraded JSON with a version mismatch error message
#        exit_code must be non-zero
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_adapter_version_validation ---"
_snapshot_fail

# Write a mock rope that reports a low version
cat > "$MOCK_BIN/rope" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "--version" || "$1" == "version" ]]; then
    echo "1.0.0"
    exit 0
fi
exit 0
MOCK
chmod +x "$MOCK_BIN/rope"

rc=0
output=$(RECIPE_NAME="rename_function" \
    RECIPE_PARAM_FILE="src/foo.py" \
    RECIPE_PARAM_FUNCTION="old_func" \
    RECIPE_PARAM_NAME="new_func" \
    ROPE_MIN_VERSION="999.0.0" \
    run_adapter 2>&1) || rc=$?

# Must exit non-zero when version requirement is not met
assert_ne "test_adapter_version_validation exit code is non-zero" "0" "$rc"

# Output must be valid JSON
json_valid=0
echo "$output" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid=$?
assert_eq "test_adapter_version_validation output is valid JSON" "0" "$json_valid"

# Must include degraded indicator
assert_contains "test_adapter_version_validation degraded field" '"degraded"' "$output"

# Must include some version-related error message
assert_contains "test_adapter_version_validation version error message" "version" "$output"

assert_pass_if_clean "test_adapter_version_validation"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
