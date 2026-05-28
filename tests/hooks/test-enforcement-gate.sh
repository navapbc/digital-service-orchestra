#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # Subshell isolation for test independence
# shellcheck disable=SC2164         # cd into known-valid mktemp dirs in test helpers
# shellcheck disable=SC2155         # Declare-and-assign in subshell context — test-only pattern
# tests/hooks/test-enforcement-gate.sh
# Tests for dso.workflow hook gating and HOOK_GATE schema.
#
# Test functions (6):
#   test_enforcement_ci_review_gate_skips   — review-gate emits HOOK_GATE: skipped on dso.workflow=ci-pr
#   test_enforcement_ci_test_gate_skips     — test-gate emits HOOK_GATE: skipped on dso.workflow=ci-pr
#   test_enforcement_ci_test_quality_gate_skips — test-quality-gate emits HOOK_GATE: skipped on dso.workflow=ci-pr
#   test_hook_gate_schema_review_gate       — exact HOOK_GATE output format for review-gate
#   test_hook_gate_schema_test_gate         — exact HOOK_GATE output format for test-gate
#   test_hook_gate_schema_test_quality_gate — exact HOOK_GATE output format for test-quality-gate
#
# All tests use isolated temp dirs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

REVIEW_GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-review-gate.sh"
TEST_GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-test-gate.sh"
TEST_QUALITY_GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-test-quality-gate.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Helper: make isolated tmpdir with dso.workflow=ci-pr config ──────────────
# Usage: _make_ci_tmpdir
# Sets _TMPDIR and creates .claude/dso-config.conf with dso.workflow=ci-pr
_make_ci_tmpdir() {
    local _t
    _t="$(mktemp -d "${TMPDIR:-/tmp}/test-enforcement-gate.XXXXXX")"
    _TEST_TMPDIRS+=("$_t")
    mkdir -p "$_t/.claude"
    printf 'dso.workflow=ci-pr\n' > "$_t/.claude/dso-config.conf"
    printf '%s' "$_t"
}

# ── Helper: make isolated git repo in tmpdir ─────────────────────────────────
# Needed by hooks that call `git diff --cached`
_make_git_repo_in() {
    local dir="$1"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test.local"
    git -C "$dir" config user.name "Test"
    # Create an initial commit so HEAD exists
    touch "$dir/placeholder"
    git -C "$dir" add placeholder
    git -C "$dir" commit -q -m "init"
}

# ════════════════════════════════════════════════════════════════════════════
# test_enforcement_ci_review_gate_skips
# Given dso.workflow=ci-pr; When pre-commit-review-gate.sh runs;
# Then output contains "HOOK_GATE: skipped reason=dso.workflow=ci-pr"
# ════════════════════════════════════════════════════════════════════════════
test_enforcement_ci_review_gate_skips() {
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    # Stage a harmless file so the hook has something to check
    touch "$tmpdir/dummy.txt"
    git -C "$tmpdir" add dummy.txt

    local output
    output="$(PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        WORKFLOW_CONFIG_FILE="$tmpdir/.claude/dso-config.conf" \
        bash "$REVIEW_GATE_HOOK" 2>&1)" || true

    assert_contains \
        "review-gate emits HOOK_GATE skip on dso.workflow=ci-pr" \
        "HOOK_GATE: skipped reason=dso.workflow=ci-pr" \
        "$output"
}

# ════════════════════════════════════════════════════════════════════════════
# test_enforcement_ci_test_gate_skips
# Given dso.workflow=ci-pr; When pre-commit-test-gate.sh runs;
# Then output contains "HOOK_GATE: skipped reason=dso.workflow=ci-pr"
# ════════════════════════════════════════════════════════════════════════════
test_enforcement_ci_test_gate_skips() {
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    touch "$tmpdir/src.sh"
    git -C "$tmpdir" add src.sh

    local output
    output="$(PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        WORKFLOW_CONFIG_FILE="$tmpdir/.claude/dso-config.conf" \
        bash "$TEST_GATE_HOOK" 2>&1)" || true

    assert_contains \
        "test-gate emits HOOK_GATE skip on dso.workflow=ci-pr" \
        "HOOK_GATE: skipped reason=dso.workflow=ci-pr" \
        "$output"
}

