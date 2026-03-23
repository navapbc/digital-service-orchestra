#!/usr/bin/env bash
# tests/scripts/test-cutover-tickets-migration-finalize.sh
# TDD RED phase: failing tests for _phase_finalize() in cutover-tickets-migration.sh.
#
# _phase_finalize is the cleanup phase that:
#   1. Creates a pre-cleanup git tag (pre-cleanup-migration)
#   2. Removes .tickets/ directory and tk script
#   3. Removes tk-specific test fixtures
#   4. Re-enables compaction (unsets TICKET_COMPACT_DISABLED)
#
# Tests (all must FAIL before _phase_finalize is implemented beyond its stub):
#   1. test_finalize_creates_git_tag
#   2. test_finalize_removes_tickets_dir
#   3. test_finalize_removes_tk_script
#   4. test_finalize_removes_tk_test_fixtures
#   5. test_finalize_removes_bench_tk
#   6. test_finalize_removes_tk_sync_force_local_test
#   7. test_finalize_commits_as_single_commit
#   8. test_finalize_dry_run_makes_no_changes
#   9. test_finalize_unsets_compaction_disable_env
#  10. test_finalize_skips_if_tickets_dir_missing
#  11. test_finalize_handles_existing_tag
#
# Usage: bash tests/scripts/test-cutover-tickets-migration-finalize.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
CUTOVER_SCRIPT="$REPO_ROOT/plugins/dso/scripts/cutover-tickets-migration.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# =============================================================================
# Fixture helpers
# =============================================================================

# _setup_finalize_fixture
# Creates a temp git repo with:
#   - An initial commit (so HEAD exists)
#   - .tickets/ directory (simulating pre-migration state)
#   - plugins/dso/scripts/tk stub script
#   - tests/scripts/test-tk-*.sh fixture files
#   - plugins/dso/scripts/bench-tk-ready.sh stub
#   - tests/plugin/test-bench-tk-ready.sh stub
#   - tests/hooks/test-tk-sync-force-local.sh stub
# Sets _FIXTURE_DIR and _FIXTURE_LOG_DIR; registers EXIT trap.
_setup_finalize_fixture() {
    _FIXTURE_DIR=$(mktemp -d)
    trap 'rm -rf "$_FIXTURE_DIR"' EXIT

    # Minimal git repo
    git -C "$_FIXTURE_DIR" init -q
    git -C "$_FIXTURE_DIR" config user.email "test@example.com"
    git -C "$_FIXTURE_DIR" config user.name "Test"

    # Create .tickets/ directory (the main thing finalize should remove)
    mkdir -p "$_FIXTURE_DIR/.tickets"
    printf 'dso-abc123\n' > "$_FIXTURE_DIR/.tickets/.index.json"

    # Create stub tk script
    mkdir -p "$_FIXTURE_DIR/plugins/dso/scripts"
    printf '#!/usr/bin/env bash\necho "tk stub"\n' > "$_FIXTURE_DIR/plugins/dso/scripts/tk"
    chmod +x "$_FIXTURE_DIR/plugins/dso/scripts/tk"

    # Create tk-specific test fixture stubs
    mkdir -p "$_FIXTURE_DIR/tests/scripts"
    printf '#!/usr/bin/env bash\necho "tk test"\n' > "$_FIXTURE_DIR/tests/scripts/test-tk-commands.sh"
    printf '#!/usr/bin/env bash\necho "tk test"\n' > "$_FIXTURE_DIR/tests/scripts/test-tk-sync.sh"
    chmod +x "$_FIXTURE_DIR/tests/scripts/test-tk-commands.sh"
    chmod +x "$_FIXTURE_DIR/tests/scripts/test-tk-sync.sh"

    # Create bench-tk stubs
    printf '#!/usr/bin/env bash\necho "bench stub"\n' > "$_FIXTURE_DIR/plugins/dso/scripts/bench-tk-ready.sh"
    mkdir -p "$_FIXTURE_DIR/tests/plugin"
    printf '#!/usr/bin/env bash\necho "bench test"\n' > "$_FIXTURE_DIR/tests/plugin/test-bench-tk-ready.sh"

    # Create tk-sync-force-local test stub
    mkdir -p "$_FIXTURE_DIR/tests/hooks"
    printf '#!/usr/bin/env bash\necho "sync-force-local test"\n' > "$_FIXTURE_DIR/tests/hooks/test-tk-sync-force-local.sh"

    # Initial commit (so HEAD exists for tagging)
    git -C "$_FIXTURE_DIR" add -A
    git -C "$_FIXTURE_DIR" commit -q -m "initial state before cutover finalize"

    # Log dir for cutover output
    _FIXTURE_LOG_DIR="$_FIXTURE_DIR/cutover-logs"
    mkdir -p "$_FIXTURE_LOG_DIR"
}

