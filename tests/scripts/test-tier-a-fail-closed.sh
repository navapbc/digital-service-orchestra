#!/usr/bin/env bash
# tests/scripts/test-tier-a-fail-closed.sh
# F-02: static-regression guard for the Tier A flips on pre-commit-test-gate
# and pre-commit-review-gate. The unit tests for the gate-unavailable helper
# (test-gate-unavailable.sh) verify the helper's contract; this file asserts
# the hooks correctly invoke the helper on their Tier A failure paths and
# never silently fail-open.
#
# Behavioral integration tests against the live hooks were considered but are
# too dependent on hook-internal setup (artifacts dir, review-status file
# format, fuzzy-match staged-files detection) to be reliable without extensive
# mocking. The static checks here catch regression of the specific bug class
# F-02 closes: a Tier A site reverting to "log_decision pass; exit 0" or
# equivalent silent fail-open.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"

TEST_GATE="$REPO_ROOT/plugins/dso/hooks/pre-commit-test-gate.sh"
REVIEW_GATE="$REPO_ROOT/plugins/dso/hooks/pre-commit-review-gate.sh"
HELPER="$REPO_ROOT/plugins/dso/hooks/lib/gate-unavailable.sh"

# ── Helper present and well-formed ───────────────────────────────────────────

test_helper_exists_and_executable() {
    assert_eq "gate-unavailable.sh exists" "1" "$([[ -f "$HELPER" ]] && echo 1 || echo 0)"
    bash -n "$HELPER" >/dev/null 2>&1
    local _rc=$?
    assert_eq "gate-unavailable.sh has valid syntax" "0" "$_rc"
}

test_helper_exports_required_functions() {
    # Source the helper in an isolated subshell and assert both public
    # functions are defined.
    local _has_unavail _has_bypass
    _has_unavail=$(bash -c "source '$HELPER'; declare -F _dso_gate_unavailable" 2>/dev/null)
    _has_bypass=$(bash -c "source '$HELPER'; declare -F _dso_gate_bypass_active" 2>/dev/null)
    assert_contains "exports _dso_gate_unavailable" "_dso_gate_unavailable" "$_has_unavail"
    assert_contains "exports _dso_gate_bypass_active" "_dso_gate_bypass_active" "$_has_bypass"
}

# ── pre-commit-test-gate.sh Tier A flip ──────────────────────────────────────

test_test_gate_declares_tier_a() {
    local _has
    _has=$(head -n 5 "$TEST_GATE" | grep -E '^#\s*DSO-GATE-TIER:\s*A\b' || true)
    assert_contains "test-gate header declares Tier A" "DSO-GATE-TIER: A" "$_has"
}

test_test_gate_sources_helper() {
    grep -q "source.*gate-unavailable.sh" "$TEST_GATE"
    local _rc=$?
    assert_eq "test-gate sources gate-unavailable.sh" "0" "$_rc"
}

test_test_gate_calls_helper_on_timeout() {
    # The timeout trap body must call _dso_gate_unavailable and exit 2 (not 0).
    grep -E '_dso_gate_unavailable test_gate' "$TEST_GATE" >/dev/null
    local _rc=$?
    assert_eq "test-gate calls _dso_gate_unavailable on timeout" "0" "$_rc"
}

test_test_gate_traps_term_and_urg() {
    # Both SIGTERM (pre-commit timeout) and SIGURG (Claude Code tool timeout)
    # must be trapped — without both, the gate misses one of the two timeout
    # routes.
    grep -q "trap.*TERM" "$TEST_GATE"
    local _rc_term=$?
    grep -q "trap.*URG" "$TEST_GATE"
    local _rc_urg=$?
    assert_eq "test-gate traps SIGTERM" "0" "$_rc_term"
    assert_eq "test-gate traps SIGURG" "0" "$_rc_urg"
}

test_test_gate_no_silent_fail_open_on_timeout() {
    # Regression guard: the obsolete _fail_open_on_timeout function (which
    # called `exit 0`) must be gone. If a future change restores it without
    # the gate-unavailable path, this test catches it.
    if grep -E '_fail_open_on_timeout\(\)\s*\{' "$TEST_GATE" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        echo "FAIL: test-gate still defines _fail_open_on_timeout()" >&2
        return 1
    fi
    PASS=$((PASS + 1))
}

# ── pre-commit-review-gate.sh Tier A flip ────────────────────────────────────

test_review_gate_declares_tier_a() {
    local _has
    _has=$(head -n 5 "$REVIEW_GATE" | grep -E '^#\s*DSO-GATE-TIER:\s*A\b' || true)
    assert_contains "review-gate header declares Tier A" "DSO-GATE-TIER: A" "$_has"
}

test_review_gate_sources_helper() {
    grep -q "source.*gate-unavailable.sh" "$REVIEW_GATE"
    local _rc=$?
    assert_eq "review-gate sources gate-unavailable.sh" "0" "$_rc"
}

test_review_gate_calls_helper_on_hash_failure() {
    grep -E '_dso_gate_unavailable review_gate' "$REVIEW_GATE" >/dev/null
    local _rc=$?
    assert_eq "review-gate calls _dso_gate_unavailable on hash compute failure" "0" "$_rc"
}

test_review_gate_no_silent_pass_on_empty_hash() {
    # The empty-CURRENT_HASH block must NOT contain the prior fail-open pattern
    # (log_decision "pass"; exit 0) without first checking the bypass envelope.
    # Static grep on a window around the empty-hash check.
    # Find the block starting at `if [[ -z "$CURRENT_HASH" ]]`.
    local _block
    _block=$(awk '/if \[\[ -z "\$CURRENT_HASH" \]\]; then/{flag=1; depth=0} flag{print; depth+=(gsub(/then|do|\{/,"&"))-(gsub(/fi\b|done\b|\}/,"&")); if (depth==0 && NR>1) {flag=0}}' "$REVIEW_GATE")
    # Must contain _dso_gate_unavailable AND exit 2 path
    if ! echo "$_block" | grep -q "_dso_gate_unavailable"; then
        FAIL=$((FAIL + 1))
        echo "FAIL: review-gate empty-hash block missing _dso_gate_unavailable call" >&2
        return 1
    fi
    if ! echo "$_block" | grep -q "exit 2"; then
        FAIL=$((FAIL + 1))
        echo "FAIL: review-gate empty-hash block missing 'exit 2' (Tier A block)" >&2
        return 1
    fi
    PASS=$((PASS + 1))
}

# ── Run all ──────────────────────────────────────────────────────────────────
test_helper_exists_and_executable
test_helper_exports_required_functions
test_test_gate_declares_tier_a
test_test_gate_sources_helper
test_test_gate_calls_helper_on_timeout
test_test_gate_traps_term_and_urg
test_test_gate_no_silent_fail_open_on_timeout
test_review_gate_declares_tier_a
test_review_gate_sources_helper
test_review_gate_calls_helper_on_hash_failure
test_review_gate_no_silent_pass_on_empty_hash

print_summary
