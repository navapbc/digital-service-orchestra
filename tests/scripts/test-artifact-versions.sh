#!/usr/bin/env bash
# tests/scripts/test-artifact-versions.sh
# RED-phase behavioral tests for plugins/dso/hooks/check-artifact-versions.sh
#
# Tests invoke check-artifact-versions.sh with isolated fixtures and assert on
# exit codes and stdout.  The script does not yet exist; all tests fail RED.
#
# Artifacts checked (4 total):
#   .claude/scripts/dso              — text stamp: "# dso-version: <ver>"
#   .claude/dso-config.conf          — text stamp: "# dso-version: <ver>"
#   .pre-commit-config.yaml          — YAML stamp: "x-dso-version: <ver>"
#   .github/workflows/ci.yml         — YAML stamp: "x-dso-version: <ver>"
#
# Plugin version sourced from: plugins/dso/.claude-plugin/plugin.json .version
# Cache file:  <host-repo>/.claude/dso-artifact-check-cache  (KEY=VALUE format)
#   VERSION=<ver>  TIMESTAMP=<epoch>
#
# Usage: bash tests/scripts/test-artifact-versions.sh
# Returns: exit 0 all pass, exit 1 any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/hooks/check-artifact-versions.sh"
PLUGIN_JSON="$PLUGIN_ROOT/plugins/dso/.claude-plugin/plugin.json"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-artifact-versions.sh ==="

# ── Global temp dir pool ──────────────────────────────────────────────────────
_TEST_TMPDIRS=()
trap 'rm -rf "${_TEST_TMPDIRS[@]+"${_TEST_TMPDIRS[@]}"}";' EXIT

new_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Read current plugin version ───────────────────────────────────────────────
PLUGIN_VERSION="$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['version'])" 2>/dev/null)"
if [[ -z "$PLUGIN_VERSION" ]]; then
    echo "ERROR: could not read version from $PLUGIN_JSON" >&2
    exit 1
fi

OLD_VERSION="0.0.0"   # guaranteed older than PLUGIN_VERSION

# ── Helper: build a host-project fixture dir ─────────────────────────────────
# make_host_repo DIR VERSION_FOR_STAMPS
# Creates the 4 artifacts each stamped with VERSION_FOR_STAMPS.
# Caller may subsequently mutate individual files to simulate stale/legacy.
make_host_repo() {
    local dir="$1"
    local ver="$2"

    mkdir -p "$dir/.claude/scripts"
    mkdir -p "$dir/.github/workflows"

    # .claude/scripts/dso — shim (text stamp)
    printf '#!/usr/bin/env bash\n# dso-version: %s\nexec "$@"\n' "$ver" \
        > "$dir/.claude/scripts/dso"
    chmod +x "$dir/.claude/scripts/dso"

    # .claude/dso-config.conf — config (text stamp)
    printf '# dso-version: %s\ndso.plugin_root=%s\n' "$ver" "$PLUGIN_ROOT" \
        > "$dir/.claude/dso-config.conf"

    # .pre-commit-config.yaml — YAML stamp
    printf 'x-dso-version: %s\nrepos: []\n' "$ver" \
        > "$dir/.pre-commit-config.yaml"

    # .github/workflows/ci.yml — YAML stamp
    printf 'x-dso-version: %s\nname: CI\n' "$ver" \
        > "$dir/.github/workflows/ci.yml"
}

# ── Helper: run script in a host repo dir ────────────────────────────────────
# run_check HOST_DIR [extra env KEY=VALUE ...]
# Executes check-artifact-versions.sh with CWD=HOST_DIR.
# Returns output via stdout; exit code via caller's `|| rc=$?` pattern.
run_check() {
    local host_dir="$1"
    shift
    (cd "$host_dir" && env PLUGIN_ROOT="$PLUGIN_ROOT" "$@" bash "$SCRIPT" 2>&1)
}

# ─────────────────────────────────────────────────────────────────────────────
# test_all_current_silent_exit
# All 4 artifacts at current plugin version → no output, exit 0
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_all_current_silent_exit ---"
_snapshot_fail

_dir_all_current="$(new_tmpdir)"
make_host_repo "$_dir_all_current" "$PLUGIN_VERSION"

_rc_all_current=0
_out_all_current="$(run_check "$_dir_all_current")" || _rc_all_current=$?

assert_eq "test_all_current_silent_exit: exit 0" "0" "$_rc_all_current"
assert_eq "test_all_current_silent_exit: no output" "" "$_out_all_current"

assert_pass_if_clean "test_all_current_silent_exit"

# ─────────────────────────────────────────────────────────────────────────────
# test_one_stale_notification
# One artifact at an older version → notice emitted naming the stale artifact
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_one_stale_notification ---"
_snapshot_fail