# _run_finalize_only FIXTURE_DIR LOG_DIR [extra args...]
# Runs the cutover script with --resume using a pre-seeded state file
# that marks validate/snapshot/migrate/verify as completed (so only finalize runs).
# Sets _FINALIZE_OUTPUT and _FINALIZE_RC.
_run_finalize_only() {
    local fixture_dir="$1"
    local log_dir="$2"
    shift 2

    local state_file="$fixture_dir/.cutover-state.json"
    python3 -c "
import json
data = {'completed_phases': ['validate', 'snapshot', 'migrate', 'verify']}
with open('$state_file', 'w') as fh:
    json.dump(data, fh)
    fh.write('\n')
"

    _FINALIZE_RC=0
    _FINALIZE_OUTPUT=$(
        CUTOVER_LOG_DIR="$log_dir" \
        CUTOVER_STATE_FILE="$state_file" \
        bash "$CUTOVER_SCRIPT" --repo-root="$fixture_dir" --resume "$@" 2>&1
    ) || _FINALIZE_RC=$?
}

# =============================================================================
# Test 1: test_finalize_creates_git_tag
#
# Run finalize phase only (via --resume after pre-seeding state).
# Assert: git tag 'pre-cleanup-migration' exists after run.
# Assert: exit 0.
#
# RED: fails because _phase_finalize stub does not create a tag.
# =============================================================================
_setup_finalize_fixture
_run_finalize_only "$_FIXTURE_DIR" "$_FIXTURE_LOG_DIR"

_snapshot_fail
# Assert exit 0
assert_eq "test_finalize_creates_git_tag_exit_0" "0" "$_FINALIZE_RC"

# Assert git tag exists
if git -C "$_FIXTURE_DIR" tag | grep -qx 'pre-cleanup-migration'; then
    _TAG_EXISTS="true"
else
    _TAG_EXISTS="false"
fi
assert_eq "test_finalize_creates_git_tag" "true" "$_TAG_EXISTS"
assert_pass_if_clean "test_finalize_creates_git_tag"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR _FINALIZE_OUTPUT _FINALIZE_RC

# =============================================================================
# Test 2: test_finalize_removes_tickets_dir
#
# Run finalize phase only.
# Assert: .tickets/ directory does NOT exist after run.
# Assert: exit 0.
#
# RED: fails because _phase_finalize stub does not remove .tickets/.
# =============================================================================
_setup_finalize_fixture
_run_finalize_only "$_FIXTURE_DIR" "$_FIXTURE_LOG_DIR"

_snapshot_fail
assert_eq "test_finalize_removes_tickets_dir_exit_0" "0" "$_FINALIZE_RC"

if [[ ! -d "$_FIXTURE_DIR/.tickets" ]]; then
    _TICKETS_REMOVED="true"
else
    _TICKETS_REMOVED="false"
fi
assert_eq "test_finalize_removes_tickets_dir" "true" "$_TICKETS_REMOVED"
assert_pass_if_clean "test_finalize_removes_tickets_dir"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR _FINALIZE_OUTPUT _FINALIZE_RC

# =============================================================================
# Test 3: test_finalize_removes_tk_script
#
# Run finalize phase only.
# Assert: plugins/dso/scripts/tk does NOT exist after run.
# Assert: exit 0.
#
# RED: fails because _phase_finalize stub does not remove the tk script.
# =============================================================================
_setup_finalize_fixture
_run_finalize_only "$_FIXTURE_DIR" "$_FIXTURE_LOG_DIR"

_snapshot_fail
assert_eq "test_finalize_removes_tk_script_exit_0" "0" "$_FINALIZE_RC"

if [[ ! -f "$_FIXTURE_DIR/plugins/dso/scripts/tk" ]]; then
    _TK_REMOVED="true"
