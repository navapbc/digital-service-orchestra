#!/usr/bin/env bash
# tests/unit/scripts/test-prefill-config.sh
# TDD RED tests for plugins/dso/scripts/prefill-config.sh
#
# Tests verify the prefill-config.sh contract:
#   1. test_node_prefill   — package.json → Node defaults written to dso-config.conf
#   2. test_ruby_prefill   — Gemfile (+_config.yml) → Ruby defaults written
#   3. test_python_prefill — pyproject.toml → Python defaults written
#   4. test_rust_prefill   — Cargo.toml → empty strings with inline comment
#   5. test_unknown_prefill — no markers → empty strings with comment
#   6. test_rerun_preservation — pre-existing custom value preserved, [DSO INFO] emitted
#
# These tests FAIL on current codebase because prefill-config.sh does not yet exist.
#
# Usage: bash tests/unit/scripts/test-prefill-config.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PREFILL_SCRIPT="$REPO_ROOT/plugins/dso/scripts/prefill-config.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-prefill-config.sh ==="

# ── Helper: create temp project dir + config, run prefill, return dir path ─────
# Usage: _run_prefill <fixture_setup_func> → sets FIXTURE_DIR and CONF_FILE
_setup_fixture() {
    FIXTURE_DIR="$(mktemp -d)"
    CONF_FILE="$FIXTURE_DIR/dso-config.conf"
}

_cleanup_fixture() {
    [[ -n "${FIXTURE_DIR:-}" ]] && rm -rf "$FIXTURE_DIR"
}

