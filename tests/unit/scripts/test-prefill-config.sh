#!/usr/bin/env bash
# tests/unit/scripts/test-prefill-config.sh
# TDD RED tests for plugins/dso/scripts/onboarding/prefill-config.sh
#
# Tests verify the prefill-config script:
#   1. Writes correct defaults for a Node/JS stack
#   2. Writes correct defaults for a Python stack
#   3. Writes correct defaults for a Ruby stack
#   4. Writes empty strings with inline comment for Rust/unknown stacks
#   5. Skips (emits [DSO INFO] log) for keys that already have a value
#   6. Is executable
#
# Approach: create temp project dirs with stack-marker files + temp config;
# run prefill-config.sh against them; assert expected config values.
#
# Usage: bash tests/unit/scripts/test-prefill-config.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PREFILL_SCRIPT="$REPO_ROOT/plugins/dso/scripts/onboarding/prefill-config.sh"
DETECT_STACK="$REPO_ROOT/plugins/dso/scripts/detect-stack.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-prefill-config.sh ==="

# ── Helper ────────────────────────────────────────────────────────────────────
# _read_config_key <conf_file> <key>  → prints value or empty string
_read_config_key() {
    local conf_file="$1" key="$2"
    grep -m1 "^${key}=" "$conf_file" | cut -d= -f2- 2>/dev/null || true
}

# ── Test 1: Node/JS defaults written correctly ────────────────────────────────

