#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-stale-version-bump-reset.sh
#
# RED test for merge-to-main.sh stale-version-bump auto-reset.
#
# Context: when a prior merge-to-main.sh run completes a local merge + version
# bump on `main` but fails to push (e.g., CI failure), the next run finds local
# `main` divergent from `origin/main` — same merged content, just an extra
# version-bump commit. The existing reset logic only handles the
# fast-forward-ancestor case (origin/main is an ancestor of HEAD); the
# divergent case currently triggers a false plugin.json conflict and aborts.
#
# Expected behavior (the fix this test validates): merge-to-main.sh exposes a
# helper `_try_reset_stale_version_bump` that detects the pattern
# (single-file diff against origin/main where the file is the configured
# VERSION_FILE_PATH) and hard-resets local main to origin/main. The version
# bump is reapplied later by the version_bump phase.
#
# Tests:
#   1. helper_resets_when_only_version_file_diverges
#   2. helper_no_op_when_other_files_diverge
#   3. helper_no_op_when_no_divergence
#   4. helper_no_op_when_version_file_path_unset
#
# Usage: bash tests/scripts/test-merge-to-main-stale-version-bump-reset.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-to-main-stale-version-bump-reset.sh ==="

_CLEANUP_DIRS=()
# shellcheck disable=SC2329  # invoked via trap, not directly
_cleanup() { for d in "${_CLEANUP_DIRS[@]+"${_CLEANUP_DIRS[@]}"}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ── Helper: extract _try_reset_stale_version_bump from merge-to-main.sh ─────
# Source the function in isolation so we can drive it against fixture repos
# without running the full multi-phase merge-to-main.sh.
_extract_helper() {
    local _outfile="$1"
    # Extract the function definition (from declaration to its closing brace).
    awk '
        /^_try_reset_stale_version_bump\(\) \{/ { in_func=1 }
        in_func { print }
        in_func && /^\}/ { exit }
    ' "$MERGE_SCRIPT" > "$_outfile"

    if [ ! -s "$_outfile" ]; then
        return 1
    fi
    return 0
}

_HELPER_FILE=$(mktemp /tmp/dso-stale-vbump-helper.XXXXXX.sh)
_CLEANUP_DIRS+=("$_HELPER_FILE")

if ! _extract_helper "$_HELPER_FILE"; then
    # Helper does not exist yet — emit the failure assertions and exit so the
    # RED test fails clearly. The fix adds the helper to merge-to-main.sh.
    assert_eq "test_helper_function_exists_in_merge_to_main_script" \
        "exists" "missing"
    print_summary
    exit 1
fi

# shellcheck source=/dev/null
source "$_HELPER_FILE"

# ── Fixture builder: local main divergent from origin/main by version bump only
# Returns: prints the env path. Sets local main as $ENV/main, with origin remote
# pointing at $ENV/bare.git. The fixture seeds:
#   - origin/main has plugin.json with version "1.0.0"
#   - local main has the same content + a follow-up commit that bumps version
#     to "1.0.1" (single-file, version-line-only diff)
_build_stale_vbump_env() {
    local _vfile_path="$1"   # relative path under repo root, e.g. "plugin.json"
    local _tmpdir
    _tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$_tmpdir")
    local _env
    _env=$(cd "$_tmpdir" && pwd -P)

    # Seed repo
    git init -q -b main "$_env/seed"
    git -C "$_env/seed" config user.email "test@test.com"
    git -C "$_env/seed" config user.name "Test"
    mkdir -p "$_env/seed/$(dirname "$_vfile_path")" 2>/dev/null || true
    printf '{\n  "name": "fixture",\n  "version": "1.0.0"\n}\n' > "$_env/seed/$_vfile_path"
    git -C "$_env/seed" add -A
    git -C "$_env/seed" commit -q -m "init"

    # Bare origin
    git clone --bare -q "$_env/seed" "$_env/bare.git"

    # Local main clone
    git clone -q "$_env/bare.git" "$_env/main"
    git -C "$_env/main" config user.email "test@test.com"
    git -C "$_env/main" config user.name "Test"

    # Apply orphan stale-version-bump commit on local main only
    printf '{\n  "name": "fixture",\n  "version": "1.0.1"\n}\n' > "$_env/main/$_vfile_path"
    git -C "$_env/main" add -- "$_vfile_path"
    git -C "$_env/main" commit -q -m "chore: bump version (orphan from prior failed merge-to-main)"

    echo "$_env"
}

_origin_sha() {
    git -C "$1" fetch -q origin main 2>/dev/null
    git -C "$1" rev-parse origin/main
}

_head_sha() { git -C "$1" rev-parse HEAD; }

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: helper_resets_when_only_version_file_diverges
# ─────────────────────────────────────────────────────────────────────────────
echo "--- test_helper_resets_when_only_version_file_diverges ---"
ENV1=$(_build_stale_vbump_env "plugin.json")
PRE_HEAD=$(_head_sha "$ENV1/main")
ORIGIN_SHA=$(_origin_sha "$ENV1/main")
[ "$PRE_HEAD" != "$ORIGIN_SHA" ] || {
    assert_eq "test1_setup: local main diverges from origin/main" "different" "same"
}

# Drive the helper against the fixture
RESET_OUT=$(cd "$ENV1/main" && VERSION_FILE_PATH="plugin.json" _try_reset_stale_version_bump 2>&1)
RESET_RC=$?
POST_HEAD=$(_head_sha "$ENV1/main")

assert_eq "test1_helper_returns_0_when_reset_performed" "0" "$RESET_RC"
assert_eq "test1_local_main_advanced_to_origin_main_after_reset" \
    "$ORIGIN_SHA" "$POST_HEAD"
assert_contains "test1_helper_logs_reset_message" "stale" "$RESET_OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: helper_no_op_when_other_files_diverge
# Local main has a diff in BOTH the version file AND another file. The helper
# must NOT auto-reset — divergence may contain real work.
# ─────────────────────────────────────────────────────────────────────────────
echo "--- test_helper_no_op_when_other_files_diverge ---"
ENV2=$(_build_stale_vbump_env "plugin.json")
# Add a second commit that touches a non-version file
echo "real change" > "$ENV2/main/some-feature.txt"
git -C "$ENV2/main" add -- some-feature.txt
git -C "$ENV2/main" commit -q -m "feat: real divergent work (must not be auto-discarded)"

PRE_HEAD2=$(_head_sha "$ENV2/main")
RESET_OUT2=$(cd "$ENV2/main" && VERSION_FILE_PATH="plugin.json" _try_reset_stale_version_bump 2>&1)
RESET_RC2=$?
POST_HEAD2=$(_head_sha "$ENV2/main")

assert_eq "test2_helper_returns_nonzero_when_reset_skipped" "1" "$RESET_RC2"
assert_eq "test2_local_main_unchanged_when_other_files_diverge" \
    "$PRE_HEAD2" "$POST_HEAD2"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: helper_no_op_when_no_divergence
# Local main equals origin/main. Helper must return non-zero (no work to do).
# ─────────────────────────────────────────────────────────────────────────────
echo "--- test_helper_no_op_when_no_divergence ---"
ENV3=$(_build_stale_vbump_env "plugin.json")
# Reset local main back to origin/main so there is no divergence
git -C "$ENV3/main" reset --hard origin/main -q

PRE_HEAD3=$(_head_sha "$ENV3/main")
RESET_RC3=0
(cd "$ENV3/main" && VERSION_FILE_PATH="plugin.json" _try_reset_stale_version_bump >/dev/null 2>&1) \
    || RESET_RC3=$?
POST_HEAD3=$(_head_sha "$ENV3/main")

assert_eq "test3_helper_returns_nonzero_when_no_divergence" "1" "$RESET_RC3"
assert_eq "test3_local_main_unchanged_when_no_divergence" \
    "$PRE_HEAD3" "$POST_HEAD3"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: helper_no_op_when_version_file_path_unset
# When VERSION_FILE_PATH is unset (project does not configure version.file_path),
# the helper must NOT reset — it has no signal to identify a stale bump.
# ─────────────────────────────────────────────────────────────────────────────
echo "--- test_helper_no_op_when_version_file_path_unset ---"
ENV4=$(_build_stale_vbump_env "plugin.json")
PRE_HEAD4=$(_head_sha "$ENV4/main")
RESET_RC4=0
(cd "$ENV4/main" && unset VERSION_FILE_PATH && _try_reset_stale_version_bump >/dev/null 2>&1) \
    || RESET_RC4=$?
POST_HEAD4=$(_head_sha "$ENV4/main")

assert_eq "test4_helper_returns_nonzero_when_version_file_path_unset" "1" "$RESET_RC4"
assert_eq "test4_local_main_unchanged_when_version_file_path_unset" \
    "$PRE_HEAD4" "$POST_HEAD4"

print_summary
