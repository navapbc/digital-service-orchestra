#!/usr/bin/env bash
# tests/scripts/test-cutover-tickets-migration.sh
# TDD RED phase: failing tests for cutover-tickets-migration.sh phase-gate skeleton.
#
# Tests (all must FAIL before T2 implementation — script does not yet exist):
#   1. test_cutover_phases_execute_in_order — all 5 phase names appear in log order, exit 0
#   2. test_cutover_creates_log_file_with_timestamp — log file at CUTOVER_LOG_DIR matching pattern
#   3. test_cutover_dry_run_flag_produces_output_without_creating_state_file — --dry-run behavior
#
# Usage: bash tests/scripts/test-cutover-tickets-migration.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
CUTOVER_SCRIPT="$REPO_ROOT/plugins/dso/scripts/cutover-tickets-migration.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# =============================================================================
# Fixture helpers
# =============================================================================

# Create a minimal temp git repo fixture for integration tests.
# Sets _FIXTURE_DIR and registers a trap to clean it up.
_setup_fixture() {
    _FIXTURE_DIR=$(mktemp -d)
    trap 'rm -rf "$_FIXTURE_DIR"' EXIT

    # Minimal git repo
    git -C "$_FIXTURE_DIR" init -q
    git -C "$_FIXTURE_DIR" config user.email "test@example.com"
    git -C "$_FIXTURE_DIR" config user.name "Test"

    # Create a .tickets dir (the script will look for tickets here)
    mkdir -p "$_FIXTURE_DIR/.tickets"

    # Log dir for cutover output
    _FIXTURE_LOG_DIR="$_FIXTURE_DIR/cutover-logs"
    mkdir -p "$_FIXTURE_LOG_DIR"
}

# =============================================================================
# Structural check: script exists
# (This FAILS in RED phase — script does not exist yet)
# =============================================================================
if [[ -f "$CUTOVER_SCRIPT" ]]; then
    _SCRIPT_EXISTS="true"
else
    _SCRIPT_EXISTS="false"
fi
assert_eq "test_cutover_script_exists" "true" "$_SCRIPT_EXISTS"

# =============================================================================
# Test 1: test_cutover_phases_execute_in_order
#
# Run the script against a temp git repo fixture.
# Assert all 5 phase names appear in order in the log output.
# Assert exit 0.
#
# Expected phases (in order): validate, snapshot, migrate, verify, finalize
# RED: fails because the script does not exist yet.
# =============================================================================
_setup_fixture

_PHASES_OUTPUT=""
_PHASES_RC=1

if [[ -f "$CUTOVER_SCRIPT" ]]; then
    _PHASES_OUTPUT=$(
        CUTOVER_LOG_DIR="$_FIXTURE_LOG_DIR" \
        bash "$CUTOVER_SCRIPT" --repo-root="$_FIXTURE_DIR" 2>&1
    ) || true
    _PHASES_RC=$?
else
    _PHASES_OUTPUT="cutover-tickets-migration.sh: not found"
    _PHASES_RC=127
fi

# Assert exit 0
assert_eq "test_cutover_phases_execute_in_order_exit_0" "0" "$_PHASES_RC"

# Assert all 5 phase names appear, in order
_PHASE_ORDER_OK="false"
if [[ "$_PHASES_RC" -eq 0 ]]; then
    # Extract only lines containing phase names, check ordering
    _PHASE_LINE_VALIDATE=$(echo "$_PHASES_OUTPUT" | grep -n 'validate' | head -1 | cut -d: -f1)
    _PHASE_LINE_SNAPSHOT=$(echo "$_PHASES_OUTPUT" | grep -n 'snapshot' | head -1 | cut -d: -f1)
    _PHASE_LINE_MIGRATE=$(echo "$_PHASES_OUTPUT" | grep -n 'migrate'  | head -1 | cut -d: -f1)
    _PHASE_LINE_VERIFY=$(echo "$_PHASES_OUTPUT"  | grep -n 'verify'   | head -1 | cut -d: -f1)
    _PHASE_LINE_FINALIZE=$(echo "$_PHASES_OUTPUT" | grep -n 'finalize' | head -1 | cut -d: -f1)

    if [[ -n "$_PHASE_LINE_VALIDATE" && -n "$_PHASE_LINE_SNAPSHOT" && \
          -n "$_PHASE_LINE_MIGRATE"  && -n "$_PHASE_LINE_VERIFY"   && \
          -n "$_PHASE_LINE_FINALIZE" ]]; then
        # Verify strictly increasing line numbers
        if [[ "$_PHASE_LINE_VALIDATE" -lt "$_PHASE_LINE_SNAPSHOT" && \
              "$_PHASE_LINE_SNAPSHOT" -lt "$_PHASE_LINE_MIGRATE"  && \
              "$_PHASE_LINE_MIGRATE"  -lt "$_PHASE_LINE_VERIFY"   && \
              "$_PHASE_LINE_VERIFY"   -lt "$_PHASE_LINE_FINALIZE" ]]; then
            _PHASE_ORDER_OK="true"
        fi
    fi
