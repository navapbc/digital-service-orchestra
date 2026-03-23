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
_snapshot_fail
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
assert_pass_if_clean "test_cutover_phases_execute_in_order"

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

_snapshot_fail
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
assert_pass_if_clean "test_cutover_creates_log_file_with_timestamp"

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

_snapshot_fail
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
assert_pass_if_clean "test_cutover_dry_run_flag_produces_output_without_creating_state_file"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR

# =============================================================================
# Test 4: test_cutover_rollback_uncommitted_uses_checkout
#
# RED phase: rollback logic does not exist yet — these tests FAIL.
#
# Setup: temp git repo with an initial commit. The MIGRATE phase touches a
# tracked file but exits non-zero WITHOUT committing the change.
# Assert: the working-tree modification is reversed after the script exits
#         (git checkout -- restores the file); exit code non-zero.
# =============================================================================
_setup_fixture

# Create a tracked file with a known initial state
printf 'initial content\n' > "$_FIXTURE_DIR/tracked.txt"
git -C "$_FIXTURE_DIR" add tracked.txt
git -C "$_FIXTURE_DIR" commit -q -m "initial commit"

_ROLLBACK_UC_STATE_FILE="$_FIXTURE_DIR/.cutover-state.json"
_ROLLBACK_UC_RC=0

# Run the script; MIGRATE phase will exit 1 (non-zero, no commit).
# The phase has no rollback today so the file remains modified — RED.
CUTOVER_LOG_DIR="$_FIXTURE_LOG_DIR" \
CUTOVER_STATE_FILE="$_ROLLBACK_UC_STATE_FILE" \
CUTOVER_PHASE_EXIT_OVERRIDE="MIGRATE=1" \
bash "$CUTOVER_SCRIPT" --repo-root="$_FIXTURE_DIR" 2>&1 >/dev/null || _ROLLBACK_UC_RC=$?

_snapshot_fail
# Assert non-zero exit
assert_ne "test_cutover_rollback_uncommitted_uses_checkout_exit_nonzero" "0" "$_ROLLBACK_UC_RC"

# Assert working-tree is clean (rollback reversed uncommitted changes)
_WT_STATUS=$(git -C "$_FIXTURE_DIR" status --porcelain 2>/dev/null)
if [[ -z "$_WT_STATUS" ]]; then
    _WT_CLEAN="true"
else
    _WT_CLEAN="false"
fi
assert_eq "test_cutover_rollback_uncommitted_uses_checkout" "true" "$_WT_CLEAN"
assert_pass_if_clean "test_cutover_rollback_uncommitted_uses_checkout"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR

# =============================================================================
# Test 5: test_cutover_rollback_committed_uses_revert
#
# RED phase: rollback logic does not exist yet — this test FAILS.
#
# Setup: temp git repo. The MIGRATE phase makes a file change and commits it;
# the VERIFY phase then exits non-zero (simulating a post-commit failure).
# Assert: committed change is absent in HEAD after rollback (git revert applied);
#         exit code non-zero.
# =============================================================================
_setup_fixture

# Create tracked file and initial commit
printf 'initial content\n' > "$_FIXTURE_DIR/data.txt"
git -C "$_FIXTURE_DIR" add data.txt
git -C "$_FIXTURE_DIR" commit -q -m "initial commit"

_INITIAL_HEAD=$(git -C "$_FIXTURE_DIR" rev-parse HEAD)
_ROLLBACK_CM_STATE_FILE="$_FIXTURE_DIR/.cutover-state.json"
_ROLLBACK_CM_RC=0

# We need the MIGRATE phase to commit a change, then VERIFY to fail.
# Inject a helper by writing a wrapper script that sources the real cutover
# script's phases but intercepts MIGRATE to make a real commit first.
# Strategy: use CUTOVER_PHASE_EXIT_OVERRIDE="VERIFY=1" and a pre-seeded commit
# by adding a commit directly in the fixture before the run. We also need
# the script to "see" that commit as having been made during the run.
# Simplest approach: produce a commit via a phase wrapper env mechanism.
# Since the real implementation doesn't have commit-in-phase yet, we simulate
# by pre-staging a commit and asserting rollback reverses it.

