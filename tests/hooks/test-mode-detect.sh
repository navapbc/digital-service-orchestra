#!/usr/bin/env bash
# tests/hooks/test-mode-detect.sh
# Behavioral tests for plugins/dso/scripts/mode-detect.sh
#
# mode-detect.sh reads dso.workflow directly from dso-config.conf via read-config.sh.
# Outputs: ci-pr | local (propagates read-config.sh exit code if config missing)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$SCRIPT_DIR/../lib/assert.sh"

TARGET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/mode-detect.sh"

# ── RED gate: fail immediately if mode-detect.sh does not exist ──
if [[ ! -f "$TARGET_SCRIPT" ]]; then
    printf "FAIL: mode-detect.sh does not exist at: %s\n" "$TARGET_SCRIPT" >&2
    (( ++FAIL ))
    print_summary
fi

# ── Shared fixture setup ──
_TEST_TMPDIRS=()
cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    printf '%s' "$d"
}

# Helper: write a minimal dso-config.conf with dso.workflow set
make_workflow_config() {
    local config_file="$1"
    local workflow="$2"
    printf 'dso.workflow=%s\n' "$workflow" > "$config_file"
}

# ── Case 1: local when dso.workflow=local ──
# Given: dso.workflow=local in dso-config.conf
# When:  mode-detect.sh is called
# Then:  mode-detect.sh outputs 'local'
test_mode_detect_local() {
    local tmp_dir config_file output
    tmp_dir=$(make_tmpdir)
    config_file="${tmp_dir}/dso-config.conf"

    make_workflow_config "$config_file" "local"

    output=$(DSO_CONFIG_PATH="$config_file" bash "$TARGET_SCRIPT" 2>/dev/null)
    assert_eq "local_when_dso_workflow_local" "local" "$output"
}

# ── Case 2: ci-pr when dso.workflow=ci-pr ──
# Given: dso.workflow=ci-pr in dso-config.conf
# When:  mode-detect.sh is called
# Then:  mode-detect.sh outputs 'ci-pr'
test_mode_detect_ci_pr() {
    local tmp_dir config_file output
    tmp_dir=$(make_tmpdir)
    config_file="${tmp_dir}/dso-config.conf"

    make_workflow_config "$config_file" "ci-pr"

    output=$(DSO_CONFIG_PATH="$config_file" bash "$TARGET_SCRIPT" 2>/dev/null)
    assert_eq "ci_pr_when_dso_workflow_ci_pr" "ci-pr" "$output"
}

# ── Case 3: non-zero exit when config is missing ──
# Given: DSO_CONFIG_PATH points to a non-existent file
# When:  mode-detect.sh is called
# Then:  mode-detect.sh exits non-zero
test_mode_detect_missing_config() {
    local tmp_dir exit_code
    tmp_dir=$(make_tmpdir)

    DSO_CONFIG_PATH="${tmp_dir}/nonexistent-dso-config.conf" bash "$TARGET_SCRIPT" 2>/dev/null
    exit_code=$?
    if [[ "$exit_code" -ne 0 ]]; then
        assert_eq "missing_config_exits_nonzero" "nonzero" "nonzero"
    else
        assert_eq "missing_config_exits_nonzero" "nonzero" "zero"
    fi
}

# ── Case 4 (legacy shim): enforcement.strategy=ci + merge.strategy=pr → ci-pr ──
# The legacy shim in read-config.sh maps these two keys to dso.workflow=ci-pr.
# This test verifies the shim still works end-to-end through mode-detect.sh.
test_mode_detect_legacy_shim_ci_pr() {
    local tmp_dir config_file output
    tmp_dir=$(make_tmpdir)
    config_file="${tmp_dir}/dso-config.conf"

    printf 'enforcement.strategy=ci\nmerge.strategy=pr\n' > "$config_file"

    output=$(DSO_CONFIG_PATH="$config_file" bash "$TARGET_SCRIPT" 2>/dev/null)
    assert_eq "legacy_shim_enforcement_ci_merge_pr_outputs_ci_pr" "ci-pr" "$output"
}

# ── Run all cases ──
test_mode_detect_local
test_mode_detect_ci_pr
test_mode_detect_missing_config
test_mode_detect_legacy_shim_ci_pr

print_summary