# ── Presence check helper ──────────────────────────────────────────────────────
# Returns 1 if the script is missing/non-executable, printing a failure message.
_require_prefill_script() {
    local test_name="$1"
    if [[ ! -x "$PREFILL_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  prefill-config.sh not found or not executable: %s\n" \
            "$test_name" "$PREFILL_SCRIPT" >&2
        return 1
    fi
    return 0
}

# ── Test 1: Node (node-npm) → Node defaults ────────────────────────────────────
test_node_prefill() {
    _snapshot_fail
    _setup_fixture
    trap '_cleanup_fixture' RETURN

    # detect-stack.sh requires package.json with valid JSON → node-npm
    printf '{"name": "my-app", "version": "1.0.0"}\n' > "$FIXTURE_DIR/package.json"

    _require_prefill_script "test_node_prefill" || {
        assert_pass_if_clean "test_node_prefill"
        return
    }

    # Run prefill-config.sh targeting the fixture dir
    bash "$PREFILL_SCRIPT" "$FIXTURE_DIR" 2>/dev/null

    local conf_content
    conf_content="$(cat "$CONF_FILE" 2>/dev/null || echo "")"

    assert_contains "node: test_runner" "commands.test_runner=npx jest" "$conf_content"
    assert_contains "node: lint" "commands.lint=npx eslint ." "$conf_content"
    assert_contains "node: format" "commands.format=npx prettier --write ." "$conf_content"
    assert_contains "node: format_check" "commands.format_check=npx prettier --check ." "$conf_content"

    assert_pass_if_clean "test_node_prefill"
}

# ── Test 2: Ruby (ruby-jekyll) → Ruby defaults ────────────────────────────────
test_ruby_prefill() {
    _snapshot_fail
    _setup_fixture
    trap '_cleanup_fixture' RETURN

    # detect-stack.sh: Gemfile + _config.yml → ruby-jekyll
    printf 'source "https://rubygems.org"\ngem "jekyll"\n' > "$FIXTURE_DIR/Gemfile"
    printf 'title: My Jekyll Site\n' > "$FIXTURE_DIR/_config.yml"

    _require_prefill_script "test_ruby_prefill" || {
        assert_pass_if_clean "test_ruby_prefill"
        return
    }

    bash "$PREFILL_SCRIPT" "$FIXTURE_DIR" 2>/dev/null

    local conf_content
    conf_content="$(cat "$CONF_FILE" 2>/dev/null || echo "")"

    # Ruby defaults should contain bundle exec commands
    assert_contains "ruby: test_runner key" "commands.test_runner=" "$conf_content"
    assert_contains "ruby: lint key" "commands.lint=" "$conf_content"
    assert_contains "ruby: format key" "commands.format=" "$conf_content"
    assert_contains "ruby: format_check key" "commands.format_check=" "$conf_content"
    # Ruby-specific: expect bundle exec or rubocop
    assert_contains "ruby: bundle or rubocop" "bundle" "$conf_content"

    assert_pass_if_clean "test_ruby_prefill"
}

# ── Test 3: Python (python-poetry) → Python defaults ─────────────────────────
test_python_prefill() {
    _snapshot_fail
    _setup_fixture
    trap '_cleanup_fixture' RETURN

    # detect-stack.sh: pyproject.toml with [tool.poetry] → python-poetry
    cat > "$FIXTURE_DIR/pyproject.toml" <<'TOML'
[tool.poetry]
name = "my-app"
version = "0.1.0"
TOML

    _require_prefill_script "test_python_prefill" || {
        assert_pass_if_clean "test_python_prefill"
        return
    }

    bash "$PREFILL_SCRIPT" "$FIXTURE_DIR" 2>/dev/null

    local conf_content
    conf_content="$(cat "$CONF_FILE" 2>/dev/null || echo "")"

    # Python defaults: poetry run pytest, ruff check, ruff format
    assert_contains "python: test_runner" "commands.test_runner=" "$conf_content"
    assert_contains "python: lint" "commands.lint=" "$conf_content"
    assert_contains "python: format" "commands.format=" "$conf_content"
    assert_contains "python: format_check" "commands.format_check=" "$conf_content"
    # Python-specific: poetry or pytest
    assert_contains "python: pytest or poetry" "pytest" "$conf_content"

    assert_pass_if_clean "test_python_prefill"
}

# ── Test 4: Rust (rust-cargo) → empty strings with inline comment ─────────────
test_rust_prefill() {
    _snapshot_fail
    _setup_fixture
    trap '_cleanup_fixture' RETURN

    # detect-stack.sh: Cargo.toml (non-empty) → rust-cargo
    cat > "$FIXTURE_DIR/Cargo.toml" <<'TOML'
[package]
name = "my-crate"
version = "0.1.0"
TOML

    _require_prefill_script "test_rust_prefill" || {
        assert_pass_if_clean "test_rust_prefill"
        return
    }

    bash "$PREFILL_SCRIPT" "$FIXTURE_DIR" 2>/dev/null

    local conf_content
    conf_content="$(cat "$CONF_FILE" 2>/dev/null || echo "")"

    # Rust: all commands.* keys present, values are empty strings
    assert_contains "rust: test_runner key" "commands.test_runner=" "$conf_content"
    assert_contains "rust: lint key" "commands.lint=" "$conf_content"
    assert_contains "rust: format key" "commands.format=" "$conf_content"
    assert_contains "rust: format_check key" "commands.format_check=" "$conf_content"
    # Inline comment indicating manual configuration required
    assert_contains "rust: inline comment" "#" "$conf_content"

    assert_pass_if_clean "test_rust_prefill"
}

# ── Test 5: Unknown (no markers) → empty strings with comment ─────────────────
test_unknown_prefill() {
    _snapshot_fail
    _setup_fixture
    trap '_cleanup_fixture' RETURN

    # Empty fixture dir → detect-stack.sh returns 'unknown'
    # (no package.json, Gemfile, pyproject.toml, Cargo.toml, go.mod, Makefile)

    _require_prefill_script "test_unknown_prefill" || {
        assert_pass_if_clean "test_unknown_prefill"
        return
    }

    bash "$PREFILL_SCRIPT" "$FIXTURE_DIR" 2>/dev/null

    local conf_content
    conf_content="$(cat "$CONF_FILE" 2>/dev/null || echo "")"

    # Unknown: all commands.* keys present with empty values and explanatory comment
    assert_contains "unknown: test_runner key" "commands.test_runner=" "$conf_content"
    assert_contains "unknown: lint key" "commands.lint=" "$conf_content"
    assert_contains "unknown: format key" "commands.format=" "$conf_content"
    assert_contains "unknown: format_check key" "commands.format_check=" "$conf_content"
    # Should have a comment explaining manual config required
    assert_contains "unknown: has comment" "#" "$conf_content"

    assert_pass_if_clean "test_unknown_prefill"
}

# ── Test 6: Re-run preservation — custom value preserved, [DSO INFO] emitted ──
test_rerun_preservation() {
    _snapshot_fail
    _setup_fixture
    trap '_cleanup_fixture' RETURN

    # Node fixture so stack is detectable
    printf '{"name": "my-app", "version": "1.0.0"}\n' > "$FIXTURE_DIR/package.json"

    _require_prefill_script "test_rerun_preservation" || {
        assert_pass_if_clean "test_rerun_preservation"
        return
    }

    # Pre-seed dso-config.conf with a custom test_runner value
    cat > "$CONF_FILE" <<'CONF'
# dso-config.conf
commands.test_runner=my-custom-cmd
CONF

    local stdout_output
    stdout_output="$(bash "$PREFILL_SCRIPT" "$FIXTURE_DIR" 2>/dev/null)"

    local conf_content
    conf_content="$(cat "$CONF_FILE" 2>/dev/null || echo "")"

    # Custom value must be preserved
    assert_contains "preserve: custom test_runner" "commands.test_runner=my-custom-cmd" "$conf_content"

    # stdout must contain [DSO INFO] for the already-set key
    assert_contains "preserve: DSO INFO emitted" "[DSO INFO]" "$stdout_output"
    assert_contains "preserve: mentions test_runner" "commands.test_runner" "$stdout_output"

    assert_pass_if_clean "test_rerun_preservation"
}

# ── Run all tests ──────────────────────────────────────────────────────────────

test_node_prefill
test_ruby_prefill
test_python_prefill
test_rust_prefill
test_unknown_prefill
test_rerun_preservation

print_summary
