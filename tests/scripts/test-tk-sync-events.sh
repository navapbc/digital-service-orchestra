#!/usr/bin/env bash
# tests/scripts/test-tk-sync-events.sh
#
# RED tests for _sync_events split-phase git sync in plugins/dso/scripts/tk.
#
# Ticket: w20-gclc
# Parent: w21-6k7v (sync-events story)
#
# All tests MUST FAIL before the implementation of _sync_events (RED phase).
# Run after T4 implementation to verify GREEN.
#
# Tests:
#   test_sync_events_cmd_exists_in_tk       — 'tk sync-events --help' outputs usage
#   test_sync_events_fetch_no_flock         — flock NOT held during git fetch phase
#   test_sync_events_flock_held_during_merge — flock IS held during git merge phase
#   test_sync_events_flock_released_after_merge — flock released before push begins
#   test_sync_events_flock_released_on_merge_failure — flock released on merge error
#   test_sync_events_push_retry_on_non_fast_forward  — push retries on exit 128
#   test_sync_events_fetch_timeout_30s      — fetch uses 'timeout 30 git'
#   test_sync_events_push_timeout_30s       — push uses 'timeout 30 git'
#   test_sync_events_merge_timeout_10s      — merge uses 'timeout 10 git merge'
#   test_sync_events_total_budget_under_60s — full cycle completes within 60s
#
# Usage: bash tests/scripts/test-tk-sync-events.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# Expected result before T4 implementation: non-zero exit (all/most tests fail)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
TK_SCRIPT="$DSO_PLUGIN_DIR/scripts/tk"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-tk-sync-events.sh ==="

# ── test_sync_events_cmd_exists_in_tk ────────────────────────────────────────
# 'tk sync-events --help' must output usage text (not "Unknown command: sync-events").
# RED: fails because sync-events is not registered in tk's command dispatcher.
_snapshot_fail
_cmd_output=$(bash "$TK_SCRIPT" sync-events --help 2>&1 || true)
_cmd_registered=0
if echo "$_cmd_output" | grep -qi 'sync.events\|usage.*sync'; then
    _cmd_registered=1
fi
if echo "$_cmd_output" | grep -qi 'Unknown command'; then
    _cmd_registered=0
fi
assert_eq "test_sync_events_cmd_exists_in_tk" "1" "$_cmd_registered"
assert_pass_if_clean "test_sync_events_cmd_exists_in_tk"

# ── test_sync_events_fetch_no_flock ──────────────────────────────────────────
# The _sync_events function must NOT hold any flock during the git fetch phase.
# The design: fetch happens outside the flock window (split-phase design).
# Static analysis: _sync_events must appear in tk before any 'flock' call in
# its body, specifically: the fetch call must precede the flock -x line.
# RED: fails because _sync_events function does not exist in tk.
_snapshot_fail
_sync_events_body=$(awk '/_sync_events\(\)/{found=1} found{print; if(/^\}$/) exit}' "$TK_SCRIPT" 2>/dev/null || true)
_has_sync_events=0
if [[ -n "$_sync_events_body" ]]; then
    _has_sync_events=1
fi
assert_eq "test_sync_events_fetch_no_flock: _sync_events function exists" "1" "$_has_sync_events"

# Within the function body: fetch must appear before the first flock line.
_fetch_line=0
_flock_line=0
if [[ -n "$_sync_events_body" ]]; then
    _fetch_line=$(echo "$_sync_events_body" | grep -n 'git.*fetch\|fetch.*git' | head -1 | cut -d: -f1)
    _flock_line=$(echo "$_sync_events_body" | grep -n 'flock' | head -1 | cut -d: -f1)
    : "${_fetch_line:=0}"
    : "${_flock_line:=0}"
fi
# fetch line must be before flock line (both > 0, fetch < flock)
_fetch_before_flock=0
if [[ "$_fetch_line" -gt 0 && "$_flock_line" -gt 0 && "$_fetch_line" -lt "$_flock_line" ]]; then
    _fetch_before_flock=1
fi
assert_eq "test_sync_events_fetch_no_flock: fetch precedes flock in _sync_events" "1" "$_fetch_before_flock"
assert_pass_if_clean "test_sync_events_fetch_no_flock"

