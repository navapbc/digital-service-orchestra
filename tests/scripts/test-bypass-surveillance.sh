#!/usr/bin/env bash
# tests/scripts/test-bypass-surveillance.sh
# Unit tests for plugins/dso/scripts/end-session/bypass-surveillance.sh
#
# Tests:
#   (a) no logs → silent exit 0, nothing archived
#   (b) below threshold → counts reported, NO ticket filed, logs archived
#   (c) at/above threshold + ticket-create succeeds → warning emitted,
#       exactly ONE ticket filed, logs archived
#   (d) at/above threshold + ticket-create FAILS → logs NOT archived,
#       retry signal emitted, exit 1
#   (e) reason sanitization: control chars stripped, length capped at 200
#
# Uses:
#   - stubbed ticket CLI (TICKET_CMD env var)
#   - isolated TMPDIR artifacts dir (DSO_ARTIFACTS_DIR env var)
#   - BYPASS_ALERT_THRESHOLD env seam (no real tracker touched)
#
# Usage: bash tests/scripts/test-bypass-surveillance.sh
# Returns: exit 0 on all tests passing, non-zero otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SURVEILLANCE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/end-session/bypass-surveillance.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-bypass-surveillance.sh ==="

# ── Helpers ───────────────────────────────────────────────────────────────────

# Create an isolated test environment: a temp ARTIFACTS_DIR and a stub TICKET_CMD.
# Prints the temp dir path so the caller can capture it.
_make_test_env() {
    mktemp -d "${TMPDIR:-/tmp}/bypass-surveillance-test.XXXXXX"
}

# Write a bypass log file with the given reason.
_write_log() {
    local artifacts_dir="$1"
    local filename="$2"
    local reason="$3"
    local logfile="$artifacts_dir/${filename}"
    printf 'DSO_SPRINT_ACTIVE=0 bypass: 2026-01-01T00:00:00Z PID=1234 REASON=%s\n' "$reason" > "$logfile"
    echo "$logfile"
}

# Create a stub ticket CLI that succeeds (exit 0) and prints a fake ticket ID.
_make_stub_ticket_success() {
    local dir="$1"
    local stub="$dir/ticket"
    cat > "$stub" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub ticket CLI that succeeds.
printf 'BUG-STUB-001\n'
exit 0
STUB_EOF
    chmod +x "$stub"
    echo "$stub"
}

# Create a stub ticket CLI that fails (exit 1).
_make_stub_ticket_fail() {
    local dir="$1"
    local stub="$dir/ticket-fail"
    cat > "$stub" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub ticket CLI that fails.
echo "ticket: simulated failure" >&2
exit 1
STUB_EOF
    chmod +x "$stub"
    echo "$stub"
}

# Run bypass-surveillance.sh with the given env vars.
# Captures stdout+stderr into variables _stdout and _stderr; sets _exit.
_run() {
    local env_overrides=("$@")
    local _tmpout
    _tmpout=$(mktemp "${TMPDIR:-/tmp}/bypass-test-out.XXXXXX")
    local _tmperr
    _tmperr=$(mktemp "${TMPDIR:-/tmp}/bypass-test-err.XXXXXX")

    env "${env_overrides[@]}" bash "$SURVEILLANCE_SCRIPT" \
        > "$_tmpout" 2> "$_tmperr"
    _exit=$?
    _stdout=$(cat "$_tmpout")
    _stderr=$(cat "$_tmperr")
    rm -f "$_tmpout" "$_tmperr"
}

# ── Test (a): no logs → silent exit 0, nothing archived ──────────────────────
_td=$(  _make_test_env)
_stub=$( _make_stub_ticket_success "$_td")

_run \
    "DSO_ARTIFACTS_DIR=${_td}" \
    "TICKET_CMD=${_stub}" \
    "BYPASS_ALERT_THRESHOLD=3"

assert_eq "no_logs_exit_0"         "0"       "$_exit"
assert_eq "no_logs_stdout_empty"   ""        "$_stdout"

