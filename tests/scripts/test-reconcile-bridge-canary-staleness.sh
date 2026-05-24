#!/usr/bin/env bash
# tests/scripts/test-reconcile-bridge-canary-staleness.sh
# Structural unit tests for reconcile-bridge-canary staleness-detection logic.
#
# Story: 7004-3121-e68b-4d80 (external heartbeat monitor: status badge /
#   scheduled-canary action)
# Done Definition: "a simulated workflow disable triggers a heartbeat alert
#   within the configured window (manual verification)" — this test satisfies
#   the deterministic / CI-safe portion of that requirement by exercising the
#   staleness check script directly with controlled timestamps.
#
# Tests:
#   1. Stale timestamp (older than threshold) → stale=true
#   2. Fresh timestamp (within threshold) → stale=false
#   3. "never" (no successful runs) → stale=true
#   4. "api-error" (transient GitHub error) → stale=false (no false alarm)
#   5. Boundary: exactly at cutoff (run_epoch == cutoff_epoch) → stale=false
#   6. Boundary: one second past cutoff → stale=true
#   7. Invalid alert_window_hours (zero) → exit 1
#   8. Invalid alert_window_hours (non-integer) → exit 1
#   9. Ticket-creation message includes required template sections
#      (verified by checking the canary workflow YAML contains the template)
#
# Usage: bash tests/scripts/test-reconcile-bridge-canary-staleness.sh
# Returns: exit 0 if all assertions pass, exit 1 if any fail.

# NOTE: -e omitted intentionally — assert helpers return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CANARY_CHECK="$REPO_ROOT/plugins/dso/scripts/reconcile-bridge-canary-check.sh"
CANARY_WORKFLOW="$REPO_ROOT/.github/workflows/reconcile-bridge-canary.yml"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-reconcile-bridge-canary-staleness.sh ==="

# ── Prereq: helper script exists and is executable ────────────────────────────
assert_eq \
  "prereq: reconcile-bridge-canary-check.sh exists" \
  "1" \
  "$(test -f "$CANARY_CHECK" && echo 1 || echo 0)"

assert_eq \
  "prereq: reconcile-bridge-canary-check.sh is executable" \
  "1" \
  "$(test -x "$CANARY_CHECK" && echo 1 || echo 0)"

assert_eq \
  "prereq: canary workflow YAML exists" \
  "1" \
  "$(test -f "$CANARY_WORKFLOW" && echo 1 || echo 0)"

# ── Helper: extract a key=value line from check output ───────────────────────
# Usage: _get_field <output> <key>
_get_field() {
  local output="$1"
  local key="$2"
  echo "$output" | grep "^${key}=" | sed "s/^${key}=//"
}

# ── Shared reference: "now" epoch for deterministic tests ────────────────────
# Use a fixed point in time: 2026-05-23T12:00:00Z → 1748001600
# Computed via: python3 -c "import calendar,datetime; print(calendar.timegm(datetime.datetime(2026,5,23,12,0,0).timetuple()))"
# This makes all tests fully deterministic regardless of wall-clock time.
NOW_EPOCH=1748001600
ALERT_WINDOW_HOURS=2
WINDOW_SECS=$(( ALERT_WINDOW_HOURS * 3600 ))
CUTOFF_EPOCH=$(( NOW_EPOCH - WINDOW_SECS ))

echo ""
echo "test_stale_timestamp_older_than_threshold"
echo "  Timestamp older than 2h threshold should emit stale=true"
_snapshot_fail

# A timestamp 3 hours before now → run_epoch < cutoff_epoch → stale
STALE_EPOCH=$(( NOW_EPOCH - 3 * 3600 ))
out=$("$CANARY_CHECK" \
  --alert-window-hours "$ALERT_WINDOW_HOURS" \
  --last-success-epoch "$STALE_EPOCH" \
  --now-epoch "$NOW_EPOCH")

assert_eq \
  "stale_ts: stale=true emitted" \
  "true" \
  "$(_get_field "$out" stale)"

assert_contains \
  "stale_ts: last_run_ago contains hours" \
  "h" \
  "$(_get_field "$out" last_run_ago)"

assert_contains \
  "stale_ts: status_msg mentions threshold" \
  "threshold" \
  "$(_get_field "$out" status_msg)"

assert_pass_if_clean "test_stale_timestamp_older_than_threshold"

echo ""
echo "test_fresh_timestamp_within_threshold"
echo "  Timestamp within 2h threshold should emit stale=false"
_snapshot_fail