# Add a "migration commit" to simulate what MIGRATE would do
printf 'migrated content\n' > "$_FIXTURE_DIR/data.txt"
git -C "$_FIXTURE_DIR" add data.txt
git -C "$_FIXTURE_DIR" commit -q -m "cutover: migrate data"
_PRE_FAILURE_HEAD=$(git -C "$_FIXTURE_DIR" rev-parse HEAD)

# Run the cutover script with VERIFY phase failing (post-commit scenario).
# Rollback should detect committed changes and revert them (git revert).
CUTOVER_LOG_DIR="$_FIXTURE_LOG_DIR" \
CUTOVER_STATE_FILE="$_ROLLBACK_CM_STATE_FILE" \
CUTOVER_PHASE_EXIT_OVERRIDE="VERIFY=1" \
bash "$CUTOVER_SCRIPT" --repo-root="$_FIXTURE_DIR" 2>&1 >/dev/null || _ROLLBACK_CM_RC=$?

_snapshot_fail
# Assert non-zero exit
assert_ne "test_cutover_rollback_committed_uses_revert_exit_nonzero" "0" "$_ROLLBACK_CM_RC"

# Assert HEAD advanced past the initial commit (a revert commit was created,
# not a hard reset which would leave HEAD == _INITIAL_HEAD).
_HEAD_AFTER=$(git -C "$_FIXTURE_DIR" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [[ "$_HEAD_AFTER" != "$_INITIAL_HEAD" ]]; then
    _HEAD_ADVANCED="true"
else
    _HEAD_ADVANCED="false"
fi
assert_eq "test_cutover_rollback_committed_uses_revert_head_advanced" "true" "$_HEAD_ADVANCED"

# Assert content at HEAD equals initial content (revert restored the original,
# distinguishing git revert from a checkout/reset that leaves no revert commit).
_HEAD_DATA=$(git -C "$_FIXTURE_DIR" show HEAD:data.txt 2>/dev/null || echo "ERROR")
if [[ "$_HEAD_DATA" == "initial content" ]]; then
    _COMMIT_ROLLED_BACK="true"
else
    _COMMIT_ROLLED_BACK="false"
fi
assert_eq "test_cutover_rollback_committed_uses_revert" "true" "$_COMMIT_ROLLED_BACK"
assert_pass_if_clean "test_cutover_rollback_committed_uses_revert"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR

# =============================================================================
# Test 6: test_cutover_exits_with_error_and_log_path_on_failure
#
# RED phase: error output format with log path is not yet guaranteed — FAILS.
#
# Setup: temp git repo. Force any phase to exit non-zero.
# Assert: stderr contains "ERROR" and the log file path; exit code non-zero.
# =============================================================================
_setup_fixture

_ERR_LOG_STATE_FILE="$_FIXTURE_DIR/.cutover-state.json"
_ERR_LOG_RC=0
_ERR_COMBINED=""

_ERR_COMBINED=$(
    CUTOVER_LOG_DIR="$_FIXTURE_LOG_DIR" \
    CUTOVER_STATE_FILE="$_ERR_LOG_STATE_FILE" \
    CUTOVER_PHASE_EXIT_OVERRIDE="MIGRATE=1" \
    bash "$CUTOVER_SCRIPT" --repo-root="$_FIXTURE_DIR" 2>&1
) || _ERR_LOG_RC=$?

_snapshot_fail
# Assert non-zero exit
assert_ne "test_cutover_exits_with_error_and_log_path_on_failure_exit_nonzero" "0" "$_ERR_LOG_RC"

# Assert stderr contains "ERROR"
if echo "$_ERR_COMBINED" | grep -q 'ERROR'; then
    _HAS_ERROR_WORD="true"
else
    _HAS_ERROR_WORD="false"
fi
assert_eq "test_cutover_exits_with_error_and_log_path_on_failure_has_ERROR" "true" "$_HAS_ERROR_WORD"

# Assert stderr contains a log file path (pattern: /path/to/cutover-*.log)
if echo "$_ERR_COMBINED" | grep -qE 'cutover-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}\.log'; then
    _HAS_LOG_PATH="true"
else
    _HAS_LOG_PATH="false"
fi
assert_eq "test_cutover_exits_with_error_and_log_path_on_failure" "true" "$_HAS_LOG_PATH"
assert_pass_if_clean "test_cutover_exits_with_error_and_log_path_on_failure"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR

# =============================================================================
# Test 7: test_cutover_rollback_distinguishes_commit_boundary
#
# RED phase: commit-boundary detection logic does not exist — FAILS.
#
# Critical adversarial case: when a pre-commit hook REJECTS a commit
# (exits 1, HEAD unchanged), rollback must use working-tree reset (git checkout --)
# NOT git revert (which would fail — there's nothing to revert).
#
# Setup: temp git repo with a pre-commit hook that always exits 1.
# Phase: working-tree modification + git add + attempted git commit (hook rejects).
# Assert: rollback performs working-tree reset; HEAD is unchanged (no new commits,
#         no revert commits); working tree is clean after rollback.
# =============================================================================
_setup_fixture

# Create tracked file with initial commit
printf 'initial content\n' > "$_FIXTURE_DIR/boundary.txt"
git -C "$_FIXTURE_DIR" add boundary.txt
git -C "$_FIXTURE_DIR" commit -q -m "initial commit"

_BOUNDARY_INITIAL_HEAD=$(git -C "$_FIXTURE_DIR" rev-parse HEAD)

# Install a pre-commit hook that always rejects commits
mkdir -p "$_FIXTURE_DIR/.git/hooks"
printf '#!/bin/sh\necho "pre-commit: rejected"\nexit 1\n' > "$_FIXTURE_DIR/.git/hooks/pre-commit"
chmod +x "$_FIXTURE_DIR/.git/hooks/pre-commit"

# Simulate the scenario: MIGRATE phase modifies + stages the file, then
# the attempted commit is rejected by the hook. MIGRATE exits non-zero.
# The script should detect HEAD is unchanged (no commit occurred) and use
# working-tree reset, not git revert.

_BOUNDARY_STATE_FILE="$_FIXTURE_DIR/.cutover-state.json"
_BOUNDARY_RC=0

# We use CUTOVER_PHASE_EXIT_OVERRIDE="MIGRATE=1" to simulate the commit-reject
# scenario. Before running, manually stage a change to simulate what a real
# MIGRATE phase would do (modify + add, then fail to commit due to hook).
printf 'modified content\n' > "$_FIXTURE_DIR/boundary.txt"
git -C "$_FIXTURE_DIR" add boundary.txt

CUTOVER_LOG_DIR="$_FIXTURE_LOG_DIR" \
CUTOVER_STATE_FILE="$_BOUNDARY_STATE_FILE" \
CUTOVER_PHASE_EXIT_OVERRIDE="MIGRATE=1" \
bash "$CUTOVER_SCRIPT" --repo-root="$_FIXTURE_DIR" 2>&1 >/dev/null || _BOUNDARY_RC=$?

_snapshot_fail
# Assert non-zero exit
assert_ne "test_cutover_rollback_distinguishes_commit_boundary_exit_nonzero" "0" "$_BOUNDARY_RC"

# Assert HEAD is unchanged (no new commit, no revert commit)
_BOUNDARY_HEAD_AFTER=$(git -C "$_FIXTURE_DIR" rev-parse HEAD 2>/dev/null)
assert_eq "test_cutover_rollback_distinguishes_commit_boundary_head_unchanged" \
    "$_BOUNDARY_INITIAL_HEAD" "$_BOUNDARY_HEAD_AFTER"

# Assert working tree is clean (rollback used checkout --, not revert)
_BOUNDARY_WT_STATUS=$(git -C "$_FIXTURE_DIR" status --porcelain 2>/dev/null)
if [[ -z "$_BOUNDARY_WT_STATUS" ]]; then
    _BOUNDARY_WT_CLEAN="true"
else
    _BOUNDARY_WT_CLEAN="false"
fi
assert_eq "test_cutover_rollback_distinguishes_commit_boundary" "true" "$_BOUNDARY_WT_CLEAN"
assert_pass_if_clean "test_cutover_rollback_distinguishes_commit_boundary"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR

# =============================================================================
# Test 8: test_cutover_state_file_written_after_each_phase
#
# RED phase: state file is written by _state_append_phase after each phase, but
# the resume logic does not yet exist — this test validates state-file content.
# The assertion for all 5 phase names should PASS (state file already written),
# but the --resume flag handling tested in T9/T10 does NOT exist — those tests
# will FAIL in RED.
#
# Setup: temp git repo. Set CUTOVER_STATE_FILE to a temp path.
# Run script to completion with all stubs succeeding.
# Assert: state file exists and contains all 5 phase names.
# =============================================================================
_setup_fixture

_STATE_WRITTEN_FILE="$_FIXTURE_DIR/.cutover-state-written.json"
_STATE_WRITTEN_RC=0

_STATE_WRITTEN_OUTPUT=$(
    CUTOVER_LOG_DIR="$_FIXTURE_LOG_DIR" \
    CUTOVER_STATE_FILE="$_STATE_WRITTEN_FILE" \
    bash "$CUTOVER_SCRIPT" --repo-root="$_FIXTURE_DIR" 2>&1
) || _STATE_WRITTEN_RC=$?

_snapshot_fail

# Assert exit 0
assert_eq "test_cutover_state_file_written_after_each_phase_exit_0" "0" "$_STATE_WRITTEN_RC"

# Assert state file exists
if [[ -f "$_STATE_WRITTEN_FILE" ]]; then
    _STATE_FILE_EXISTS="true"
else
    _STATE_FILE_EXISTS="false"
fi
assert_eq "test_cutover_state_file_written_after_each_phase_file_exists" "true" "$_STATE_FILE_EXISTS"

# Assert all 5 phase names appear in the state file
_STATE_HAS_ALL_PHASES="false"
if [[ -f "$_STATE_WRITTEN_FILE" ]]; then
    _STATE_CONTENT=$(cat "$_STATE_WRITTEN_FILE")
    if echo "$_STATE_CONTENT" | grep -q 'validate' && \
       echo "$_STATE_CONTENT" | grep -q 'snapshot' && \
       echo "$_STATE_CONTENT" | grep -q 'migrate'  && \
       echo "$_STATE_CONTENT" | grep -q 'verify'   && \
       echo "$_STATE_CONTENT" | grep -q 'finalize'; then
        _STATE_HAS_ALL_PHASES="true"
    fi
fi
assert_eq "test_cutover_state_file_written_after_each_phase" "true" "$_STATE_HAS_ALL_PHASES"
assert_pass_if_clean "test_cutover_state_file_written_after_each_phase"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR

# =============================================================================
# Test 9: test_cutover_resume_skips_completed_phases
#
# RED phase: --resume flag and skip logic do not exist yet — FAILS.
#
# Setup: temp git repo. Pre-write a state file indicating 'validate' and
# 'snapshot' (PRE_FLIGHT and SNAPSHOT) are completed.
# Run script with --resume flag.
# Assert: output does NOT contain 'Running phase: validate' or
#         'Running phase: snapshot'.
# Assert: output DOES contain 'Skipping completed phase: validate' (or equivalent).
# Assert: output DOES contain 'Running phase: migrate' (resumes from third phase).
# =============================================================================
_setup_fixture

_RESUME_SKIP_STATE_FILE="$_FIXTURE_DIR/.cutover-resume-skip.json"
_RESUME_SKIP_RC=0

# Pre-write state file with first two phases completed
python3 -c "
import json
data = {'completed_phases': ['validate', 'snapshot']}
with open('$_RESUME_SKIP_STATE_FILE', 'w') as fh:
    json.dump(data, fh)
    fh.write('\n')
"

_RESUME_SKIP_OUTPUT=$(
    CUTOVER_LOG_DIR="$_FIXTURE_LOG_DIR" \
    CUTOVER_STATE_FILE="$_RESUME_SKIP_STATE_FILE" \
    bash "$CUTOVER_SCRIPT" --repo-root="$_FIXTURE_DIR" --resume 2>&1
) || _RESUME_SKIP_RC=$?

_snapshot_fail

# Assert exit 0
assert_eq "test_cutover_resume_skips_completed_phases_exit_0" "0" "$_RESUME_SKIP_RC"

# Assert output does NOT contain 'Running phase: validate'
if echo "$_RESUME_SKIP_OUTPUT" | grep -q 'Running phase: validate'; then
    _SKIP_VALIDATE="false"
else
    _SKIP_VALIDATE="true"
fi
assert_eq "test_cutover_resume_skips_completed_phases_no_validate" "true" "$_SKIP_VALIDATE"

# Assert output does NOT contain 'Running phase: snapshot'
if echo "$_RESUME_SKIP_OUTPUT" | grep -q 'Running phase: snapshot'; then
    _SKIP_SNAPSHOT="false"
else
    _SKIP_SNAPSHOT="true"
fi
assert_eq "test_cutover_resume_skips_completed_phases_no_snapshot" "true" "$_SKIP_SNAPSHOT"

# Assert output DOES contain a skip message for validate
if echo "$_RESUME_SKIP_OUTPUT" | grep -qiE 'Skipping.*validate|validate.*skip'; then
    _HAS_SKIP_MSG="true"
else
    _HAS_SKIP_MSG="false"
fi
assert_eq "test_cutover_resume_skips_completed_phases_skip_msg" "true" "$_HAS_SKIP_MSG"

# Assert output DOES contain 'Running phase: migrate' (resumes from third phase)
if echo "$_RESUME_SKIP_OUTPUT" | grep -q 'Running phase: migrate'; then
    _RESUMES_AT_MIGRATE="true"
else
    _RESUMES_AT_MIGRATE="false"
fi
assert_eq "test_cutover_resume_skips_completed_phases" "true" "$_RESUMES_AT_MIGRATE"
assert_pass_if_clean "test_cutover_resume_skips_completed_phases"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR

# =============================================================================
# Test 10: test_cutover_resume_does_not_rerun_already_completed_phase
#
# RED phase: --resume flag and all-phases-complete logic do not exist — FAILS.
#
# Setup: temp git repo. Pre-write state file showing ALL 5 phases completed.
# Run script with --resume.
# Assert: output contains 'All phases already completed' or similar; exit 0.
# Assert: no phase was re-executed (no 'Running phase:' lines in output).
# =============================================================================
_setup_fixture

_RESUME_ALL_STATE_FILE="$_FIXTURE_DIR/.cutover-resume-all.json"
_RESUME_ALL_RC=0

# Pre-write state file with all phases completed
python3 -c "
import json
data = {'completed_phases': ['validate', 'snapshot', 'migrate', 'verify', 'finalize']}
with open('$_RESUME_ALL_STATE_FILE', 'w') as fh:
    json.dump(data, fh)
    fh.write('\n')
"

_RESUME_ALL_OUTPUT=$(
    CUTOVER_LOG_DIR="$_FIXTURE_LOG_DIR" \
    CUTOVER_STATE_FILE="$_RESUME_ALL_STATE_FILE" \
    bash "$CUTOVER_SCRIPT" --repo-root="$_FIXTURE_DIR" --resume 2>&1
) || _RESUME_ALL_RC=$?

_snapshot_fail

# Assert exit 0
assert_eq "test_cutover_resume_does_not_rerun_already_completed_phase_exit_0" "0" "$_RESUME_ALL_RC"

# Assert output contains 'All phases already completed' or similar
if echo "$_RESUME_ALL_OUTPUT" | grep -qiE 'all phases already completed|nothing to resume|all.*complete'; then
    _HAS_COMPLETE_MSG="true"
else
    _HAS_COMPLETE_MSG="false"
fi
assert_eq "test_cutover_resume_does_not_rerun_already_completed_phase_msg" "true" "$_HAS_COMPLETE_MSG"

# Assert no phase was re-executed (no 'Running phase:' lines)
if echo "$_RESUME_ALL_OUTPUT" | grep -q 'Running phase:'; then
    _NO_RERUN="false"
else
    _NO_RERUN="true"
fi
assert_eq "test_cutover_resume_does_not_rerun_already_completed_phase" "true" "$_NO_RERUN"
assert_pass_if_clean "test_cutover_resume_does_not_rerun_already_completed_phase"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR

# =============================================================================
print_summary