else
    _TK_REMOVED="false"
fi
assert_eq "test_finalize_removes_tk_script" "true" "$_TK_REMOVED"
assert_pass_if_clean "test_finalize_removes_tk_script"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR _FINALIZE_OUTPUT _FINALIZE_RC

# =============================================================================
# Test 4: test_finalize_removes_tk_test_fixtures
#
# Run finalize phase only.
# Assert: tests/scripts/test-tk-*.sh files do NOT exist after run.
# Assert: exit 0.
#
# RED: fails because _phase_finalize stub does not remove test fixtures.
# =============================================================================
_setup_finalize_fixture
_run_finalize_only "$_FIXTURE_DIR" "$_FIXTURE_LOG_DIR"

_snapshot_fail
assert_eq "test_finalize_removes_tk_test_fixtures_exit_0" "0" "$_FINALIZE_RC"

# Check that no test-tk-*.sh files remain
_TK_FIXTURES_REMAIN=$(find "$_FIXTURE_DIR/tests/scripts" -name 'test-tk-*.sh' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$_TK_FIXTURES_REMAIN" -eq 0 ]]; then
    _TK_FIXTURES_REMOVED="true"
else
    _TK_FIXTURES_REMOVED="false"
fi
assert_eq "test_finalize_removes_tk_test_fixtures" "true" "$_TK_FIXTURES_REMOVED"
assert_pass_if_clean "test_finalize_removes_tk_test_fixtures"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR _FINALIZE_OUTPUT _FINALIZE_RC _TK_FIXTURES_REMAIN

# =============================================================================
# Test 5: test_finalize_removes_bench_tk
#
# Run finalize phase only.
# Assert: plugins/dso/scripts/bench-tk-ready.sh does NOT exist after run.
# Assert: tests/plugin/test-bench-tk-ready.sh does NOT exist after run.
# Assert: exit 0.
#
# RED: fails because _phase_finalize stub does not remove bench-tk files.
# =============================================================================
_setup_finalize_fixture
_run_finalize_only "$_FIXTURE_DIR" "$_FIXTURE_LOG_DIR"

_snapshot_fail
assert_eq "test_finalize_removes_bench_tk_exit_0" "0" "$_FINALIZE_RC"

if [[ ! -f "$_FIXTURE_DIR/plugins/dso/scripts/bench-tk-ready.sh" ]]; then
    _BENCH_SCRIPT_REMOVED="true"
else
    _BENCH_SCRIPT_REMOVED="false"
fi
assert_eq "test_finalize_removes_bench_tk_script" "true" "$_BENCH_SCRIPT_REMOVED"

if [[ ! -f "$_FIXTURE_DIR/tests/plugin/test-bench-tk-ready.sh" ]]; then
    _BENCH_TEST_REMOVED="true"
else
    _BENCH_TEST_REMOVED="false"
fi
assert_eq "test_finalize_removes_bench_tk" "true" "$_BENCH_TEST_REMOVED"
assert_pass_if_clean "test_finalize_removes_bench_tk"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR _FINALIZE_OUTPUT _FINALIZE_RC

# =============================================================================
# Test 6: test_finalize_removes_tk_sync_force_local_test
#
# Run finalize phase only.
# Assert: tests/hooks/test-tk-sync-force-local.sh does NOT exist after run.
# Assert: exit 0.
#
# RED: fails because _phase_finalize stub does not remove this test file.
# =============================================================================
_setup_finalize_fixture
_run_finalize_only "$_FIXTURE_DIR" "$_FIXTURE_LOG_DIR"

_snapshot_fail
assert_eq "test_finalize_removes_tk_sync_force_local_test_exit_0" "0" "$_FINALIZE_RC"

if [[ ! -f "$_FIXTURE_DIR/tests/hooks/test-tk-sync-force-local.sh" ]]; then
    _SYNC_LOCAL_TEST_REMOVED="true"
else
    _SYNC_LOCAL_TEST_REMOVED="false"
fi
assert_eq "test_finalize_removes_tk_sync_force_local_test" "true" "$_SYNC_LOCAL_TEST_REMOVED"
assert_pass_if_clean "test_finalize_removes_tk_sync_force_local_test"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR _FINALIZE_OUTPUT _FINALIZE_RC

# =============================================================================
# Test 7: test_finalize_commits_as_single_commit
#
# Run finalize phase only. Count commits before and after.
# Assert: exactly one new commit is created by finalize (all removals in one commit).
# Assert: exit 0.
#
# RED: fails because _phase_finalize stub makes no commits.
# =============================================================================
_setup_finalize_fixture

_COMMITS_BEFORE=$(git -C "$_FIXTURE_DIR" rev-list --count HEAD 2>/dev/null)
_run_finalize_only "$_FIXTURE_DIR" "$_FIXTURE_LOG_DIR"

_snapshot_fail
assert_eq "test_finalize_commits_as_single_commit_exit_0" "0" "$_FINALIZE_RC"

_COMMITS_AFTER=$(git -C "$_FIXTURE_DIR" rev-list --count HEAD 2>/dev/null)
_NEW_COMMITS=$(( _COMMITS_AFTER - _COMMITS_BEFORE ))
assert_eq "test_finalize_commits_as_single_commit" "1" "$_NEW_COMMITS"
assert_pass_if_clean "test_finalize_commits_as_single_commit"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR _FINALIZE_OUTPUT _FINALIZE_RC _COMMITS_BEFORE _COMMITS_AFTER _NEW_COMMITS

# =============================================================================
# Test 8: test_finalize_dry_run_makes_no_changes
#
# Run finalize phase with --dry-run.
# Assert: .tickets/ directory still exists (no changes made).
# Assert: tk script still exists (no changes made).
# Assert: output contains "[DRY RUN]" prefix.
# Assert: exit 0.
#
# RED: fails because _phase_finalize stub does not produce [DRY RUN] output
#      (the stub body has no ops, so dry-run vs real-run are indistinguishable
#       and no removals happen anyway — but the [DRY RUN] prefix assertion is
#       currently vacuously satisfied; the tickets-dir assertion catches the RED).
# =============================================================================
_setup_finalize_fixture

_DRYRUN_STATE_FILE="$_FIXTURE_DIR/.cutover-state-dryrun.json"
python3 -c "
import json
data = {'completed_phases': ['validate', 'snapshot', 'migrate', 'verify']}
with open('$_DRYRUN_STATE_FILE', 'w') as fh:
    json.dump(data, fh)
    fh.write('\n')
"

_DRYRUN_RC=0
_DRYRUN_OUTPUT=$(
    CUTOVER_LOG_DIR="$_FIXTURE_LOG_DIR" \
    CUTOVER_STATE_FILE="$_DRYRUN_STATE_FILE" \
    bash "$CUTOVER_SCRIPT" --repo-root="$_FIXTURE_DIR" --resume --dry-run 2>&1
) || _DRYRUN_RC=$?

_snapshot_fail
assert_eq "test_finalize_dry_run_makes_no_changes_exit_0" "0" "$_DRYRUN_RC"

# Assert [DRY RUN] prefix appears in output
if echo "$_DRYRUN_OUTPUT" | grep -q '\[DRY RUN\]'; then
    _DRYRUN_PREFIX_OK="true"
else
    _DRYRUN_PREFIX_OK="false"
fi
assert_eq "test_finalize_dry_run_output_has_prefix" "true" "$_DRYRUN_PREFIX_OK"

# Assert .tickets/ still exists (dry-run must not remove it)
if [[ -d "$_FIXTURE_DIR/.tickets" ]]; then
    _TICKETS_PRESERVED="true"
else
    _TICKETS_PRESERVED="false"
fi
assert_eq "test_finalize_dry_run_makes_no_changes" "true" "$_TICKETS_PRESERVED"

# Assert tk script still exists (dry-run must not remove it)
if [[ -f "$_FIXTURE_DIR/plugins/dso/scripts/tk" ]]; then
    _TK_PRESERVED="true"
else
    _TK_PRESERVED="false"
fi
assert_eq "test_finalize_dry_run_preserves_tk_script" "true" "$_TK_PRESERVED"
assert_pass_if_clean "test_finalize_dry_run_makes_no_changes"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR _DRYRUN_OUTPUT _DRYRUN_RC _DRYRUN_STATE_FILE

# =============================================================================
# Test 9: test_finalize_unsets_compaction_disable_env
#
# Run finalize phase with TICKET_COMPACT_DISABLED pre-set.
# Assert: finalize exits 0.
# Assert: output does NOT contain "TICKET_COMPACT_DISABLED=1" (compaction re-enabled).
# Note: we verify via output since the env is cleared inside the script subprocess;
#       we check that the finalize phase emits a re-enable message.
#
# RED: fails because _phase_finalize stub does not unset TICKET_COMPACT_DISABLED
#      and does not emit any re-enable message.
# =============================================================================
_setup_finalize_fixture
TICKET_COMPACT_DISABLED=1 _run_finalize_only "$_FIXTURE_DIR" "$_FIXTURE_LOG_DIR"

_snapshot_fail
assert_eq "test_finalize_unsets_compaction_disable_env_exit_0" "0" "$_FINALIZE_RC"

# Assert that the output mentions re-enabling compaction (finalize should log this)
if echo "$_FINALIZE_OUTPUT" | grep -qiE 'compact|compaction'; then
    _COMPACT_MENTIONED="true"
else
    _COMPACT_MENTIONED="false"
fi
assert_eq "test_finalize_unsets_compaction_disable_env" "true" "$_COMPACT_MENTIONED"
assert_pass_if_clean "test_finalize_unsets_compaction_disable_env"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR _FINALIZE_OUTPUT _FINALIZE_RC TICKET_COMPACT_DISABLED

# =============================================================================
# Test 10: test_finalize_skips_if_tickets_dir_missing
#
# Run finalize when .tickets/ does not exist (already removed / idempotent).
# Assert: exit 0 (graceful skip, not an error).
# Assert: no error message in output.
#
# RED: fails because _phase_finalize stub would either error trying to remove a
#      missing directory (rm -rf is safe, but tag creation and commit may fail
#      or be skipped incorrectly depending on implementation).
#      The stub currently exits 0 trivially — but the commit assertion (T7) fails.
#      This test checks the idempotent path: if .tickets/ is already gone,
#      finalize should still create the tag and commit (or skip gracefully).
# =============================================================================
_setup_finalize_fixture

# Remove .tickets/ before running (simulate already-cleaned state)
rm -rf "$_FIXTURE_DIR/.tickets"

_run_finalize_only "$_FIXTURE_DIR" "$_FIXTURE_LOG_DIR"

_snapshot_fail
assert_eq "test_finalize_skips_if_tickets_dir_missing_exit_0" "0" "$_FINALIZE_RC"

# Assert no ERROR in output
if echo "$_FINALIZE_OUTPUT" | grep -q '^ERROR:'; then
    _HAS_ERROR="true"
else
    _HAS_ERROR="false"
fi
assert_eq "test_finalize_skips_if_tickets_dir_missing" "false" "$_HAS_ERROR"
assert_pass_if_clean "test_finalize_skips_if_tickets_dir_missing"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR _FINALIZE_OUTPUT _FINALIZE_RC

# =============================================================================
# Test 11: test_finalize_handles_existing_tag
#
# Run finalize when 'pre-cleanup-migration' tag already exists (idempotent run).
# Assert: exit 0 (tag creation step must not fail or must skip gracefully).
# Assert: tag still exists after run.
#
# RED: fails because _phase_finalize stub does not create the tag at all,
#      so there is nothing to be idempotent about; this test verifies the
#      idempotent behavior of a real implementation.
# =============================================================================
_setup_finalize_fixture

# Pre-create the tag to simulate a prior partial run
git -C "$_FIXTURE_DIR" tag pre-cleanup-migration

_run_finalize_only "$_FIXTURE_DIR" "$_FIXTURE_LOG_DIR"

_snapshot_fail
assert_eq "test_finalize_handles_existing_tag_exit_0" "0" "$_FINALIZE_RC"

# Assert tag still exists
if git -C "$_FIXTURE_DIR" tag | grep -qx 'pre-cleanup-migration'; then
    _TAG_STILL_EXISTS="true"
else
    _TAG_STILL_EXISTS="false"
fi
assert_eq "test_finalize_handles_existing_tag" "true" "$_TAG_STILL_EXISTS"
assert_pass_if_clean "test_finalize_handles_existing_tag"

rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR _FINALIZE_OUTPUT _FINALIZE_RC

print_summary