# A timestamp 30 minutes before now → run_epoch >= cutoff_epoch → not stale
FRESH_EPOCH=$(( NOW_EPOCH - 1800 ))
out=$("$CANARY_CHECK" \
  --alert-window-hours "$ALERT_WINDOW_HOURS" \
  --last-success-epoch "$FRESH_EPOCH" \
  --now-epoch "$NOW_EPOCH")

assert_eq \
  "fresh_ts: stale=false emitted" \
  "false" \
  "$(_get_field "$out" stale)"

assert_contains \
  "fresh_ts: status_msg mentions healthy" \
  "healthy" \
  "$(_get_field "$out" status_msg)"

assert_contains \
  "fresh_ts: last_run_ago contains time info" \
  "m ago" \
  "$(_get_field "$out" last_run_ago)"

assert_pass_if_clean "test_fresh_timestamp_within_threshold"

echo ""
echo "test_never_case"
echo "  'never' (no successful runs ever) should emit stale=true"
_snapshot_fail

out=$("$CANARY_CHECK" \
  --alert-window-hours "$ALERT_WINDOW_HOURS" \
  --last-success-epoch "never" \
  --now-epoch "$NOW_EPOCH")

assert_eq \
  "never: stale=true emitted" \
  "true" \
  "$(_get_field "$out" stale)"

assert_eq \
  "never: last_run_ago=never emitted" \
  "never" \
  "$(_get_field "$out" last_run_ago)"

assert_contains \
  "never: status_msg mentions no runs found" \
  "No successful" \
  "$(_get_field "$out" status_msg)"

assert_pass_if_clean "test_never_case"

echo ""
echo "test_api_error_case"
echo "  'api-error' (transient GitHub error) should emit stale=false (no false alarm)"
_snapshot_fail

out=$("$CANARY_CHECK" \
  --alert-window-hours "$ALERT_WINDOW_HOURS" \
  --last-success-epoch "api-error" \
  --now-epoch "$NOW_EPOCH")

assert_eq \
  "api_error: stale=false emitted" \
  "false" \
  "$(_get_field "$out" stale)"

assert_eq \
  "api_error: last_run_ago=unknown emitted" \
  "unknown" \
  "$(_get_field "$out" last_run_ago)"

assert_contains \
  "api_error: status_msg mentions transient" \
  "transient" \
  "$(_get_field "$out" status_msg)"

assert_pass_if_clean "test_api_error_case"

echo ""
echo "test_boundary_exactly_at_cutoff"
echo "  Timestamp exactly at cutoff (run_epoch == cutoff_epoch) should emit stale=false"
_snapshot_fail

# The workflow condition is: (( run_epoch < cutoff_epoch ))
# So run_epoch == cutoff_epoch → NOT strictly less than → stale=false
EXACT_CUTOFF_EPOCH=$CUTOFF_EPOCH
out=$("$CANARY_CHECK" \
  --alert-window-hours "$ALERT_WINDOW_HOURS" \
  --last-success-epoch "$EXACT_CUTOFF_EPOCH" \
  --now-epoch "$NOW_EPOCH")

assert_eq \
  "boundary_at_cutoff: stale=false (run_epoch == cutoff_epoch)" \
  "false" \
  "$(_get_field "$out" stale)"

assert_pass_if_clean "test_boundary_exactly_at_cutoff"

echo ""
echo "test_boundary_one_second_past_cutoff"
echo "  Timestamp 1s past cutoff (run_epoch == cutoff_epoch - 1) should emit stale=true"
_snapshot_fail

ONE_PAST_CUTOFF=$(( CUTOFF_EPOCH - 1 ))
out=$("$CANARY_CHECK" \
  --alert-window-hours "$ALERT_WINDOW_HOURS" \
  --last-success-epoch "$ONE_PAST_CUTOFF" \
  --now-epoch "$NOW_EPOCH")

assert_eq \
  "boundary_past_cutoff: stale=true (run_epoch < cutoff_epoch)" \
  "true" \
  "$(_get_field "$out" stale)"

assert_pass_if_clean "test_boundary_one_second_past_cutoff"

echo ""
echo "test_invalid_alert_window_zero"
echo "  alert_window_hours=0 should exit 1 (zero is not a positive integer)"
_snapshot_fail

invalid_exit=0
"$CANARY_CHECK" \
  --alert-window-hours "0" \
  --last-success-epoch "$NOW_EPOCH" \
  --now-epoch "$NOW_EPOCH" 2>/dev/null || invalid_exit=$?