test_node_prefill() {
    _snapshot_fail

    if [[ ! -x "$PREFILL_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_node_prefill\n  prefill script not found or not executable: %s\n" "$PREFILL_SCRIPT" >&2
        assert_pass_if_clean "test_node_prefill"
        return
    fi

    local proj_dir conf_file
    proj_dir="$(mktemp -d)"
    conf_file="$(mktemp)"
    trap 'rm -rf "$proj_dir" "$conf_file"' RETURN

    # Create a Node/JS project marker
    echo '{"name":"test"}' > "$proj_dir/package.json"

    WORKFLOW_CONFIG_FILE="$conf_file" \
        bash "$PREFILL_SCRIPT" --project-dir "$proj_dir" >/dev/null 2>&1

    assert_eq "node: test_runner" "npx jest" "$(_read_config_key "$conf_file" "commands.test_runner")"
    assert_eq "node: lint"        "npx eslint ." "$(_read_config_key "$conf_file" "commands.lint")"
    assert_eq "node: format"      "npx prettier --write ." "$(_read_config_key "$conf_file" "commands.format")"
    assert_eq "node: format_check" "npx prettier --check ." "$(_read_config_key "$conf_file" "commands.format_check")"

    assert_pass_if_clean "test_node_prefill"
}

# ── Test 2: Python defaults written correctly ─────────────────────────────────

test_python_prefill() {
    _snapshot_fail

    if [[ ! -x "$PREFILL_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_python_prefill\n  prefill script not found or not executable: %s\n" "$PREFILL_SCRIPT" >&2
        assert_pass_if_clean "test_python_prefill"
        return
    fi

    local proj_dir conf_file
    proj_dir="$(mktemp -d)"
    conf_file="$(mktemp)"
    trap 'rm -rf "$proj_dir" "$conf_file"' RETURN

    # Create a Python project marker
    printf '[project]\nname = "myapp"\n' > "$proj_dir/pyproject.toml"

    WORKFLOW_CONFIG_FILE="$conf_file" \
        bash "$PREFILL_SCRIPT" --project-dir "$proj_dir" >/dev/null 2>&1

    assert_eq "python: test_runner" "pytest" "$(_read_config_key "$conf_file" "commands.test_runner")"
    assert_eq "python: lint"        "ruff check ." "$(_read_config_key "$conf_file" "commands.lint")"
    assert_eq "python: format"      "ruff format ." "$(_read_config_key "$conf_file" "commands.format")"
    assert_eq "python: format_check" "ruff format --check ." "$(_read_config_key "$conf_file" "commands.format_check")"

    assert_pass_if_clean "test_python_prefill"
}

# ── Test 3: Ruby defaults written correctly ───────────────────────────────────

test_ruby_prefill() {
    _snapshot_fail

    if [[ ! -x "$PREFILL_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_ruby_prefill\n  prefill script not found or not executable: %s\n" "$PREFILL_SCRIPT" >&2
        assert_pass_if_clean "test_ruby_prefill"
        return
    fi

    local proj_dir conf_file
    proj_dir="$(mktemp -d)"
    conf_file="$(mktemp)"
    trap 'rm -rf "$proj_dir" "$conf_file"' RETURN

    # Create a Ruby/Rails project marker
    echo "source 'https://rubygems.org'" > "$proj_dir/Gemfile"
    mkdir -p "$proj_dir/config"
    touch "$proj_dir/config/routes.rb"

    WORKFLOW_CONFIG_FILE="$conf_file" \
        bash "$PREFILL_SCRIPT" --project-dir "$proj_dir" >/dev/null 2>&1

    assert_eq "ruby: test_runner" "bundle exec rspec" "$(_read_config_key "$conf_file" "commands.test_runner")"
    assert_eq "ruby: lint"        "bundle exec rubocop" "$(_read_config_key "$conf_file" "commands.lint")"
    assert_eq "ruby: format"      "bundle exec rubocop -A" "$(_read_config_key "$conf_file" "commands.format")"
    assert_eq "ruby: format_check" "bundle exec rubocop --format simple" "$(_read_config_key "$conf_file" "commands.format_check")"

    assert_pass_if_clean "test_ruby_prefill"
}

# ── Test 4: Unknown/Rust stack writes empty values with comment ───────────────

test_unknown_prefill() {
    _snapshot_fail

    if [[ ! -x "$PREFILL_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_unknown_prefill\n  prefill script not found or not executable: %s\n" "$PREFILL_SCRIPT" >&2
        assert_pass_if_clean "test_unknown_prefill"
        return
    fi

    local proj_dir conf_file out
    proj_dir="$(mktemp -d)"
    conf_file="$(mktemp)"
    trap 'rm -rf "$proj_dir" "$conf_file"' RETURN

    # Empty project — no markers → 'unknown' stack
    WORKFLOW_CONFIG_FILE="$conf_file" \
        bash "$PREFILL_SCRIPT" --project-dir "$proj_dir" >/dev/null 2>&1

    # Values should be empty (key written as 'commands.test_runner=' with no value)
    assert_eq "unknown: test_runner empty" "" "$(_read_config_key "$conf_file" "commands.test_runner")"
    assert_eq "unknown: lint empty"        "" "$(_read_config_key "$conf_file" "commands.lint")"

    # Config file should contain the comment line explaining why defaults are absent
    local conf_content
    conf_content="$(cat "$conf_file")"
    assert_contains "unknown: comment present" "# no default defined for unknown" "$conf_content"

    assert_pass_if_clean "test_unknown_prefill"
}

# ── Test 5: Existing non-empty key is skipped, emitting [DSO INFO] ─────────────

test_skip_existing_key() {
    _snapshot_fail

    if [[ ! -x "$PREFILL_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_skip_existing_key\n  prefill script not found or not executable: %s\n" "$PREFILL_SCRIPT" >&2
        assert_pass_if_clean "test_skip_existing_key"
        return
    fi

    local proj_dir conf_file log_out
    proj_dir="$(mktemp -d)"
    conf_file="$(mktemp)"
    trap 'rm -rf "$proj_dir" "$conf_file"' RETURN

    # Pre-populate test_runner in the config
    echo "commands.test_runner=my-custom-runner" > "$conf_file"

    # Node/JS project
    echo '{"name":"test"}' > "$proj_dir/package.json"

    log_out=$(WORKFLOW_CONFIG_FILE="$conf_file" \
        bash "$PREFILL_SCRIPT" --project-dir "$proj_dir" 2>&1)

    # The pre-existing value must be preserved unchanged
    assert_eq "skip: test_runner preserved" "my-custom-runner" "$(_read_config_key "$conf_file" "commands.test_runner")"

    # [DSO INFO] message must be emitted for the skipped key
    assert_contains "skip: DSO INFO emitted" "[DSO INFO] commands.test_runner already set — skipping" "$log_out"

    # Other keys (empty/absent) should still be written with Node defaults
    assert_eq "skip: lint written" "npx eslint ." "$(_read_config_key "$conf_file" "commands.lint")"

    assert_pass_if_clean "test_skip_existing_key"
}

# ── Test 6: Script is executable ─────────────────────────────────────────────

test_prefill_script_is_executable() {
    _snapshot_fail

    if [[ -x "$PREFILL_SCRIPT" ]]; then
        assert_eq "executable" "yes" "yes"
    else
        (( ++FAIL ))
        printf "FAIL: test_prefill_script_is_executable\n  not executable: %s\n" "$PREFILL_SCRIPT" >&2
    fi

    assert_pass_if_clean "test_prefill_script_is_executable"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_node_prefill
test_python_prefill
test_ruby_prefill
test_unknown_prefill
test_skip_existing_key
test_prefill_script_is_executable

print_summary
