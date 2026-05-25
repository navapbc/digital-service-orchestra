#!/usr/bin/env bash
# tests/unit/scripts/test_audit_dd4_phase_gate.sh
# Behavioral unit tests for the audit_dd4_phase_gate.sh sourceable library.
#
# Tests:
#   1. test_missing_gate_exits_2          — no gate files → exit 2 + diagnostic stderr
#   2. test_present_gate_exits_0          — matching .reconciler-phase-gate → exit 0
#   3. test_ops_marker_exits_0            — matching .reconciler-phase-gate.ops entry → exit 0
#   4. test_phase_mismatch_exits_2        — gate content doesn't match requested phase → exit 2
#   5. test_ops_absent_with_gate_match    — ops file absent + gate matches → exit 0 + WARNING
#   6. test_env_var_override              — RECONCILER_PHASE_GATE_DIR env var honored
#   7. test_malformed_ops_fails_closed    — malformed JSON in ops, no gate file → exit 2
#   8. test_cli_invocation_exit_2         — CLI: missing gate → exit 2
#   9. test_cli_invocation_exit_0         — CLI: matching gate → exit 0
#  10. test_script_is_executable          — file has executable bit set
#
# Usage: bash tests/unit/scripts/test_audit_dd4_phase_gate.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/dso_reconciler/audits/audit_dd4_phase_gate.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test_audit_dd4_phase_gate.sh ==="

# ── Helper: isolated gate dir ─────────────────────────────────────────────────
_make_gate_dir() { mktemp -d; }

# ── Source the library with an isolated gate dir ──────────────────────────────
# Re-source per test with the appropriate env so functions see the right dir.
_source_with_dir() {
    local gate_dir="$1"
    RECONCILER_PHASE_GATE_DIR="$gate_dir" source "$SCRIPT"
}

# ── Test 1: missing gate files → exit 2 + stderr contains diagnostic ─────────
test_missing_gate_exits_2() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_missing_gate_exits_2\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_missing_gate_exits_2"
        return
    fi

    local gate_dir
    gate_dir="$(_make_gate_dir)"
    trap 'rm -rf "$gate_dir"' RETURN

    local stderr_out
    stderr_out="$(RECONCILER_PHASE_GATE_DIR="$gate_dir" \
        bash -c "source \"$SCRIPT\"; check_phase_gate 1" 2>&1 >/dev/null)"
    local rc=$?

    assert_eq "exit code is 2"       "2"   "$rc"
    assert_contains "stderr diagnostic" "phase not advanced: phase=1 gate_missing" "$stderr_out"

    assert_pass_if_clean "test_missing_gate_exits_2"
}

# ── Test 2: matching .reconciler-phase-gate → exit 0 ─────────────────────────
test_present_gate_exits_0() {
    _snapshot_fail

    local gate_dir
    gate_dir="$(_make_gate_dir)"
    trap 'rm -rf "$gate_dir"' RETURN

    printf 'bootstrap-strict\n' > "$gate_dir/.reconciler-phase-gate"

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
        bash -c "source \"$SCRIPT\"; check_phase_gate bootstrap-strict" \
        >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 0" "0" "$rc"

    assert_pass_if_clean "test_present_gate_exits_0"
}

# ── Test 3: matching .reconciler-phase-gate.ops entry → exit 0 ───────────────
test_ops_marker_exits_0() {
    _snapshot_fail

    local gate_dir
    gate_dir="$(_make_gate_dir)"
    trap 'rm -rf "$gate_dir"' RETURN

    # Write an ops-log entry with the target phase (no plain gate file)
    printf '{"operator":"alice","timestamp":"2026-05-25T00:00:00Z","phase":"live","comment":"promoting"}\n' \
        > "$gate_dir/.reconciler-phase-gate.ops"

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
        bash -c "source \"$SCRIPT\"; check_phase_gate live" \
        >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 0" "0" "$rc"

    assert_pass_if_clean "test_ops_marker_exits_0"
}

# ── Test 4: phase mismatch → exit 2 ──────────────────────────────────────────
test_phase_mismatch_exits_2() {
    _snapshot_fail

    local gate_dir
    gate_dir="$(_make_gate_dir)"
    trap 'rm -rf "$gate_dir"' RETURN

    printf 'bootstrap-strict\n' > "$gate_dir/.reconciler-phase-gate"

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
        bash -c "source \"$SCRIPT\"; check_phase_gate bootstrap-throttle" \
        >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 2" "2" "$rc"

    assert_pass_if_clean "test_phase_mismatch_exits_2"
}

