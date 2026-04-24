#!/usr/bin/env bash
# tests/scripts/test-artifact-update-integration.sh
# Integration test: before/after cycle combining check-artifact-versions.sh
# and update-artifacts.sh.
#
# Scenario: dso-setup.sh creates a host project with current-version stamps.
# The shim stamp is then downgraded to "0.0.0" (simulating a stale artifact).
# check-artifact-versions.sh should notice the stale artifact and suggest
# running update-artifacts. update-artifacts.sh then updates the stale shim.
# After clearing the cache, check-artifact-versions.sh should produce no output.
#
# Usage: bash tests/scripts/test-artifact-update-integration.sh
# Returns: exit 0 if all assertions pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

CHECK_SCRIPT="$PLUGIN_ROOT/plugins/dso/hooks/check-artifact-versions.sh"
UPDATE_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/update-artifacts.sh"

echo "=== test-artifact-update-integration.sh ==="

# ── Temp dir pool with auto-cleanup ──────────────────────────────────────────
TMPDIRS=()
trap 'rm -rf "${TMPDIRS[@]}"' EXIT

_new_tmpdir() {
    local d
    d="$(mktemp -d)"
    TMPDIRS+=("$d")
    echo "$d"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_before_after_stale_update_cycle
# Full before/after integration cycle:
#   1. dso-setup.sh creates host project with current-version stamps
#   2. Shim stamp downgraded to 0.0.0 (simulating stale artifact)
#   3. check-artifact-versions.sh → notice emitted naming update-artifacts
#   4. update-artifacts.sh → updates the stale shim
#   5. Cache cleared
#   6. check-artifact-versions.sh → no output (all artifacts current)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_before_after_stale_update_cycle ---"
_snapshot_fail

_host_dir="$(_new_tmpdir)"

# Step 1: Run dso-setup.sh to create a host project with current-version stamps
# dso-setup.sh usage: dso-setup.sh [TARGET_REPO [PLUGIN_ROOT]]
_setup_rc=0
bash "$PLUGIN_ROOT/plugins/dso/scripts/onboarding/dso-setup.sh" \
    "$_host_dir" "$PLUGIN_ROOT/plugins/dso" \
    >/dev/null 2>&1 || _setup_rc=$?

assert_eq "test_before_after_stale_update_cycle: dso-setup exits 0 or 2 (warnings ok)" \
    "0" "$(( _setup_rc == 0 || _setup_rc == 2 ? 0 : _setup_rc ))"

# Confirm shim was created with a current-version stamp
_shim_path="$_host_dir/.claude/scripts/dso"
_shim_exists="no"
[[ -f "$_shim_path" ]] && _shim_exists="yes"
assert_eq "test_before_after_stale_update_cycle: shim created by dso-setup" "yes" "$_shim_exists"

# Step 2: Downgrade the shim stamp to "0.0.0" to simulate a stale artifact
# (Never write to live repo cache — all writes go to isolated _host_dir)
if [[ -f "$_shim_path" ]]; then
    sed -i.bak "s|^# dso-version:.*|# dso-version: 0.0.0|" "$_shim_path" \
        && rm -f "${_shim_path}.bak"
fi

# Verify downgrade took effect
_shim_stamp_before="$(grep '^# dso-version:' "$_shim_path" 2>/dev/null | head -1 | awk '{print $3}')"
assert_eq "test_before_after_stale_update_cycle: shim stamp downgraded to 0.0.0" \
    "0.0.0" "$_shim_stamp_before"

# Clear any existing cache so check runs fresh
rm -f "$_host_dir/.claude/dso-artifact-check-cache"

# Step 3: Run check-artifact-versions.sh from the temp dir context
# With PLUGIN_ROOT env var pointing to the real plugin root.
# CWD=_host_dir (not a git repo — source repo guard will not fire).
_check_out_before=""
_check_rc_before=0
_check_out_before="$(cd "$_host_dir" && PLUGIN_ROOT="$PLUGIN_ROOT" bash "$CHECK_SCRIPT" 2>&1)" \
    || _check_rc_before=$?

assert_eq "test_before_after_stale_update_cycle: check exits 0 (fail-open)" \
    "0" "$_check_rc_before"

# Step 4 precondition: check output must contain "update-artifacts" notice
assert_contains "test_before_after_stale_update_cycle: check notices stale artifact" \
    "update-artifacts" "$_check_out_before"

# Step 5: Run update-artifacts.sh to update the stale shim
# --target: host project dir; PLUGIN_ROOT resolves the real templates
_update_rc=0
PLUGIN_ROOT="$PLUGIN_ROOT" bash "$UPDATE_SCRIPT" \
    --target "$_host_dir" \
    >/dev/null 2>&1 || _update_rc=$?

assert_eq "test_before_after_stale_update_cycle: update-artifacts exits 0" \
    "0" "$_update_rc"

# Verify shim stamp was updated to a non-0.0.0 version
_shim_stamp_after="$(grep '^# dso-version:' "$_shim_path" 2>/dev/null | head -1 | awk '{print $3}')"
assert_ne "test_before_after_stale_update_cycle: shim stamp updated from 0.0.0" \
    "0.0.0" "$_shim_stamp_after"

# Step 6: Clear the cache file so the next check doesn't return a cache hit
rm -f "$_host_dir/.claude/dso-artifact-check-cache"

# Step 7: Run check-artifact-versions.sh again — should produce no output
# (all artifacts are now current)
_check_out_after=""
_check_rc_after=0
_check_out_after="$(cd "$_host_dir" && PLUGIN_ROOT="$PLUGIN_ROOT" bash "$CHECK_SCRIPT" 2>&1)" \
    || _check_rc_after=$?

assert_eq "test_before_after_stale_update_cycle: second check exits 0" \
    "0" "$_check_rc_after"

assert_eq "test_before_after_stale_update_cycle: second check produces no output (all current)" \
    "" "$_check_out_after"

assert_pass_if_clean "test_before_after_stale_update_cycle"

# ─────────────────────────────────────────────────────────────────────────────
print_summary