# ── test_sync_events_flock_held_during_merge ─────────────────────────────────
# The _sync_events function must hold flock during the git merge phase.
# Static analysis: a 'flock' call must appear before the 'git merge' call
# within _sync_events, and the merge must be inside the locked region.
# RED: fails because _sync_events does not exist.
_snapshot_fail
_has_flock_before_merge=0
if [[ -n "$_sync_events_body" ]]; then
    _flock_first=$(echo "$_sync_events_body" | grep -n 'flock' | head -1 | cut -d: -f1)
    _merge_line=$(echo "$_sync_events_body" | grep -n 'git.*merge\|merge.*git' | head -1 | cut -d: -f1)
    : "${_flock_first:=0}"
    : "${_merge_line:=0}"
    if [[ "$_flock_first" -gt 0 && "$_merge_line" -gt 0 && "$_flock_first" -lt "$_merge_line" ]]; then
        _has_flock_before_merge=1
    fi
fi
assert_eq "test_sync_events_flock_held_during_merge: flock precedes merge in _sync_events" "1" "$_has_flock_before_merge"
assert_pass_if_clean "test_sync_events_flock_held_during_merge"

# ── test_sync_events_flock_released_after_merge ──────────────────────────────
# After git merge completes and before push begins, the flock must be released.
# Static analysis: there must be a flock release (flock -u or closing the fd or
# exec closing the lock fd) between the merge call and the git push call in
# _sync_events body.
# RED: fails because _sync_events does not exist.
_snapshot_fail
_flock_released_before_push=0
if [[ -n "$_sync_events_body" ]]; then
    # Capture line numbers for key operations
    _merge_ln=$(echo "$_sync_events_body" | grep -n 'git.*merge\|merge.*git' | head -1 | cut -d: -f1)
    _push_ln=$(echo "$_sync_events_body" | grep -n 'git.*push\|push.*git' | head -1 | cut -d: -f1)
    # flock release: closing the fd (exec N>&-), flock -u, or exec closing a numbered fd
    _release_ln=$(echo "$_sync_events_body" | grep -nE 'exec [0-9]+>&-|flock -u|_flock_release|unlock' | head -1 | cut -d: -f1)
    : "${_merge_ln:=0}"
    : "${_push_ln:=0}"
    : "${_release_ln:=0}"
    # release must appear after merge and before push
    if [[ "$_release_ln" -gt 0 && "$_merge_ln" -gt 0 && "$_push_ln" -gt 0 ]]; then
        if [[ "$_release_ln" -gt "$_merge_ln" && "$_release_ln" -lt "$_push_ln" ]]; then
            _flock_released_before_push=1
        fi
    fi
fi
assert_eq "test_sync_events_flock_released_after_merge: flock released between merge and push" "1" "$_flock_released_before_push"
assert_pass_if_clean "test_sync_events_flock_released_after_merge"

# ── test_sync_events_flock_released_on_merge_failure ─────────────────────────
# Even when git merge fails, the flock must be released (trap or explicit cleanup).
# Static analysis: _sync_events must contain a trap handler that performs flock
# release, ensuring the lock is freed on the error path.
# RED: fails because _sync_events does not exist.
_snapshot_fail
_has_trap_for_flock_release=0
if [[ -n "$_sync_events_body" ]]; then
    # trap must reference something that closes the lock fd or releases flock
    if echo "$_sync_events_body" | grep -qE "trap.*exec [0-9]+>&-|trap.*flock|trap.*_flock|trap.*unlock|trap.*release"; then
        _has_trap_for_flock_release=1
    fi
fi
assert_eq "test_sync_events_flock_released_on_merge_failure: trap releases flock on error" "1" "$_has_trap_for_flock_release"
assert_pass_if_clean "test_sync_events_flock_released_on_merge_failure"

# ── test_sync_events_push_retry_on_non_fast_forward ──────────────────────────
# When git push exits 128 (non-fast-forward), _sync_events must retry the push.
# Static analysis: _sync_events must contain a retry loop or check for exit 128
# from git push, and re-attempt the push (or re-fetch + re-merge + re-push cycle).
# RED: fails because _sync_events does not exist.
_snapshot_fail
_has_push_retry=0
if [[ -n "$_sync_events_body" ]]; then
    # Look for: retry loop referencing push, OR 128 exit code check, OR while/for loop around push
    if echo "$_sync_events_body" | grep -qE 'retry|128|while.*push|push.*retry|_push_attempt|for.*retry'; then
        _has_push_retry=1
    fi
fi
assert_eq "test_sync_events_push_retry_on_non_fast_forward: retry logic present for exit 128" "1" "$_has_push_retry"
assert_pass_if_clean "test_sync_events_push_retry_on_non_fast_forward"

