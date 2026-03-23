#!/usr/bin/env bash
# tests/scripts/test-cutover-tickets-migration-dryrun.sh
# Dry-run integration tests for _phase_finalize in cutover-tickets-migration.sh.
#
# Runs the entire cutover script with --dry-run (no --phase flag is supported).
# All phases execute in dry-run mode; these tests focus on the finalize-phase
# assertions defined in ticket dso-hyvp.
#
# Tests:
#   1. test_dryrun_finalize_prefixes_output     — output contains [DRY RUN] lines
#   2. test_dryrun_finalize_no_files_removed    — .tickets/, tk script, test-tk-*.sh still exist
#   3. test_dryrun_finalize_no_commit_created   — git log count unchanged
#   4. test_dryrun_finalize_no_git_tag          — no 'pre-cleanup-migration' tag created
#   5. test_dryrun_finalize_exits_zero          — script exits 0
#
# Usage: bash tests/scripts/test-cutover-tickets-migration-dryrun.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
CUTOVER_SCRIPT="$REPO_ROOT/plugins/dso/scripts/cutover-tickets-migration.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# =============================================================================
# Fixture helpers
# =============================================================================

# _setup_dryrun_fixture
# Creates a temp git repo populated with all artefacts that finalize would
# normally remove, then records the initial commit count.
# Sets: _FIXTURE_DIR, _FIXTURE_LOG_DIR, _COMMITS_BEFORE
# Registers EXIT trap.
_setup_dryrun_fixture() {
    _FIXTURE_DIR=$(mktemp -d)
    trap 'rm -rf "$_FIXTURE_DIR"' EXIT

    # Minimal git repo
    git -C "$_FIXTURE_DIR" init -q
    git -C "$_FIXTURE_DIR" config user.email "test@example.com"
    git -C "$_FIXTURE_DIR" config user.name "Test"

    # .tickets/ directory (finalize should remove this — but not in dry-run)
    mkdir -p "$_FIXTURE_DIR/.tickets"
    printf 'dso-abc123\n' > "$_FIXTURE_DIR/.tickets/.index.json"

    # stub tk script (finalize should remove this — but not in dry-run)
    mkdir -p "$_FIXTURE_DIR/plugins/dso/scripts"
    printf '#!/usr/bin/env bash\necho "tk stub"\n' > "$_FIXTURE_DIR/plugins/dso/scripts/tk"
    chmod +x "$_FIXTURE_DIR/plugins/dso/scripts/tk"

    # tk-specific test fixture stubs (finalize should remove — but not in dry-run)
    mkdir -p "$_FIXTURE_DIR/tests/scripts"
    printf '#!/usr/bin/env bash\necho "tk test"\n' > "$_FIXTURE_DIR/tests/scripts/test-tk-commands.sh"
    printf '#!/usr/bin/env bash\necho "tk test"\n' > "$_FIXTURE_DIR/tests/scripts/test-tk-sync.sh"
    chmod +x "$_FIXTURE_DIR/tests/scripts/test-tk-commands.sh"
    chmod +x "$_FIXTURE_DIR/tests/scripts/test-tk-sync.sh"

    # bench-tk stubs
    printf '#!/usr/bin/env bash\necho "bench stub"\n' > "$_FIXTURE_DIR/plugins/dso/scripts/bench-tk-ready.sh"
    mkdir -p "$_FIXTURE_DIR/tests/plugin"
    printf '#!/usr/bin/env bash\necho "bench test"\n' > "$_FIXTURE_DIR/tests/plugin/test-bench-tk-ready.sh"

    # tk-sync-force-local test stub
    mkdir -p "$_FIXTURE_DIR/tests/hooks"
    printf '#!/usr/bin/env bash\necho "sync-force-local test"\n' > "$_FIXTURE_DIR/tests/hooks/test-tk-sync-force-local.sh"

    # Initial commit (so HEAD exists for tagging)
    git -C "$_FIXTURE_DIR" add -A
    git -C "$_FIXTURE_DIR" commit -q -m "initial state before cutover dry-run"

    # Record commit count before the dry-run
    _COMMITS_BEFORE=$(git -C "$_FIXTURE_DIR" rev-list --count HEAD 2>/dev/null)

    # Log dir for cutover output
    _FIXTURE_LOG_DIR="$_FIXTURE_DIR/cutover-logs"
    mkdir -p "$_FIXTURE_LOG_DIR"
}

# _run_dryrun FIXTURE_DIR LOG_DIR
# Runs the cutover script with --dry-run (all phases).
# Sets _DRYRUN_OUTPUT and _DRYRUN_RC.
_run_dryrun() {
    local fixture_dir="$1"
    local log_dir="$2"

    _DRYRUN_RC=0
    _DRYRUN_OUTPUT=$(
        CUTOVER_LOG_DIR="$log_dir" \
        bash "$CUTOVER_SCRIPT" --repo-root="$fixture_dir" --dry-run 2>&1
    ) || _DRYRUN_RC=$?
}

# =============================================================================
# Structural check: cutover script exists
# =============================================================================
if [[ -f "$CUTOVER_SCRIPT" ]]; then
    _SCRIPT_EXISTS="true"
else
    _SCRIPT_EXISTS="false"
fi
assert_eq "test_cutover_script_exists" "true" "$_SCRIPT_EXISTS"

# =============================================================================
# Shared fixture + run (all five tests share one dry-run execution)
# =============================================================================
_setup_dryrun_fixture
_run_dryrun "$_FIXTURE_DIR" "$_FIXTURE_LOG_DIR"

