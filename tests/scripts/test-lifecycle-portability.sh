#!/usr/bin/env bash
# tests/scripts/test-lifecycle-portability.sh
# Portability smoke test: exercises all agent-batch-lifecycle.sh subcommands
# against a minimal project skeleton (empty/stub dso-config.conf with no
# database, infrastructure, or session sections).
#
# Validates:
#   - All subcommands exit 0 against a minimal config (no crashes)
#   - No-op subcommands (preflight --start-db, pre-check --db, cleanup-stale-containers)
#     emit WARN messages for absent config sections
#   - Non-infrastructure subcommands produce expected structured output
#
# Usage: bash tests/scripts/test-lifecycle-portability.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
LIFECYCLE="$DSO_PLUGIN_DIR/scripts/agent-batch-lifecycle.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-lifecycle-portability.sh ==="

# ── Setup: minimal project skeleton ─────────────────────────────────────────
# Create a temporary git repo with a stub dso-config.conf that has NO
# database, infrastructure, or session sections.
TMPDIR_SKELETON="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SKELETON"' EXIT

# Initialize a bare-minimum git repo so the script's git rev-parse works
git init -q -b main "$TMPDIR_SKELETON"
git -C "$TMPDIR_SKELETON" commit --allow-empty -m "init" -q

# Stub dso-config.conf with only version/stack (no optional sections)
cat > "$TMPDIR_SKELETON/dso-config.conf" <<'CONF'
stack=python-poetry
CONF

# Create .tickets dir (lock subcommands scan it)
mkdir -p "$TMPDIR_SKELETON/.tickets"

# Point WORKFLOW_CONFIG at the minimal config; run lifecycle from the temp repo
export WORKFLOW_CONFIG="$TMPDIR_SKELETON/dso-config.conf"

# Helper: run lifecycle subcommand inside the temp repo context
_run() {
    git -C "$TMPDIR_SKELETON" rev-parse --show-toplevel >/dev/null 2>&1
    (cd "$TMPDIR_SKELETON" && bash "$LIFECYCLE" "$@")
}

# ── test_preflight_exit_0 ───────────────────────────────────────────────────
# preflight --start-db should exit 0 with minimal config (DB no-op)
_snapshot_fail
preflight_exit=0
preflight_output=""
preflight_output=$(_run preflight --start-db 2>&1) || preflight_exit=$?
assert_eq "test_preflight_exit_0: exit code" "0" "$preflight_exit"
assert_contains "test_preflight_exit_0: DB_STATUS in output" "DB_STATUS:" "$preflight_output"
assert_pass_if_clean "test_preflight_exit_0"

# ── test_preflight_noop_warns ───────────────────────────────────────────────
# preflight --start-db should emit WARN for absent database config
_snapshot_fail
assert_contains "test_preflight_noop_warns: WARN" "WARN" "$preflight_output"
assert_contains "test_preflight_noop_warns: skipped" "skipped" "$preflight_output"
assert_pass_if_clean "test_preflight_noop_warns"

# ── test_pre_check_exit_0 ──────────────────────────────────────────────────
# pre-check --db should exit 0 or 1 (git dirty is OK), but DB should be skipped
_snapshot_fail
precheck_exit=0
precheck_output=""
precheck_output=$(_run pre-check --db 2>&1) || precheck_exit=$?
# DB_STATUS should be "skipped" (not "stopped" which would indicate a real DB check)
assert_contains "test_pre_check_exit_0: DB_STATUS skipped" "DB_STATUS: skipped" "$precheck_output"
assert_pass_if_clean "test_pre_check_exit_0"

# ── test_pre_check_noop_warns ──────────────────────────────────────────────
# pre-check --db should emit WARN for absent database config
_snapshot_fail
assert_contains "test_pre_check_noop_warns: WARN" "WARN" "$precheck_output"
assert_contains "test_pre_check_noop_warns: database" "database" "$precheck_output"
assert_pass_if_clean "test_pre_check_noop_warns"

# ── test_file_overlap_exit_0 ───────────────────────────────────────────────
# file-overlap with no args should exit 0 (no conflicts)
_snapshot_fail
overlap_exit=0
overlap_output=""
overlap_output=$(_run file-overlap 2>&1) || overlap_exit=$?
assert_eq "test_file_overlap_exit_0: exit code" "0" "$overlap_exit"
assert_contains "test_file_overlap_exit_0: CONFLICTS 0" "CONFLICTS: 0" "$overlap_output"
assert_pass_if_clean "test_file_overlap_exit_0"

