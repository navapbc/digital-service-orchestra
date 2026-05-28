#!/usr/bin/env bash
# tests/unit/shared/test-protocol-conformance-harness.sh
# Behavioral tests for tests/lib/protocol-conformance-harness.sh
#
# Tests verify the protocol-conformance harness:
#   1. Exits 0 on forced-failure with max=3, emits REPLAN_ESCALATE
#   2. Never dispatches more than MAX_CYCLES times
#   3. REPLAN_ESCALATE upstream is in valid enum {brainstorm, preplanning, planner_supplied}
#   4. Emits OSCILLATION_HALT on oscillation fixture
#   5. Emits PROTOCOL_ERROR (non-zero exit) on illegal-transition fixture
#   6. Rejects --max-cycles < 2 with exit code 5
#   7. --max-cycles flag overrides planning.max_remediation_cycles config
#
# Usage: bash tests/unit/shared/test-protocol-conformance-harness.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HARNESS="$REPO_ROOT/tests/lib/protocol-conformance-harness.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-protocol-conformance-harness.sh ==="

# ── Helper: skip test if harness not executable ───────────────────────────────
_require_harness() {
    if [[ ! -x "$HARNESS" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  harness not found or not executable: %s\n" "$1" "$HARNESS" >&2
        return 1
    fi
    return 0
}

# ── Test 1: exits 0 on forced-failure with max=3 ─────────────────────────────
# Behavior: --simulate-failure with fixture-a and 3 cycles → exits 0 with REPLAN_ESCALATE
test_harness_exits_0_on_forced_failure_max3() {
    _snapshot_fail
    _require_harness "test_harness_exits_0_on_forced_failure_max3" || { assert_pass_if_clean "test_harness_exits_0_on_forced_failure_max3"; return; }

    local output exit_code
    output="$(bash "$HARNESS" --touchpoint=fixture-a --simulate-failure --max-cycles=3 2>&1)" || exit_code=$?
    exit_code="${exit_code:-0}"

    assert_eq "exits_0_max3: exit code is 0" "0" "$exit_code"
    assert_contains "exits_0_max3: REPLAN_ESCALATE present" "REPLAN_ESCALATE:" "$output"
    assert_contains "exits_0_max3: DISPATCH:1 present" "DISPATCH:1" "$output"
    assert_contains "exits_0_max3: DISPATCH:3 present" "DISPATCH:3" "$output"

    assert_pass_if_clean "test_harness_exits_0_on_forced_failure_max3"
}

# ── Test 2: dispatch count never exceeds MAX_CYCLES ──────────────────────────
# Behavior: with --max-cycles=2, only 2 DISPATCHes should appear in output
test_harness_never_exceeds_max_cycles() {
    _snapshot_fail
    _require_harness "test_harness_never_exceeds_max_cycles" || { assert_pass_if_clean "test_harness_never_exceeds_max_cycles"; return; }

    local output dispatch_count
    output="$(bash "$HARNESS" --touchpoint=fixture-a --simulate-failure --max-cycles=2 2>&1)" || true

    dispatch_count="$(echo "$output" | grep -c "^DISPATCH:" 2>/dev/null || true)"

    # Must not dispatch more than 2 times
    if [[ "$dispatch_count" -le 2 ]]; then
        assert_eq "never_exceeds_max: dispatch count <= 2" "ok" "ok"
    else
        (( ++FAIL ))
        printf "FAIL: test_harness_never_exceeds_max_cycles\n  expected dispatch_count <= 2, got: %s\n" \
            "$dispatch_count" >&2
    fi

    assert_pass_if_clean "test_harness_never_exceeds_max_cycles"
}

# ── Test 3: REPLAN_ESCALATE upstream is in valid enum ────────────────────────
# Behavior: the upstream token after REPLAN_ESCALATE: must be one of
#   {brainstorm, preplanning, planner_supplied}
test_harness_replan_escalate_valid_upstream_enum() {
    _snapshot_fail
    _require_harness "test_harness_replan_escalate_valid_upstream_enum" || { assert_pass_if_clean "test_harness_replan_escalate_valid_upstream_enum"; return; }

    local output escalate_line upstream_val
    output="$(bash "$HARNESS" --touchpoint=fixture-a --simulate-failure --max-cycles=3 2>&1)" || true

    if ! echo "$output" | grep -q "^REPLAN_ESCALATE:"; then
        (( ++FAIL ))
        printf "FAIL: test_harness_replan_escalate_valid_upstream_enum\n  REPLAN_ESCALATE not found in output\n" >&2
        assert_pass_if_clean "test_harness_replan_escalate_valid_upstream_enum"
        return
    fi

    escalate_line="$(echo "$output" | grep "^REPLAN_ESCALATE:" | head -1)"
    upstream_val="${escalate_line#REPLAN_ESCALATE:}"

    local valid=0
    for _u in brainstorm preplanning planner_supplied; do
        if [[ "$upstream_val" == "$_u" ]]; then
            valid=1
            break
        fi
    done

    if [[ "$valid" -eq 1 ]]; then
        assert_eq "upstream_enum: valid upstream" "ok" "ok"
    else
        (( ++FAIL ))
        printf "FAIL: test_harness_replan_escalate_valid_upstream_enum\n  upstream '%s' not in valid enum {brainstorm, preplanning, planner_supplied}\n" \
            "$upstream_val" >&2
    fi

    assert_pass_if_clean "test_harness_replan_escalate_valid_upstream_enum"
}

# ── Test 4: OSCILLATION_HALT emitted on oscillation fixture ──────────────────
# Behavior: fixture-oscillation with max-cycles=3 emits OSCILLATION_HALT before cycle N
test_harness_oscillation_halt_emitted() {
    _snapshot_fail
    _require_harness "test_harness_oscillation_halt_emitted" || { assert_pass_if_clean "test_harness_oscillation_halt_emitted"; return; }

    local output
    output="$(bash "$HARNESS" --touchpoint=fixture-oscillation --simulate-failure --max-cycles=3 2>&1)" || true

    assert_contains "oscillation_halt: OSCILLATION_HALT present" "OSCILLATION_HALT" "$output"
    # Oscillation must halt before exhausting all cycles
    assert_not_contains "oscillation_halt: DISPATCH:3 absent" "DISPATCH:3" "$output"

    assert_pass_if_clean "test_harness_oscillation_halt_emitted"
}

# ── Test 5: PROTOCOL_ERROR emitted and exit non-zero on illegal transition ────
# Behavior: fixture-illegal-transition emits PROTOCOL_ERROR and exits non-zero
test_harness_protocol_error_on_illegal_transition() {
    _snapshot_fail
    _require_harness "test_harness_protocol_error_on_illegal_transition" || { assert_pass_if_clean "test_harness_protocol_error_on_illegal_transition"; return; }

    local output exit_code
    exit_code=0
    output="$(bash "$HARNESS" --touchpoint=fixture-illegal-transition --simulate-failure --max-cycles=3 2>&1)" || exit_code=$?

    assert_contains "protocol_error: PROTOCOL_ERROR present" "PROTOCOL_ERROR" "$output"

    if [[ "$exit_code" -ne 0 ]]; then
        assert_eq "protocol_error: non-zero exit" "ok" "ok"
    else
        (( ++FAIL ))
        printf "FAIL: test_harness_protocol_error_on_illegal_transition\n  expected non-zero exit, got: %d\n" \
            "$exit_code" >&2
    fi

    assert_pass_if_clean "test_harness_protocol_error_on_illegal_transition"
}

# ── Test 6: rejects --max-cycles < 2 with exit code 5 ────────────────────────
# Behavior: --max-cycles=1 causes harness to exit with code 5
test_harness_rejects_max_cycles_below_2() {
    _snapshot_fail
    _require_harness "test_harness_rejects_max_cycles_below_2" || { assert_pass_if_clean "test_harness_rejects_max_cycles_below_2"; return; }

    local exit_code
    exit_code=0
    bash "$HARNESS" --touchpoint=fixture-a --simulate-failure --max-cycles=1 >/dev/null 2>&1 || exit_code=$?

    assert_eq "rejects_below_2: exit code is 5" "5" "$exit_code"

    assert_pass_if_clean "test_harness_rejects_max_cycles_below_2"
}

# ── Test 7: --max-cycles flag overrides config ────────────────────────────────
# Behavior: even if planning.max_remediation_cycles=5, --max-cycles=2 means only 2 dispatches
test_flag_overrides_config() {
    _snapshot_fail
    _require_harness "test_flag_overrides_config" || { assert_pass_if_clean "test_flag_overrides_config"; return; }

    local output dispatch_count
    # Use a temp config file that sets max_remediation_cycles=5, but override with --max-cycles=2
    local tmp_conf
    tmp_conf="$(mktemp "${TMPDIR:-/tmp}/protocol-conformance-config.XXXXXX")"
    trap 'rm -f "$tmp_conf"' RETURN
    echo "planning.max_remediation_cycles=5" > "$tmp_conf"

    # Override via flag: --max-cycles=2 must win over config value of 5
    output="$(WORKFLOW_CONFIG_FILE="$tmp_conf" bash "$HARNESS" \
        --touchpoint=fixture-a --simulate-failure --max-cycles=2 2>&1)" || true

    dispatch_count="$(echo "$output" | grep -c "^DISPATCH:" 2>/dev/null || true)"

    # Should dispatch exactly 2 times (flag wins, not config's 5)
    if [[ "$dispatch_count" -le 2 ]]; then
        assert_eq "flag_overrides_config: dispatch count <= 2" "ok" "ok"
    else
        (( ++FAIL ))
        printf "FAIL: test_flag_overrides_config\n  --max-cycles=2 should win over config=5; got dispatch_count=%s\n" \
            "$dispatch_count" >&2
    fi

    assert_pass_if_clean "test_flag_overrides_config"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_harness_exits_0_on_forced_failure_max3
test_harness_never_exceeds_max_cycles
test_harness_replan_escalate_valid_upstream_enum
test_harness_oscillation_halt_emitted
test_harness_protocol_error_on_illegal_transition
test_harness_rejects_max_cycles_below_2
test_flag_overrides_config

print_summary
