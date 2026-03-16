#!/usr/bin/env bash
# tests/scripts/test-lifecycle-noop-guards.sh
# Tests that agent-batch-lifecycle.sh subcommands gracefully no-op when
# database or infrastructure config sections are absent.
#
# Validates:
#   - preflight --start-db warns and exits 0 when database config absent
#   - pre-check --db warns and exits 0 when database config absent
#   - cleanup-stale-containers warns and exits 0 when infrastructure config absent
#   - Warning messages go to stderr (not stdout)
#   - No-op paths do not set any_fail=true (exit 0)
#
# Usage: bash tests/scripts/test-lifecycle-noop-guards.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
LIFECYCLE="$PLUGIN_ROOT/scripts/agent-batch-lifecycle.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-lifecycle-noop-guards.sh ==="

# ── test_preflight_start_db_noop_exit_0 ──────────────────────────────────────
# When database config is absent, preflight --start-db should exit 0
_snapshot_fail
preflight_exit=0
preflight_output=""
preflight_output=$(WORKFLOW_CONFIG=/dev/null bash "$LIFECYCLE" preflight --start-db 2>&1) || preflight_exit=$?
assert_eq "test_preflight_start_db_noop: exit 0" "0" "$preflight_exit"
assert_pass_if_clean "test_preflight_start_db_noop_exit_0"

# ── test_preflight_start_db_noop_warns ───────────────────────────────────────
# Warning message should contain WARN and skipped
_snapshot_fail
assert_contains "test_preflight_start_db_noop: WARN in output" "WARN" "$preflight_output"
assert_contains "test_preflight_start_db_noop: skipped in output" "skipped" "$preflight_output"
assert_pass_if_clean "test_preflight_start_db_noop_warns"

# ── test_preflight_start_db_noop_stderr ──────────────────────────────────────
# Warning should be on stderr, not stdout
_snapshot_fail
preflight_stdout=""
preflight_stdout=$(WORKFLOW_CONFIG=/dev/null bash "$LIFECYCLE" preflight --start-db 2>/dev/null) || true
# stdout should NOT contain WARN
if echo "$preflight_stdout" | grep -q "WARN"; then
    assert_eq "test_preflight_start_db_noop_stderr: WARN not on stdout" "no_warn" "has_warn"
else
    assert_eq "test_preflight_start_db_noop_stderr: WARN not on stdout" "no_warn" "no_warn"
fi
assert_pass_if_clean "test_preflight_start_db_noop_stderr"

# ── test_pre_check_db_noop_exit_0 ───────────────────────────────────────────
# When database config is absent, the DB no-op should not cause failure.
# Note: pre-check may still exit non-zero due to other checks (dirty git).
# We verify DB_STATUS: skipped (not stopped) and WARN message presence.
_snapshot_fail
precheck_exit=0
precheck_output=""
precheck_output=$(WORKFLOW_CONFIG=/dev/null bash "$LIFECYCLE" pre-check --db 2>&1) || precheck_exit=$?
# DB no-op should produce "DB_STATUS: skipped" (not "DB_STATUS: stopped" which sets any_fail)
precheck_stdout_only=""
precheck_stdout_only=$(WORKFLOW_CONFIG=/dev/null bash "$LIFECYCLE" pre-check --db 2>/dev/null) || true
if echo "$precheck_stdout_only" | grep -q "DB_STATUS: stopped"; then
    assert_eq "test_pre_check_db_noop: DB not stopped" "skipped" "stopped"
else
    assert_eq "test_pre_check_db_noop: DB not stopped" "skipped" "skipped"
fi
assert_pass_if_clean "test_pre_check_db_noop_exit_0"

# ── test_pre_check_db_noop_warns ────────────────────────────────────────────
# Warning message should contain WARN and skipped
_snapshot_fail
assert_contains "test_pre_check_db_noop: WARN in output" "WARN" "$precheck_output"
assert_contains "test_pre_check_db_noop: skipped in output" "skipped" "$precheck_output"
assert_pass_if_clean "test_pre_check_db_noop_warns"

