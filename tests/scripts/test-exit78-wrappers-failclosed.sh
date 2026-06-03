#!/usr/bin/env bash
# tests/scripts/test-exit78-wrappers-failclosed.sh
#
# Story a85d-5f7f-8898-4a4f — fail-close the silent-pass review gates.
#
# The three backstop workflows (review-coverage-invariant, dangling-references,
# ruleset-invariants) each wrap a fail-closed check script and must map the
# script's exit 78 (PRECONDITION_NOT_MET) to a pass ONLY in warn mode; in
# enforce mode a precondition failure must BLOCK (never silently green-stamp an
# un-reviewed candidate). That decision is centralized in the shared helper
# plugins/dso/scripts/ci/precondition-gate.sh, which all three workflows call.
#
# This test EXECUTES the helper with real (rc, mode) inputs and asserts the real
# exit code — a behavioral contract test, not an inspection of the YAML text.
# (Earlier this file extracted the YAML run-block and string-matched it; that is
# the source-grepping anti-pattern the behavioral-testing standard prohibits.)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GATE="$REPO_ROOT/plugins/dso/scripts/ci/precondition-gate.sh"

PASS=0
FAIL=0

# Run the gate and echo its exit code. Args are passed through verbatim.
_gate_rc() {
    bash "$GATE" "$@" >/dev/null 2>&1
    echo $?
}

_assert_eq() {  # name expected actual
    if [[ "$3" -eq "$2" ]]; then
        echo "PASS: $1"; PASS=$((PASS+1))
    else
        echo "FAIL: $1 (expected $2, got $3)"; FAIL=$((FAIL+1))
    fi
}

_assert_ne() {  # name not_expected actual
    if [[ "$3" -ne "$2" ]]; then
        echo "PASS: $1"; PASS=$((PASS+1))
    else
        echo "FAIL: $1 (expected != $2, got $3)"; FAIL=$((FAIL+1))
    fi
}

# --- exit 78 (precondition not met): the core fail-closed-under-enforce split ---

# WARN: 78 -> 0 (advisory pass during rollout) — today's default behavior.
_assert_eq warn_exit78_maps_to_zero 0 "$(_gate_rc 78 warn review-coverage-invariant)"

# ENFORCE: 78 -> non-zero (fail-closed; block the candidate).
_assert_ne enforce_exit78_blocks 0 "$(_gate_rc 78 enforce review-coverage-invariant)"

# ENFORCE preserves the precondition code (78) so the cause is visible.
_assert_eq enforce_exit78_preserves_code 78 "$(_gate_rc 78 enforce dangling-references)"

# DEFAULT (mode arg omitted) behaves like warn -> 0, so live CI is unchanged.
_assert_eq default_mode_is_warn 0 "$(_gate_rc 78)"

# Empty mode string also defaults to warn (not "enforce").
_assert_eq empty_mode_is_warn 0 "$(_gate_rc 78 '' ruleset-invariants)"

# --- non-78 codes: passthrough regardless of mode (mode only gates 78) ---

# A real violation (rc=1) blocks in BOTH modes — the wrapped script already
# decided to block; the gate must not mask it.
_assert_eq warn_passthrough_violation 1 "$(_gate_rc 1 warn review-coverage-invariant)"
_assert_eq enforce_passthrough_violation 1 "$(_gate_rc 1 enforce review-coverage-invariant)"

# A clean pass (rc=0) stays a pass in both modes.
_assert_eq enforce_passthrough_pass 0 "$(_gate_rc 0 enforce review-coverage-invariant)"

# Some other non-78 failure code is preserved (not coerced to 0 or 1).
_assert_eq passthrough_preserves_other_code 2 "$(_gate_rc 2 enforce review-coverage-invariant)"

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
if [[ $FAIL -eq 0 ]]; then exit 0; else exit 1; fi
