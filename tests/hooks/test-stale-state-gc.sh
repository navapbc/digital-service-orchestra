#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-stale-state-gc.sh
# TDD tests for gc_stale_state_files() in cleanup-claude-session.sh
#
# Tests:
#   test_gc_function_exists               — function is defined in the script
#   test_old_files_removed                — files older than 24h are removed
#   test_fresh_files_kept                 — files newer than 24h are kept
#   test_empty_plugin_dir_removed         — empty plugin dirs are removed after GC
#   test_nonempty_plugin_dir_kept         — plugin dirs with fresh files are kept
#   test_idempotent_on_missing_dir        — no error when /tmp has no plugin dirs
#   test_gc_called_from_cleanup_script    — the main script calls gc_stale_state_files
#
# Usage: bash lockpick-workflow/tests/hooks/test-stale-state-gc.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
CLEANUP_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/cleanup-claude-session.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-stale-state-gc.sh ==="

# ============================================================================
# Helpers
# ============================================================================

# Make a temp dir that simulates a /tmp/workflow-plugin-<hash>/ directory.
# Callers provide a variable name to receive the path.
make_plugin_dir() {
    local varname="$1"
    local dir
    dir=$(mktemp -d)
    eval "$varname=$dir"
}

# Set a file's mtime to 25 hours ago (stale).
make_stale() {
    local file="$1"
    # 25 hours = 1500 minutes ago; touch -t uses [[CC]YY]MMDDhhmm[.ss]
    touch -t "$(date -d '25 hours ago' '+%Y%m%d%H%M' 2>/dev/null || date -v-25H '+%Y%m%d%H%M')" "$file"
}

# Set a file's mtime to 1 hour ago (fresh).
make_fresh() {
    local file="$1"
    touch -t "$(date -d '1 hour ago' '+%Y%m%d%H%M' 2>/dev/null || date -v-1H '+%Y%m%d%H%M')" "$file"
}

# ============================================================================
# Test: gc_stale_state_files function exists in cleanup-claude-session.sh
# ============================================================================
echo ""
echo "=== test_gc_function_exists ==="
_snapshot_fail

_FN_DEFINED="no"
if grep -q 'gc_stale_state_files' "$CLEANUP_SCRIPT" 2>/dev/null; then
    _FN_DEFINED="yes"
fi
assert_eq "test_gc_function_exists: function name present in cleanup script" "yes" "$_FN_DEFINED"

assert_pass_if_clean "test_gc_function_exists"

# ============================================================================
# Source the GC function from the cleanup script.
# We define stubs for the external calls cleanup-claude-session.sh makes so
# sourcing it doesn't actually run cleanup steps or fail on missing env.
# ============================================================================

# Stub dependencies so the script can be sourced safely
git() { command git "$@" 2>/dev/null || true; }
export -f git

# Source only the gc function by extracting and eval-ing it.
# This avoids executing the full cleanup script body.
_GC_BODY=$(awk '/^gc_stale_state_files\(\)/{found=1} found{print} found && /^\}$/{exit}' "$CLEANUP_SCRIPT")

if [[ -z "$_GC_BODY" ]]; then
    # Function not yet implemented — remaining tests will verify behavior once implemented
    echo "SKIP: gc_stale_state_files not yet implemented; skipping behavioral tests (expected RED)" >&2
    print_summary
fi

eval "$_GC_BODY"

# ============================================================================
# Test: old state files are removed
# ============================================================================
echo ""
echo "=== test_old_files_removed ==="
_snapshot_fail

make_plugin_dir PLUGIN_DIR_OLD
trap 'rm -rf "$PLUGIN_DIR_OLD"' EXIT

# Create stale state files matching known patterns
touch "$PLUGIN_DIR_OLD/review-status"
touch "$PLUGIN_DIR_OLD/validation-status"
touch "$PLUGIN_DIR_OLD/reviewer-findings.json"
touch "$PLUGIN_DIR_OLD/commit-breadcrumbs.log"
touch "$PLUGIN_DIR_OLD/review-diff-abc123.txt"
touch "$PLUGIN_DIR_OLD/review-stat-abc123.txt"