assert_eq \
  "invalid_zero: exit code is 1" \
  "1" \
  "$invalid_exit"

assert_pass_if_clean "test_invalid_alert_window_zero"

echo ""
echo "test_invalid_alert_window_non_integer"
echo "  alert_window_hours='abc' should exit 1"
_snapshot_fail

invalid_exit2=0
"$CANARY_CHECK" \
  --alert-window-hours "abc" \
  --last-success-epoch "$NOW_EPOCH" \
  --now-epoch "$NOW_EPOCH" 2>/dev/null || invalid_exit2=$?

assert_eq \
  "invalid_str: exit code is 1" \
  "1" \
  "$invalid_exit2"

assert_pass_if_clean "test_invalid_alert_window_non_integer"

echo ""
echo "test_ticket_creation_message_template_sections"
echo "  Canary workflow YAML must contain required DSO bug-ticket template sections"
_snapshot_fail

# The workflow's ticket-creation command must include the three required
# template sections so that the filed bug is properly structured for triage.
# We verify these are present in the YAML source (structural check).
wf_content=""
wf_content=$(cat "$CANARY_WORKFLOW")

assert_contains \
  "template: '### 1. Technical Environment' section present in workflow" \
  "### 1. Technical Environment" \
  "$wf_content"

assert_contains \
  "template: '### 2. Incident Overview' section present in workflow" \
  "### 2. Incident Overview" \
  "$wf_content"

assert_contains \
  "template: '### 3. Action History' section present in workflow" \
  "### 3. Action History" \
  "$wf_content"

# Confirm the alert tag is set to heartbeat-alert (referenced by find_ticket step)
assert_contains \
  "template: ALERT_TAG=heartbeat-alert in workflow" \
  "heartbeat-alert" \
  "$wf_content"

# Confirm priority 1 is used (P1 bug per the story requirement)
assert_contains \
  "template: --priority 1 in ticket-create command" \
  "--priority 1" \
  "$wf_content"

assert_pass_if_clean "test_ticket_creation_message_template_sections"

echo ""
echo "test_large_alert_window"
echo "  alert_window_hours=24 with a 25h-old timestamp should emit stale=true"
_snapshot_fail

LARGE_WINDOW=24
EPOCH_25H_OLD=$(( NOW_EPOCH - 25 * 3600 ))
out=$("$CANARY_CHECK" \
  --alert-window-hours "$LARGE_WINDOW" \
  --last-success-epoch "$EPOCH_25H_OLD" \
  --now-epoch "$NOW_EPOCH")

assert_eq \
  "large_window: stale=true for 25h-old run in 24h window" \
  "true" \
  "$(_get_field "$out" stale)"

assert_contains \
  "large_window: status_msg references 24h threshold" \
  "24h" \
  "$(_get_field "$out" status_msg)"

assert_pass_if_clean "test_large_alert_window"

echo ""
echo "test_large_alert_window_fresh"
echo "  alert_window_hours=24 with a 23h-old timestamp should emit stale=false"
_snapshot_fail

EPOCH_23H_OLD=$(( NOW_EPOCH - 23 * 3600 ))
out=$("$CANARY_CHECK" \
  --alert-window-hours "$LARGE_WINDOW" \
  --last-success-epoch "$EPOCH_23H_OLD" \
  --now-epoch "$NOW_EPOCH")

assert_eq \
  "large_window_fresh: stale=false for 23h-old run in 24h window" \
  "false" \
  "$(_get_field "$out" stale)"

assert_pass_if_clean "test_large_alert_window_fresh"

# ── Test 12: default --now-epoch path (no override) uses real wall clock ─────
# Production canary invokes the helper WITHOUT --now-epoch; the script must
# default to `date -u +%s`. Test the default path with a known-fresh
# last-success timestamp so the result is deterministic regardless of when
# the test runs.
echo "--- test_default_now_epoch_uses_real_clock ---"
_snapshot_fail

# Use a last-success epoch one second from now (well within ANY alert window)
LAST_SUCCESS_NOWISH=$(( $(date -u +%s) ))
out=$("$CANARY_CHECK" \
  --alert-window-hours 2 \
  --last-success-epoch "$LAST_SUCCESS_NOWISH")
# Default now-epoch path resolves now to real time → fresh result.
assert_eq \
  "default_now_epoch: stale=false when last-success is current wall clock" \
  "false" \
  "$(_get_field "$out" stale)"

assert_pass_if_clean "test_default_now_epoch_uses_real_clock"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
