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
# strategy: "direct" maps to dso.workflow=local; "pr" maps to dso.workflow=ci-pr
_write_config() {
    local cfg_file="$1"
    local strategy="$2"
    mkdir -p "$(dirname "$cfg_file")"
    # Map legacy strategy values to dso.workflow
    local workflow
    case "$strategy" in
        pr)           workflow="ci-pr" ;;
        direct)       workflow="local" ;;
        *)            workflow="$strategy" ;;  # pass-through for unknown values
    esac
    {
        echo "dso.workflow=$workflow"
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
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dispatcher-test.XXXXXX")"
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
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dispatcher-test.XXXXXX")"
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
# Verifies the shared _emit_conflict_data helper (in merge-helpers.sh) emits
# the four-key contract used by direct-mode merge-failure paths. Also verifies
# merge-to-main-direct.sh wires the helper into both exit-1 paths in
# _phase_merge so a real merge conflict produces CONFLICT_DATA output.
#
# This is a unit-level test of the helper (end-to-end integration with a real
# git conflict is covered by S7 ab3f-46a4 — it requires a full git fixture).
# ---------------------------------------------------------------------------
test_conflict_data_schema_direct() {
    local _T _out
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dispatcher-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    # Set up a minimal git repo with two unmerged paths so _emit_conflict_data's
    # `git diff --name-only --diff-filter=U` fallback reports real conflicted files.
    (
        cd "$_T" || exit 1
        git init -q -b main >/dev/null 2>&1
        git config user.email "test@test.local"
        git config user.name "test"
        echo "base" > a.txt
        echo "base" > b.txt
        git add a.txt b.txt
        git commit -q -m "base" >/dev/null
        git checkout -q -b feature
        echo "feature-a" > a.txt
        echo "feature-b" > b.txt
        git commit -aq -m "feature"
        git checkout -q main
        echo "main-a" > a.txt
        echo "main-b" > b.txt
        git commit -aq -m "main"
        # Trigger a real conflict that leaves unmerged paths in the index.
        git merge feature -q >/dev/null 2>&1 || true
    )

    # Source merge-helpers.sh and call the helper from inside the conflicted repo.
    _out="$(
        cd "$_T" || exit 1
        # shellcheck source=/dev/null
        BRANCH="feature" source "$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"
        _emit_conflict_data "feature" "main" "git-merge-no-ff" 2>&1
    )"

    local _has_conflict_data="false"
    local _has_branch="false"
    local _has_base_branch="false"
    local _has_conflicted_files="false"
    local _has_resolution_strategy="false"
    local _has_real_files="false"

    if echo "$_out" | grep -q "CONFLICT_DATA"; then
        _has_conflict_data="true"
        echo "$_out" | grep -q '"branch"' && _has_branch="true"
        echo "$_out" | grep -q '"base_branch"' && _has_base_branch="true"
        echo "$_out" | grep -q '"conflicted_files"' && _has_conflicted_files="true"
        echo "$_out" | grep -q '"resolution_strategy"' && _has_resolution_strategy="true"
        # Verify the helper actually populated conflicted_files from the real repo.
        echo "$_out" | grep -q 'a.txt' && _has_real_files="true"
    fi

    local _has_strategy_value="false"
    echo "$_out" | grep -q '"resolution_strategy".*"git-merge-no-ff"' && _has_strategy_value="true"

    assert_eq "test_conflict_data_schema_direct_emitted" "true" "$_has_conflict_data"
    assert_eq "test_conflict_data_schema_direct_has_branch" "true" "$_has_branch"
    assert_eq "test_conflict_data_schema_direct_has_base_branch" "true" "$_has_base_branch"
    assert_eq "test_conflict_data_schema_direct_has_conflicted_files" "true" "$_has_conflicted_files"
    assert_eq "test_conflict_data_schema_direct_has_resolution_strategy" "true" "$_has_resolution_strategy"
    assert_eq "test_conflict_data_schema_direct_populates_real_conflicted_files" "true" "$_has_real_files"
    # Behavioral: verify the resolution_strategy field carries the expected value;
    # this tests the helper's output contract without coupling to call-site source structure.
    assert_eq "test_conflict_data_schema_direct_resolution_strategy_value" "true" "$_has_strategy_value"
}
test_conflict_data_schema_direct

