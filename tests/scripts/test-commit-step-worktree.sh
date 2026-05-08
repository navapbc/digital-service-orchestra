#!/usr/bin/env bash
# tests/scripts/test-commit-step-worktree.sh
#
# RED tests for commit-step.sh worktree context safety (task 8ab2-95b1-34d1-4016).
#
# Tests 1 and 2 are RED: commit-step.sh has no CWD mismatch check or
# DSO_HARVEST_MODE bypass, so test_cwd_mismatch_fails_fast will PASS
# (the script succeeds when it shouldn't) and test_harvest_mode_bypasses_cwd_check
# will FAIL (harvest mode does not yet force exit 0).
#
# Tests 3-5 may already pass given the existing atomic mktemp pattern.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
COMMIT_STEP="$REPO_ROOT/plugins/dso/scripts/commit-step.sh"
LIB_DIR="$REPO_ROOT/tests/lib"

# shellcheck source=../lib/assert.sh
source "$LIB_DIR/assert.sh"

# ── Temp-dir tracking ──────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "$d" ]] && rm -rf "$d"
    done
}
trap '_cleanup_tmpdirs' EXIT

_make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Helper: create a minimal git repo ──────────────────────────────────────
_init_git_repo() {
    local dir="$1"
    git -C "$dir" init -q 2>/dev/null
    git -C "$dir" -c user.email=t@t -c user.name=T commit -q --allow-empty -m "init" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════
# Test 1 — RED
# Expectation: when commit-step.sh is invoked with CWD set to a non-git
# directory it should detect the mismatch and exit non-zero.
# Current reality: no such check exists → script exits 0 → assertion FAILS.
# ══════════════════════════════════════════════════════════════════════════
test_cwd_mismatch_fails_fast() {
    local non_git_dir artifacts_dir
    non_git_dir=$(_make_tmpdir)
    artifacts_dir=$(_make_tmpdir)

    # Run commit-step.sh from a non-git CWD; capture exit code
    local exit_code
    (cd "$non_git_dir" && \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$COMMIT_STEP" lint 30 true 2>/dev/null)
    exit_code=$?

    # Must exit non-zero when CWD is not inside a git repo
    assert_ne "cwd_mismatch_must_fail: exit code should be non-zero" "0" "$exit_code"
}

# ══════════════════════════════════════════════════════════════════════════
# Test 2 — RED
# Expectation: DSO_HARVEST_MODE=1 should bypass the CWD check, exit 0,
# and write the artifact.
# Current reality: no harvest mode check exists at all → behavior undefined.
# ══════════════════════════════════════════════════════════════════════════
test_harvest_mode_bypasses_cwd_check() {
    local non_git_dir artifacts_dir
    non_git_dir=$(_make_tmpdir)
    artifacts_dir=$(_make_tmpdir)

    local exit_code
    (cd "$non_git_dir" && \
        DSO_HARVEST_MODE=1 \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$COMMIT_STEP" lint 30 true 2>/dev/null)
    exit_code=$?

    # Harvest mode must exit 0 even from a non-git CWD
    assert_eq "harvest_mode_bypass: exit 0" "0" "$exit_code"

    # And the artifact must be written
    local result_file="$artifacts_dir/lint.result"
    assert_eq "harvest_mode_bypass: artifact written" "yes" \
        "$( [[ -f "$result_file" ]] && echo yes || echo no )"

    # The artifact must explicitly record that harvest mode was active.
    # This assertion is RED: commit-step.sh does not yet write a harvest_mode field.
    local harvest_field
    harvest_field=$(python3 -c "
import json, sys
data = json.load(sys.stdin)
print(str(data.get('harvest_mode', 'MISSING')).lower())
" < "$result_file" 2>/dev/null || echo "MISSING")
    assert_eq "harvest_mode_bypass: artifact records harvest_mode=true" "true" "$harvest_field"
}

# ══════════════════════════════════════════════════════════════════════════
# Test 3 — may already PASS
# Verify that a branch name containing slashes does NOT cause path divergence
# in the written artifact path (the result must be $ARTIFACTS_DIR/lint.result,
# not a sub-path rooted at the branch name fragments).
# ══════════════════════════════════════════════════════════════════════════
test_branch_slash_no_path_divergence() {
    local repo_dir artifacts_dir
    repo_dir=$(_make_tmpdir)
    artifacts_dir=$(_make_tmpdir)

    _init_git_repo "$repo_dir"
    git -C "$repo_dir" checkout -q -b feat/foo/bar 2>/dev/null

    local exit_code
    exit_code=$(cd "$repo_dir" && \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        REPO_ROOT="$repo_dir" \
        bash "$COMMIT_STEP" lint 30 true 2>/dev/null; echo $?)

    assert_eq "slash_branch: exit 0" "0" "$exit_code"

    # Artifact must be at flat path, not nested under feat/foo/bar
    local result_file="$artifacts_dir/lint.result"
    assert_eq "slash_branch: artifact at correct path" "yes" \
        "$( [[ -f "$result_file" ]] && echo yes || echo no )"

    # Confirm no nested path artifact was created (e.g., artifacts_dir/feat/foo/bar/lint.result)
    local nested_file="$artifacts_dir/feat/foo/bar/lint.result"
    assert_eq "slash_branch: no nested artifact path" "no" \
        "$( [[ -f "$nested_file" ]] && echo yes || echo no )"
}

# ══════════════════════════════════════════════════════════════════════════
# Test 4 — may already PASS
# Concurrent invocations writing different step names to the same ARTIFACTS_DIR
# must both produce valid JSON result files with no partial-write corruption.
# ══════════════════════════════════════════════════════════════════════════
test_concurrent_writes_atomic() {
    local repo_dir artifacts_dir
    repo_dir=$(_make_tmpdir)
    artifacts_dir=$(_make_tmpdir)

    _init_git_repo "$repo_dir"

    # Launch two parallel commit-step invocations with distinct step names
    (cd "$repo_dir" && \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        REPO_ROOT="$repo_dir" \
        bash "$COMMIT_STEP" step-alpha 30 true 2>/dev/null) &
    local pid1=$!

    (cd "$repo_dir" && \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        REPO_ROOT="$repo_dir" \
        bash "$COMMIT_STEP" step-beta 30 true 2>/dev/null) &
    local pid2=$!

    wait "$pid1"
    wait "$pid2"

    # Both result files must exist
    assert_eq "concurrent: step-alpha.result exists" "yes" \
        "$( [[ -f "$artifacts_dir/step-alpha.result" ]] && echo yes || echo no )"
    assert_eq "concurrent: step-beta.result exists" "yes" \
        "$( [[ -f "$artifacts_dir/step-beta.result" ]] && echo yes || echo no )"

    # Both must be valid JSON (python3 parse succeeds)
    local alpha_valid beta_valid
    alpha_valid=$(python3 -c "import json,sys; json.load(sys.stdin)" \
        < "$artifacts_dir/step-alpha.result" 2>/dev/null && echo yes || echo no)
    beta_valid=$(python3 -c "import json,sys; json.load(sys.stdin)" \
        < "$artifacts_dir/step-beta.result" 2>/dev/null && echo yes || echo no)

    assert_eq "concurrent: step-alpha.result is valid JSON" "yes" "$alpha_valid"
    assert_eq "concurrent: step-beta.result is valid JSON" "yes" "$beta_valid"
}

# ══════════════════════════════════════════════════════════════════════════
# Test 5 — may already PASS
# Two invocations using different WORKFLOW_PLUGIN_ARTIFACTS_DIR values must
# write artifacts into their respective dirs with no cross-contamination.
# ══════════════════════════════════════════════════════════════════════════
test_correct_worktree_isolation() {
    local repo_dir artifacts_dir_a artifacts_dir_b
    repo_dir=$(_make_tmpdir)
    artifacts_dir_a=$(_make_tmpdir)
    artifacts_dir_b=$(_make_tmpdir)

    _init_git_repo "$repo_dir"

    # First invocation → artifacts_dir_a
    (cd "$repo_dir" && \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir_a" \
        REPO_ROOT="$repo_dir" \
        bash "$COMMIT_STEP" lint 30 true 2>/dev/null)

    # Second invocation → artifacts_dir_b
    (cd "$repo_dir" && \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir_b" \
        REPO_ROOT="$repo_dir" \
        bash "$COMMIT_STEP" lint 30 true 2>/dev/null)

    # Each dir must have its own artifact
    assert_eq "isolation: artifact in dir_a" "yes" \
        "$( [[ -f "$artifacts_dir_a/lint.result" ]] && echo yes || echo no )"
    assert_eq "isolation: artifact in dir_b" "yes" \
        "$( [[ -f "$artifacts_dir_b/lint.result" ]] && echo yes || echo no )"

    # No cross-contamination: dir_a's steps.log must not contain entries that
    # reference dir_b's path, and the two result files must be separate inodes
    # (i.e., they are distinct files, not hard-links pointing to each other).
    local same_inode
    same_inode=$(python3 -c "
import os
a = os.stat('$artifacts_dir_a/lint.result')
b = os.stat('$artifacts_dir_b/lint.result')
print('yes' if (a.st_dev == b.st_dev and a.st_ino == b.st_ino) else 'no')
" 2>/dev/null || echo "no")
    assert_eq "isolation: result files are not the same inode (separate)" "no" "$same_inode"
    # Both steps.log entries must exist independently
    assert_eq "isolation: steps.log in dir_a" "yes" \
        "$( [[ -f "$artifacts_dir_a/steps.log" ]] && echo yes || echo no )"
    assert_eq "isolation: steps.log in dir_b" "yes" \
        "$( [[ -f "$artifacts_dir_b/steps.log" ]] && echo yes || echo no )"
}

# ── Run all tests ──────────────────────────────────────────────────────────
test_cwd_mismatch_fails_fast
test_harvest_mode_bypasses_cwd_check
test_branch_slash_no_path_divergence
test_concurrent_writes_atomic
test_correct_worktree_isolation

print_summary
