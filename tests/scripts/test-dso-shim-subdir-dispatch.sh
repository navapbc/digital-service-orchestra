#!/usr/bin/env bash
# tests/scripts/test-dso-shim-subdir-dispatch.sh
# RED-phase test for bug 0736-a97e: shim does not dispatch nested scripts by bare name.
#
# The .claude/scripts/dso shim currently only probes:
#   $DSO_ROOT/scripts/<cmd>          (exact flat match)
#   $DSO_ROOT/scripts/<cmd>.sh       (flat + .sh)
#   $DSO_ROOT/hooks/<cmd>[.sh]       (hook fallback)
#
# It does NOT search subdirectories under $DSO_ROOT/scripts/, so bare-name
# dispatch of scripts that live in e.g. scripts/sprint/ fails with exit 127
# and "command not found".
#
# After the approved fix (find $DSO_ROOT/scripts -type f \( -name "$CMD"
# -o -name "${CMD}.sh" \) fallback), all three assertions below must pass.
#
# Usage:
#   bash tests/scripts/test-dso-shim-subdir-dispatch.sh
# Returns: exit 0 if all assertions pass, exit 1 if any fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIM="$REPO_ROOT/.claude/scripts/dso"

source "$REPO_ROOT/tests/lib/assert.sh"

# ── Verify test prerequisites ──────────────────────────────────────────────────
if [ ! -x "$SHIM" ]; then
    printf 'FATAL: shim not found or not executable: %s\n' "$SHIM" >&2
    exit 1
fi

# Bound each SHIM dispatch so a downstream script hang fails this test fast
# rather than tripping the 120s suite ceiling and reporting an unactionable
# TIMEOUT. d163-6756 (cluster Track D). `timeout` exits 124 on kill — distinct
# from 127 (command not found), so the existing assertions remain correct.
# Falls back to a no-op when `timeout` is unavailable (preserves prior behavior).
if command -v timeout >/dev/null 2>&1; then
    _TIMEOUT_WRAP=(timeout 10s)
else
    _TIMEOUT_WRAP=()
fi

# ── Test 1: bare-name dispatch of a nested script runs (not 127 / not "command not found") ───
test_bare_name_nested_script_does_not_produce_command_not_found() {
    local stderr_out
    local exit_code

    stderr_out="$("${_TIMEOUT_WRAP[@]}" "$SHIM" sprint-drift-check.sh BOGUS_EPIC_ID_xyz 2>&1 >/dev/null)" || exit_code=$?
    exit_code="${exit_code:-0}"

    # The critical assertion: exit code must NOT be 127
    assert_ne \
        "bare-name dispatch: exit code must not be 127 (command not found)" \
        "127" \
        "$exit_code"

    # The critical assertion: stderr must NOT contain "command not found"
    local contains_cnf=0
    printf '%s' "$stderr_out" | grep -q "command not found" && contains_cnf=1
    assert_eq \
        "bare-name dispatch: stderr must not contain 'command not found'" \
        "0" \
        "$contains_cnf"
}

# ── Test 2: a different nested script also dispatches without "command not found" ──
test_bare_name_error_sweep_does_not_produce_command_not_found() {
    local stderr_out
    local exit_code

    stderr_out="$("${_TIMEOUT_WRAP[@]}" "$SHIM" error-sweep.sh 2>&1 >/dev/null)" || exit_code=$?
    exit_code="${exit_code:-0}"

    # Must NOT be 127
    assert_ne \
        "error-sweep.sh bare-name dispatch: exit code must not be 127" \
        "127" \
        "$exit_code"

    # stderr must NOT contain "command not found"
    local contains_cnf=0
    printf '%s' "$stderr_out" | grep -q "command not found" && contains_cnf=1
    assert_eq \
        "error-sweep.sh bare-name dispatch: stderr must not contain 'command not found'" \
        "0" \
        "$contains_cnf"
}

# ── Test 3: truly nonexistent script still produces "command not found" (negative case) ──
test_nonexistent_script_still_produces_command_not_found() {
    local combined_out
    local exit_code=0

    combined_out="$("$SHIM" nonexistent-script-xyz.sh 2>&1)" || exit_code=$?

    # Must exit 127
    assert_eq \
        "nonexistent script: exit code must be 127" \
        "127" \
        "$exit_code"

    # stderr must contain "command not found"
    local contains_cnf=0
    printf '%s' "$combined_out" | grep -q "command not found" && contains_cnf=1
    assert_eq \
        "nonexistent script: output must contain 'command not found'" \
        "1" \
        "$contains_cnf"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_bare_name_nested_script_does_not_produce_command_not_found
test_bare_name_error_sweep_does_not_produce_command_not_found
test_nonexistent_script_still_produces_command_not_found

print_summary
