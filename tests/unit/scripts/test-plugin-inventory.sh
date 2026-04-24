#!/usr/bin/env bash
# tests/unit/scripts/test-plugin-inventory.sh
# Behavioral tests for plugins/dso/scripts/onboarding/plugin-inventory.sh
#
# Tests verify observable behavior:
#   1. Default (JSON) output contains plugin_root, hooks, scripts, skills keys
#   2. --format json emits valid JSON with expected structure
#   3. --format table emits a human-readable table with "Component" header
#   4. --format=json (= form) is equivalent to --format json
#   5. Unknown --format argument exits 1 with error message
#   6. Unknown argument exits 1 with error message
#   7. -h/--help prints usage and exits 0
#   8. Script is executable
#
# Usage: bash tests/unit/scripts/test-plugin-inventory.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/onboarding/plugin-inventory.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-plugin-inventory.sh ==="

# ── Test 1: Default output (no flags) contains JSON structural keys ───────────

test_default_output_is_json_with_required_keys() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_default_output_is_json_with_required_keys\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_default_output_is_json_with_required_keys"
        return
    fi

    local out
    out=$(bash "$SCRIPT" 2>/dev/null)

    assert_contains "default: plugin_root key present" '"plugin_root"' "$out"
    assert_contains "default: hooks key present"       '"hooks"'       "$out"
    assert_contains "default: scripts key present"     '"scripts"'     "$out"
    assert_contains "default: skills key present"      '"skills"'      "$out"

    assert_pass_if_clean "test_default_output_is_json_with_required_keys"
}

# ── Test 2: --format json output is parseable JSON ────────────────────────────

test_format_json_is_valid_json() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_format_json_is_valid_json\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_format_json_is_valid_json"
        return
    fi

    local out parse_exit=0
    out=$(bash "$SCRIPT" --format json 2>/dev/null)
    printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null || parse_exit=$?

    assert_eq "json format: valid JSON" "0" "$parse_exit"

    # The plugin_root value should be a non-empty string pointing to a real dir
    local root
    root=$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['plugin_root'])" 2>/dev/null || true)
    assert_ne "json format: plugin_root is non-empty" "" "$root"

    # hooks, scripts, skills must be JSON arrays
    local hooks_type
    hooks_type=$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(type(d['hooks']).__name__)" 2>/dev/null || echo "error")
    assert_eq "json format: hooks is array" "list" "$hooks_type"

    local scripts_type
    scripts_type=$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(type(d['scripts']).__name__)" 2>/dev/null || echo "error")
    assert_eq "json format: scripts is array" "list" "$scripts_type"

    local skills_type
    skills_type=$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(type(d['skills']).__name__)" 2>/dev/null || echo "error")
    assert_eq "json format: skills is array" "list" "$skills_type"

    assert_pass_if_clean "test_format_json_is_valid_json"
}

# ── Test 3: --format table emits human-readable table with Component header ───

test_format_table_contains_header() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_format_table_contains_header\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_format_table_contains_header"
        return
    fi

    local out exit_code=0
    out=$(bash "$SCRIPT" --format table 2>/dev/null) || exit_code=$?

    assert_eq "table format: exits 0" "0" "$exit_code"
    assert_contains "table format: Component header" "Component" "$out"
    assert_contains "table format: Type column header" "Type" "$out"

    assert_pass_if_clean "test_format_table_contains_header"
}

# ── Test 4: --format=json (equals form) works equivalently ───────────────────

test_format_equals_form_works() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_format_equals_form_works\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_format_equals_form_works"
        return
    fi

    local out exit_code=0
    out=$(bash "$SCRIPT" --format=json 2>/dev/null) || exit_code=$?

    assert_eq "format=json: exits 0" "0" "$exit_code"
    assert_contains "format=json: hooks key present" '"hooks"' "$out"

    assert_pass_if_clean "test_format_equals_form_works"
}

# ── Test 5: Unknown --format value exits 1 with error on stderr ──────────────

test_unknown_format_exits_1_with_error() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_unknown_format_exits_1_with_error\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_unknown_format_exits_1_with_error"
        return
    fi

    local stderr_out exit_code=0
    stderr_out=$(bash "$SCRIPT" --format bogus 2>&1 >/dev/null) || exit_code=$?

    assert_eq "unknown format: exits 1" "1" "$exit_code"
    assert_contains "unknown format: error message on stderr" "Error" "$stderr_out"

    assert_pass_if_clean "test_unknown_format_exits_1_with_error"
}

# ── Test 6: Unknown argument exits 1 with error on stderr ────────────────────

test_unknown_argument_exits_1_with_error() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_unknown_argument_exits_1_with_error\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_unknown_argument_exits_1_with_error"
        return
    fi

    local stderr_out exit_code=0
    stderr_out=$(bash "$SCRIPT" --not-a-real-flag 2>&1 >/dev/null) || exit_code=$?

    assert_eq "unknown arg: exits 1" "1" "$exit_code"
    assert_contains "unknown arg: error message on stderr" "Error" "$stderr_out"

    assert_pass_if_clean "test_unknown_argument_exits_1_with_error"
}

# ── Test 7: --help exits 0 and prints usage ───────────────────────────────────

test_help_flag_exits_0_with_usage() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_help_flag_exits_0_with_usage\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_help_flag_exits_0_with_usage"
        return
    fi

    local out exit_code=0
    out=$(bash "$SCRIPT" --help 2>&1) || exit_code=$?

    assert_eq "help: exits 0" "0" "$exit_code"
    assert_contains "help: Usage in output" "Usage" "$out"

    assert_pass_if_clean "test_help_flag_exits_0_with_usage"
}

# ── Test 8: JSON output includes at least one script entry (the script itself) ─

test_json_scripts_array_is_nonempty() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_json_scripts_array_is_nonempty\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_json_scripts_array_is_nonempty"
        return
    fi

    local out
    out=$(bash "$SCRIPT" --format json 2>/dev/null)

    local count
    count=$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['scripts']))" 2>/dev/null || echo "0")

    # The plugin has several scripts; count must be > 0
    local is_positive=0
    [[ "$count" -gt 0 ]] 2>/dev/null && is_positive=1 || true

    assert_eq "scripts: array is non-empty" "1" "$is_positive"

    assert_pass_if_clean "test_json_scripts_array_is_nonempty"
}

# ── Test 9: Script is executable ─────────────────────────────────────────────

test_plugin_inventory_is_executable() {
    _snapshot_fail

    if [[ -x "$SCRIPT" ]]; then
        assert_eq "executable" "yes" "yes"
    else
        (( ++FAIL ))
        printf "FAIL: test_plugin_inventory_is_executable\n  not executable: %s\n" "$SCRIPT" >&2
    fi

    assert_pass_if_clean "test_plugin_inventory_is_executable"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_default_output_is_json_with_required_keys
test_format_json_is_valid_json
test_format_table_contains_header
test_format_equals_form_works
test_unknown_format_exits_1_with_error
test_unknown_argument_exits_1_with_error
test_help_flag_exits_0_with_usage
test_json_scripts_array_is_nonempty
test_plugin_inventory_is_executable

print_summary
