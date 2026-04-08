#!/usr/bin/env bash
# tests/scripts/test-synvert-adapter.sh
# Behavioral tests for plugins/dso/scripts/recipe-adapters/synvert-adapter.sh
#
# Mock 'synvert' binary is placed on PATH; real synvert is NOT required.
#
# Tests cover:
#   - Degraded JSON returned when synvert is absent (exit_code: 2, degraded: true)
#   - Degraded JSON when installed version is below RECIPE_MIN_ENGINE_VERSION
#   - Successful execution (mock synvert exits 0, no file change) → valid JSON
#   - Failed execution (mock synvert exits 1) → executor receives structured error
#   - Parameters passed via RECIPE_PARAM_* env vars (no shell metachar injection)
#
# Usage: bash tests/scripts/test-synvert-adapter.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTER="$PLUGIN_ROOT/plugins/dso/scripts/recipe-adapters/synvert-adapter.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-synvert-adapter.sh ==="

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"

# ── Helpers ───────────────────────────────────────────────────────────────────

# write_mock_synvert exit_code version
write_mock_synvert() {
    local exit_code="${1:-0}"
    local version="${2:-1.5.0}"
    cat > "$MOCK_BIN/synvert" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
    echo "$version"
    exit 0
fi
exit $exit_code
MOCK
    chmod +x "$MOCK_BIN/synvert"
}

# make_ruby_fixture dir — creates a minimal Ruby file in dir
make_ruby_fixture() {
    local dir="$1"
    mkdir -p "$dir"
    printf "require 'ostruct'\nrequire 'json'\n" > "$dir/main.rb"
}

# run_adapter FILE [extra env vars...]
run_adapter() {
    local file="$1"
    shift
    PATH="$MOCK_BIN:$PATH" RECIPE_PARAM_file="$file" "$@" bash "$ADAPTER" 2>&1
}

# test_degraded_when_synvert_missing
# When synvert is not on PATH, adapter exits 2 and emits degraded JSON.
test_degraded_when_synvert_missing() {
    local fixture_dir="$TMPDIR_TEST/test_missing"
    make_ruby_fixture "$fixture_dir"
    local file="$fixture_dir/main.rb"

    local output exit_code=0
    # Use a PATH that excludes mock bin so synvert is absent
    output=$(PATH="/usr/bin:/bin" RECIPE_PARAM_file="$file" bash "$ADAPTER" 2>&1) || exit_code=$?

    local degraded
    degraded=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('degraded',''))" 2>/dev/null || echo "")
    assert_eq "test_degraded_when_synvert_missing: degraded=true" "True" "$degraded"

    local ec
    ec=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('exit_code',''))" 2>/dev/null || echo "")
    assert_eq "test_degraded_when_synvert_missing: exit_code=2" "2" "$ec"
}

# test_degraded_when_version_below_minimum
# When installed version is below RECIPE_MIN_ENGINE_VERSION, adapter exits 2 degraded.
test_degraded_when_version_below_minimum() {
    write_mock_synvert 0 "0.5.0"
    local fixture_dir="$TMPDIR_TEST/test_version"
    make_ruby_fixture "$fixture_dir"
    local file="$fixture_dir/main.rb"

    local output exit_code=0
    output=$(PATH="$MOCK_BIN:$PATH" RECIPE_PARAM_file="$file" RECIPE_MIN_ENGINE_VERSION="1.0.0" \
        bash "$ADAPTER" 2>&1) || exit_code=$?

    local degraded
    degraded=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('degraded',''))" 2>/dev/null || echo "")
    assert_eq "test_degraded_when_version_below_minimum: degraded=true" "True" "$degraded"

    local ec
    ec=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('exit_code',''))" 2>/dev/null || echo "")
    assert_eq "test_degraded_when_version_below_minimum: exit_code=2" "2" "$ec"
}

# test_success_path_valid_json
# When mock synvert exits 0 (no file changes), adapter exits 0 with valid JSON.
test_success_path_valid_json() {
    write_mock_synvert 0 "1.5.0"
    local fixture_dir="$TMPDIR_TEST/test_success"
    make_ruby_fixture "$fixture_dir"
    local file="$fixture_dir/main.rb"

    local output exit_code=0
    output=$(run_adapter "$file") || exit_code=$?

    local valid_json=0
    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && valid_json=1 || true
    assert_eq "test_success_path_valid_json: output is valid JSON" "1" "$valid_json"

    local ec
    ec=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('exit_code',''))" 2>/dev/null || echo "")
    assert_eq "test_success_path_valid_json: exit_code=0" "0" "$ec"

    local has_files_key=0
    echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('files_changed'), list)" 2>/dev/null && has_files_key=1 || true
    assert_eq "test_success_path_valid_json: files_changed is array" "1" "$has_files_key"
}

# test_failed_execution_structured_error
# When mock synvert exits non-zero, adapter exits 1 with structured error JSON.
test_failed_execution_structured_error() {
    write_mock_synvert 1 "1.5.0"
    local fixture_dir="$TMPDIR_TEST/test_fail"
    make_ruby_fixture "$fixture_dir"
    local file="$fixture_dir/main.rb"

    local output exit_code=0
    output=$(run_adapter "$file") || exit_code=$?

    assert_ne "test_failed_execution_structured_error: adapter exits non-zero" "0" "$exit_code"

    local ec
    ec=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('exit_code',''))" 2>/dev/null || echo "")
    assert_eq "test_failed_execution_structured_error: exit_code=1 in JSON" "1" "$ec"

    local has_error=0
    echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d.get('errors',[]))>0" 2>/dev/null && has_error=1 || true
    assert_eq "test_failed_execution_structured_error: errors non-empty" "1" "$has_error"
}

# test_missing_file_param_exits_error
# When RECIPE_PARAM_file is missing, adapter exits 1 with errors.
test_missing_file_param_exits_error() {
    write_mock_synvert 0 "1.5.0"

    local output exit_code=0
    output=$(PATH="$MOCK_BIN:$PATH" bash "$ADAPTER" 2>&1) || exit_code=$?

    assert_ne "test_missing_file_param_exits_error: exits non-zero" "0" "$exit_code"
}

# test_unsafe_path_rejected
# When RECIPE_PARAM_file contains Ruby metacharacters, adapter exits 1 with error.
# This guards against injection via the _REL_PATH embedded in the snippet heredoc.
test_unsafe_path_rejected() {
    write_mock_synvert 0 "1.5.0"
    local fixture_dir="$TMPDIR_TEST/test_inject"
    make_ruby_fixture "$fixture_dir"

    # Construct a path with a double-quote character (Ruby string injection vector)
    local unsafe_file=''"$fixture_dir"'/foo"bar.rb'

    local output exit_code=0
    output=$(PATH="$MOCK_BIN:$PATH" RECIPE_PARAM_file="$unsafe_file" \
        RECIPE_PARAM_project_root="$fixture_dir" bash "$ADAPTER" 2>&1) || exit_code=$?

    assert_ne "test_unsafe_path_rejected: exits non-zero" "0" "$exit_code"

    local has_error=0
    echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d.get('errors',[]))>0" 2>/dev/null && has_error=1 || true
    assert_eq "test_unsafe_path_rejected: errors non-empty" "1" "$has_error"
}

# Run all tests
test_degraded_when_synvert_missing
test_degraded_when_version_below_minimum
test_success_path_valid_json
test_failed_execution_structured_error
test_missing_file_param_exits_error
test_unsafe_path_rejected

print_summary
