#!/usr/bin/env bash
# tests/scripts/test-commit-step.sh
# RED-phase tests for plugins/dso/scripts/commit-step.sh (does not exist yet).
# All tests must FAIL until the implementation is written (T2).
#
# REVIEW-DEFENSE (PR #78 cycle-2 finding 5): tests assert field presence, not type
# correctness (exit_code is integer, timestamp is ISO 8601, etc.). Type validation
# would be a change-detector: the behavioral contract is "file written with expected
# fields" not "field X has type Y". The Python failure guard added in finding-3 fix
# (cycle 1) closes the primary corruption path. Per the behavioral testing standard,
# tests should focus on observable outcomes, not internal JSON schema enforcement.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$SCRIPT_DIR/../lib/assert.sh"

SCRIPT="$REPO_ROOT/plugins/dso/scripts/commit-step.sh"

# ── Isolation: each test gets a fresh artifacts dir ──
_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup_tmpdirs EXIT

_make_artifacts_dir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Test 1: test_writes_result_artifact ──
# Given: WORKFLOW_PLUGIN_ARTIFACTS_DIR set to a temp dir
# When: commit-step.sh lint 5 /bin/true is run
# Then: $ARTIFACTS_DIR/lint.result exists
test_writes_result_artifact() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$SCRIPT" lint 5 /bin/true 2>/dev/null

    local result_file="$artifacts_dir/lint.result"
    local file_exists="no"
    [[ -f "$result_file" ]] && file_exists="yes"
    assert_eq "writes_result_artifact" "yes" "$file_exists"
}

# ── Test 2: test_result_json_fields ──
# Given: WORKFLOW_PLUGIN_ARTIFACTS_DIR set to a temp dir
# When: commit-step.sh lint 5 /bin/true is run
# Then: lint.result is valid JSON with fields: step, exit_code, stdout, stderr, timestamp
test_result_json_fields() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$SCRIPT" lint 5 /bin/true 2>/dev/null

    local result_file="$artifacts_dir/lint.result"
    local result_content=""
    [[ -f "$result_file" ]] && result_content=$(cat "$result_file")

    local has_step="no"
    local has_exit_code="no"
    local has_stdout="no"
    local has_stderr="no"
    local has_timestamp="no"

    if [[ -f "$result_file" ]]; then
        has_step=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print('yes' if 'step' in data else 'no')
except Exception:
    print('no')
" "$result_content" 2>/dev/null || echo "no")

        has_exit_code=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print('yes' if 'exit_code' in data else 'no')
except Exception:
    print('no')
" "$result_content" 2>/dev/null || echo "no")

        has_stdout=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print('yes' if 'stdout' in data else 'no')
except Exception:
    print('no')
" "$result_content" 2>/dev/null || echo "no")

        has_stderr=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print('yes' if 'stderr' in data else 'no')
except Exception:
    print('no')
" "$result_content" 2>/dev/null || echo "no")

        has_timestamp=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print('yes' if 'timestamp' in data else 'no')
except Exception:
    print('no')
" "$result_content" 2>/dev/null || echo "no")
    fi

    assert_eq "result_json_has_step" "yes" "$has_step"
    assert_eq "result_json_has_exit_code" "yes" "$has_exit_code"
    assert_eq "result_json_has_stdout" "yes" "$has_stdout"
    assert_eq "result_json_has_stderr" "yes" "$has_stderr"
    assert_eq "result_json_has_timestamp" "yes" "$has_timestamp"
}

# ── Test 3: test_appends_breadcrumb ──
# Given: WORKFLOW_PLUGIN_ARTIFACTS_DIR set to a temp dir
# When: commit-step.sh lint 5 /bin/true is run
# Then: $ARTIFACTS_DIR/steps.log exists and contains a line mentioning "lint"
test_appends_breadcrumb() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$SCRIPT" lint 5 /bin/true 2>/dev/null

    local log_file="$artifacts_dir/steps.log"
    local log_exists="no"
    [[ -f "$log_file" ]] && log_exists="yes"
    assert_eq "breadcrumb_log_exists" "yes" "$log_exists"

    local log_content=""
    [[ -f "$log_file" ]] && log_content=$(cat "$log_file")
    local log_mentions_lint="no"
    [[ "$log_content" == *"lint"* ]] && log_mentions_lint="yes"
    assert_eq "breadcrumb_log_mentions_lint" "yes" "$log_mentions_lint"
}

# ── Test 4: test_exit_144_writes_timeout ──
# Given: WORKFLOW_PLUGIN_ARTIFACTS_DIR set to a temp dir
# When: commit-step.sh lint 5 bash -c 'exit 144' is run
# Then: $ARTIFACTS_DIR/lint.timeout exists and lint.result does NOT exist
test_exit_144_writes_timeout() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$SCRIPT" lint 5 bash -c 'exit 144' 2>/dev/null

    local timeout_file="$artifacts_dir/lint.timeout"
    local result_file="$artifacts_dir/lint.result"

    local timeout_exists="no"
    [[ -f "$timeout_file" ]] && timeout_exists="yes"
    assert_eq "exit_144_writes_timeout_file" "yes" "$timeout_exists"

    local result_exists="no"
    [[ -f "$result_file" ]] && result_exists="yes"
    assert_eq "exit_144_does_not_write_result" "no" "$result_exists"
}

# ── Test 5: test_creates_artifacts_dir ──
# Given: WORKFLOW_PLUGIN_ARTIFACTS_DIR points to a non-existent subdirectory
# When: commit-step.sh lint 5 /bin/true is run
# Then: the directory is created and lint.result exists inside it
test_creates_artifacts_dir() {
    local base_dir
    base_dir=$(mktemp -d)
    _TEST_TMPDIRS+=("$base_dir")

    local artifacts_dir="$base_dir/subdir/artifacts"
    # Confirm the directory does NOT exist yet
    local dir_pre_exists="no"
    [[ -d "$artifacts_dir" ]] && dir_pre_exists="yes"
    assert_eq "artifacts_dir_does_not_exist_before" "no" "$dir_pre_exists"

    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$SCRIPT" lint 5 /bin/true 2>/dev/null

    local dir_exists="no"
    [[ -d "$artifacts_dir" ]] && dir_exists="yes"
    assert_eq "artifacts_dir_created" "yes" "$dir_exists"

    local result_file="$artifacts_dir/lint.result"
    local result_exists="no"
    [[ -f "$result_file" ]] && result_exists="yes"
    assert_eq "result_exists_in_created_dir" "yes" "$result_exists"
}

# ── Run all tests ──
test_writes_result_artifact
test_result_json_fields
test_appends_breadcrumb
test_exit_144_writes_timeout
test_creates_artifacts_dir

print_summary