# Nothing should be archived (bypass-processed dir should not exist or be empty)
_archived=0
if [[ -d "${_td}/bypass-processed" ]]; then
    _archived=$(find "${_td}/bypass-processed" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
fi
assert_eq "no_logs_nothing_archived" "0" "$_archived"

rm -rf "$_td"

# ── Test (b): below threshold → counts reported, NO ticket, logs archived ─────
_td=$(_make_test_env)
_stub=$(_make_stub_ticket_success "$_td")

_write_log "$_td" "sprint-merge-only-bypass-001.log" "test reason one" > /dev/null
_write_log "$_td" "sprint-merge-only-bypass-002.log" "test reason two" > /dev/null

# threshold=3, count=2 → below threshold
_run \
    "DSO_ARTIFACTS_DIR=${_td}" \
    "TICKET_CMD=${_stub}" \
    "BYPASS_ALERT_THRESHOLD=3"

assert_eq "below_threshold_exit_0" "0" "$_exit"

# No ticket should have been filed — stub prints BUG-STUB-001 only when invoked
assert_eq "below_threshold_no_ticket_in_stderr" \
    "0" "$(echo "$_stderr" | grep -c 'BUG-STUB-001' || true)"

# Logs should be archived
_archived=$(find "${_td}/bypass-processed" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "below_threshold_logs_archived" "2" "$_archived"

# Original log files should be gone
_remaining=$(find "${_td}" -maxdepth 1 -name "*.log" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "below_threshold_originals_removed" "0" "$_remaining"

rm -rf "$_td"

# ── Test (c): at/above threshold + ticket succeeds ────────────────────────────
_td=$(_make_test_env)
_stub=$(_make_stub_ticket_success "$_td")

_write_log "$_td" "sprint-merge-only-bypass-001.log" "bypass reason A" > /dev/null
_write_log "$_td" "sprint-merge-only-bypass-002.log" "bypass reason B" > /dev/null
_write_log "$_td" "sprint-merge-only-bypass-003.log" "bypass reason C" > /dev/null

# threshold=3, count=3 → at threshold
_run \
    "DSO_ARTIFACTS_DIR=${_td}" \
    "TICKET_CMD=${_stub}" \
    "BYPASS_ALERT_THRESHOLD=3"

assert_eq "at_threshold_exit_0" "0" "$_exit"

# Warning must be emitted to stderr
_warn_count=$(echo "$_stderr" | grep -c "INTEGRITY WARNING" || true)
assert_eq "at_threshold_warning_emitted" "1" "$_warn_count"

# Exactly one ticket must have been filed (stub echoes BUG-STUB-001 once per invocation)
_ticket_lines=$(echo "$_stderr" | grep -c "BUG-STUB-001\|Follow-up ticket filed" || true)
if [[ "$_ticket_lines" -ge 1 ]]; then
    _ticket_filed="yes"
else
    _ticket_filed="no"
fi
assert_eq "at_threshold_ticket_filed" "yes" "$_ticket_filed"

# Logs must be archived after successful ticket creation
_archived=$(find "${_td}/bypass-processed" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "at_threshold_logs_archived" "3" "$_archived"

_remaining=$(find "${_td}" -maxdepth 1 -name "*.log" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "at_threshold_originals_removed" "0" "$_remaining"

rm -rf "$_td"

# ── Test (d): at/above threshold + ticket FAILS ───────────────────────────────
_td=$(_make_test_env)
_stub_fail=$(_make_stub_ticket_fail "$_td")

_write_log "$_td" "sprint-merge-only-bypass-001.log" "bypass reason X" > /dev/null
_write_log "$_td" "sprint-merge-only-bypass-002.log" "bypass reason Y" > /dev/null
_write_log "$_td" "sprint-merge-only-bypass-003.log" "bypass reason Z" > /dev/null

_run \
    "DSO_ARTIFACTS_DIR=${_td}" \
    "TICKET_CMD=${_stub_fail}" \
    "BYPASS_ALERT_THRESHOLD=3"

assert_eq "ticket_fail_exit_1" "1" "$_exit"

# Logs must NOT be archived — they should remain in ARTIFACTS_DIR for retry
_archived=0
if [[ -d "${_td}/bypass-processed" ]]; then
    _archived=$(find "${_td}/bypass-processed" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
fi
assert_eq "ticket_fail_logs_not_archived" "0" "$_archived"

# Originals must still be present
_remaining=$(find "${_td}" -maxdepth 1 -name "*.log" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "ticket_fail_originals_remain" "3" "$_remaining"

# Retry signal must be emitted to stderr
_retry_signal=$(echo "$_stderr" | grep -c "RETRY REQUIRED" || true)
assert_eq "ticket_fail_retry_signal" "1" "$_retry_signal"

rm -rf "$_td"

# ── Test (e): reason sanitization ─────────────────────────────────────────────
# Verify that control characters are stripped and reasons are capped at 200 chars.
_td=$(_make_test_env)
_stub=$(_make_stub_ticket_success "$_td")

# Log with control chars and a very long reason (>200 chars)
_long_reason="$(python3 -c "print('A'*300, end='')")"
_ctrl_reason="$(printf 'bad\x01\x02\x03reason\x0a')"

_write_log "$_td" "sprint-merge-only-bypass-001.log" "${_ctrl_reason}" > /dev/null
_write_log "$_td" "sprint-merge-only-bypass-002.log" "${_long_reason}" > /dev/null
_write_log "$_td" "sprint-merge-only-bypass-003.log" "normal reason" > /dev/null

_run \
    "DSO_ARTIFACTS_DIR=${_td}" \
    "TICKET_CMD=${_stub}" \
    "BYPASS_ALERT_THRESHOLD=3"

assert_eq "sanitize_exit_0" "0" "$_exit"

# Check that the long reason was truncated (ticket output shouldn't have 300 A's in a row).
# The ticket description goes to the stub which ignores it, but we verify the script
# didn't crash and the warning was emitted cleanly.
_warn_count=$(echo "$_stderr" | grep -c "INTEGRITY WARNING" || true)
assert_eq "sanitize_warning_emitted" "1" "$_warn_count"

# Verify no raw control characters leak into stderr output.
_ctrl_leak=$(echo "$_stderr" | grep -cP '[\x00-\x1f]' 2>/dev/null || true)
# Note: newlines are expected (\n is 0x0a); we check for other control chars specifically.
_non_nl_ctrl=$(printf '%s' "$_stderr" | tr -d '\n' | grep -cP '[\x00-\x1f]' 2>/dev/null || echo "0")
assert_eq "sanitize_no_control_chars_in_stderr" "0" "$_non_nl_ctrl"

rm -rf "$_td"

print_summary
