#!/usr/bin/env bash
# tests/scripts/test-collect-discoveries-plugin-root.sh
# Regression guard for dso-or3g: collect-discoveries.sh must not crash with
# "get_artifacts_dir not found" when CLAUDE_PLUGIN_ROOT points to the main
# repo root instead of the plugin subdirectory.
#
# This mirrors the test_cleanup_discoveries_wrong_plugin_root test in
# test-lifecycle-portability.sh (dso-094a guard), extended to cover the
# top-level collect-discoveries.sh script which had the same unguarded pattern.
#
# Usage: bash tests/scripts/test-collect-discoveries-plugin-root.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
COLLECT="$DSO_PLUGIN_DIR/scripts/collect-discoveries.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-collect-discoveries-plugin-root.sh ==="

# ── Setup: temporary working git repo ───────────────────────────────────────
TMPDIR_REPO="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_REPO"' EXIT

git init -q -b main "$TMPDIR_REPO"
git -C "$TMPDIR_REPO" commit --allow-empty -m "init" -q

# ── Test 1: Normal invocation exits 0 and emits empty JSON array ─────────────
_snapshot_fail
_disc_tmpdir=$(mktemp -d)
normal_exit=0
normal_output=""
normal_output=$(AGENT_DISCOVERIES_DIR="$_disc_tmpdir/agent-discoveries" \
    bash "$COLLECT" 2>&1) || normal_exit=$?
assert_eq "test_normal_invocation: exit code" "0" "$normal_exit"
assert_contains "test_normal_invocation: empty array" "[]" "$normal_output"
rm -rf "$_disc_tmpdir"
assert_pass_if_clean "test_normal_invocation"

# ── Test 2: Wrong CLAUDE_PLUGIN_ROOT (main repo root) does not crash ─────────
# Regression test for dso-or3g: when CLAUDE_PLUGIN_ROOT points to the main
# repo root (not plugins/dso/), collect-discoveries.sh previously crashed with
# "get_artifacts_dir: command not found" because deps.sh was not found at
# ${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh.
# The fix: add the same plugin.json sentinel guard used in agent-batch-lifecycle.sh.
# We use AGENT_DISCOVERIES_DIR to redirect artifacts to a writable tmp dir,
# so this test exercises the plugin-root resolution without get_artifacts_dir.
_snapshot_fail
_disc_tmpdir2=$(mktemp -d)
wrong_root_exit=0
wrong_root_output=""
wrong_root_output=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    AGENT_DISCOVERIES_DIR="$_disc_tmpdir2/agent-discoveries" \
    bash "$COLLECT" 2>&1) || wrong_root_exit=$?
assert_eq "test_wrong_plugin_root: exit code" "0" "$wrong_root_exit"
assert_contains "test_wrong_plugin_root: empty array" "[]" "$wrong_root_output"
rm -rf "$_disc_tmpdir2"
assert_pass_if_clean "test_wrong_plugin_root"

# ── Test 3: Wrong CLAUDE_PLUGIN_ROOT still collects valid discovery files ─────
# Ensures the sentinel guard doesn't break actual collection when plugin root
# is wrong (uses AGENT_DISCOVERIES_DIR override to skip get_artifacts_dir path).
_snapshot_fail
_disc_tmpdir3=$(mktemp -d)
mkdir -p "$_disc_tmpdir3/discoveries"
cat > "$_disc_tmpdir3/discoveries/task-abc.json" <<'JSON'
{
  "task_id": "task-abc",
  "type": "bug",
  "summary": "Test discovery entry",
  "affected_files": ["src/foo.py"]
}
JSON
collection_exit=0
collection_output=""
collection_output=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    AGENT_DISCOVERIES_DIR="$_disc_tmpdir3/discoveries" \
    bash "$COLLECT" 2>&1) || collection_exit=$?
assert_eq "test_collection_with_wrong_root: exit code" "0" "$collection_exit"
assert_contains "test_collection_with_wrong_root: task_id present" "task-abc" "$collection_output"
assert_contains "test_collection_with_wrong_root: type present" "bug" "$collection_output"
rm -rf "$_disc_tmpdir3"
assert_pass_if_clean "test_collection_with_wrong_root"

print_summary