fi
assert_eq "test_cutover_phases_execute_in_order" "true" "$_PHASE_ORDER_OK"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR

# =============================================================================
# Test 2: test_cutover_creates_log_file_with_timestamp
#
# Run the script with CUTOVER_LOG_DIR set to a temp directory.
# Assert a log file matching cutover-YYYY-MM-DDTHH-MM-SS.log exists there.
# Assert the file is non-empty.
#
# RED: fails because the script does not exist yet.
# =============================================================================
_setup_fixture

_LOG_FILE_RC=1
if [[ -f "$CUTOVER_SCRIPT" ]]; then
    CUTOVER_LOG_DIR="$_FIXTURE_LOG_DIR" \
    bash "$CUTOVER_SCRIPT" --repo-root="$_FIXTURE_DIR" 2>&1 >/dev/null || true
    _LOG_FILE_RC=$?
else
    _LOG_FILE_RC=127
fi

# Find a log file matching the timestamp pattern
_LOG_MATCH=$(find "$_FIXTURE_LOG_DIR" -maxdepth 1 -name 'cutover-????-??-??T??-??-??.log' 2>/dev/null | head -1)

if [[ -n "$_LOG_MATCH" ]]; then
    _LOG_EXISTS="true"
else
    _LOG_EXISTS="false"
    _LOG_MATCH="(not found)"
fi
assert_eq "test_cutover_creates_log_file_with_timestamp" "true" "$_LOG_EXISTS"

# Assert non-empty
if [[ -n "$_LOG_MATCH" && -s "$_LOG_MATCH" ]]; then
    _LOG_NONEMPTY="true"
else
    _LOG_NONEMPTY="false"
fi
assert_eq "test_cutover_log_file_is_nonempty" "true" "$_LOG_NONEMPTY"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR

# =============================================================================
# Test 3: test_cutover_dry_run_flag_produces_output_without_creating_state_file
#
# Run the script with --dry-run.
# Assert output contains "[DRY RUN]" prefix on at least one line.
# Assert no state file is created (CUTOVER_STATE_FILE should not exist).
# Assert exit 0.
#
# RED: fails because the script does not exist yet.
# =============================================================================
_setup_fixture

_DRYRUN_OUTPUT=""
_DRYRUN_RC=1
_DRYRUN_STATE_FILE="$_FIXTURE_DIR/.cutover-state.json"

if [[ -f "$CUTOVER_SCRIPT" ]]; then
    _DRYRUN_OUTPUT=$(
        CUTOVER_LOG_DIR="$_FIXTURE_LOG_DIR" \
        CUTOVER_STATE_FILE="$_DRYRUN_STATE_FILE" \
        bash "$CUTOVER_SCRIPT" --repo-root="$_FIXTURE_DIR" --dry-run 2>&1
    ) || true
    _DRYRUN_RC=$?
else
    _DRYRUN_OUTPUT="cutover-tickets-migration.sh: not found"
    _DRYRUN_RC=127
fi

# Assert exit 0
assert_eq "test_cutover_dry_run_flag_produces_output_without_creating_state_file_exit_0" "0" "$_DRYRUN_RC"

# Assert [DRY RUN] prefix appears in output
if echo "$_DRYRUN_OUTPUT" | grep -q '\[DRY RUN\]'; then
    _DRYRUN_PREFIX_OK="true"
else
    _DRYRUN_PREFIX_OK="false"
fi
assert_eq "test_cutover_dry_run_output_has_prefix" "true" "$_DRYRUN_PREFIX_OK"

# Assert no state file was created
if [[ -f "$_DRYRUN_STATE_FILE" ]]; then
    _NO_STATE_FILE="false"
else
    _NO_STATE_FILE="true"
fi
assert_eq "test_cutover_dry_run_flag_produces_output_without_creating_state_file" "true" "$_NO_STATE_FILE"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR

# =============================================================================
print_summary