# =============================================================================
# Test 1: test_dryrun_finalize_exits_zero
#
# Run the full script with --dry-run.
# Assert: exit code is 0.
# =============================================================================
_snapshot_fail
assert_eq "test_dryrun_finalize_exits_zero" "0" "$_DRYRUN_RC"
assert_pass_if_clean "test_dryrun_finalize_exits_zero"

# =============================================================================
# Test 2: test_dryrun_finalize_prefixes_output
#
# Run the full script with --dry-run.
# Assert: output contains at least one line prefixed with '[DRY RUN]'.
# The finalize phase emits '[DRY RUN] finalize: [would] ...' lines via
# _run_phase_dry which wraps every output line with '[DRY RUN] '.
# =============================================================================
_snapshot_fail
if echo "$_DRYRUN_OUTPUT" | grep -q '\[DRY RUN\]'; then
    _HAS_DRY_RUN_PREFIX="true"
else
    _HAS_DRY_RUN_PREFIX="false"
fi
assert_eq "test_dryrun_finalize_prefixes_output" "true" "$_HAS_DRY_RUN_PREFIX"
assert_pass_if_clean "test_dryrun_finalize_prefixes_output"

# =============================================================================
# Test 3: test_dryrun_finalize_no_files_removed
#
# After --dry-run, assert that ALL of the following still exist:
#   - .tickets/ directory
#   - plugins/dso/scripts/tk script
#   - tests/scripts/test-tk-commands.sh
#   - tests/scripts/test-tk-sync.sh
#   - plugins/dso/scripts/bench-tk-ready.sh
#   - tests/plugin/test-bench-tk-ready.sh
#   - tests/hooks/test-tk-sync-force-local.sh
# =============================================================================
_snapshot_fail

if [[ -d "$_FIXTURE_DIR/.tickets" ]]; then
    _TICKETS_DIR_EXISTS="true"
else
    _TICKETS_DIR_EXISTS="false"
fi
assert_eq "test_dryrun_finalize_no_files_removed_tickets_dir" "true" "$_TICKETS_DIR_EXISTS"

if [[ -f "$_FIXTURE_DIR/plugins/dso/scripts/tk" ]]; then
    _TK_SCRIPT_EXISTS="true"
else
    _TK_SCRIPT_EXISTS="false"
fi
assert_eq "test_dryrun_finalize_no_files_removed_tk_script" "true" "$_TK_SCRIPT_EXISTS"

_TK_FIXTURES_REMAINING=$(find "$_FIXTURE_DIR/tests/scripts" -maxdepth 1 -name 'test-tk-*.sh' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$_TK_FIXTURES_REMAINING" -ge 2 ]]; then
    _TK_FIXTURES_PRESERVED="true"
else
    _TK_FIXTURES_PRESERVED="false"
fi
assert_eq "test_dryrun_finalize_no_files_removed_tk_fixtures" "true" "$_TK_FIXTURES_PRESERVED"

if [[ -f "$_FIXTURE_DIR/plugins/dso/scripts/bench-tk-ready.sh" ]]; then
    _BENCH_SCRIPT_EXISTS="true"
else
    _BENCH_SCRIPT_EXISTS="false"
fi
assert_eq "test_dryrun_finalize_no_files_removed_bench_script" "true" "$_BENCH_SCRIPT_EXISTS"

if [[ -f "$_FIXTURE_DIR/tests/hooks/test-tk-sync-force-local.sh" ]]; then
    _SYNC_TEST_EXISTS="true"
else
    _SYNC_TEST_EXISTS="false"
fi
assert_eq "test_dryrun_finalize_no_files_removed_sync_test" "true" "$_SYNC_TEST_EXISTS"

assert_pass_if_clean "test_dryrun_finalize_no_files_removed"

# =============================================================================
# Test 4: test_dryrun_finalize_no_commit_created
#
# After --dry-run, assert the git commit count is unchanged.
# Dry-run must not call 'git commit'.
# =============================================================================
_snapshot_fail
_COMMITS_AFTER=$(git -C "$_FIXTURE_DIR" rev-list --count HEAD 2>/dev/null)
_NEW_COMMITS=$(( _COMMITS_AFTER - _COMMITS_BEFORE ))
assert_eq "test_dryrun_finalize_no_commit_created" "0" "$_NEW_COMMITS"
assert_pass_if_clean "test_dryrun_finalize_no_commit_created"

# =============================================================================
# Test 5: test_dryrun_finalize_no_git_tag
#
# After --dry-run, assert that no 'pre-cleanup-migration' git tag was created.
# Dry-run must not call 'git tag'.
# =============================================================================
_snapshot_fail
if git -C "$_FIXTURE_DIR" tag | grep -qx 'pre-cleanup-migration'; then
    _TAG_EXISTS="true"
else
    _TAG_EXISTS="false"
fi
assert_eq "test_dryrun_finalize_no_git_tag" "false" "$_TAG_EXISTS"
assert_pass_if_clean "test_dryrun_finalize_no_git_tag"

# =============================================================================
# Cleanup
# =============================================================================
rm -rf "$_FIXTURE_DIR"
unset _FIXTURE_DIR _FIXTURE_LOG_DIR _DRYRUN_OUTPUT _DRYRUN_RC
unset _COMMITS_BEFORE _COMMITS_AFTER _NEW_COMMITS

print_summary
