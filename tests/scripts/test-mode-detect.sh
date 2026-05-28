#!/usr/bin/env bash
# tests/scripts/test-mode-detect.sh
# RED tests for plugins/dso/scripts/mode-detect.sh — dso.workflow lookup behavior.
#
# These tests specify the NEW behavior (dso.workflow key lookup via read-config.sh).
# All 5 test functions FAIL against the current unmodified mode-detect.sh, which
# still uses legacy git-remote + enforcement.strategy + merge.strategy detection.
#
# Usage: bash tests/scripts/test-mode-detect.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

# Suite-runner guard: do not auto-run test_ functions when sourced.
# Only execute when run directly (BASH_SOURCE[0] == $0).
# shellcheck disable=SC2317
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/mode-detect.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-mode-detect.sh ==="

# ── Temp dir setup with EXIT trap cleanup ─────────────────────────────────────
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# ── Helper: create a minimal config file with given content ──────────────────
# Usage: _make_config <tmpdir> <content>
# Prints path to the config file
_make_config() {
    local tmpdir="$1" content="$2"
    local cfg
    # mktemp on macOS requires suffix via -t prefix.XXXXXX (no inline path template with suffix)
    cfg="$(mktemp "${TMPDIR:-/tmp}/dso-config.XXXXXX")"
    mv "$cfg" "${cfg}.conf"
    cfg="${cfg}.conf"
    printf '%s\n' "$content" > "$cfg"
    printf '%s\n' "$cfg"
}

# ── test_mode_detect_returns_ci_pr_when_dso_workflow_ci_pr ───────────────────
# Given: config has dso.workflow=ci-pr
# When:  mode-detect.sh is called with DSO_CONFIG_PATH pointing to that config
# Then:  stdout=ci-pr, exit 0
#
# RED: current mode-detect.sh uses legacy git-remote detection — it does NOT
# read dso.workflow from the config file, so it will output 'local' (no remote
# in the temp git repo), not 'ci-pr'.
_fail_before_cipw=$FAIL
cfg_cipw=$(_make_config "$TMPDIR_FIXTURE" "dso.workflow=ci-pr")
cipw_exit=0
cipw_output=""
cipw_output=$(DSO_CONFIG_PATH="$cfg_cipw" bash "$SCRIPT" 2>/dev/null) || cipw_exit=$?
assert_eq "test_mode_detect_returns_ci_pr_when_dso_workflow_ci_pr: exit 0" "0" "$cipw_exit"
assert_eq "test_mode_detect_returns_ci_pr_when_dso_workflow_ci_pr: stdout is ci-pr" "ci-pr" "$cipw_output"
if [[ "$FAIL" -eq "$_fail_before_cipw" ]]; then
    echo "test_mode_detect_returns_ci_pr_when_dso_workflow_ci_pr ... PASS"
fi

# ── test_mode_detect_returns_local_when_dso_workflow_local ───────────────────
# Given: config has dso.workflow=local
# When:  mode-detect.sh is called with DSO_CONFIG_PATH pointing to that config
# Then:  stdout=local, exit 0
#
# RED: current mode-detect.sh ignores dso.workflow and falls through to legacy
# detection. With a config containing only dso.workflow=local, the legacy path
# reads enforcement.strategy and merge.strategy (both absent), so it would also
# produce 'local'. However, the new implementation must read dso.workflow
# directly from the config via read-config.sh. This test validates that the
# dso.workflow key — not the legacy keys — is the authoritative source.
# We verify this by also asserting there is no git remote fallback side-effect.
_fail_before_locw=$FAIL
cfg_locw=$(_make_config "$TMPDIR_FIXTURE" "dso.workflow=local")
locw_exit=0
locw_output=""
locw_output=$(DSO_CONFIG_PATH="$cfg_locw" bash "$SCRIPT" 2>/dev/null) || locw_exit=$?
assert_eq "test_mode_detect_returns_local_when_dso_workflow_local: exit 0" "0" "$locw_exit"
assert_eq "test_mode_detect_returns_local_when_dso_workflow_local: stdout is local" "local" "$locw_output"
# Additional signal: current impl uses `git remote get-url origin`; new impl
# must NOT require a real git remote — it reads from config only.
# We prove RED by checking the script does NOT call read-config.sh currently.
if grep -q 'read-config' "$SCRIPT"; then
    actual_reads_config="yes"
else
    actual_reads_config="no"
fi
assert_eq "test_mode_detect_returns_local_when_dso_workflow_local: script uses read-config.sh" "yes" "$actual_reads_config"
if [[ "$FAIL" -eq "$_fail_before_locw" ]]; then
    echo "test_mode_detect_returns_local_when_dso_workflow_local ... PASS"
fi