_dir_one_stale="$(new_tmpdir)"
make_host_repo "$_dir_one_stale" "$PLUGIN_VERSION"
# Downgrade just the shim stamp
sed -i.bak "s|# dso-version: .*|# dso-version: $OLD_VERSION|" \
    "$_dir_one_stale/.claude/scripts/dso" && rm -f "$_dir_one_stale/.claude/scripts/dso.bak"

_rc_one_stale=0
_out_one_stale="$(run_check "$_dir_one_stale")" || _rc_one_stale=$?

assert_eq "test_one_stale_notification: exit 0" "0" "$_rc_one_stale"
assert_ne "test_one_stale_notification: output not empty" "" "$_out_one_stale"
assert_contains "test_one_stale_notification: names stale artifact" "dso" "$_out_one_stale"

assert_pass_if_clean "test_one_stale_notification"

# ─────────────────────────────────────────────────────────────────────────────
# test_all_stale_notification
# All 4 artifacts at older version → notice listing all stale artifacts
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_all_stale_notification ---"
_snapshot_fail

_dir_all_stale="$(new_tmpdir)"
make_host_repo "$_dir_all_stale" "$OLD_VERSION"

_rc_all_stale=0
_out_all_stale="$(run_check "$_dir_all_stale")" || _rc_all_stale=$?

assert_eq "test_all_stale_notification: exit 0" "0" "$_rc_all_stale"
assert_ne "test_all_stale_notification: output not empty" "" "$_out_all_stale"
# All 4 artifact names should appear somewhere in the output
assert_contains "test_all_stale_notification: mentions dso shim" "dso" "$_out_all_stale"
assert_contains "test_all_stale_notification: mentions config" "dso-config" "$_out_all_stale"
assert_contains "test_all_stale_notification: mentions pre-commit" "pre-commit" "$_out_all_stale"
assert_contains "test_all_stale_notification: mentions ci" "ci" "$_out_all_stale"

assert_pass_if_clean "test_all_stale_notification"

# ─────────────────────────────────────────────────────────────────────────────
# test_legacy_artifact_notification
# One artifact has no version stamp → notice with legacy/migration message
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_legacy_artifact_notification ---"
_snapshot_fail

_dir_legacy="$(new_tmpdir)"
make_host_repo "$_dir_legacy" "$PLUGIN_VERSION"
# Strip the version stamp from the shim to simulate a legacy artifact
python3 - "$_dir_legacy/.claude/scripts/dso" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
with open(path, 'w') as f:
    for line in lines:
        if '# dso-version:' not in line:
            f.write(line)
PYEOF

_rc_legacy=0
_out_legacy="$(run_check "$_dir_legacy")" || _rc_legacy=$?

assert_eq "test_legacy_artifact_notification: exit 0" "0" "$_rc_legacy"
assert_ne "test_legacy_artifact_notification: output not empty" "" "$_out_legacy"
# Output should reference migration or legacy
_legacy_contains_keyword=0
if [[ "$_out_legacy" == *"legacy"* ]] || [[ "$_out_legacy" == *"migrat"* ]] || \
   [[ "$_out_legacy" == *"unstamped"* ]] || [[ "$_out_legacy" == *"no stamp"* ]] || \
   [[ "$_out_legacy" == *"no version"* ]]; then
    _legacy_contains_keyword=1
fi
assert_eq "test_legacy_artifact_notification: legacy/migration keyword in output" "1" "$_legacy_contains_keyword"

assert_pass_if_clean "test_legacy_artifact_notification"

# ─────────────────────────────────────────────────────────────────────────────
# test_cache_hit_skips_reads
# Cache valid (matching version, age < 24h) → script exits 0 with no output,
# even when artifact files would report stale if read
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_cache_hit_skips_reads ---"
_snapshot_fail

_dir_cache_hit="$(new_tmpdir)"
# Intentionally stale artifacts — cache hit should prevent any actual reads
make_host_repo "$_dir_cache_hit" "$OLD_VERSION"

# Write a fresh cache entry matching the current plugin version
_now_ts="$(date +%s)"
mkdir -p "$_dir_cache_hit/.claude"
printf 'VERSION=%s\nTIMESTAMP=%s\n' "$PLUGIN_VERSION" "$_now_ts" \
    > "$_dir_cache_hit/.claude/dso-artifact-check-cache"

_rc_cache_hit=0
_out_cache_hit="$(run_check "$_dir_cache_hit")" || _rc_cache_hit=$?

assert_eq "test_cache_hit_skips_reads: exit 0" "0" "$_rc_cache_hit"
assert_eq "test_cache_hit_skips_reads: no output (cache valid)" "" "$_out_cache_hit"

assert_pass_if_clean "test_cache_hit_skips_reads"