# ════════════════════════════════════════════════════════════════════════════
# test_enforcement_ci_test_quality_gate_skips
# Given dso.workflow=ci-pr; When pre-commit-test-quality-gate.sh runs;
# Then output contains "HOOK_GATE: skipped reason=dso.workflow=ci-pr"
# ════════════════════════════════════════════════════════════════════════════
test_enforcement_ci_test_quality_gate_skips() {
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    # Stage a test file so the quality gate has something to check
    mkdir -p "$tmpdir/tests"
    touch "$tmpdir/tests/test-foo.sh"
    git -C "$tmpdir" add tests/test-foo.sh

    local output
    output="$(PROJECT_ROOT="$tmpdir" DSO_CONFIG_FILE="$tmpdir/.claude/dso-config.conf" \
        GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        WORKFLOW_CONFIG_FILE="$tmpdir/.claude/dso-config.conf" \
        bash "$TEST_QUALITY_GATE_HOOK" 2>&1)" || true

    assert_contains \
        "test-quality-gate emits HOOK_GATE skip on dso.workflow=ci-pr" \
        "HOOK_GATE: skipped reason=dso.workflow=ci-pr" \
        "$output"
}

# ════════════════════════════════════════════════════════════════════════════
# test_hook_gate_schema_review_gate
# Given dso.workflow=ci-pr; When pre-commit-review-gate.sh runs;
# Then output contains exactly "HOOK_GATE: skipped reason=dso.workflow=ci-pr"
# ════════════════════════════════════════════════════════════════════════════
test_hook_gate_schema_review_gate() {
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    touch "$tmpdir/dummy.txt"
    git -C "$tmpdir" add dummy.txt

    local output
    output="$(PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        WORKFLOW_CONFIG_FILE="$tmpdir/.claude/dso-config.conf" \
        bash "$REVIEW_GATE_HOOK" 2>&1)" || true

    # Exact schema check (not just substring — full token must appear on a line)
    local schema_token="HOOK_GATE: skipped reason=dso.workflow=ci-pr"
    assert_contains \
        "review-gate HOOK_GATE output matches exact schema: '$schema_token'" \
        "$schema_token" \
        "$output"
}

# ════════════════════════════════════════════════════════════════════════════
# test_hook_gate_schema_test_gate
# Given dso.workflow=ci-pr; When pre-commit-test-gate.sh runs;
# Then output contains exactly "HOOK_GATE: skipped reason=dso.workflow=ci-pr"
# ════════════════════════════════════════════════════════════════════════════
test_hook_gate_schema_test_gate() {
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    touch "$tmpdir/src.sh"
    git -C "$tmpdir" add src.sh

    local output
    output="$(PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        WORKFLOW_CONFIG_FILE="$tmpdir/.claude/dso-config.conf" \
        bash "$TEST_GATE_HOOK" 2>&1)" || true

    local schema_token="HOOK_GATE: skipped reason=dso.workflow=ci-pr"
    assert_contains \
        "test-gate HOOK_GATE output matches exact schema: '$schema_token'" \
        "$schema_token" \
        "$output"
}

# ════════════════════════════════════════════════════════════════════════════
# test_hook_gate_schema_test_quality_gate
# Given dso.workflow=ci-pr; When pre-commit-test-quality-gate.sh runs;
# Then output contains exactly "HOOK_GATE: skipped reason=dso.workflow=ci-pr"
# ════════════════════════════════════════════════════════════════════════════
test_hook_gate_schema_test_quality_gate() {
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    mkdir -p "$tmpdir/tests"
    touch "$tmpdir/tests/test-foo.sh"
    git -C "$tmpdir" add tests/test-foo.sh

    local output
    output="$(PROJECT_ROOT="$tmpdir" DSO_CONFIG_FILE="$tmpdir/.claude/dso-config.conf" \
        GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        WORKFLOW_CONFIG_FILE="$tmpdir/.claude/dso-config.conf" \
        bash "$TEST_QUALITY_GATE_HOOK" 2>&1)" || true

    local schema_token="HOOK_GATE: skipped reason=dso.workflow=ci-pr"
    assert_contains \
        "test-quality-gate HOOK_GATE output matches exact schema: '$schema_token'" \
        "$schema_token" \
        "$output"
}

# ════════════════════════════════════════════════════════════════════════════
# Main: run all tests
# ════════════════════════════════════════════════════════════════════════════
echo "=== test-enforcement-gate.sh: dso.workflow enforcement strategy tests ==="
echo ""

test_enforcement_ci_review_gate_skips
test_enforcement_ci_test_gate_skips
test_enforcement_ci_test_quality_gate_skips
test_hook_gate_schema_review_gate
test_hook_gate_schema_test_gate
test_hook_gate_schema_test_quality_gate

print_summary