# ── test_mode_detect_forwards_config_path_via_env ────────────────────────────
# Given: DSO_CONFIG_PATH is set and the config contains dso.workflow=ci-pr
# When:  mode-detect.sh is invoked
# Then:  the config path is passed through to read-config.sh (WORKFLOW_CONFIG_FILE),
#        stdout=ci-pr, exit 0
#
# RED: current mode-detect.sh passes DSO_CONFIG_PATH directly to grep — it does
# not invoke read-config.sh at all. After implementation, mode-detect.sh must
# delegate to read-config.sh with WORKFLOW_CONFIG_FILE set from DSO_CONFIG_PATH.
_fail_before_fwde=$FAIL
cfg_fwde=$(_make_config "$TMPDIR_FIXTURE" "dso.workflow=ci-pr")
fwde_exit=0
fwde_output=""
fwde_output=$(DSO_CONFIG_PATH="$cfg_fwde" bash "$SCRIPT" 2>/dev/null) || fwde_exit=$?
assert_eq "test_mode_detect_forwards_config_path_via_env: exit 0" "0" "$fwde_exit"
assert_eq "test_mode_detect_forwards_config_path_via_env: stdout is ci-pr" "ci-pr" "$fwde_output"
# Contract: new impl must source or call read-config.sh.
# Verify the current script does NOT invoke read-config.sh (proves RED).
if grep -q 'read-config\.sh' "$SCRIPT"; then
    actual_calls_read_config="yes"
else
    actual_calls_read_config="no"
fi
assert_eq "test_mode_detect_forwards_config_path_via_env: script invokes read-config.sh" "yes" "$actual_calls_read_config"
if [[ "$FAIL" -eq "$_fail_before_fwde" ]]; then
    echo "test_mode_detect_forwards_config_path_via_env ... PASS"
fi

# ── test_mode_detect_exits_nonzero_on_missing_config ─────────────────────────
# Given: DSO_CONFIG_PATH points to a nonexistent file
# When:  mode-detect.sh is called
# Then:  exits non-zero (read-config.sh will exit 1 when dso.workflow is absent)
#
# RED: current mode-detect.sh silently tolerates a missing config — grep returns
# empty strings and it outputs 'local' with exit 0. New impl calls read-config.sh
# which exits 1 for a missing dso.workflow key (nonexistent config).
_fail_before_mnze=$FAIL
nonexistent="$TMPDIR_FIXTURE/does-not-exist-$(date +%s).conf"
mnze_exit=0
mnze_output=""
mnze_output=$(DSO_CONFIG_PATH="$nonexistent" bash "$SCRIPT" 2>/dev/null) || mnze_exit=$?
if [[ "$mnze_exit" -ne 0 ]]; then
    actual_mnze_exit="nonzero"
else
    actual_mnze_exit="zero"
fi
assert_eq "test_mode_detect_exits_nonzero_on_missing_config: exits non-zero" "nonzero" "$actual_mnze_exit"
if [[ "$FAIL" -eq "$_fail_before_mnze" ]]; then
    echo "test_mode_detect_exits_nonzero_on_missing_config ... PASS"
fi

# ── test_mode_detect_legacy_keys_absent ──────────────────────────────────────
# Given: config has merge.strategy=pr + enforcement.strategy=ci (NO dso.workflow)
# When:  mode-detect.sh is called with DSO_CONFIG_PATH pointing to that config
# Then:  stdout=ci-pr (shim in read-config.sh maps legacy keys), exit 0
#
# RED: the current mode-detect.sh does read merge.strategy and enforcement.strategy,
# but it also requires `git remote get-url origin` to return a non-empty value.
# In the test environment (temp dir without a real remote), it will output 'local'
# even when both legacy keys are set correctly. New impl relies entirely on
# read-config.sh's legacy-key shim (which does NOT require a git remote check).
_fail_before_lka=$FAIL
cfg_lka=$(_make_config "$TMPDIR_FIXTURE" "merge.strategy=pr
enforcement.strategy=ci")
lka_exit=0
lka_output=""
# Run in a temp dir that has NO git remote (ensuring legacy behavior requires remote)
_tmp_repo_lka="$(mktemp -d)"
git -C "$_tmp_repo_lka" init -q 2>/dev/null
lka_output=$(
    cd "$_tmp_repo_lka" && \
    DSO_CONFIG_PATH="$cfg_lka" bash "$SCRIPT" 2>/dev/null
) || lka_exit=$?
rm -rf "$_tmp_repo_lka"
assert_eq "test_mode_detect_legacy_keys_absent: exit 0" "0" "$lka_exit"
assert_eq "test_mode_detect_legacy_keys_absent: stdout is ci-pr (legacy shim)" "ci-pr" "$lka_output"
if [[ "$FAIL" -eq "$_fail_before_lka" ]]; then
    echo "test_mode_detect_legacy_keys_absent ... PASS"
fi

print_summary
