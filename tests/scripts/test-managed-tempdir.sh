#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-managed-tempdir.sh
# Tests for create_managed_tempdir() in lockpick-workflow/hooks/lib/deps.sh
#
# Tests:
#   1. test_function_exists_in_deps_sh           — function is defined in deps.sh
#   2. test_cleanup_on_normal_exit               — temp dir removed on normal exit
#   3. test_cleanup_on_error_exit                — temp dir removed on error exit
#   4. test_trap_chaining                        — existing EXIT trap is preserved
#   5. test_returns_valid_directory              — returned path is a real directory
#   6. test_merge_to_main_uses_managed_tempdir   — merge-to-main.sh uses managed cleanup
#   7. test_stale_tmp_cleanup_in_deps_sh         — cleanup_stale_tmpdirs function exists
#
# Usage: bash lockpick-workflow/tests/scripts/test-managed-tempdir.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

DEPS_SH="$PLUGIN_ROOT/hooks/lib/deps.sh"
MERGE_SCRIPT="$PLUGIN_ROOT/scripts/merge-to-main.sh"

echo "=== test-managed-tempdir.sh ==="

# =============================================================================
# Test 1: create_managed_tempdir is defined in deps.sh
# =============================================================================
echo ""
echo "--- function existence in deps.sh ---"
_snapshot_fail

HAS_FUNCTION=$(grep -c "create_managed_tempdir" "$DEPS_SH" || true)
assert_ne "test_function_exists_in_deps_sh" "0" "$HAS_FUNCTION"

assert_pass_if_clean "function exists in deps.sh"

# =============================================================================
# Test 2: cleanup_stale_tmpdirs is defined in deps.sh
# =============================================================================
echo ""
echo "--- stale cleanup function existence ---"
_snapshot_fail

HAS_STALE_CLEANUP=$(grep -c "cleanup_stale_tmpdirs" "$DEPS_SH" || true)
assert_ne "test_stale_tmp_cleanup_in_deps_sh" "0" "$HAS_STALE_CLEANUP"

assert_pass_if_clean "stale cleanup function exists in deps.sh"

# =============================================================================
# Test 3: cleanup on normal exit
# Create a subprocess that uses create_managed_tempdir, saves the path,
# then exits normally. Verify the directory no longer exists after exit.
# =============================================================================
echo ""
echo "--- cleanup on normal exit ---"
_snapshot_fail

_OUTER_TMP=$(mktemp -d)
trap 'rm -rf "$_OUTER_TMP"' EXIT

_TMPDIR_PATH_FILE="$_OUTER_TMP/tempdir_path.txt"

# Run a subprocess that sources deps.sh, calls create_managed_tempdir,
# writes the path out, then exits normally (exit 0).
bash -c "
source '$DEPS_SH'
create_managed_tempdir TMPDIR_MANAGED
echo \"\$TMPDIR_MANAGED\" > '$_TMPDIR_PATH_FILE'
# Directory should exist now
test -d \"\$TMPDIR_MANAGED\" || exit 2
# Exit normally — trap should clean it up
exit 0
"
_subprocess_exit=$?

assert_eq "subprocess exits 0 on normal exit" "0" "$_subprocess_exit"

