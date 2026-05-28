#!/usr/bin/env bash
# shellcheck disable=SC2164,SC2064
# tests/hooks/lib/test-enforcement-gate-lib.sh
# Unit tests for _dso_enforcement_gate_check (enforcement-gate.sh library).
#
# Test coverage:
#   1. dso.workflow=ci-pr: exits 0 + emits HOOK_GATE log to stderr
#   2. dso.workflow=local: exits non-zero (proceed)
#   3. absent key: defaults to local (exits non-zero)
#   4. exact HOOK_GATE log schema
#
# Usage: bash tests/hooks/lib/test-enforcement-gate-lib.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/dso"
ENFORCEMENT_GATE_LIB="$PLUGIN_DIR/hooks/lib/enforcement-gate.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# Helper: create isolated tmpdir with a dso-config.conf
# ---------------------------------------------------------------------------
_make_tmpdir_with_strategy() {
    local strategy="$1"
    local t
    t="$(mktemp -d "${TMPDIR:-/tmp}/test-enforcement-gate-lib.XXXXXX")"
    mkdir -p "$t/.claude"
    if [[ -n "$strategy" ]]; then
        printf 'dso.workflow=%s\n' "$strategy" > "$t/.claude/dso-config.conf"
    else
        # No strategy key — absent from config
        touch "$t/.claude/dso-config.conf"
    fi
    printf '%s' "$t"
}

# ---------------------------------------------------------------------------
# Test 1: dso.workflow=ci-pr → exits 0 (hook should skip)
# ---------------------------------------------------------------------------
test_ci_strategy_exits_zero() {
    local t exit_code
    t="$(_make_tmpdir_with_strategy "ci-pr")"
    trap "rm -rf '$t'" RETURN

    (
        PROJECT_ROOT="$t" WORKFLOW_CONFIG_FILE="$t/.claude/dso-config.conf" \
        source "$ENFORCEMENT_GATE_LIB"
        _dso_enforcement_gate_check
    ) > /dev/null 2>&1
    exit_code=$?

    assert_eq "ci-pr workflow exits 0" "0" "$exit_code"
    rm -rf "$t"
}
test_ci_strategy_exits_zero

# ---------------------------------------------------------------------------
# Test 2: dso.workflow=ci-pr → emits HOOK_GATE log to stderr
# ---------------------------------------------------------------------------
test_ci_strategy_emits_hook_gate_log() {
    local t stderr_out
    t="$(_make_tmpdir_with_strategy "ci-pr")"
    trap "rm -rf '$t'" RETURN

    stderr_out="$(
        PROJECT_ROOT="$t" WORKFLOW_CONFIG_FILE="$t/.claude/dso-config.conf" \
        bash -c "source '$ENFORCEMENT_GATE_LIB'; _dso_enforcement_gate_check" 2>&1 >/dev/null
    )" || true

    assert_contains "ci-pr workflow emits HOOK_GATE log" \
        "HOOK_GATE: skipped reason=dso.workflow=ci-pr" "$stderr_out"
    rm -rf "$t"
}
test_ci_strategy_emits_hook_gate_log

# ---------------------------------------------------------------------------
# Test 3: exact HOOK_GATE log schema (no extra text on the line)
# ---------------------------------------------------------------------------
test_ci_strategy_exact_hook_gate_schema() {
    local t stderr_out hook_gate_line
    t="$(_make_tmpdir_with_strategy "ci-pr")"
    trap "rm -rf '$t'" RETURN

    stderr_out="$(
        PROJECT_ROOT="$t" WORKFLOW_CONFIG_FILE="$t/.claude/dso-config.conf" \
        bash -c "source '$ENFORCEMENT_GATE_LIB'; _dso_enforcement_gate_check" 2>&1 >/dev/null
    )" || true

    hook_gate_line="$(echo "$stderr_out" | grep "^HOOK_GATE:" || echo "")"
    assert_eq "exact HOOK_GATE schema" \
        "HOOK_GATE: skipped reason=dso.workflow=ci-pr" "$hook_gate_line"
    rm -rf "$t"
}
test_ci_strategy_exact_hook_gate_schema

# ---------------------------------------------------------------------------
# Test 4: dso.workflow=local → exits non-zero (hook should proceed)
# ---------------------------------------------------------------------------
test_local_strategy_exits_nonzero() {
    local t exit_code
    t="$(_make_tmpdir_with_strategy "local")"
    trap "rm -rf '$t'" RETURN

    (
        PROJECT_ROOT="$t" WORKFLOW_CONFIG_FILE="$t/.claude/dso-config.conf" \
        source "$ENFORCEMENT_GATE_LIB"
        _dso_enforcement_gate_check
    ) > /dev/null 2>&1
    exit_code=$?

    local nonzero="false"
    [[ "$exit_code" -ne 0 ]] && nonzero="true"
    assert_eq "local workflow exits non-zero" "true" "$nonzero"
    rm -rf "$t"
}
test_local_strategy_exits_nonzero

# ---------------------------------------------------------------------------
# Test 5: dso.workflow absent → defaults to local (exits non-zero)
# ---------------------------------------------------------------------------
test_absent_strategy_defaults_to_local() {
    local t exit_code
    t="$(_make_tmpdir_with_strategy "")"
    trap "rm -rf '$t'" RETURN

    (
        PROJECT_ROOT="$t" WORKFLOW_CONFIG_FILE="$t/.claude/dso-config.conf" \
        source "$ENFORCEMENT_GATE_LIB"
        _dso_enforcement_gate_check
    ) > /dev/null 2>&1
    exit_code=$?

    local nonzero="false"
    [[ "$exit_code" -ne 0 ]] && nonzero="true"
    assert_eq "absent dso.workflow defaults to local (exits non-zero)" "true" "$nonzero"
    rm -rf "$t"
}
test_absent_strategy_defaults_to_local

# ---------------------------------------------------------------------------
# Test 6: local workflow does NOT emit HOOK_GATE log
# ---------------------------------------------------------------------------
test_local_strategy_no_hook_gate_log() {
    local t stderr_out
    t="$(_make_tmpdir_with_strategy "local")"
    trap "rm -rf '$t'" RETURN

    stderr_out="$(
        PROJECT_ROOT="$t" WORKFLOW_CONFIG_FILE="$t/.claude/dso-config.conf" \
        bash -c "source '$ENFORCEMENT_GATE_LIB'; _dso_enforcement_gate_check" 2>&1 >/dev/null
    )" || true

    local has_hook_gate="false"
    echo "$stderr_out" | grep -q "HOOK_GATE:" && has_hook_gate="true"
    assert_eq "local workflow does not emit HOOK_GATE" "false" "$has_hook_gate"
    rm -rf "$t"
}
test_local_strategy_no_hook_gate_log

# ---------------------------------------------------------------------------
print_summary
