#!/usr/bin/env bash
# tests/hooks/test-design-md-lint.sh
# Tests for hooks/pre-commit-design-md-lint.sh
#
# The pre-commit hook is a thin wrapper that:
#   1. Fails open on timeout (SIGTERM/SIGURG).
#   2. Short-circuits when ci-pr enforcement mode is active.
#   3. Delegates to $PLUGIN_ROOT/scripts/design-md-lint.sh and propagates exit code.
#   4. Fails open (exit 0) when design-md-lint.sh is missing.
#
# Tests:
#   [test_design_md_lint_hook] test_hook_file_is_executable
#   [test_design_md_lint_hook] test_hook_exits_zero_when_lint_script_missing
#   [test_design_md_lint_hook] test_hook_propagates_exit_zero_from_lint_script
#   [test_design_md_lint_hook] test_hook_propagates_nonzero_from_lint_script
#   [test_design_md_lint_hook] test_hook_skips_in_ci_pr_mode

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-design-md-lint.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Prerequisite check ───────────────────────────────────────────────────────
if [[ ! -f "$HOOK" ]]; then
    echo "SKIP: pre-commit-design-md-lint.sh not found at $HOOK"
    exit 0
fi

# ── Helper: create a fake dso-config.conf with a given workflow value ─────────
make_config_file() {
    local workflow="$1"
    local tmpfile
    tmpfile=$(mktemp /tmp/dso-config.XXXXXX)
    _TEST_TMPDIRS+=("$tmpfile")
    echo "dso.workflow=${workflow}" > "$tmpfile"
    echo "$tmpfile"
}

# ── Helper: create a fake plugin dir with a stub design-md-lint.sh ───────────
make_fake_plugin_with_lint_script() {
    local exit_code="$1"
    local fake_plugin
    fake_plugin=$(mktemp -d)
    _TEST_TMPDIRS+=("$fake_plugin")
    mkdir -p "$fake_plugin/scripts"
    cat > "$fake_plugin/scripts/design-md-lint.sh" <<EOF
#!/usr/bin/env bash
exit ${exit_code}
EOF
    chmod +x "$fake_plugin/scripts/design-md-lint.sh"
    echo "$fake_plugin"
}

# ── Test: hook file is executable ────────────────────────────────────────────
test_hook_file_is_executable() {
    if [[ -x "$HOOK" ]]; then
        assert_eq "[test_design_md_lint_hook] test_hook_file_is_executable" "executable" "executable"
    else
        assert_eq "[test_design_md_lint_hook] test_hook_file_is_executable" "executable" "not-executable"
    fi
}

# ── Test: hook exits 0 (fail-open) when lint script is missing ───────────────
test_hook_exits_zero_when_lint_script_missing() {
    local config_file
    config_file=$(make_config_file "local")

    # Create a fake plugin dir with NO design-md-lint.sh
    local fake_plugin
    fake_plugin=$(mktemp -d)
    _TEST_TMPDIRS+=("$fake_plugin")
    mkdir -p "$fake_plugin/scripts"

    local output exit_code
    output=$(WORKFLOW_CONFIG_FILE="$config_file" CLAUDE_PLUGIN_ROOT="$fake_plugin" bash "$HOOK" 2>&1)
    exit_code=$?

    assert_eq "[test_design_md_lint_hook] test_hook_exits_zero_when_lint_script_missing:exit" "0" "$exit_code"
    assert_contains "[test_design_md_lint_hook] test_hook_exits_zero_when_lint_script_missing:warn" "WARNING" "$output"
}

# ── Test: hook propagates exit 0 from lint script ────────────────────────────
test_hook_propagates_exit_zero_from_lint_script() {
    local config_file
    config_file=$(make_config_file "local")

    local fake_plugin
    fake_plugin=$(make_fake_plugin_with_lint_script "0")

    local exit_code
    WORKFLOW_CONFIG_FILE="$config_file" CLAUDE_PLUGIN_ROOT="$fake_plugin" bash "$HOOK" 2>&1
    exit_code=$?

    assert_eq "[test_design_md_lint_hook] test_hook_propagates_exit_zero_from_lint_script" "0" "$exit_code"
}

# ── Test: hook propagates non-zero from lint script ──────────────────────────
test_hook_propagates_nonzero_from_lint_script() {
    local config_file
    config_file=$(make_config_file "local")

    local fake_plugin
    fake_plugin=$(make_fake_plugin_with_lint_script "1")

    local exit_code
    WORKFLOW_CONFIG_FILE="$config_file" CLAUDE_PLUGIN_ROOT="$fake_plugin" bash "$HOOK" 2>&1
    exit_code=$?

    assert_eq "[test_design_md_lint_hook] test_hook_propagates_nonzero_from_lint_script" "1" "$exit_code"
}

# ── Test: hook skips (exits 0) in ci-pr enforcement mode ─────────────────────
test_hook_skips_in_ci_pr_mode() {
    local config_file
    config_file=$(make_config_file "ci-pr")

    # design-md-lint.sh exits 1 — should NOT be reached in ci-pr mode
    local fake_plugin
    fake_plugin=$(make_fake_plugin_with_lint_script "1")

    local exit_code
    WORKFLOW_CONFIG_FILE="$config_file" CLAUDE_PLUGIN_ROOT="$fake_plugin" bash "$HOOK" 2>&1
    exit_code=$?

    assert_eq "[test_design_md_lint_hook] test_hook_skips_in_ci_pr_mode" "0" "$exit_code"
}

# ── Run tests ────────────────────────────────────────────────────────────────
test_hook_file_is_executable
test_hook_exits_zero_when_lint_script_missing
test_hook_propagates_exit_zero_from_lint_script
test_hook_propagates_nonzero_from_lint_script
test_hook_skips_in_ci_pr_mode

print_summary
