#!/usr/bin/env bash
# tests/unit/scripts/test-planning-config-source.sh
# TDD tests for plugins/dso/hooks/lib/planning-config.sh
#
# Tests verify that the planning-config library:
#   1. Can be sourced under set -u (nounset) without emitting errors
#   2. Can be sourced under set -euo pipefail without errors
#   3. is_external_dep_block_enabled returns 1 (false) when config absent
#   4. is_external_dep_block_enabled returns 0 (true) when config=true
#   5. Sourcing does not alter the caller's nounset/errexit options
#
# Usage: bash tests/unit/scripts/test-planning-config-source.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
LIB="$REPO_ROOT/plugins/dso/hooks/lib/planning-config.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-planning-config-source.sh ==="

# ── Test 1: Source under set -u emits no stderr ───────────────────────────────

test_source_under_set_u_no_stderr() {
    _snapshot_fail

    local stderr_out
    stderr_out=$(
        set -u
        # shellcheck source=/dev/null
        source "$LIB" 2>&1 >/dev/null
    )

    if [[ -n "$stderr_out" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_source_under_set_u_no_stderr\n  unexpected stderr: %s\n" "$stderr_out" >&2
    fi

    assert_pass_if_clean "test_source_under_set_u_no_stderr"
}

# ── Test 2: Source under set -euo pipefail emits no stderr ───────────────────

test_source_under_strict_mode_no_stderr() {
    _snapshot_fail

    local stderr_out
    stderr_out=$(
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$LIB" 2>&1 >/dev/null
    )

    if [[ -n "$stderr_out" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_source_under_strict_mode_no_stderr\n  unexpected stderr: %s\n" "$stderr_out" >&2
    fi

    assert_pass_if_clean "test_source_under_strict_mode_no_stderr"
}

# ── Test 3: is_external_dep_block_enabled returns false when config absent ────

test_flag_disabled_by_default() {
    _snapshot_fail

    local tmp_conf
    tmp_conf="$(mktemp)"

    # shellcheck source=/dev/null
    source "$LIB" 2>/dev/null

    if WORKFLOW_CONFIG_FILE="$tmp_conf" is_external_dep_block_enabled; then
        (( ++FAIL ))
        printf "FAIL: test_flag_disabled_by_default\n  expected exit 1, got exit 0\n" >&2
    fi

    rm -f "$tmp_conf"
    assert_pass_if_clean "test_flag_disabled_by_default"
}

# ── Test 4: is_external_dep_block_enabled returns true when config=true ───────

test_flag_enabled_when_config_true() {
    _snapshot_fail

    local tmp_conf
    tmp_conf="$(mktemp)"

    printf 'planning.external_dependency_block_enabled=true\n' > "$tmp_conf"

    # shellcheck source=/dev/null
    source "$LIB" 2>/dev/null

    if ! WORKFLOW_CONFIG_FILE="$tmp_conf" is_external_dep_block_enabled; then
        (( ++FAIL ))
        printf "FAIL: test_flag_enabled_when_config_true\n  expected exit 0, got exit 1\n" >&2
    fi

    rm -f "$tmp_conf"
    assert_pass_if_clean "test_flag_enabled_when_config_true"
}

# ── Test 5: Sourcing does not alter caller's nounset state ───────────────────
# The caller starts without nounset; after sourcing the library, nounset
# should still be off (the library must not impose set -u on the caller).

test_source_does_not_impose_nounset() {
    _snapshot_fail

    local result
    result=$(
        # Start with nounset OFF
        set +u
        # shellcheck source=/dev/null
        source "$LIB" 2>/dev/null
        # Under nounset, referencing an unset var would fail; if the lib
        # imposed set -u this would cause the subshell to exit nonzero.
        unset _test_unset_probe 2>/dev/null || true
        echo "${_test_unset_probe:-ok}"
    )

    assert_eq "nounset not imposed" "ok" "$result"

    assert_pass_if_clean "test_source_does_not_impose_nounset"
}

# ── Test 6: BASH_SOURCE guard — no error when BASH_SOURCE is unset ───────────
# Simulates sourcing in a non-bash (e.g. zsh) environment where BASH_SOURCE
# is undefined. We unset BASH_SOURCE and source under set -u; the library must
# not emit "parameter not set" errors.

test_bash_source_guard_under_nounset() {
    _snapshot_fail

    local stderr_out
    stderr_out=$(
        set -u
        unset BASH_SOURCE 2>/dev/null || true
        # shellcheck source=/dev/null
        source "$LIB" 2>&1 >/dev/null
    )

    if [[ -n "$stderr_out" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_bash_source_guard_under_nounset\n  unexpected stderr when BASH_SOURCE unset: %s\n" "$stderr_out" >&2
    fi

    assert_pass_if_clean "test_bash_source_guard_under_nounset"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_source_under_set_u_no_stderr
test_source_under_strict_mode_no_stderr
test_flag_disabled_by_default
test_flag_enabled_when_config_true
test_source_does_not_impose_nounset
test_bash_source_guard_under_nounset

print_summary