# ── Test 5: ops absent + gate matches → exit 0 with WARNING on stderr ─────────
test_ops_absent_with_gate_match() {
    _snapshot_fail

    local gate_dir
    gate_dir="$(_make_gate_dir)"
    trap 'rm -rf "$gate_dir"' RETURN

    printf 'dry-run\n' > "$gate_dir/.reconciler-phase-gate"
    # No .reconciler-phase-gate.ops file

    local stderr_out
    stderr_out="$(RECONCILER_PHASE_GATE_DIR="$gate_dir" \
        bash -c "source \"$SCRIPT\"; check_phase_gate dry-run" 2>&1 >/dev/null)"
    local rc=$?

    assert_eq "exit code is 0" "0" "$rc"
    assert_contains "WARNING emitted" "WARNING" "$stderr_out"

    assert_pass_if_clean "test_ops_absent_with_gate_match"
}

# ── Test 6: RECONCILER_PHASE_GATE_DIR env var is honored ─────────────────────
test_env_var_override() {
    _snapshot_fail

    local gate_dir
    gate_dir="$(_make_gate_dir)"
    trap 'rm -rf "$gate_dir"' RETURN

    printf 'live\n' > "$gate_dir/.reconciler-phase-gate"

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
        bash -c "source \"$SCRIPT\"; check_phase_gate live" \
        >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 0 with custom dir" "0" "$rc"

    assert_pass_if_clean "test_env_var_override"
}

# ── Test 7: malformed JSON in ops, no gate file → fail-closed exit 2 ──────────
test_malformed_ops_fails_closed() {
    _snapshot_fail

    local gate_dir
    gate_dir="$(_make_gate_dir)"
    trap 'rm -rf "$gate_dir"' RETURN

    # Malformed JSON — no valid "phase" field extractable
    printf 'NOT_VALID_JSON phase=live\n' > "$gate_dir/.reconciler-phase-gate.ops"
    # No .reconciler-phase-gate file

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
        bash -c "source \"$SCRIPT\"; check_phase_gate live" \
        >/dev/null 2>&1
    rc=$?

    assert_eq "malformed ops → exit 2" "2" "$rc"

    assert_pass_if_clean "test_malformed_ops_fails_closed"
}

# ── Test 8: CLI invocation — missing gate → exit 2 ────────────────────────────
test_cli_invocation_exit_2() {
    _snapshot_fail

    local gate_dir
    gate_dir="$(_make_gate_dir)"
    trap 'rm -rf "$gate_dir"' RETURN

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" bash "$SCRIPT" "bootstrap-throttle" \
        >/dev/null 2>&1
    rc=$?

    assert_eq "CLI exit 2" "2" "$rc"

    assert_pass_if_clean "test_cli_invocation_exit_2"
}

# ── Test 9: CLI invocation — matching gate → exit 0 ───────────────────────────
test_cli_invocation_exit_0() {
    _snapshot_fail

    local gate_dir
    gate_dir="$(_make_gate_dir)"
    trap 'rm -rf "$gate_dir"' RETURN

    printf 'bootstrap-throttle\n' > "$gate_dir/.reconciler-phase-gate"

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" bash "$SCRIPT" "bootstrap-throttle" \
        >/dev/null 2>&1
    rc=$?

    assert_eq "CLI exit 0" "0" "$rc"

    assert_pass_if_clean "test_cli_invocation_exit_0"
}

# ── Test 10: script is executable ─────────────────────────────────────────────
test_script_is_executable() {
    _snapshot_fail

    if [[ -x "$SCRIPT" ]]; then
        assert_eq "executable" "yes" "yes"
    else
        (( ++FAIL ))
        printf "FAIL: test_script_is_executable\n  not executable: %s\n" "$SCRIPT" >&2
    fi

    assert_pass_if_clean "test_script_is_executable"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_missing_gate_exits_2
test_present_gate_exits_0
test_ops_marker_exits_0
test_phase_mismatch_exits_2
test_ops_absent_with_gate_match
test_env_var_override
test_malformed_ops_fails_closed
test_cli_invocation_exit_2
test_cli_invocation_exit_0
test_script_is_executable

print_summary