# ── test_sync_events_fetch_timeout_30s ───────────────────────────────────────
# The fetch invocation in _sync_events must use 'timeout 30 git' to bound the
# fetch phase to 30 seconds.
# Static analysis: grep tk source for 'timeout 30 git.*fetch' within _sync_events.
# RED: fails because _sync_events does not exist.
_snapshot_fail
_fetch_has_timeout30=0
if [[ -n "$_sync_events_body" ]]; then
    if echo "$_sync_events_body" | grep -qE 'timeout 30 git.*fetch|timeout 30.*git fetch'; then
        _fetch_has_timeout30=1
    fi
fi
assert_eq "test_sync_events_fetch_timeout_30s: fetch uses timeout 30 git" "1" "$_fetch_has_timeout30"
assert_pass_if_clean "test_sync_events_fetch_timeout_30s"

# ── test_sync_events_push_timeout_30s ────────────────────────────────────────
# The push invocation in _sync_events must use 'timeout 30 git' to bound the
# push phase to 30 seconds.
# Static analysis: grep tk source for 'timeout 30 git.*push' within _sync_events.
# RED: fails because _sync_events does not exist.
_snapshot_fail
_push_has_timeout30=0
if [[ -n "$_sync_events_body" ]]; then
    if echo "$_sync_events_body" | grep -qE 'timeout 30 git.*push|timeout 30.*git push'; then
        _push_has_timeout30=1
    fi
fi
assert_eq "test_sync_events_push_timeout_30s: push uses timeout 30 git" "1" "$_push_has_timeout30"
assert_pass_if_clean "test_sync_events_push_timeout_30s"

# ── test_sync_events_merge_timeout_10s ───────────────────────────────────────
# The merge invocation in _sync_events must use 'timeout 10 git merge' to bound
# the local merge operation to 10 seconds (local ops are fast; short timeout
# ensures flock isn't held longer than necessary).
# Static analysis: grep tk source for 'timeout 10 git merge' within _sync_events.
# RED: fails because _sync_events does not exist.
_snapshot_fail
_merge_has_timeout10=0
if [[ -n "$_sync_events_body" ]]; then
    if echo "$_sync_events_body" | grep -qE 'timeout 10 git.*merge|timeout 10.*git merge'; then
        _merge_has_timeout10=1
    fi
fi
assert_eq "test_sync_events_merge_timeout_10s: merge uses timeout 10 git merge" "1" "$_merge_has_timeout10"
assert_pass_if_clean "test_sync_events_merge_timeout_10s"

# ── test_sync_events_total_budget_under_60s ──────────────────────────────────
# A full sync-events cycle (fetch + flock + merge + release + push) must
# complete within a 60-second nominal budget when git operations are fast.
#
# Implementation: we create a mock git wrapper that exits 0 after a 0.1s delay
# for all operations, then invoke _sync_events via a subprocess with the mock
# git on PATH, measuring elapsed wall time.
#
# RED: fails because _sync_events does not exist (the command will fail
# immediately with "Unknown command", but we check for function presence first).
_snapshot_fail

# Check if _sync_events is registered as a tk command at all
_sync_events_cmd_registered=0
if bash "$TK_SCRIPT" sync-events --help 2>&1 | grep -qiE 'sync.events|usage'; then
    _sync_events_cmd_registered=1
fi
# If not registered, the time budget test cannot run — fail explicitly
if [[ "$_sync_events_cmd_registered" -eq 0 ]]; then
    assert_eq "test_sync_events_total_budget_under_60s: sync-events cmd registered (required for timing test)" "1" "0"
else
    # Create a temp directory for mock git and a fake tickets dir
    _tmp_dir=$(mktemp -d)
    trap 'rm -rf "$_tmp_dir"' EXIT

    # Write mock git wrapper: sleeps 0.1s then exits 0
    cat > "$_tmp_dir/git" <<'MOCK_GIT'
#!/usr/bin/env bash
sleep 0.1
exit 0
MOCK_GIT
    chmod +x "$_tmp_dir/git"

    # Create a minimal fake tickets dir
    _fake_tickets="$_tmp_dir/tickets"
    mkdir -p "$_fake_tickets"

    # Time the full sync-events cycle
    _start=$(date +%s)
    PATH="$_tmp_dir:$PATH" TICKETS_DIR="$_fake_tickets" \
        timeout 65 bash "$TK_SCRIPT" sync-events 2>/dev/null
    _elapsed=$(( $(date +%s) - _start ))

    if [[ "$_elapsed" -lt 60 ]]; then
        assert_eq "test_sync_events_total_budget_under_60s: elapsed ${_elapsed}s < 60s" "pass" "pass"
    else
        assert_eq "test_sync_events_total_budget_under_60s: elapsed ${_elapsed}s must be < 60s" "under_60s" "over_60s"
    fi
fi
assert_pass_if_clean "test_sync_events_total_budget_under_60s"

print_summary