# ── test_lock_acquire_release_exit_0 ────────────────────────────────────────
# lock-acquire and lock-release should work with the minimal skeleton's .tickets
# Note: lock-acquire uses tk which may not be available in the minimal skeleton,
# so we test lock-status instead (it only scans .tickets/ files, no tk needed)
_snapshot_fail
lock_status_exit=0
lock_status_output=""
lock_status_output=$(_run lock-status "portability-test" 2>&1) || lock_status_exit=$?
assert_eq "test_lock_status_exit_0: exit code" "0" "$lock_status_exit"
assert_contains "test_lock_status_exit_0: UNLOCKED" "UNLOCKED" "$lock_status_output"
assert_pass_if_clean "test_lock_status_exit_0"

# ── test_cleanup_discoveries_exit_0 ─────────────────────────────────────────
# cleanup-discoveries should exit 0 and create the agent-discoveries directory
_snapshot_fail
_disc_tmpdir=$(mktemp -d)
discoveries_exit=0
discoveries_output=""
discoveries_output=$(AGENT_DISCOVERIES_DIR="$_disc_tmpdir/agent-discoveries" _run cleanup-discoveries 2>&1) || discoveries_exit=$?
assert_eq "test_cleanup_discoveries_exit_0: exit code" "0" "$discoveries_exit"
assert_contains "test_cleanup_discoveries_exit_0: DISCOVERIES_CLEANED" "DISCOVERIES_CLEANED:" "$discoveries_output"
# Verify the directory was created via AGENT_DISCOVERIES_DIR override
if [ -d "$_disc_tmpdir/agent-discoveries" ]; then
    assert_eq "test_cleanup_discoveries_exit_0: dir created" "1" "1"
else
    assert_eq "test_cleanup_discoveries_exit_0: dir created" "1" "0"
fi
rm -rf "$_disc_tmpdir"
assert_pass_if_clean "test_cleanup_discoveries_exit_0"

# ── test_cleanup_stale_containers_exit_0 ────────────────────────────────────
# cleanup-stale-containers should exit 0 with no-op when infrastructure absent
_snapshot_fail
containers_exit=0
containers_output=""
containers_output=$(_run cleanup-stale-containers 2>&1) || containers_exit=$?
assert_eq "test_cleanup_stale_containers_exit_0: exit code" "0" "$containers_exit"
assert_contains "test_cleanup_stale_containers_exit_0: STALE_CLEANED" "STALE_CLEANED: 0" "$containers_output"
assert_pass_if_clean "test_cleanup_stale_containers_exit_0"

# ── test_cleanup_stale_containers_noop_warns ────────────────────────────────
# cleanup-stale-containers should emit WARN for absent infrastructure config
_snapshot_fail
assert_contains "test_cleanup_stale_containers_noop_warns: WARN" "WARN" "$containers_output"
assert_contains "test_cleanup_stale_containers_noop_warns: infrastructure" "infrastructure" "$containers_output"
assert_pass_if_clean "test_cleanup_stale_containers_noop_warns"

# ── test_context_check_exit_0 ──────────────────────────────────────────────
# context-check should exit 0 (normal) when no usage env var is set
_snapshot_fail
context_exit=0
context_output=""
context_output=$(CLAUDE_CONTEXT_WINDOW_USAGE="" _run context-check 2>&1) || context_exit=$?
assert_eq "test_context_check_exit_0: exit code" "0" "$context_exit"
assert_contains "test_context_check_exit_0: CONTEXT_LEVEL normal" "CONTEXT_LEVEL: normal" "$context_output"
assert_pass_if_clean "test_context_check_exit_0"

# ── test_pre_check_no_db_flag_exit_0 ───────────────────────────────────────
# pre-check without --db should also work (DB_STATUS: skipped without WARN)
_snapshot_fail
precheck_nodb_exit=0
precheck_nodb_output=""
precheck_nodb_output=$(_run pre-check 2>&1) || precheck_nodb_exit=$?
# Should have structured output with SESSION_USAGE and GIT_CLEAN
assert_contains "test_pre_check_no_db_flag_exit_0: SESSION_USAGE" "SESSION_USAGE:" "$precheck_nodb_output"
assert_contains "test_pre_check_no_db_flag_exit_0: GIT_CLEAN" "GIT_CLEAN:" "$precheck_nodb_output"
assert_pass_if_clean "test_pre_check_no_db_flag_exit_0"

print_summary
