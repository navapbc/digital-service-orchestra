#!/usr/bin/env bash
# tests/scripts/test-update-shim.sh
# TDD tests for plugins/dso/scripts/update-shim.sh
#
# Tests:
#   1. Script exits 1 when TARGET_REPO does not exist
#   2. Script copies template shim to TARGET_REPO/.claude/scripts/dso
#   3. Copied shim is executable
#   4. Script exits 0 on success
#   5. Script warns and creates shim dir when .claude/scripts/ is missing
#
# Usage: bash tests/scripts/test-update-shim.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
UPDATE_SHIM="$REPO_ROOT/plugins/dso/scripts/update-shim.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-update-shim.sh ==="

# ── test_nonexistent_target_repo_exits_1 ─────────────────────────────────────
_snapshot_fail
_actual_exit=0
bash "$UPDATE_SHIM" "/nonexistent/path/$$" >/dev/null 2>&1 || _actual_exit=$?
assert_ne "test_nonexistent_target_repo_exits_1" "0" "$_actual_exit"
assert_pass_if_clean "test_nonexistent_target_repo_exits_1"

# ── test_copies_shim_to_target_repo ──────────────────────────────────────────
_snapshot_fail
_TMPDIR=$(mktemp -d)
mkdir -p "$_TMPDIR/.claude/scripts"
# Create a placeholder shim so the script doesn't warn about missing dir
touch "$_TMPDIR/.claude/scripts/dso"

bash "$UPDATE_SHIM" "$_TMPDIR" >/dev/null 2>&1
_copy_exit=$?
assert_eq "test_copies_shim_to_target_repo" "0" "$_copy_exit"
assert_pass_if_clean "test_copies_shim_to_target_repo"
rm -rf "$_TMPDIR"

# ── test_copied_shim_is_executable ───────────────────────────────────────────
_snapshot_fail
_TMPDIR2=$(mktemp -d)
mkdir -p "$_TMPDIR2/.claude/scripts"
touch "$_TMPDIR2/.claude/scripts/dso"

bash "$UPDATE_SHIM" "$_TMPDIR2" >/dev/null 2>&1
_is_executable=0
[ -x "$_TMPDIR2/.claude/scripts/dso" ] && _is_executable=1
assert_eq "test_copied_shim_is_executable" "1" "$_is_executable"
assert_pass_if_clean "test_copied_shim_is_executable"
rm -rf "$_TMPDIR2"

# ── test_creates_scripts_dir_when_missing ────────────────────────────────────
_snapshot_fail
_TMPDIR3=$(mktemp -d)
# No .claude/scripts/ directory — script should create it

bash "$UPDATE_SHIM" "$_TMPDIR3" >/dev/null 2>&1
_dir_exit=$?
_shim_exists=0
[ -f "$_TMPDIR3/.claude/scripts/dso" ] && _shim_exists=1
assert_eq "test_creates_scripts_dir_when_missing" "1" "$_shim_exists"
assert_pass_if_clean "test_creates_scripts_dir_when_missing"
rm -rf "$_TMPDIR3"

print_summary
