#!/usr/bin/env bash
# tests/scripts/test-shim-smoke.sh
# TDD red-phase tests for templates/host-project/dso shim script
#
# Verifies that the dso shim template exists, is POSIX-compatible, and
# correctly delegates to DSO scripts via CLAUDE_PLUGIN_ROOT or dso-config.conf.
#
# RED PHASE: All tests are expected to FAIL until templates/host-project/dso is created.
#
# Usage:
#   bash tests/scripts/test-shim-smoke.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SHIM="$DSO_PLUGIN_DIR/templates/host-project/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Temp dir setup ────────────────────────────────────────────────────────────
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

echo "=== test-shim-smoke.sh ==="

# ── test_shim_template_file_exists ────────────────────────────────────────────
# The shim must exist at templates/host-project/dso.
test_shim_template_file_exists() {
    if [[ -f "$SHIM" ]]; then
        assert_eq "test_shim_template_file_exists" "exists" "exists"
    else
        assert_eq "test_shim_template_file_exists" "exists" "missing"
    fi
}

# ── test_shim_is_executable ───────────────────────────────────────────────────
# The shim must be executable (chmod +x).
test_shim_is_executable() {
    if [[ -x "$SHIM" ]]; then
        assert_eq "test_shim_is_executable" "executable" "executable"
    else
        assert_eq "test_shim_is_executable" "executable" "not-executable"
    fi
}

# ── test_shim_no_nonposix_constructs ─────────────────────────────────────────
# The shim must not use readlink -f or realpath (GNU coreutils, not available on
# macOS without coreutils). Only POSIX-compatible path resolution is permitted.
test_shim_no_nonposix_constructs() {
    if [[ ! -f "$SHIM" ]]; then
        assert_eq "test_shim_no_nonposix_constructs" "posix-only" "file-missing"
        return
    fi
    if grep -qE 'readlink -f|realpath' "$SHIM"; then
        assert_eq "test_shim_no_nonposix_constructs" "posix-only" "has-nonposix"
    else
        assert_eq "test_shim_no_nonposix_constructs" "posix-only" "posix-only"
    fi
}

# ── test_shim_exits_0_with_valid_dso_root ─────────────────────────────────────
# When CLAUDE_PLUGIN_ROOT is set to the plugin root, invoking 'dso read-config.sh --help'
# must exit 0 (script is found and delegates successfully).
test_shim_exits_0_with_valid_dso_root() {
    if [[ ! -x "$SHIM" ]]; then
        assert_eq "test_shim_exits_0_with_valid_dso_root" "0" "shim-missing"
        return
    fi
    local exit_code=0
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" bash "$SHIM" read-config.sh --help >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_shim_exits_0_with_valid_dso_root" "0" "$exit_code"
}

# ── test_shim_exits_127_for_missing_script ───────────────────────────────────
# When CLAUDE_PLUGIN_ROOT is set but the requested script does not exist,
# the shim must exit 127 (command not found — POSIX convention).
test_shim_exits_127_for_missing_script() {
    if [[ ! -x "$SHIM" ]]; then
        assert_eq "test_shim_exits_127_for_missing_script" "127" "shim-missing"
        return
    fi
    local exit_code=0
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SHIM" nonexistent >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_shim_exits_127_for_missing_script" "127" "$exit_code"
}

# ── test_shim_error_names_missing_script ─────────────────────────────────────
# When the requested script does not exist, the shim's stderr message must
# include the name of the missing script so the user knows what was not found.
test_shim_error_names_missing_script() {
    if [[ ! -x "$SHIM" ]]; then
        assert_contains "test_shim_error_names_missing_script" "nonexistent" "shim-missing"
        return
    fi
    local stderr_output=""
    stderr_output=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SHIM" nonexistent 2>&1 >/dev/null) || true
    assert_contains "test_shim_error_names_missing_script" "nonexistent" "$stderr_output"
}

# ── test_shim_resolves_dso_root_from_config ───────────────────────────────────
# When CLAUDE_PLUGIN_ROOT is unset, the shim must read dso.plugin_root from
# .claude/dso-config.conf in the git repo root and use that path to find scripts.
test_shim_resolves_dso_root_from_config() {
    if [[ ! -x "$SHIM" ]]; then
        assert_eq "test_shim_resolves_dso_root_from_config" "0" "shim-missing"
        return
    fi
    # Create a minimal git repo with a .claude/dso-config.conf pointing at the real plugin
    local fake_repo="$TMPDIR_BASE/fake-repo"
    mkdir -p "$fake_repo/.claude"
    git -C "$fake_repo" init -q
    printf 'dso.plugin_root=%s\n' "$DSO_PLUGIN_DIR" > "$fake_repo/.claude/dso-config.conf"
    git -C "$fake_repo" add .claude/dso-config.conf
    git -c user.email=test@test.com -c user.name=Test -C "$fake_repo" commit -q -m "init"

    local exit_code=0
    # Run shim from inside the fake repo; CLAUDE_PLUGIN_ROOT unset to force config fallback
    (
        cd "$fake_repo"
        unset CLAUDE_PLUGIN_ROOT
        bash "$SHIM" read-config.sh --help >/dev/null 2>&1
    ) || exit_code=$?
    assert_eq "test_shim_resolves_dso_root_from_config" "0" "$exit_code"
}