# ---------------------------------------------------------------------------
# Test 3b: test_conflict_data_schema_direct_recovery_failed_fallback
# Regression for important finding 2026-05-01: on the recovery-failed branch
# of _phase_merge, _squash_rebase_recovery aborts the rebase before returning,
# AND the caller cd's back to a non-conflicted repo. Both effects strip the
# live `git diff --diff-filter=U` signal. The helper must populate
# conflicted_files via the _SQUASH_REBASE_CONFLICTS export captured by the
# recovery helper before its abort.
# ---------------------------------------------------------------------------
test_conflict_data_schema_direct_recovery_failed_fallback() {
    local _T _out
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dispatcher-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    # Set up a clean (non-conflicted) git repo to simulate $_MERGE_SAVED_DIR
    # after the caller has cd'd back from the worktree where conflicts arose.
    (
        cd "$_T" || exit 1
        git init -q -b main >/dev/null 2>&1
        git config user.email "test@test.local"
        git config user.name "test"
        echo "clean" > c.txt
        git add c.txt
        git commit -q -m "clean" >/dev/null
    )

    # Source merge-helpers.sh from inside the clean repo, set the global
    # _SQUASH_REBASE_CONFLICTS as _squash_rebase_recovery would have done
    # before its rebase --abort, then call the helper.
    _out="$(
        cd "$_T" || exit 1
        # shellcheck source=/dev/null
        BRANCH="feature" source "$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"
        export _SQUASH_REBASE_CONFLICTS=$'pkg/foo.py\npkg/bar.py'
        _emit_conflict_data "feature" "main" "git-merge-no-ff" 2>&1
    )"

    local _has_conflict_data="false"
    local _has_foo="false"
    local _has_bar="false"
    local _empty_array="false"

    if echo "$_out" | grep -q "CONFLICT_DATA"; then
        _has_conflict_data="true"
        echo "$_out" | grep -q 'pkg/foo.py' && _has_foo="true"
        echo "$_out" | grep -q 'pkg/bar.py' && _has_bar="true"
        # Sanity: ensure the fallback isn't degenerating to an empty array.
        echo "$_out" | grep -q '"conflicted_files": *\[\]' && _empty_array="true"
    fi

    assert_eq "test_recovery_failed_fallback_emitted" "true" "$_has_conflict_data"
    assert_eq "test_recovery_failed_fallback_includes_foo" "true" "$_has_foo"
    assert_eq "test_recovery_failed_fallback_includes_bar" "true" "$_has_bar"
    assert_eq "test_recovery_failed_fallback_not_empty" "false" "$_empty_array"
}
test_conflict_data_schema_direct_recovery_failed_fallback

