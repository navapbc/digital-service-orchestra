#!/usr/bin/env bash
# shellcheck disable=SC2046,SC2329
# tests/scripts/test-merge-to-main-dispatcher.sh
# RED tests for merge-to-main.sh dispatcher routing, CONFLICT_DATA schema,
# and --resume cross-strategy rejection.
#
# TDD tests (tests 1-5 are RED — FAIL against current codebase):
#   1. test_dispatcher_routes_to_direct_script  — RED
#   2. test_dispatcher_routes_to_pr_script      — RED
#   3. test_conflict_data_schema_direct         — RED
#   4. test_conflict_data_schema_pr_equivalent  — RED
#   5. test_resume_rejects_cross_strategy       — RED
#   6. test_direct_mode_regression_no_network   — GREEN (regression guard, PASSES now)
#
# Usage: bash tests/scripts/test-merge-to-main-dispatcher.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# Shared helper
# ---------------------------------------------------------------------------

# _write_config <config_file> <strategy>
_write_config() {
    local cfg_file="$1"
    local strategy="$2"
    mkdir -p "$(dirname "$cfg_file")"
    {
        echo "merge.strategy=$strategy"
        echo "ci.workflow_name=test-ci"
    } > "$cfg_file"
}

# ---------------------------------------------------------------------------
# Test 1: test_dispatcher_routes_to_direct_script
# RED: merge-to-main-direct.sh doesn't exist; dispatcher not implemented.
# When merge.strategy=direct, merge-to-main.sh should delegate to
# merge-to-main-direct.sh, which (as a stub) writes a sentinel file.
# ---------------------------------------------------------------------------
test_dispatcher_routes_to_direct_script() {
    local _T _ec _out _sentinel_exists
    _T="$(mktemp -d /tmp/dso-dispatcher-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    local bin_dir="$_T/bin"
    mkdir -p "$bin_dir"

    local sentinel_direct="$_T/sentinel-direct"
    cat > "$bin_dir/merge-to-main-direct.sh" <<STUB
#!/usr/bin/env bash
touch "$sentinel_direct"
exit 0
STUB
    chmod +x "$bin_dir/merge-to-main-direct.sh"

    _write_config "$_T/.claude/dso-config.conf" "direct"

    # Capture exit code without || true masking
    _out="$(
        PATH="$bin_dir:$PATH" \
        PROJECT_ROOT="$_T" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$MERGE_SCRIPT" 2>&1
    )"; _ec=$?
    : "$_ec" "$_out"  # suppress unused-variable warnings

    _sentinel_exists="false"
    [[ -f "$sentinel_direct" ]] && _sentinel_exists="true"

    assert_eq "test_dispatcher_routes_to_direct_script" "true" "$_sentinel_exists"
}
test_dispatcher_routes_to_direct_script

# ---------------------------------------------------------------------------
# Test 2: test_dispatcher_routes_to_pr_script
# RED: merge-to-main-pr.sh doesn't exist; dispatcher not implemented.
# When merge.strategy=pr, merge-to-main.sh should delegate to
# merge-to-main-pr.sh; the direct stub must NOT be invoked.
# ---------------------------------------------------------------------------
test_dispatcher_routes_to_pr_script() {
    local _T _ec _out _pr_exists _direct_exists
    _T="$(mktemp -d /tmp/dso-dispatcher-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    local bin_dir="$_T/bin"
    mkdir -p "$bin_dir"

    local sentinel_direct="$_T/sentinel-direct"
    local sentinel_pr="$_T/sentinel-pr"

    cat > "$bin_dir/merge-to-main-direct.sh" <<STUB
#!/usr/bin/env bash
touch "$sentinel_direct"
exit 0
STUB
    chmod +x "$bin_dir/merge-to-main-direct.sh"

    cat > "$bin_dir/merge-to-main-pr.sh" <<STUB
#!/usr/bin/env bash
touch "$sentinel_pr"
exit 0
STUB
    chmod +x "$bin_dir/merge-to-main-pr.sh"

    _write_config "$_T/.claude/dso-config.conf" "pr"

    _out="$(
        PATH="$bin_dir:$PATH" \
        PROJECT_ROOT="$_T" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$MERGE_SCRIPT" 2>&1
    )"; _ec=$?
    : "$_ec" "$_out"

    _pr_exists="false"
    _direct_exists="false"
    [[ -f "$sentinel_pr" ]] && _pr_exists="true"
    [[ -f "$sentinel_direct" ]] && _direct_exists="true"

    assert_eq "test_dispatcher_routes_to_pr_script_pr_invoked" "true" "$_pr_exists"
    assert_eq "test_dispatcher_routes_to_pr_script_direct_not_invoked" "false" "$_direct_exists"
}
test_dispatcher_routes_to_pr_script

