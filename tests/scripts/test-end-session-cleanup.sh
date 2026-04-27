#!/usr/bin/env bash
# tests/scripts/test-end-session-cleanup.sh
# Behavioral tests for plugins/dso/scripts/end-session/end-session-cleanup.sh.
# Process kill is skipped via SKIP_PROCESS_KILL=1 to keep tests hermetic.
#
# Usage: bash tests/scripts/test-end-session-cleanup.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$PLUGIN_ROOT/plugins/dso/scripts/end-session/end-session-cleanup.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-end-session-cleanup.sh ==="

# Each test gets its own scratch repo + ARTIFACTS_DIR so the helper has a real
# directory to operate on but no contamination from the host worktree.
_setup_scratch() {
    local tmp; tmp=$(mktemp -d)
    (
        cd "$tmp" || exit 1
        git init -q
        git config user.email t@t
        git config user.name t
        git commit -q --allow-empty -m initial
    )
    mkdir -p "$tmp/artifacts"
    echo "$tmp"
}

# ---------------------------------------------------------------------------
# test_removes_playwright_state_directory
# When .playwright-cli exists at repo root, helper removes it.
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup_scratch)
mkdir -p "$tmp/.playwright-cli/sessions"
echo "stale" > "$tmp/.playwright-cli/sessions/state"
(cd "$tmp" && SKIP_PROCESS_KILL=1 ARTIFACTS_DIR="$tmp/artifacts" bash "$HELPER" >/dev/null 2>&1)
[[ ! -d "$tmp/.playwright-cli" ]] && playwright_removed=yes || playwright_removed=no
assert_eq "test_removes_playwright_state_dir" "yes" "$playwright_removed"
assert_pass_if_clean "test_removes_playwright_state_directory"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# test_no_playwright_state_dir_is_noop
# When .playwright-cli does not exist, helper exits 0 without error.
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup_scratch)
(cd "$tmp" && SKIP_PROCESS_KILL=1 ARTIFACTS_DIR="$tmp/artifacts" bash "$HELPER" >/dev/null 2>&1)
rc=$?
assert_eq "test_missing_playwright_dir_rc" "0" "$rc"
assert_pass_if_clean "test_no_playwright_state_dir_is_noop"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# test_deletes_hash_suffixed_config_cache_files
# config-cache-<hash> files get deleted; the primary config-cache file (no
# suffix) is preserved. This is the gate that protects active config caching.
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup_scratch)
touch "$tmp/artifacts/config-cache"
touch "$tmp/artifacts/config-cache-deadbeef"
touch "$tmp/artifacts/config-cache-cafefeed"
touch "$tmp/artifacts/unrelated-file"
(cd "$tmp" && SKIP_PROCESS_KILL=1 ARTIFACTS_DIR="$tmp/artifacts" bash "$HELPER" >/dev/null 2>&1)
[[ -f "$tmp/artifacts/config-cache" ]] && primary=present || primary=missing
[[ -f "$tmp/artifacts/config-cache-deadbeef" ]] && hash1=present || hash1=missing
[[ -f "$tmp/artifacts/config-cache-cafefeed" ]] && hash2=present || hash2=missing
[[ -f "$tmp/artifacts/unrelated-file" ]] && other=present || other=missing
assert_eq "test_primary_config_cache_preserved" "present" "$primary"
assert_eq "test_hash_cache_1_deleted" "missing" "$hash1"
assert_eq "test_hash_cache_2_deleted" "missing" "$hash2"
assert_eq "test_unrelated_file_preserved" "present" "$other"
assert_pass_if_clean "test_deletes_hash_suffixed_config_cache_files"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# test_artifacts_dir_missing_is_noop
# When ARTIFACTS_DIR is unset/empty and deps.sh fails to resolve one, helper
# exits 0 without error and without crashing.
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup_scratch)
(cd "$tmp" && SKIP_PROCESS_KILL=1 ARTIFACTS_DIR="" bash "$HELPER" >/dev/null 2>&1)
rc=$?
assert_eq "test_no_artifacts_dir_rc" "0" "$rc"
assert_pass_if_clean "test_artifacts_dir_missing_is_noop"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# test_idempotent_on_already_clean
# Running twice is safe; second run must still exit 0 with no errors.
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup_scratch)
mkdir -p "$tmp/.playwright-cli"
touch "$tmp/artifacts/config-cache-aaa"
(cd "$tmp" && SKIP_PROCESS_KILL=1 ARTIFACTS_DIR="$tmp/artifacts" bash "$HELPER" >/dev/null 2>&1)
(cd "$tmp" && SKIP_PROCESS_KILL=1 ARTIFACTS_DIR="$tmp/artifacts" bash "$HELPER" >/dev/null 2>&1)
rc=$?
assert_eq "test_second_run_rc" "0" "$rc"
assert_pass_if_clean "test_idempotent_on_already_clean"
rm -rf "$tmp"

echo
print_summary
