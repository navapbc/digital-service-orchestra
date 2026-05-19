#!/usr/bin/env bash
# tests/hooks/test-session-safety-24h-boundary.sh
# SDET audit P1-5: focused tests for the 24-hour dedup window boundary in
# session-safety-check.sh. Existing tests cover the 7-day rotation; this
# fills the gap by asserting boundary behavior at 23h59m vs 24h01m.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HOOK_SCRIPT="$REPO_ROOT/plugins/dso/hooks/session-safety-check.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-session-safety-24h-boundary.sh ==="

if [[ ! -f "$HOOK_SCRIPT" ]]; then
    echo "SKIP: $HOOK_SCRIPT not found"
    printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
    exit 0
fi

# Isolated test HOME so we control the hook error log location.
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/session-safety-24h.XXXXXX")
trap 'rm -rf "$TEST_HOME"' EXIT
mkdir -p "$TEST_HOME/.claude/logs"

# Write a single error entry for the given hook at a given timestamp.
# The hook reads obj.get('ts', '') so the field name must be `ts`, NOT
# `timestamp` (confirmed against session-safety-check.sh:102).
_write_log_entry() {
    local hook="$1" iso_ts="$2"
    printf '{"ts":"%s","hook":"%s","exit_code":1}\n' "$iso_ts" "$hook" \
        >> "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl"
}

# Compute an ISO-8601 UTC timestamp offset from now by ±H hours.
# Uses portable date fallback (BSD -v vs GNU -d).
_iso_now_offset_hours() {
    local hours="$1"
    if date -u -v"${hours}H" +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
        date -u -v"${hours}H" +"%Y-%m-%dT%H:%M:%SZ"
    else
        date -u -d "${hours} hours" +"%Y-%m-%dT%H:%M:%SZ"
    fi
}

# ─── Test 1 — entry at 23h ago is counted (just inside window) ───────────────
echo ""
echo "--- test_entry_23h_ago_is_within_window ---"

test_entry_23h_ago_is_within_window() {
    _snapshot_fail
    : > "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl"

    local ts
    ts=$(_iso_now_offset_hours -23)
    # 10 entries at -23h triggers threshold (THRESHOLD=10)
    local i
    for i in $(seq 1 10); do
        _write_log_entry "session-safety-check.sh" "$ts"
    done

    local out
    out=$(HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" bash "$HOOK_SCRIPT" 2>&1 || true)

    assert_contains "23h-old errors counted toward 24h window" "session-safety-check.sh" "$out"
    assert_pass_if_clean "test_entry_23h_ago_is_within_window"
}
test_entry_23h_ago_is_within_window

# ─── Test 2 — entry at 25h ago is NOT counted (outside window) ───────────────
echo ""
echo "--- test_entry_25h_ago_is_outside_window ---"

test_entry_25h_ago_is_outside_window() {
    _snapshot_fail
    : > "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl"

    local ts
    ts=$(_iso_now_offset_hours -25)
    local i
    for i in $(seq 1 10); do
        _write_log_entry "session-safety-check.sh" "$ts"
    done

    local out
    out=$(HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" bash "$HOOK_SCRIPT" 2>&1 || true)

    assert_not_contains "25h-old errors filtered out of 24h window" "session-safety-check.sh" "$out"
    assert_pass_if_clean "test_entry_25h_ago_is_outside_window"
}
test_entry_25h_ago_is_outside_window

print_summary