# ── test_pre_check_db_noop_stderr ───────────────────────────────────────────
# Warning should be on stderr, not stdout
_snapshot_fail
precheck_stdout=""
precheck_stdout=$(WORKFLOW_CONFIG=/dev/null bash "$LIFECYCLE" pre-check --db 2>/dev/null) || true
if echo "$precheck_stdout" | grep -q "WARN"; then
    assert_eq "test_pre_check_db_noop_stderr: WARN not on stdout" "no_warn" "has_warn"
else
    assert_eq "test_pre_check_db_noop_stderr: WARN not on stdout" "no_warn" "no_warn"
fi
assert_pass_if_clean "test_pre_check_db_noop_stderr"

# ── test_pre_check_db_noop_db_status_skipped ────────────────────────────────
# DB_STATUS should be "skipped" in the structured output (not "stopped")
_snapshot_fail
precheck_stdout2=""
precheck_stdout2=$(WORKFLOW_CONFIG=/dev/null bash "$LIFECYCLE" pre-check --db 2>/dev/null) || true
assert_contains "test_pre_check_db_noop: DB_STATUS skipped" "DB_STATUS: skipped" "$precheck_stdout2"
assert_pass_if_clean "test_pre_check_db_noop_db_status_skipped"

# ── test_cleanup_stale_containers_noop_exit_0 ────────────────────────────────
# When infrastructure config is absent, cleanup-stale-containers should exit 0
_snapshot_fail
cleanup_exit=0
cleanup_output=""
cleanup_output=$(WORKFLOW_CONFIG=/dev/null bash "$LIFECYCLE" cleanup-stale-containers 2>&1) || cleanup_exit=$?
assert_eq "test_cleanup_stale_containers_noop: exit 0" "0" "$cleanup_exit"
assert_pass_if_clean "test_cleanup_stale_containers_noop_exit_0"

# ── test_cleanup_stale_containers_noop_warns ─────────────────────────────────
# Warning message should contain WARN and skipped
_snapshot_fail
assert_contains "test_cleanup_stale_containers_noop: WARN in output" "WARN" "$cleanup_output"
assert_contains "test_cleanup_stale_containers_noop: skipped in output" "skipped" "$cleanup_output"
assert_pass_if_clean "test_cleanup_stale_containers_noop_warns"

# ── test_cleanup_stale_containers_noop_stderr ────────────────────────────────
# Warning should be on stderr, not stdout
_snapshot_fail
cleanup_stdout=""
cleanup_stdout=$(WORKFLOW_CONFIG=/dev/null bash "$LIFECYCLE" cleanup-stale-containers 2>/dev/null) || true
if echo "$cleanup_stdout" | grep -q "WARN"; then
    assert_eq "test_cleanup_stale_containers_noop_stderr: WARN not on stdout" "no_warn" "has_warn"
else
    assert_eq "test_cleanup_stale_containers_noop_stderr: WARN not on stdout" "no_warn" "no_warn"
fi
assert_pass_if_clean "test_cleanup_stale_containers_noop_stderr"

# ── test_warn_message_format ─────────────────────────────────────────────────
# Warning messages should follow: "WARN: <subcommand> skipped — <config_section> not configured"
_snapshot_fail
preflight_stderr=""
preflight_stderr=$(WORKFLOW_CONFIG=/dev/null bash "$LIFECYCLE" preflight --start-db 2>&1 1>/dev/null) || true
assert_contains "test_warn_format_preflight: database not configured" "database" "$preflight_stderr"

precheck_stderr=""
precheck_stderr=$(WORKFLOW_CONFIG=/dev/null bash "$LIFECYCLE" pre-check --db 2>&1 1>/dev/null) || true
assert_contains "test_warn_format_precheck: database not configured" "database" "$precheck_stderr"

cleanup_stderr=""
cleanup_stderr=$(WORKFLOW_CONFIG=/dev/null bash "$LIFECYCLE" cleanup-stale-containers 2>&1 1>/dev/null) || true
assert_contains "test_warn_format_cleanup: infrastructure not configured" "infrastructure" "$cleanup_stderr"
assert_pass_if_clean "test_warn_message_format"

print_summary