# ---------------------------------------------------------------------------
# Test 4: test_conflict_data_schema_pr_equivalent
# RED: merge-to-main-pr.sh doesn't exist; CONFLICT_DATA not emitted.
# When merge.strategy=pr, CONFLICT_DATA fields must match direct mode exactly.
# ---------------------------------------------------------------------------
test_conflict_data_schema_pr_equivalent() {
    local _T _ec _out
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dispatcher-test.XXXXXX")"
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
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dispatcher-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _write_config "$_T/.claude/dso-config.conf" "pr"

    # Initialize a git repo on the branch named in the state file. The dispatcher
    # resolves the per-branch state-file path via `git branch --show-current`, so
    # without a real git context the cross-strategy check would silently no-op
    # and the test would only catch the rejection by accident (e.g., an unrelated
    # error in the downstream strategy script). Setting up the matching branch
    # exercises the production code path.
    local _branch_name="worktrees/cross-strategy-test-$$"
    local _branch_safe="${_branch_name//\//-}"
    (
        cd "$_T" || exit 1
        git init -q -b main >/dev/null 2>&1
        git config user.email "test@test.local"
        git config user.name "test"
        git commit -q --allow-empty -m "init" >/dev/null
        git checkout -q -b "$_branch_name"
    )

    # Write a state file with merge.strategy=direct (simulating a prior run
    # that started with direct mode, now resumed under pr config).
    local _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    python3 - <<PYEOF > "$_state_file"
import json, time
data = {
    'branch': '$_branch_name',
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
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dispatcher-test.XXXXXX")"
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
# Test 7: test_dispatcher_unknown_workflow_defaults_to_direct
# GREEN: when dso.workflow is set to an unrecognized value, dispatcher
# defaults to direct mode (routes to merge-to-main-direct.sh stub).
# ---------------------------------------------------------------------------
test_dispatcher_unknown_workflow_defaults_to_direct() {
    local _T _ec _out _sentinel_direct
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dispatcher-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    local bin_dir="$_T/bin"
    mkdir -p "$bin_dir"

    _sentinel_direct="$_T/sentinel-direct"
    cat > "$bin_dir/merge-to-main-direct.sh" <<STUB
#!/usr/bin/env bash
touch "$_sentinel_direct"
exit 0
STUB
    chmod +x "$bin_dir/merge-to-main-direct.sh"

    # Write config with an unrecognized dso.workflow value
    mkdir -p "$_T/.claude"
    {
        echo "dso.workflow=unknown_value"
        echo "ci.workflow_name=test-ci"
    } > "$_T/.claude/dso-config.conf"

    _out="$(
        PATH="$bin_dir:$PATH" \
        PROJECT_ROOT="$_T" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$MERGE_SCRIPT" 2>&1
    )"; _ec=$?
    : "$_ec" "$_out"

    local _direct_invoked="false"
    [[ -f "$_sentinel_direct" ]] && _direct_invoked="true"

    assert_eq "test_dispatcher_unknown_workflow_defaults_to_direct" "true" "$_direct_invoked"
}
test_dispatcher_unknown_workflow_defaults_to_direct

# ---------------------------------------------------------------------------
# Test 8: test_state_init_writes_merge_strategy_from_env
# GREEN: _state_init in merge-helpers.sh must write merge_strategy from
# the MERGE_STRATEGY env var (default "direct" when unset). This is the
# behavioral contract the dispatcher relies on for cross-strategy --resume.
# ---------------------------------------------------------------------------
test_state_init_writes_merge_strategy_from_env() {
    local _T _state_pr _state_default
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dispatcher-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    # Source merge-helpers.sh and call _state_init with branch fixtures.
    # _state_init writes /tmp/merge-to-main-state-<branch>.json; redirect via
    # a unique branch name so we don't clobber real state files.
    local _branch_pr="dispatcher-test-pr-$$"
    local _branch_default="dispatcher-test-default-$$"
    local _state_pr_path="/tmp/merge-to-main-state-${_branch_pr}.json"
    local _state_default_path="/tmp/merge-to-main-state-${_branch_default}.json"
    rm -f "$_state_pr_path" "$_state_default_path"

    # Case A: MERGE_STRATEGY=pr exported → state file contains "pr"
    (
        # shellcheck source=/dev/null
        source "$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"
        BRANCH="$_branch_pr" MERGE_STRATEGY=pr _state_init >/dev/null 2>&1
    )
    _state_pr="$(python3 -c "
import json, sys
try:
    d = json.load(open('$_state_pr_path'))
    print(d.get('merge_strategy', 'MISSING'))
except Exception as e:
    print('ERR:' + str(e))
" 2>/dev/null)"

    # Case B: MERGE_STRATEGY unset → state file contains "direct" (default)
    (
        # shellcheck source=/dev/null
        source "$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"
        BRANCH="$_branch_default" _state_init >/dev/null 2>&1
    )
    _state_default="$(python3 -c "
import json, sys
try:
    d = json.load(open('$_state_default_path'))
    print(d.get('merge_strategy', 'MISSING'))
except Exception as e:
    print('ERR:' + str(e))
" 2>/dev/null)"

    rm -f "$_state_pr_path" "$_state_default_path"

    assert_eq "test_state_init_writes_merge_strategy_pr_when_env_set" "pr" "$_state_pr"
    assert_eq "test_state_init_writes_merge_strategy_direct_when_env_unset" "direct" "$_state_default"
}
test_state_init_writes_merge_strategy_from_env

# ---------------------------------------------------------------------------
# Test 9: test_state_init_writes_merge_strategy_pr_on_direct_invocation
# RED: when merge-to-main-pr.sh is invoked directly (bypassing the dispatcher),
# MERGE_STRATEGY is derived as a plain bash variable but NOT exported.
# _state_init spawns python3 which reads os.environ.get('MERGE_STRATEGY','direct')
# — a non-exported bash var is invisible to os.environ, so the state file records
# 'direct' instead of 'pr', causing --resume cross-strategy abort.
#
# Test seam: invoke merge-to-main-pr.sh directly (no dispatcher) in a temp git
# repo with WORKFLOW_CONFIG_FILE pointing to dso.workflow=ci-pr and BRANCH
# pre-set to a known unique name. The script will derive MERGE_STRATEGY=pr, run
# _state_init (which writes the state file), then fail at later phases — but the
# state file is written before any failure. Assert that merge_strategy in the
# state file equals 'pr' (not 'direct').
#
# RED before fix: derivation block sets MERGE_STRATEGY='pr' without export;
#   python3 in _state_init reads os.environ.get('MERGE_STRATEGY','direct') → 'direct'.
# GREEN after fix: `export MERGE_STRATEGY` added → python3 reads 'pr' correctly.
# ---------------------------------------------------------------------------
test_state_init_writes_merge_strategy_pr_on_direct_invocation() {
    local _T _branch_name _branch_safe _state_path _state_val _cfg_file
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dispatcher-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    # Set up a minimal git repo so REPO_ROOT and BRANCH can be resolved.
    (
        cd "$_T" || exit 1
        git init -q -b main >/dev/null 2>&1
        git config user.email "test@test.local"
        git config user.name "test"
        git commit -q --allow-empty -m "init" >/dev/null 2>&1
    )

    _branch_name="dispatcher-test-direct-invoc-pr-$$"
    _branch_safe="${_branch_name//\//-}"
    _state_path="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_path"

    # Write a config file that sets dso.workflow=ci-pr (→ MERGE_STRATEGY=pr).
    _cfg_file="$_T/.claude/dso-config.conf"
    mkdir -p "$(dirname "$_cfg_file")"
    printf 'dso.workflow=ci-pr\n' > "$_cfg_file"

    # Invoke merge-to-main-pr.sh directly (not via dispatcher).
    # MERGE_STRATEGY is NOT pre-exported — must be derived from config.
    # BRANCH is pre-set so _state_init writes to a predictable path.
    # The script will fail after _state_init (no real remote/gh auth) — ignore exit code.
    PROJECT_ROOT="$_T" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    WORKFLOW_CONFIG_FILE="$_cfg_file" \
    BRANCH="$_branch_name" \
    bash "$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh" >/dev/null 2>&1 || true

    _state_val="$(python3 -c "
import json, sys
try:
    d = json.load(open('$_state_path'))
    print(d.get('merge_strategy', 'MISSING'))
except Exception as e:
    print('ERR:' + str(e))
" 2>/dev/null)"

    rm -f "$_state_path"

    # Pre-fix: MERGE_STRATEGY not exported → python3 sees default → 'direct' → FAIL
    # Post-fix: `export MERGE_STRATEGY` in derivation block → python3 reads 'pr' → PASS
    assert_eq "test_state_init_writes_merge_strategy_pr_on_direct_invocation" "pr" "$_state_val"
}
test_state_init_writes_merge_strategy_pr_on_direct_invocation

# ---------------------------------------------------------------------------
print_summary
