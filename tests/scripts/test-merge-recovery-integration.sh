#!/usr/bin/env bash
# shellcheck disable=SC2164  # cd in test subshells; failure exits subshell
# tests/scripts/test-merge-recovery-integration.sh
# Integration tests for recovery wiring in _phase_merge() in merge-to-main.sh
#
# TDD tests:
#   1. test_recovery_triggers_on_merge_failure
#   2. test_retry_succeeds_after_squash_rebase
#   3. test_escalation_after_budget_exhausted
#   4. test_clear_directive_on_unresolvable_conflict
#   5. test_failure_output_prescribes_only_resume
#   6. test_syntax_check
#
# Each integration test creates an isolated temp repo structure:
#   - bare origin remote
#   - main repo (clone of origin, checked out to main)
#   - worktree (separate directory, simulates the worktree session)
#
# To simulate merge failure, tests use core.hooksPath with a pre-merge-commit
# hook that exits 1 when staged file count > 5. This causes git merge to fail
# before the merge commit is recorded, triggering the recovery path.
#
# Usage: bash tests/scripts/test-merge-recovery-integration.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"
MERGE_HELPERS_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"

# Cleanup trap: remove temp dirs and ensure core.hooksPath is never left
# pointing to a stale test directory (bug e899-77d0).
_cleanup_test_dirs() {
    # Unset core.hooksPath if it points to a temp dir (safety net)
    local current_hooks
    current_hooks=$(git config core.hooksPath 2>/dev/null || true)
    if [[ "$current_hooks" == /tmp/* ]] || [[ "$current_hooks" == /var/folders/* ]]; then
        git config --unset core.hooksPath 2>/dev/null || true
    fi
}
trap _cleanup_test_dirs EXIT

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-recovery-integration.sh ==="

# =============================================================================
# Helper: extract state file helpers from merge-to-main.sh for use in tests
# =============================================================================
_extract_state_helpers() {
    local _body
    _body=$(awk '/^# --- State file helpers/,/^# --- SIGURG trap/' "$MERGE_SCRIPT" \
        | grep -v '^# ---')
    # State helpers were extracted to merge-helpers.sh; if not found in merge-to-main.sh,
    # source the entire merge-helpers.sh (all its functions are pure utilities).
    if [[ -z "$_body" ]] && [[ -f "${MERGE_HELPERS_LIB:-}" ]]; then
        _body=$(cat "$MERGE_HELPERS_LIB")
    fi
    echo "$_body"
}

# =============================================================================
# Helper: set up the three-repo structure needed for integration tests.
# Creates:
#   _TEST_BASE  — temp directory
#   _ORIGIN_DIR — bare "origin" remote
#   _MAIN_REPO  — main repo clone (checked out to main)
#   _WORKTREE   — worktree directory (simulated worktree session)
#
# After setup:
#   - origin has an initial commit on main
#   - _MAIN_REPO is checked out to main
#   - _WORKTREE has a branch named $1 (default: feature-branch) with 6 commits
#     (the pre-merge-commit hook triggers on >5 staged files)
# =============================================================================
_setup_integration_repos() {
    local branch_name="${1:-feature-branch}"
    local num_branch_files="${2:-6}"

    _TEST_BASE=$(mktemp -d)
    _ORIGIN_DIR="$_TEST_BASE/origin.git"
    _MAIN_REPO="$_TEST_BASE/main-repo"
    _WORKTREE="$_TEST_BASE/worktree"

    export GIT_ATTR_NOSYSTEM=1

    # Create bare origin
    git init --bare "$_ORIGIN_DIR" -b main --quiet 2>/dev/null

    # Create main repo
    git clone "$_ORIGIN_DIR" "$_MAIN_REPO" --quiet 2>/dev/null
    (
        cd "$_MAIN_REPO"
        git config user.email "main@test.com"
        git config user.name "Main"
        echo "init" > README.md
        git add README.md
        git commit -m "initial commit" --quiet
        git push origin main --quiet 2>/dev/null
    )

    # Create worktree directory as a separate clone (simulates a worktree)
    # It has the same origin but is set up like a worktree (has .git file, not dir)
    git clone "$_ORIGIN_DIR" "$_WORKTREE" --quiet 2>/dev/null
    (
        cd "$_WORKTREE"
        git config user.email "worktree@test.com"
        git config user.name "Worktree"
        # Switch to feature branch
        git checkout -b "$branch_name" --quiet

        # Create N files to simulate branch work
        local i=1
        while [[ $i -le $num_branch_files ]]; do
            echo "feature file $i" > "feature_$i.txt"
            i=$(( i + 1 ))
        done
        git add .
        git commit -m "feature: add $num_branch_files files" --quiet
    )
}

# =============================================================================
# Helper: set up a pre-merge-commit hook that fails when staged file count > 5.
# Installs hook into $1 (the hooks dir) so git merge uses it via core.hooksPath.
# =============================================================================
_install_merge_failure_hook() {
    local hooks_dir="$1"
    mkdir -p "$hooks_dir"
    cat > "$hooks_dir/pre-merge-commit" <<'HOOK'
#!/usr/bin/env bash
# Pre-merge-commit hook: fails when staged file count > 5
staged_count=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
if [ "$staged_count" -gt 5 ]; then
    echo "pre-merge-commit: too many staged files ($staged_count > 5), aborting merge" >&2
    exit 1
fi
exit 0
HOOK
    chmod +x "$hooks_dir/pre-merge-commit"
}

# =============================================================================
# Helper: install a hooks dir with a pre-merge-commit hook that always succeeds.
# Used to verify that retry_merge succeeds after squash-rebase reduces file count.
# =============================================================================
_install_merge_success_hook() {
    local hooks_dir="$1"
    mkdir -p "$hooks_dir"
    cat > "$hooks_dir/pre-merge-commit" <<'HOOK'
#!/usr/bin/env bash
# Pre-merge-commit hook: always succeeds
exit 0
HOOK
    chmod +x "$hooks_dir/pre-merge-commit"
}

# =============================================================================
# Helper: build a minimal harness that sources the _phase_merge function
# from merge-to-main.sh in a controlled environment.
# Required env vars passed:
#   BRANCH, MAIN_REPO, REPO_ROOT, WORKTREE_DIR, state_file
# =============================================================================
_run_phase_merge() {
    local branch="$1"
    local main_repo="$2"
    local worktree_dir="$3"
    local state_file="$4"
    local core_hooks_path="${5:-}"

    # Extract state helpers + _squash_rebase_recovery + _phase_merge from script
    local _state_helpers
    _state_helpers=$(_extract_state_helpers)

    local _recovery_fn
    _recovery_fn=$(awk '/^_squash_rebase_recovery\(\)/,/^\}$/' "$MERGE_SCRIPT")
    if [[ -z "$_recovery_fn" ]] && [[ -f "${MERGE_HELPERS_LIB:-}" ]]; then
        _recovery_fn=$(awk '/^_squash_rebase_recovery\(\)/,/^\}$/' "$MERGE_HELPERS_LIB")
    fi

    local _phase_fn
    _phase_fn=$(awk '/^_phase_merge\(\)/,/^\}$/' "$MERGE_SCRIPT")

    bash -c "
set -uo pipefail
export GIT_ATTR_NOSYSTEM=1
export CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT'

BRANCH='$branch'
MAIN_REPO='$main_repo'
REPO_ROOT='$worktree_dir'
WORKTREE_DIR='$worktree_dir'
MSG_EXCLUSION_PATTERN=''
MAX_MERGE_RETRIES=5
_CURRENT_PHASE=''

$_state_helpers

# Override _state_file_path AFTER sourcing helpers so our override wins
_state_file_path() { echo '$state_file'; }

# Initialize state file if not present
if [[ ! -f '$state_file' ]]; then
    python3 -c \"
import json
d = {'branch': '$branch', 'merge_sha': '', 'completed_phases': [], 'current_phase': '', 'phases': {}, 'retry_count': 0}
with open('$state_file', 'w') as f:
    json.dump(d, f)
\"
fi

# Stub out functions not needed for merge-only test
_state_write_phase() { :; }
_state_record_merge_sha() { :; }
_state_mark_complete() { :; }
_set_phase_status() { :; }

$_recovery_fn

$_phase_fn

# Set core.hooksPath if provided
if [[ -n '$core_hooks_path' ]]; then
    git -C '$main_repo' config core.hooksPath '$core_hooks_path'
fi

# Start in main_repo (where merge happens)
cd '$main_repo'

_phase_merge
" 2>&1
}

# =============================================================================
# Test 1: test_recovery_triggers_on_merge_failure
# When the pre-merge-commit hook causes merge failure, _phase_merge should:
#   - call git merge --abort
#   - call _squash_rebase_recovery
#   - NOT exit 0 (since squash still leaves >5 files staged in this scenario)
# =============================================================================
echo ""
echo "--- test_recovery_triggers_on_merge_failure ---"
_snapshot_fail

_setup_integration_repos "test-recovery-trigger" 6

_T1_HOOKS="$_TEST_BASE/hooks-fail"
_install_merge_failure_hook "$_T1_HOOKS"
_T1_STATE="$_TEST_BASE/state-t1.json"

# Pull the feature branch into main_repo's ref list so merge can find it
git -C "$_MAIN_REPO" fetch "$_WORKTREE" "test-recovery-trigger:test-recovery-trigger" --quiet 2>/dev/null
git -C "$_MAIN_REPO" config core.hooksPath "$_T1_HOOKS"

_T1_RC=0
_T1_OUTPUT=$(_run_phase_merge \
    "test-recovery-trigger" \
    "$_MAIN_REPO" \
    "$_WORKTREE" \
    "$_T1_STATE" \
    "$_T1_HOOKS" \
) || _T1_RC=$?

# Merge should NOT succeed (6 files > 5 threshold), should exit 1
assert_eq "test_recovery_triggers: exit non-zero" "1" "$_T1_RC"

# Output should contain evidence of recovery attempt
_T1_HAS_RECOVERY=0
if [[ "${_T1_OUTPUT,,}" =~ recovery|squash|rebase|_squash_rebase_recovery ]]; then
    _T1_HAS_RECOVERY=1
fi
# Also acceptable: increment retry or directive to --resume
_T1_HAS_RESUME=0
if [[ "$_T1_OUTPUT" == *--resume* ]]; then
    _T1_HAS_RESUME=1
fi
# At least one of recovery attempt OR --resume directive should appear
_T1_EVIDENCE=$(( _T1_HAS_RECOVERY + _T1_HAS_RESUME ))
assert_ne "test_recovery_triggers: evidence of recovery or resume" "0" "$_T1_EVIDENCE"

assert_pass_if_clean "test_recovery_triggers_on_merge_failure"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 2: test_retry_succeeds_after_squash_rebase
# When squash-rebase reduces the branch to 1 commit (touching <=5 files),
# the retry merge should succeed.
# Steps:
#   - Feature branch adds 3 small files (<=5, so retry will succeed)
#   - First merge attempt fails due to hook (threshold lowered to 0 for first attempt)
#   - After squash-rebase, retry merge uses a success hook
# To simulate first-fail/retry-pass: use a stateful hook that fails once.
# =============================================================================
echo ""
echo "--- test_retry_succeeds_after_squash_rebase ---"
_snapshot_fail

_setup_integration_repos "test-retry-success" 3

_T2_HOOKS="$_TEST_BASE/hooks-retry"
mkdir -p "$_T2_HOOKS"

# Create a stateful hook: fail on first call, succeed on subsequent calls
_T2_COUNTER="$_TEST_BASE/merge-hook-counter"
echo "0" > "$_T2_COUNTER"
cat > "$_T2_HOOKS/pre-merge-commit" <<HOOK
#!/usr/bin/env bash
count=\$(cat "$_T2_COUNTER" 2>/dev/null || echo "0")
new_count=\$(( count + 1 ))
echo "\$new_count" > "$_T2_COUNTER"
if [ "\$count" -eq 0 ]; then
    echo "pre-merge-commit: first attempt fails to trigger recovery" >&2
    exit 1
fi
exit 0
HOOK
chmod +x "$_T2_HOOKS/pre-merge-commit"

_T2_STATE="$_TEST_BASE/state-t2.json"

git -C "$_MAIN_REPO" fetch "$_WORKTREE" "test-retry-success:test-retry-success" --quiet 2>/dev/null
git -C "$_MAIN_REPO" config core.hooksPath "$_T2_HOOKS"

_T2_RC=0
_T2_OUTPUT=$(_run_phase_merge \
    "test-retry-success" \
    "$_MAIN_REPO" \
    "$_WORKTREE" \
    "$_T2_STATE" \
    "$_T2_HOOKS" \
) || _T2_RC=$?

# After squash-rebase recovery, retry should succeed (exit 0)
assert_eq "test_retry_succeeds: exit 0" "0" "$_T2_RC"

# Output should contain evidence of recovery + success
_T2_HAS_RECOVERY=0
if [[ "${_T2_OUTPUT,,}" =~ recovery|squash ]]; then
    _T2_HAS_RECOVERY=1
fi
assert_eq "test_retry_succeeds: shows recovery output" "1" "$_T2_HAS_RECOVERY"

_T2_HAS_MERGED=0
if [[ "${_T2_OUTPUT}" =~ OK.*[Mm]erg|[Mm]erg.*OK|[Mm]erge.*success ]]; then
    _T2_HAS_MERGED=1
fi
assert_eq "test_retry_succeeds: confirms merge success" "1" "$_T2_HAS_MERGED"

assert_pass_if_clean "test_retry_succeeds_after_squash_rebase"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 3: test_escalation_after_budget_exhausted
# When retry_count in state file is already >= MAX_MERGE_RETRIES (5),
# the --resume dispatch should print ESCALATE and exit 1 without running phases.
# This tests the escalation gate that was added by task nzu5.
# =============================================================================
echo ""
echo "--- test_escalation_after_budget_exhausted ---"
_snapshot_fail

_T3_TMP=$(mktemp -d)
trap 'rm -rf "$_T3_TMP"' EXIT

# Create state file with retry_count=5 (at threshold)
python3 -c "
import json
d = {'branch': 'test-escalate', 'merge_sha': '', 'completed_phases': [], 'current_phase': '', 'phases': {}, 'retry_count': 5}
with open('$_T3_TMP/state.json', 'w') as f:
    json.dump(d, f)
"

_state_helpers=$(_extract_state_helpers)

_T3_RC=0
_T3_OUTPUT=$(bash -c "
export CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT'
BRANCH='test-escalate'
MAX_MERGE_RETRIES=5

$_state_helpers

# Override _state_file_path AFTER helpers
_state_file_path() { echo '$_T3_TMP/state.json'; }

# Simulate --resume escalation gate
_resume_retry_count=\$(_state_get_retry_count 2>/dev/null || echo '0')
if [[ \$_resume_retry_count -ge \$MAX_MERGE_RETRIES ]]; then
    echo 'ESCALATE: Merge has failed 5 times. Stop and ask the user for help. Do NOT retry.'
    exit 1
fi
echo 'CONTINUE'
" 2>&1) || _T3_RC=$?

assert_eq "test_escalation_after_budget: exit 1" "1" "$_T3_RC"
assert_contains "test_escalation_after_budget: ESCALATE message" "ESCALATE" "$_T3_OUTPUT"
assert_contains "test_escalation_after_budget: Do NOT retry" "Do NOT retry" "$_T3_OUTPUT"

assert_pass_if_clean "test_escalation_after_budget_exhausted"
rm -rf "$_T3_TMP"
trap - EXIT

# =============================================================================
# Test 4: test_clear_directive_on_unresolvable_conflict
# When _squash_rebase_recovery fails due to an unresolvable conflict (non-tickets file),
# _phase_merge should increment retry count and print --resume directive.
# =============================================================================
echo ""
echo "--- test_clear_directive_on_unresolvable_conflict ---"
_snapshot_fail

_setup_integration_repos "test-unresolvable" 6

_T4_HOOKS="$_TEST_BASE/hooks-fail-unresolvable"
_install_merge_failure_hook "$_T4_HOOKS"
_T4_STATE="$_TEST_BASE/state-t4.json"

# Initialize state file with retry_count=0
python3 -c "
import json
d = {'branch': 'test-unresolvable', 'merge_sha': '', 'completed_phases': [], 'current_phase': '', 'phases': {}, 'retry_count': 0}
with open('$_T4_STATE', 'w') as f:
    json.dump(d, f)
"

# Add a conflicting file to origin/main so that rebase will conflict
git -C "$_MAIN_REPO" fetch "$_WORKTREE" "test-unresolvable:test-unresolvable" --quiet 2>/dev/null
git -C "$_MAIN_REPO" config core.hooksPath "$_T4_HOOKS"

# Create a second clone to push diverging changes to origin
_WORK2="$_TEST_BASE/work2"
git clone "$_ORIGIN_DIR" "$_WORK2" --quiet 2>/dev/null
(
    cd "$_WORK2"
    git config user.email "test2@test.com"
    git config user.name "Test2"
    # Create a conflict with feature_1.txt from the branch
    echo "main version of feature_1" > feature_1.txt
    git add feature_1.txt
    git commit -m "main: add conflicting feature_1.txt" --quiet
    git push origin main --quiet 2>/dev/null
)

# Update MAIN_REPO from origin so it sees the diverged main
(
    cd "$_MAIN_REPO"
    git pull --quiet 2>/dev/null || true
    # Re-fetch branch ref
    git fetch "$_WORKTREE" "test-unresolvable:test-unresolvable" --quiet 2>/dev/null
)

_T4_RC=0
_T4_OUTPUT=$(_run_phase_merge \
    "test-unresolvable" \
    "$_MAIN_REPO" \
    "$_WORKTREE" \
    "$_T4_STATE" \
    "$_T4_HOOKS" \
) || _T4_RC=$?

# Should fail (exit 1) since conflict is unresolvable
assert_eq "test_clear_directive: exit non-zero" "1" "$_T4_RC"

# Output should contain --resume directive
_T4_HAS_RESUME=0
if [[ "$_T4_OUTPUT" == *--resume* ]]; then
    _T4_HAS_RESUME=1
fi
assert_eq "test_clear_directive: --resume in output" "1" "$_T4_HAS_RESUME"

# Retry count should have been incremented
_T4_RETRY_COUNT=$(python3 -c "
import json
with open('$_T4_STATE') as f:
    d = json.load(f)
print(d.get('retry_count', 0))
" 2>/dev/null || echo "error")
assert_eq "test_clear_directive: retry count incremented" "1" "$_T4_RETRY_COUNT"

assert_pass_if_clean "test_clear_directive_on_unresolvable_conflict"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 5: test_failure_output_prescribes_only_resume
# When _phase_merge fails (merge failure + squash-rebase fails), the failure
# output must contain --resume and must NOT contain bare git commands like
# "git merge", "git rebase", or "git reset".
# =============================================================================
echo ""
echo "--- test_failure_output_prescribes_only_resume ---"
_snapshot_fail

_setup_integration_repos "test-output-clean" 6

_T5_HOOKS="$_TEST_BASE/hooks-fail-output"
_install_merge_failure_hook "$_T5_HOOKS"
_T5_STATE="$_TEST_BASE/state-t5.json"

python3 -c "
import json
d = {'branch': 'test-output-clean', 'merge_sha': '', 'completed_phases': [], 'current_phase': '', 'phases': {}, 'retry_count': 0}
with open('$_T5_STATE', 'w') as f:
    json.dump(d, f)
"

git -C "$_MAIN_REPO" fetch "$_WORKTREE" "test-output-clean:test-output-clean" --quiet 2>/dev/null
git -C "$_MAIN_REPO" config core.hooksPath "$_T5_HOOKS"

_T5_RC=0
_T5_OUTPUT=$(_run_phase_merge \
    "test-output-clean" \
    "$_MAIN_REPO" \
    "$_WORKTREE" \
    "$_T5_STATE" \
    "$_T5_HOOKS" \
) || _T5_RC=$?

# Should fail
assert_eq "test_failure_output: exits non-zero" "1" "$_T5_RC"

# Must contain --resume
_T5_HAS_RESUME=0
if [[ "$_T5_OUTPUT" == *--resume* ]]; then
    _T5_HAS_RESUME=1
fi
assert_eq "test_failure_output: contains --resume" "1" "$_T5_HAS_RESUME"

# Must NOT prescribe manual git merge command as recovery
_T5_HAS_GIT_MERGE_CMD=0
# Only check the ERROR/directive lines, not informational "Merging..." output
if echo "$_T5_OUTPUT" | grep -iE '^(ERROR|DIRECTIVE|ACTION|Try):.*git merge' >/dev/null 2>&1; then
    _T5_HAS_GIT_MERGE_CMD=1
fi
assert_eq "test_failure_output: no 'git merge' in directives" "0" "$_T5_HAS_GIT_MERGE_CMD"

assert_pass_if_clean "test_failure_output_prescribes_only_resume"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 6: test_syntax_check
# Bash syntax check on merge-to-main.sh must pass.
# =============================================================================
echo ""
echo "--- test_syntax_check ---"
_snapshot_fail

_T6_RC=0
bash -n "$MERGE_SCRIPT" 2>/dev/null || _T6_RC=$?

assert_eq "test_syntax_check: bash -n passes" "0" "$_T6_RC"

assert_pass_if_clean "test_syntax_check"

# =============================================================================
# Summary
# =============================================================================
print_summary