# ---------------------------------------------------------------------------
# Test 3: test_conflict_data_schema_direct
# RED: dispatcher split not done; CONFLICT_DATA not emitted with required fields.
# When merge.strategy=direct, output should contain CONFLICT_DATA JSON with
# fields: branch, base_branch, conflicted_files, resolution_strategy.
# ---------------------------------------------------------------------------
test_conflict_data_schema_direct() {
    local _T _ec _out
    _T="$(mktemp -d /tmp/dso-dispatcher-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _write_config "$_T/.claude/dso-config.conf" "direct"

    _out="$(
        PROJECT_ROOT="$_T" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$MERGE_SCRIPT" 2>&1
    )"; _ec=$?
    : "$_ec"

    local _has_conflict_data="false"
    local _has_branch="false"
    local _has_base_branch="false"
    local _has_conflicted_files="false"
    local _has_resolution_strategy="false"

    if echo "$_out" | grep -q "CONFLICT_DATA"; then
        _has_conflict_data="true"
        echo "$_out" | grep -q '"branch"' && _has_branch="true"
        echo "$_out" | grep -q '"base_branch"' && _has_base_branch="true"
        echo "$_out" | grep -q '"conflicted_files"' && _has_conflicted_files="true"
        echo "$_out" | grep -q '"resolution_strategy"' && _has_resolution_strategy="true"
    fi

    assert_eq "test_conflict_data_schema_direct_emitted" "true" "$_has_conflict_data"
    assert_eq "test_conflict_data_schema_direct_has_branch" "true" "$_has_branch"
    assert_eq "test_conflict_data_schema_direct_has_base_branch" "true" "$_has_base_branch"
    assert_eq "test_conflict_data_schema_direct_has_conflicted_files" "true" "$_has_conflicted_files"
    assert_eq "test_conflict_data_schema_direct_has_resolution_strategy" "true" "$_has_resolution_strategy"
}
test_conflict_data_schema_direct

# ---------------------------------------------------------------------------
# Test 4: test_conflict_data_schema_pr_equivalent
# RED: merge-to-main-pr.sh doesn't exist; CONFLICT_DATA not emitted.
# When merge.strategy=pr, CONFLICT_DATA fields must match direct mode exactly.
# ---------------------------------------------------------------------------
test_conflict_data_schema_pr_equivalent() {
    local _T _ec _out
    _T="$(mktemp -d /tmp/dso-dispatcher-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _write_config "$_T/.claude/dso-config.conf" "pr"

    _out="$(
        PROJECT_ROOT="$_T" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$MERGE_SCRIPT" 2>&1
    )"; _ec=$?
    : "$_ec"

    local _has_conflict_data="false"
    local _has_branch="false"
    local _has_base_branch="false"
    local _has_conflicted_files="false"
    local _has_resolution_strategy="false"

    if echo "$_out" | grep -q "CONFLICT_DATA"; then
        _has_conflict_data="true"
        echo "$_out" | grep -q '"branch"' && _has_branch="true"
        echo "$_out" | grep -q '"base_branch"' && _has_base_branch="true"
        echo "$_out" | grep -q '"conflicted_files"' && _has_conflicted_files="true"
        echo "$_out" | grep -q '"resolution_strategy"' && _has_resolution_strategy="true"
    fi

    assert_eq "test_conflict_data_schema_pr_emitted" "true" "$_has_conflict_data"
    assert_eq "test_conflict_data_schema_pr_has_branch" "true" "$_has_branch"
    assert_eq "test_conflict_data_schema_pr_has_base_branch" "true" "$_has_base_branch"
    assert_eq "test_conflict_data_schema_pr_has_conflicted_files" "true" "$_has_conflicted_files"
    assert_eq "test_conflict_data_schema_pr_has_resolution_strategy" "true" "$_has_resolution_strategy"
}
test_conflict_data_schema_pr_equivalent