# ─────────────────────────────────────────────────────────────────────────────
# test_cache_bust_on_version_change
# Cache has OLD_VERSION, plugin has PLUGIN_VERSION, timestamp < 24h → re-check fires
# (stale artifacts detected despite age < 24h because plugin version changed)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_cache_bust_on_version_change ---"
_snapshot_fail

_dir_version_change="$(new_tmpdir)"
# All artifacts at OLD_VERSION (stale)
make_host_repo "$_dir_version_change" "$OLD_VERSION"

# Cache says we already checked against OLD_VERSION (a previous plugin release),
# but the current plugin is PLUGIN_VERSION — cache should be busted.
_now_ts2="$(date +%s)"
mkdir -p "$_dir_version_change/.claude"
printf 'VERSION=%s\nTIMESTAMP=%s\n' "$OLD_VERSION" "$_now_ts2" \
    > "$_dir_version_change/.claude/dso-artifact-check-cache"

_rc_version_change=0
_out_version_change="$(run_check "$_dir_version_change")" || _rc_version_change=$?

assert_eq "test_cache_bust_on_version_change: exit 0" "0" "$_rc_version_change"
# Staleness notice should appear because version mismatch busted the cache
assert_ne "test_cache_bust_on_version_change: output not empty" "" "$_out_version_change"

assert_pass_if_clean "test_cache_bust_on_version_change"

# ─────────────────────────────────────────────────────────────────────────────
# test_plugin_source_repo_silent_exit
# plugins/dso/.claude-plugin/plugin.json exists in CWD → silent exit (no output, exit 0)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_plugin_source_repo_silent_exit ---"
_snapshot_fail

_dir_plugin_source="$(new_tmpdir)"
# Set up as a simulated plugin source repo: create the sentinel path
mkdir -p "$_dir_plugin_source/plugins/dso/.claude-plugin"
cp "$PLUGIN_JSON" "$_dir_plugin_source/plugins/dso/.claude-plugin/plugin.json"
# Also add stale artifacts to confirm they are NOT checked in plugin source mode
make_host_repo "$_dir_plugin_source" "$OLD_VERSION"

_rc_plugin_source=0
_out_plugin_source="$(run_check "$_dir_plugin_source" DSO_SOURCE_REPO=true)" || _rc_plugin_source=$?

assert_eq "test_plugin_source_repo_silent_exit: exit 0" "0" "$_rc_plugin_source"
assert_eq "test_plugin_source_repo_silent_exit: no output" "" "$_out_plugin_source"

assert_pass_if_clean "test_plugin_source_repo_silent_exit"

# ─────────────────────────────────────────────────────────────────────────────
# test_fail_open_on_unreadable_plugin
# PLUGIN_ROOT points to a dir without plugin.json → exit 0, no output (fail-open)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_fail_open_on_unreadable_plugin ---"
_snapshot_fail

_dir_fail_open="$(new_tmpdir)"
make_host_repo "$_dir_fail_open" "$PLUGIN_VERSION"
# Point PLUGIN_ROOT to a directory that has no plugin.json
_empty_plugin_root="$(new_tmpdir)"

_rc_fail_open=0
_out_fail_open=""
_out_fail_open="$(cd "$_dir_fail_open" && PLUGIN_ROOT="$_empty_plugin_root" bash "$SCRIPT" 2>&1)" \
    || _rc_fail_open=$?

assert_eq "test_fail_open_on_unreadable_plugin: exit 0" "0" "$_rc_fail_open"
assert_eq "test_fail_open_on_unreadable_plugin: no output" "" "$_out_fail_open"

assert_pass_if_clean "test_fail_open_on_unreadable_plugin"

# ─────────────────────────────────────────────────────────────────────────────
# test_gitignore_includes_cache
# dso-setup.sh appends .claude/dso-artifact-check-cache to host .gitignore
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_gitignore_includes_cache ---"
_snapshot_fail

_dir_gitignore="$(new_tmpdir)"
# Use dso-setup.sh (not make_host_repo) — dso-setup.sh is what appends the cache path to .gitignore
bash "$PLUGIN_ROOT/plugins/dso/scripts/onboarding/dso-setup.sh" "$_dir_gitignore" "$PLUGIN_ROOT/plugins/dso" >/dev/null 2>&1 || true

if grep -qF '.claude/dso-artifact-check-cache' "$_dir_gitignore/.gitignore" 2>/dev/null; then
    _gi_result="found"
else
    _gi_result="missing"
fi
assert_eq "test_gitignore_includes_cache: cache path in .gitignore" "found" "$_gi_result"

assert_pass_if_clean "test_gitignore_includes_cache"

# ─────────────────────────────────────────────────────────────────────────────
print_summary