# Make them all stale
for f in "$PLUGIN_DIR_OLD"/*; do
    make_stale "$f"
done

# Run the GC pointing at our temp dir (override the glob by setting env var)
GC_PLUGIN_GLOB="$PLUGIN_DIR_OLD" gc_stale_state_files 2>/dev/null

_OLD_REVIEW_GONE="no"
[[ ! -f "$PLUGIN_DIR_OLD/review-status" ]] && _OLD_REVIEW_GONE="yes"
assert_eq "test_old_files_removed: review-status stale file deleted" "yes" "$_OLD_REVIEW_GONE"

_OLD_VALIDATION_GONE="no"
[[ ! -f "$PLUGIN_DIR_OLD/validation-status" ]] && _OLD_VALIDATION_GONE="yes"
assert_eq "test_old_files_removed: validation-status stale file deleted" "yes" "$_OLD_VALIDATION_GONE"

_OLD_FINDINGS_GONE="no"
[[ ! -f "$PLUGIN_DIR_OLD/reviewer-findings.json" ]] && _OLD_FINDINGS_GONE="yes"
assert_eq "test_old_files_removed: reviewer-findings.json stale file deleted" "yes" "$_OLD_FINDINGS_GONE"

_OLD_CRUMBS_GONE="no"
[[ ! -f "$PLUGIN_DIR_OLD/commit-breadcrumbs.log" ]] && _OLD_CRUMBS_GONE="yes"
assert_eq "test_old_files_removed: commit-breadcrumbs.log stale file deleted" "yes" "$_OLD_CRUMBS_GONE"

_OLD_DIFF_GONE="no"
[[ ! -f "$PLUGIN_DIR_OLD/review-diff-abc123.txt" ]] && _OLD_DIFF_GONE="yes"
assert_eq "test_old_files_removed: review-diff-*.txt stale file deleted" "yes" "$_OLD_DIFF_GONE"

_OLD_STAT_GONE="no"
[[ ! -f "$PLUGIN_DIR_OLD/review-stat-abc123.txt" ]] && _OLD_STAT_GONE="yes"
assert_eq "test_old_files_removed: review-stat-*.txt stale file deleted" "yes" "$_OLD_STAT_GONE"

assert_pass_if_clean "test_old_files_removed"

# ============================================================================
# Test: fresh state files are kept
# ============================================================================
echo ""
echo "=== test_fresh_files_kept ==="
_snapshot_fail

make_plugin_dir PLUGIN_DIR_FRESH
trap 'rm -rf "$PLUGIN_DIR_FRESH"' EXIT

touch "$PLUGIN_DIR_FRESH/review-status"
touch "$PLUGIN_DIR_FRESH/validation-status"
touch "$PLUGIN_DIR_FRESH/reviewer-findings.json"
touch "$PLUGIN_DIR_FRESH/commit-breadcrumbs.log"
touch "$PLUGIN_DIR_FRESH/review-diff-fresh.txt"
touch "$PLUGIN_DIR_FRESH/review-stat-fresh.txt"

for f in "$PLUGIN_DIR_FRESH"/*; do
    make_fresh "$f"
done

GC_PLUGIN_GLOB="$PLUGIN_DIR_FRESH" gc_stale_state_files 2>/dev/null

_FRESH_REVIEW_EXISTS="no"
[[ -f "$PLUGIN_DIR_FRESH/review-status" ]] && _FRESH_REVIEW_EXISTS="yes"
assert_eq "test_fresh_files_kept: review-status fresh file kept" "yes" "$_FRESH_REVIEW_EXISTS"

_FRESH_VALIDATION_EXISTS="no"
[[ -f "$PLUGIN_DIR_FRESH/validation-status" ]] && _FRESH_VALIDATION_EXISTS="yes"
assert_eq "test_fresh_files_kept: validation-status fresh file kept" "yes" "$_FRESH_VALIDATION_EXISTS"

_FRESH_DIFF_EXISTS="no"
[[ -f "$PLUGIN_DIR_FRESH/review-diff-fresh.txt" ]] && _FRESH_DIFF_EXISTS="yes"
assert_eq "test_fresh_files_kept: review-diff-*.txt fresh file kept" "yes" "$_FRESH_DIFF_EXISTS"

assert_pass_if_clean "test_fresh_files_kept"

# ============================================================================
# Test: empty plugin dir is removed after GC
# ============================================================================
echo ""
echo "=== test_empty_plugin_dir_removed ==="
_snapshot_fail

make_plugin_dir PLUGIN_DIR_EMPTY
trap 'rm -rf "$PLUGIN_DIR_EMPTY"' EXIT

# Create a single stale file so GC has something to remove
touch "$PLUGIN_DIR_EMPTY/review-status"
make_stale "$PLUGIN_DIR_EMPTY/review-status"

GC_PLUGIN_GLOB="$PLUGIN_DIR_EMPTY" gc_stale_state_files 2>/dev/null

_DIR_GONE="no"
[[ ! -d "$PLUGIN_DIR_EMPTY" ]] && _DIR_GONE="yes"
assert_eq "test_empty_plugin_dir_removed: empty dir deleted after GC" "yes" "$_DIR_GONE"

assert_pass_if_clean "test_empty_plugin_dir_removed"

# ============================================================================
# Test: plugin dir with fresh files is NOT removed
# ============================================================================
echo ""
echo "=== test_nonempty_plugin_dir_kept ==="
_snapshot_fail

make_plugin_dir PLUGIN_DIR_MIX
trap 'rm -rf "$PLUGIN_DIR_MIX"' EXIT

# One stale, one fresh
touch "$PLUGIN_DIR_MIX/review-status"
make_stale "$PLUGIN_DIR_MIX/review-status"

touch "$PLUGIN_DIR_MIX/validation-status"
make_fresh "$PLUGIN_DIR_MIX/validation-status"

GC_PLUGIN_GLOB="$PLUGIN_DIR_MIX" gc_stale_state_files 2>/dev/null

_DIR_STILL_EXISTS="no"
[[ -d "$PLUGIN_DIR_MIX" ]] && _DIR_STILL_EXISTS="yes"
assert_eq "test_nonempty_plugin_dir_kept: dir with fresh files not removed" "yes" "$_DIR_STILL_EXISTS"

_FRESH_STILL_EXISTS="no"
[[ -f "$PLUGIN_DIR_MIX/validation-status" ]] && _FRESH_STILL_EXISTS="yes"
assert_eq "test_nonempty_plugin_dir_kept: fresh file still present" "yes" "$_FRESH_STILL_EXISTS"

assert_pass_if_clean "test_nonempty_plugin_dir_kept"

# ============================================================================
# Test: idempotent — no error when no plugin dirs exist
# ============================================================================
echo ""
echo "=== test_idempotent_on_missing_dir ==="
_snapshot_fail

# Point at a path that doesn't exist
NONEXISTENT_DIR="/tmp/workflow-plugin-nonexistent-does-not-exist-xyz"
rm -rf "$NONEXISTENT_DIR"

EXIT_CODE=0
GC_PLUGIN_GLOB="$NONEXISTENT_DIR" gc_stale_state_files 2>/dev/null || EXIT_CODE=$?
assert_eq "test_idempotent_on_missing_dir: exits zero when no dirs found" "0" "$EXIT_CODE"

assert_pass_if_clean "test_idempotent_on_missing_dir"

# ============================================================================
# Test: main cleanup script calls gc_stale_state_files
# ============================================================================
echo ""
echo "=== test_gc_called_from_cleanup_script ==="
_snapshot_fail

_GC_CALLED="no"
if grep -q 'gc_stale_state_files' "$CLEANUP_SCRIPT" 2>/dev/null; then
    # Check it's called, not just defined (look for a bare invocation line)
    if grep -qE '^\s*gc_stale_state_files' "$CLEANUP_SCRIPT" 2>/dev/null; then
        _GC_CALLED="yes"
    fi
fi
assert_eq "test_gc_called_from_cleanup_script: function invoked in main flow" "yes" "$_GC_CALLED"

assert_pass_if_clean "test_gc_called_from_cleanup_script"

# ============================================================================
print_summary