# ---------------------------------------------------------------------------
# Test 5: test_resume_rejects_cross_strategy
# RED: merge.strategy not read; no cross-strategy rejection logic.
# Given: state file written with merge.strategy=direct
# When:  merge-to-main.sh --resume runs with merge.strategy=pr in config
# Then:  (a) exits non-zero, (b) output contains BOTH stored strategy ("direct")
#        AND current config strategy ("pr"), (c) state file NOT deleted/mutated.
# ---------------------------------------------------------------------------
test_resume_rejects_cross_strategy() {
    local _T _ec _out
    _T="$(mktemp -d /tmp/dso-dispatcher-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _write_config "$_T/.claude/dso-config.conf" "pr"

    # Write a state file with merge.strategy=direct (simulating a prior run
    # that started with direct mode, now resumed under pr config).
    local _branch_safe="worktrees-cross-strategy-test-$$"
    local _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    python3 - <<PYEOF > "$_state_file"
import json, time
data = {
    'branch': 'worktrees/cross-strategy-test',
    'merge_sha': '',
    'completed_phases': ['sync'],
    'current_phase': 'merge',
    'phases': {},
    'merge_strategy': 'direct',
    'created_at': time.time()
}
print(json.dumps(data))
PYEOF

    local _state_before
    _state_before="$(cat "$_state_file" 2>/dev/null || echo 'MISSING')"

    _out="$(
        PROJECT_ROOT="$_T" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$MERGE_SCRIPT" --resume 2>&1
    )"; _ec=$?

    # (a) exits non-zero
    local _nonzero="false"
    [[ "$_ec" -ne 0 ]] && _nonzero="true"

    # (b) output contains both strategy names
    local _has_direct="false"
    local _has_pr="false"
    echo "$_out" | grep -q "direct" && _has_direct="true"
    echo "$_out" | grep -q "pr" && _has_pr="true"

    # (c) state file NOT deleted or mutated
    local _state_after
    _state_after="$(cat "$_state_file" 2>/dev/null || echo 'MISSING')"
    local _state_unchanged="false"
    [[ "$_state_before" == "$_state_after" ]] && _state_unchanged="true"

    assert_eq "test_resume_rejects_cross_strategy_exits_nonzero" "true" "$_nonzero"
    assert_eq "test_resume_rejects_cross_strategy_output_has_stored" "true" "$_has_direct"
    assert_eq "test_resume_rejects_cross_strategy_output_has_current" "true" "$_has_pr"
    assert_eq "test_resume_rejects_cross_strategy_state_unchanged" "true" "$_state_unchanged"

    rm -f "$_state_file"
}
test_resume_rejects_cross_strategy

# ---------------------------------------------------------------------------
# Test 6: test_direct_mode_regression_no_network
# GREEN: This test SHOULD PASS against current codebase (regression guard).
#
# When merge.strategy is absent and the PROJECT_ROOT is not a git repo,
# merge-to-main.sh must exit non-zero with a non-empty error message.
# This guards against regressions where the dispatcher silently exits 0.
#
# Note: the current script fails early at the "cd" step or git detection
# because PROJECT_ROOT points to a plain tmpdir (not a git repo), so the
# CLAUDE_PLUGIN_ROOT path resolution fails with a non-zero exit.
# ---------------------------------------------------------------------------
test_direct_mode_regression_no_network() {
    local _T _ec _out
    _T="$(mktemp -d /tmp/dso-dispatcher-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    # Config with no merge.strategy — defaults to direct behavior in current code
    mkdir -p "$_T/.claude"
    echo "ci.workflow_name=test-ci" > "$_T/.claude/dso-config.conf"

    # Run against a non-git tmpdir — script must exit non-zero
    _out="$(
        PROJECT_ROOT="$_T" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$MERGE_SCRIPT" 2>&1
    )"; _ec=$?

    local _exits_nonzero="false"
    [[ "$_ec" -ne 0 ]] && _exits_nonzero="true"

    local _has_output="false"
    [[ -n "$_out" ]] && _has_output="true"

    assert_eq "test_direct_mode_regression_no_network_exits_nonzero" "true" "$_exits_nonzero"
    assert_eq "test_direct_mode_regression_no_network_has_error_output" "true" "$_has_output"
}
test_direct_mode_regression_no_network

# ---------------------------------------------------------------------------
print_summary