if [[ -f "$_TMPDIR_PATH_FILE" ]]; then
    _managed_path=$(cat "$_TMPDIR_PATH_FILE")
    if [[ -n "$_managed_path" ]] && [[ ! -d "$_managed_path" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        if [[ -z "$_managed_path" ]]; then
            echo "FAIL: create_managed_tempdir returned empty path" >&2
        else
            echo "FAIL: temp dir still exists after normal exit: $_managed_path" >&2
        fi
    fi
else
    (( ++FAIL ))
    echo "FAIL: subprocess did not write tempdir path to file" >&2
fi

assert_pass_if_clean "cleanup on normal exit"

# =============================================================================
# Test 4: cleanup on error exit
# Same as above but the subprocess exits with non-zero exit code.
# =============================================================================
echo ""
echo "--- cleanup on error exit ---"
_snapshot_fail

_TMPDIR_PATH_FILE2="$_OUTER_TMP/tempdir_path2.txt"

# Run a subprocess that exits non-zero (simulates an error path).
# set -e is intentionally NOT set here so the subprocess can control exit cleanly.
bash -c "
source '$DEPS_SH'
create_managed_tempdir TMPDIR_MANAGED
echo \"\$TMPDIR_MANAGED\" > '$_TMPDIR_PATH_FILE2'
# Exit with error — trap should still clean up
exit 1
" || true  # We expect exit 1, so ignore it here

if [[ -f "$_TMPDIR_PATH_FILE2" ]]; then
    _managed_path2=$(cat "$_TMPDIR_PATH_FILE2")
    if [[ -n "$_managed_path2" ]] && [[ ! -d "$_managed_path2" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        if [[ -z "$_managed_path2" ]]; then
            echo "FAIL: create_managed_tempdir returned empty path on error path" >&2
        else
            echo "FAIL: temp dir still exists after error exit: $_managed_path2" >&2
        fi
    fi
else
    (( ++FAIL ))
    echo "FAIL: subprocess did not write tempdir path to file on error path" >&2
fi

assert_pass_if_clean "cleanup on error exit"

# =============================================================================
# Test 5: trap chaining — existing EXIT trap is preserved
# Set an EXIT trap that writes a marker file, then call create_managed_tempdir.
# After subprocess exits, verify both: temp dir gone AND marker file exists.
# =============================================================================
echo ""
echo "--- trap chaining ---"
_snapshot_fail

_MARKER_FILE="$_OUTER_TMP/trap_chaining_marker.txt"
_TMPDIR_PATH_FILE3="$_OUTER_TMP/tempdir_path3.txt"

bash -c "
source '$DEPS_SH'
# Set an existing EXIT trap BEFORE calling create_managed_tempdir
trap 'echo chained_trap_ran > \"$_MARKER_FILE\"' EXIT
# Now call create_managed_tempdir — it must chain, not clobber
create_managed_tempdir TMPDIR_MANAGED
echo \"\$TMPDIR_MANAGED\" > '$_TMPDIR_PATH_FILE3'
exit 0
"
_chain_exit=$?

assert_eq "subprocess exits 0 with trap chaining" "0" "$_chain_exit"

# Verify the original trap still ran
if [[ -f "$_MARKER_FILE" ]]; then
    _marker_content=$(cat "$_MARKER_FILE")
    assert_contains "original EXIT trap still ran after chaining" "chained_trap_ran" "$_marker_content"
else
    (( ++FAIL ))
    echo "FAIL: original EXIT trap did NOT run (trap was clobbered, not chained)" >&2
fi

# Also verify temp dir was cleaned up (managed cleanup also ran)
if [[ -f "$_TMPDIR_PATH_FILE3" ]]; then
    _managed_path3=$(cat "$_TMPDIR_PATH_FILE3")
    if [[ -n "$_managed_path3" ]] && [[ ! -d "$_managed_path3" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        if [[ -z "$_managed_path3" ]]; then
            echo "FAIL: create_managed_tempdir returned empty path in chain test" >&2
        else
            echo "FAIL: temp dir still exists after chained exit: $_managed_path3" >&2
        fi
    fi
fi

assert_pass_if_clean "trap chaining"

# =============================================================================
# Test 6: returns a valid directory immediately
# The returned path must be an existing directory after the call.
# =============================================================================
echo ""
echo "--- returns valid directory ---"
_snapshot_fail

_TMPDIR_PATH_FILE4="$_OUTER_TMP/tempdir_path4.txt"
_DIR_EXISTS_FILE="$_OUTER_TMP/dir_existed.txt"

bash -c "
source '$DEPS_SH'
create_managed_tempdir TMPDIR_MANAGED
echo \"\$TMPDIR_MANAGED\" > '$_TMPDIR_PATH_FILE4'
if [[ -d \"\$TMPDIR_MANAGED\" ]]; then
    echo yes > '$_DIR_EXISTS_FILE'
else
    echo no > '$_DIR_EXISTS_FILE'
fi
exit 0
"

if [[ -f "$_DIR_EXISTS_FILE" ]]; then
    _dir_exists=$(cat "$_DIR_EXISTS_FILE")
    assert_eq "returned path was a directory while alive" "yes" "$_dir_exists"
fi

if [[ -f "$_TMPDIR_PATH_FILE4" ]]; then
    _returned_path=$(cat "$_TMPDIR_PATH_FILE4")
    assert_ne "returned path is non-empty" "" "$_returned_path"
fi

assert_pass_if_clean "returns valid directory"

# =============================================================================
# Test 7: merge-to-main.sh uses create_managed_tempdir or has trap cleanup
# Acceptance criteria: mktemp calls must use create_managed_tempdir or have
# explicit trap cleanup for the temp files.
# =============================================================================
echo ""
echo "--- merge-to-main.sh managed cleanup ---"
_snapshot_fail

# Check that the verification command from the acceptance criteria passes:
# grep -q "create_managed_tempdir\|trap.*_FMT_LOG\|trap.*_LINT_LOG"
MERGE_MANAGED=$(grep -c "create_managed_tempdir\|trap.*_FMT_LOG\|trap.*_LINT_LOG" "$MERGE_SCRIPT" 2>/dev/null || true)
assert_ne "test_merge_to_main_uses_managed_tempdir" "0" "$MERGE_MANAGED"

assert_pass_if_clean "merge-to-main.sh uses managed cleanup"

# =============================================================================
# Summary
# =============================================================================
print_summary
