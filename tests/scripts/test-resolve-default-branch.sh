#!/usr/bin/env bash
# tests/scripts/test-resolve-default-branch.sh
# Tests for resolve-default-branch.sh.
#
# Verifies the precedence chain (config → symbolic-ref → gh → main fallback)
# and the per-step contracts (test-injection env vars, --no-warn, exit codes).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"

SUT="$REPO_ROOT/plugins/dso/scripts/resolve-default-branch.sh"

# ── Scaffolding ──────────────────────────────────────────────────────────────
TMPDIR_TEST=""
_setup() {
    TMPDIR_TEST=$(mktemp -d /tmp/test-resolve-default-branch.XXXXXX)
    cd "$TMPDIR_TEST"
    git init -b main --quiet
    git config user.email "test@test.example"
    git config user.name "Test"
    mkdir -p .claude
}
_teardown() {
    [[ -n "$TMPDIR_TEST" ]] && { cd /tmp; rm -rf "$TMPDIR_TEST"; }
    TMPDIR_TEST=""
}
trap _teardown EXIT

# ── Tests ────────────────────────────────────────────────────────────────────

test_config_takes_precedence_over_symbolic_ref() {
    _setup
    printf 'dso.default_branch=trunk\n' > .claude/dso-config.conf
    # Even if test-injected symbolic-ref says master, config wins.
    local _result
    _result=$(DSO_CONFIG_FILE="$TMPDIR_TEST/.claude/dso-config.conf" \
              DSO_DEFAULT_BRANCH_TEST_SYMBOLIC_REF="origin/master" \
              bash "$SUT" --no-warn 2>/dev/null)
    assert_eq "config beats symbolic-ref" "trunk" "$_result"
    cd "$REPO_ROOT"
    _teardown
}

test_symbolic_ref_used_when_config_absent() {
    _setup
    # No config file. Symbolic-ref says master.
    local _result
    _result=$(DSO_CONFIG_FILE="/nonexistent" \
              DSO_DEFAULT_BRANCH_TEST_SYMBOLIC_REF="origin/master" \
              bash "$SUT" --no-warn 2>/dev/null)
    assert_eq "symbolic-ref used when config absent" "master" "$_result"
    cd "$REPO_ROOT"
    _teardown
}

test_symbolic_ref_strips_origin_prefix() {
    _setup
    local _result
    _result=$(DSO_CONFIG_FILE="/nonexistent" \
              DSO_DEFAULT_BRANCH_TEST_SYMBOLIC_REF="origin/develop" \
              bash "$SUT" --no-warn 2>/dev/null)
    assert_eq "origin/ prefix stripped from symbolic-ref" "develop" "$_result"
    cd "$REPO_ROOT"
    _teardown
}

test_gh_used_when_symbolic_ref_empty() {
    _setup
    local _result
    _result=$(DSO_CONFIG_FILE="/nonexistent" \
              DSO_DEFAULT_BRANCH_TEST_SYMBOLIC_REF="" \
              DSO_DEFAULT_BRANCH_TEST_GH_OUTPUT="release" \
              bash "$SUT" --no-warn 2>/dev/null)
    assert_eq "gh output used when symbolic-ref empty" "release" "$_result"
    cd "$REPO_ROOT"
    _teardown
}

test_fallback_to_main_when_all_steps_fail() {
    _setup
    local _result
    _result=$(DSO_CONFIG_FILE="/nonexistent" \
              DSO_DEFAULT_BRANCH_TEST_SYMBOLIC_REF="" \
              DSO_DEFAULT_BRANCH_TEST_GH_OUTPUT="" \
              bash "$SUT" --no-warn 2>/dev/null)
    assert_eq "fallback to main when all steps fail" "main" "$_result"
    cd "$REPO_ROOT"
    _teardown
}

test_warning_emitted_on_fallback() {
    _setup
    local _stderr
    _stderr=$(DSO_CONFIG_FILE="/nonexistent" \
              DSO_DEFAULT_BRANCH_TEST_SYMBOLIC_REF="" \
              DSO_DEFAULT_BRANCH_TEST_GH_OUTPUT="" \
              bash "$SUT" 2>&1 1>/dev/null)
    assert_contains "warning emitted on fallback" "Falling back to 'main'" "$_stderr"
    cd "$REPO_ROOT"
    _teardown
}

test_no_warn_suppresses_warning() {
    _setup
    local _stderr
    _stderr=$(DSO_CONFIG_FILE="/nonexistent" \
              DSO_DEFAULT_BRANCH_TEST_SYMBOLIC_REF="" \
              DSO_DEFAULT_BRANCH_TEST_GH_OUTPUT="" \
              bash "$SUT" --no-warn 2>&1 1>/dev/null)
    assert_eq "--no-warn suppresses warning" "" "$_stderr"
    cd "$REPO_ROOT"
    _teardown
}

test_always_exits_zero() {
    _setup
    local _rc=0
    DSO_CONFIG_FILE="/nonexistent" \
        DSO_DEFAULT_BRANCH_TEST_SYMBOLIC_REF="" \
        DSO_DEFAULT_BRANCH_TEST_GH_OUTPUT="" \
        bash "$SUT" --no-warn >/dev/null 2>&1 || _rc=$?
    assert_eq "always exits 0" "0" "$_rc"
    cd "$REPO_ROOT"
    _teardown
}

test_config_empty_value_falls_through() {
    _setup
    printf 'dso.default_branch=\n' > .claude/dso-config.conf
    local _result
    _result=$(DSO_CONFIG_FILE="$TMPDIR_TEST/.claude/dso-config.conf" \
              DSO_DEFAULT_BRANCH_TEST_SYMBOLIC_REF="origin/master" \
              bash "$SUT" --no-warn 2>/dev/null)
    assert_eq "empty config falls through to symbolic-ref" "master" "$_result"
    cd "$REPO_ROOT"
    _teardown
}

# ── Run all ──────────────────────────────────────────────────────────────────
test_config_takes_precedence_over_symbolic_ref
test_symbolic_ref_used_when_config_absent
test_symbolic_ref_strips_origin_prefix
test_gh_used_when_symbolic_ref_empty
test_fallback_to_main_when_all_steps_fail
test_warning_emitted_on_fallback
test_no_warn_suppresses_warning
test_always_exits_zero
test_config_empty_value_falls_through

print_summary