# ── test_shim_error_names_config_key_when_no_dso_root ────────────────────────
# When CLAUDE_PLUGIN_ROOT is unset and no dso-config.conf provides
# dso.plugin_root, the shim must exit non-zero and print a message that
# names the 'dso.plugin_root' config key so the user knows how to fix it.
test_shim_error_names_config_key_when_no_dso_root() {
    if [[ ! -x "$SHIM" ]]; then
        # Shim missing — assert that it exists so test fails (RED)
        assert_eq "test_shim_error_names_config_key_when_no_dso_root (shim exists)" \
            "exists" "missing"
        return
    fi
    # Create a minimal git repo with NO dso-config.conf
    local empty_repo="$TMPDIR_BASE/empty-repo"
    mkdir -p "$empty_repo"
    git -C "$empty_repo" init -q
    git -c user.email=test@test.com -c user.name=Test -C "$empty_repo" commit --allow-empty -q -m "init"

    local exit_code=0
    local stderr_output=""
    stderr_output=$(
        cd "$empty_repo"
        unset CLAUDE_PLUGIN_ROOT
        bash "$SHIM" read-config.sh --help 2>&1 >/dev/null
    ) || exit_code=$?

    # Must exit non-zero
    assert_ne "test_shim_error_names_config_key_when_no_dso_root (exit code)" "0" "$exit_code"
    # Must name the config key so the user knows what to set
    assert_contains "test_shim_error_names_config_key_when_no_dso_root (message)" \
        "dso.plugin_root" "$stderr_output"
}

# ── test_lib_mode_exports_dso_root ───────────────────────────────────────────
# When the shim is sourced with --lib, it must export DSO_ROOT set to the
# plugin root (so callers can locate plugin scripts without exec-ing anything).
test_lib_mode_exports_dso_root() {
    if [[ ! -f "$SHIM" ]]; then
        assert_eq "test_lib_mode_exports_dso_root" "set" "shim-missing"; return
    fi
    local output
    output=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c ". \"$SHIM\" --lib; echo \"DSO_ROOT=\$DSO_ROOT\"" 2>/dev/null) || true
    assert_contains "test_lib_mode_exports_dso_root" "$PLUGIN_ROOT" "$output"
}

# ── test_lib_mode_produces_no_stdout ─────────────────────────────────────────
# When the shim is sourced with --lib, it must produce no stdout output
# (it is being used as a library, not a command dispatcher).
# The helper also exits 0 explicitly; if the sourced shim calls exit/exec with
# non-zero, the subshell exits non-zero and the test must fail.
test_lib_mode_produces_no_stdout() {
    if [[ ! -f "$SHIM" ]]; then
        assert_eq "test_lib_mode_produces_no_stdout" "" "shim-missing"; return
    fi
    local stdout
    stdout=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c ". \"$SHIM\" --lib" 2>/dev/null) || true
    assert_eq "test_lib_mode_produces_no_stdout" "" "$stdout"
}

# ── test_lib_mode_does_not_dispatch ──────────────────────────────────────────
# When the shim is sourced with --lib and the caller then exits 0,
# the exit code must be 0 (the shim must not exec or dispatch anything).
test_lib_mode_does_not_dispatch() {
    if [[ ! -f "$SHIM" ]]; then
        assert_eq "test_lib_mode_does_not_dispatch" "0" "shim-missing"; return
    fi
    local exit_code=0
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c ". \"$SHIM\" --lib 2>/dev/null; exit 0" >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_lib_mode_does_not_dispatch" "0" "$exit_code"
}

# ── test_lib_mode_exec_exits_zero ────────────────────────────────────────────
# When the shim is executed (not sourced) with --lib, it must exit 0.
test_lib_mode_exec_exits_zero() {
    local exit_code=0
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SHIM" --lib >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_lib_mode_exec_exits_zero" "0" "$exit_code"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_shim_template_file_exists
test_shim_is_executable
test_shim_no_nonposix_constructs
test_shim_exits_0_with_valid_dso_root
test_shim_exits_127_for_missing_script
test_shim_error_names_missing_script
test_shim_resolves_dso_root_from_config
test_shim_error_names_config_key_when_no_dso_root
test_lib_mode_exports_dso_root
test_lib_mode_produces_no_stdout
test_lib_mode_does_not_dispatch
test_lib_mode_exec_exits_zero

print_summary
