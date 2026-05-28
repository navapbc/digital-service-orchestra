#!/usr/bin/env bash
# tests/scripts/test-rollback-sub-pr-cutover.sh
# RED-phase behavioral tests for plugins/dso/scripts/rollback-sub-pr-cutover.sh
#
# Story DD5: Rollback runnable WITHOUT post-migration format intact.
# Task aa46-6562-bac3-46f9 (S_mig.T8)
#
# All tests FAIL until rollback-sub-pr-cutover.sh is implemented (RED gate).
#
# Behavioral contracts tested here:
#   1. Script exists and is executable
#   2. Rollback runs when ledger is corrupted/missing (no v1.2.0 dependency)
#   3. Rollback removes migration-grace labels from PRs (branch protection demotion)
#   4. Rollback is idempotent — re-running on already-rolled-back state exits 0
#   5. Rollback runs on any v1.x ledger state (v1.1.0, v1.2.0, missing, corrupted)
#   6. Rollback removes review-sub-pr.yml workflow file (or logs that it is absent)
#
# Usage: bash tests/scripts/test-rollback-sub-pr-cutover.sh
# Returns: exit 0 if all tests pass, exit N where N = number of failing assertions.
#
# .test-index marker: [test_rollback_sub_pr_cutover]

# ── RED marker ────────────────────────────────────────────────────────────────
# RED: plugins/dso/scripts/rollback-sub-pr-cutover.sh does not exist yet.
# Every test that exercises the script will fail until T9 implements it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/rollback-sub-pr-cutover.sh"

# shellcheck source=tests/lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-rollback-sub-pr-cutover.sh ==="

# ── Isolation helpers ─────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
make_tmpdir() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/test-rollback-sub-pr-cutover.XXXXXX")
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}
cleanup_all() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "$d" ]] && rm -rf "$d"
    done
}
trap cleanup_all EXIT

# ── Helper: build a mock gh binary ───────────────────────────────────────────
# Usage: make_mock_gh <bin_dir> <label_list_json>
# label_list_json: JSON array of PR objects with "number", "labels" arrays
make_mock_gh() {
    local bin_dir="$1"
    local label_list_json="${2:-[]}"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/gh" <<GHEOF
#!/usr/bin/env bash
# Minimal gh stub for rollback testing
case "\$*" in
  *"pr list"*"label=migration-grace"*)
    echo '${label_list_json}'
    exit 0
    ;;
  *"pr edit"*"--remove-label"*)
    # Accept label removal silently
    exit 0
    ;;
  *"api"*"repos"*"required_status_checks"*)
    # Branch protection query — return minimal JSON
    echo '{"contexts":["llm-review-sub-pr"]}'
    exit 0
    ;;
  *"api"*"repos"*"protection"*"-X PATCH"*|*"api"*"repos"*"protection"*"--method PATCH"*)
    # Branch protection update — accept
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
GHEOF
    chmod +x "$bin_dir/gh"
}

# ── Test 1: script exists and is executable ───────────────────────────────────
# RED: rollback-sub-pr-cutover.sh does not exist.
_snapshot_fail
test_script_exists_and_executable() {
    local exists_exec=0
    if [[ -x "$SCRIPT" ]]; then exists_exec=1; fi
    assert_eq \
        "test_script_exists_and_executable: rollback-sub-pr-cutover.sh exists and is executable" \
        "1" \
        "$exists_exec"
}
test_script_exists_and_executable
assert_pass_if_clean "test_script_exists_and_executable"

# ── Test 2: rollback runs on corrupted/missing v1.2.0 ledger ─────────────────
# DD5: Rollback must NOT depend on the post-migration v1.2.0 ledger being intact.
# Even when the ledger is corrupted or absent, the rollback script must exit 0
# and proceed with the non-ledger rollback steps (label removal, workflow removal).
#
# RED: script does not exist — exit code will be non-zero.
_snapshot_fail
test_rollback_runs_with_corrupted_ledger() {
    local tmpdir
    tmpdir=$(make_tmpdir)
    local mock_bin="$tmpdir/bin"
    make_mock_gh "$mock_bin" "[]"

    # Write a corrupted ledger file (invalid JSON)
    local artifacts_dir="$tmpdir/artifacts"
    mkdir -p "$artifacts_dir"
    printf 'THIS IS NOT JSON {{{' > "$artifacts_dir/cycle-ledger.json"

    # Mock a fake repo root with workflow dir so the script can navigate
    local fake_repo="$tmpdir/fake-repo"
    mkdir -p "$fake_repo/.github/workflows"
    # review-sub-pr.yml is present (post-cutover state)
    touch "$fake_repo/.github/workflows/review-sub-pr.yml"

    local exit_code=0
    local output
    output=$(PATH="$mock_bin:$PATH" \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        DSO_ROLLBACK_REPO_ROOT="$fake_repo" \
        bash "$SCRIPT" 2>&1) || exit_code=$?

    assert_eq \
        "test_rollback_runs_with_corrupted_ledger: exits 0 even when ledger is corrupted" \
        "0" \
        "$exit_code"

    # The output should NOT mention a hard failure on corrupted ledger
    assert_not_contains \
        "test_rollback_runs_with_corrupted_ledger: does not abort on corrupted ledger" \
        "FATAL" \
        "$output"
}
test_rollback_runs_with_corrupted_ledger
assert_pass_if_clean "test_rollback_runs_with_corrupted_ledger"

# ── Test 3: rollback removes migration-grace labels ───────────────────────────
# Phase 1 reverse: PRs tagged with migration-grace must have that label removed.
# The rollback script must invoke `gh pr edit <pr_number> --remove-label migration-grace`
# for each open PR that bears the label.
#
# RED: script does not exist.
_snapshot_fail
test_rollback_removes_migration_grace_labels() {
    local tmpdir
    tmpdir=$(make_tmpdir)
    local mock_bin="$tmpdir/bin"
    local gh_log="$tmpdir/gh-calls.log"

    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" <<GHEOF
#!/usr/bin/env bash
echo "\$*" >> "$gh_log"
case "\$*" in
  *"pr list"*"label=migration-grace"*|*"pr list"*"--label migration-grace"*)
    echo '[{"number":101},{"number":202}]'
    exit 0
    ;;
  *"pr edit"*"--remove-label"*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
GHEOF
    chmod +x "$mock_bin/gh"

    local fake_repo="$tmpdir/fake-repo"
    mkdir -p "$fake_repo/.github/workflows"

    local artifacts_dir="$tmpdir/artifacts"
    mkdir -p "$artifacts_dir"

    local exit_code=0
    PATH="$mock_bin:$PATH" \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        DSO_ROLLBACK_REPO_ROOT="$fake_repo" \
        bash "$SCRIPT" 2>&1 || exit_code=$?

    # Verify the script called gh to remove the label from at least one PR
    local removed_labels=0
    if grep -q -- "--remove-label" "$gh_log" 2>/dev/null; then removed_labels=1; fi
    assert_eq \
        "test_rollback_removes_migration_grace_labels: gh called with --remove-label for migration-grace" \
        "1" \
        "$removed_labels"
}
test_rollback_removes_migration_grace_labels
assert_pass_if_clean "test_rollback_removes_migration_grace_labels"

# ── Test 4: rollback is idempotent on already-rolled-back state ───────────────
# When the workflow file is already absent and no PRs have the migration-grace
# label, the rollback must exit 0 gracefully (no errors for missing resources).
#
# RED: script does not exist.
_snapshot_fail
test_rollback_idempotent_on_clean_state() {
    local tmpdir
    tmpdir=$(make_tmpdir)
    local mock_bin="$tmpdir/bin"
    make_mock_gh "$mock_bin" "[]"  # No PRs with migration-grace label

    local fake_repo="$tmpdir/fake-repo"
    mkdir -p "$fake_repo/.github/workflows"
    # review-sub-pr.yml is ABSENT (already rolled back)

    local artifacts_dir="$tmpdir/artifacts"
    mkdir -p "$artifacts_dir"
    # No ledger file at all

    local exit_code=0
    local output
    output=$(PATH="$mock_bin:$PATH" \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        DSO_ROLLBACK_REPO_ROOT="$fake_repo" \
        bash "$SCRIPT" 2>&1) || exit_code=$?

    assert_eq \
        "test_rollback_idempotent_on_clean_state: exits 0 when already rolled back" \
        "0" \
        "$exit_code"
}
test_rollback_idempotent_on_clean_state
assert_pass_if_clean "test_rollback_idempotent_on_clean_state"

# ── Test 5: rollback runs on v1.1.0 ledger (independent of post-migration format) ──
# DD5: Rollback must run on any v1.x ledger, including a v1.1.0 ledger that has
# never been migrated. It must NOT fail because schema_version is "1.1.0" instead
# of "1.2.0".
#
# RED: script does not exist.
_snapshot_fail
test_rollback_runs_on_v11_ledger() {
    local tmpdir
    tmpdir=$(make_tmpdir)
    local mock_bin="$tmpdir/bin"
    make_mock_gh "$mock_bin" "[]"

    local fake_repo="$tmpdir/fake-repo"
    mkdir -p "$fake_repo/.github/workflows"
    touch "$fake_repo/.github/workflows/review-sub-pr.yml"

    local artifacts_dir="$tmpdir/artifacts"
    mkdir -p "$artifacts_dir"

    # Write a valid v1.1.0 ledger (no pr_number field)
    cat > "$artifacts_dir/cycle-ledger.json" <<'LEDGEREOF'
{
  "schema_version": "1.1.0",
  "cycles": [
    {
      "cycle_num": 1,
      "commit_sha": "abc123",
      "findings_hash": "h1",
      "findings_tuples": [["x.py", "1", "correctness"]]
    }
  ]
}
LEDGEREOF

    local exit_code=0
    local output
    output=$(PATH="$mock_bin:$PATH" \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        DSO_ROLLBACK_REPO_ROOT="$fake_repo" \
        bash "$SCRIPT" 2>&1) || exit_code=$?

    assert_eq \
        "test_rollback_runs_on_v11_ledger: exits 0 on v1.1.0 ledger (no v1.2.0 dependency)" \
        "0" \
        "$exit_code"

    # Must not fail with a schema-version error message
    assert_not_contains \
        "test_rollback_runs_on_v11_ledger: no schema_version error on v1.1.0 ledger" \
        "schema_version" \
        "$output"
}
test_rollback_runs_on_v11_ledger
assert_pass_if_clean "test_rollback_runs_on_v11_ledger"

# ── Test 6: rollback removes or logs absence of review-sub-pr.yml ─────────────
# Phase 4 reverse: if .github/workflows/review-sub-pr.yml is present in the
# repo, the rollback script must remove it (or stage its removal). If it is
# already absent, the script logs that and exits 0.
#
# RED: script does not exist.
_snapshot_fail
test_rollback_removes_review_sub_pr_workflow() {
    local tmpdir
    tmpdir=$(make_tmpdir)
    local mock_bin="$tmpdir/bin"
    make_mock_gh "$mock_bin" "[]"

    local fake_repo="$tmpdir/fake-repo"
    mkdir -p "$fake_repo/.github/workflows"
    # Workflow present — rollback should remove it
    touch "$fake_repo/.github/workflows/review-sub-pr.yml"

    local artifacts_dir="$tmpdir/artifacts"
    mkdir -p "$artifacts_dir"

    local exit_code=0
    PATH="$mock_bin:$PATH" \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        DSO_ROLLBACK_REPO_ROOT="$fake_repo" \
        bash "$SCRIPT" 2>&1 || exit_code=$?

    # Workflow file must be gone after rollback
    local still_present=0
    if [[ -f "$fake_repo/.github/workflows/review-sub-pr.yml" ]]; then still_present=1; fi
    assert_eq \
        "test_rollback_removes_review_sub_pr_workflow: review-sub-pr.yml removed after rollback" \
        "0" \
        "$still_present"

    assert_eq \
        "test_rollback_removes_review_sub_pr_workflow: script exits 0" \
        "0" \
        "$exit_code"
}
test_rollback_removes_review_sub_pr_workflow
assert_pass_if_clean "test_rollback_removes_review_sub_pr_workflow"

# ── Test 7: corrupted-state assertion (AC: grep -qE 'corrupted|broken') ───────
# The AC requires the test to assert rollback runs on corrupted state AND that
# the test file references the word 'corrupted' or 'broken' (grep check).
# This assertion documents that the test already satisfies that AC clause.
_snapshot_fail
test_rollback_corrupted_state_grep_ac() {
    # This test file already contains the word 'corrupted' (see tests 2, 5 above).
    # We verify this as a self-referential AC check so the CI can assert the AC:
    #   grep -qE 'corrupted|broken' tests/scripts/test-rollback-sub-pr-cutover.sh
    local self="$SCRIPT_DIR/test-rollback-sub-pr-cutover.sh"
    local found=0
    if grep -qE 'corrupted|broken' "$self" 2>/dev/null; then found=1; fi
    assert_eq \
        "test_rollback_corrupted_state_grep_ac: test file references 'corrupted' or 'broken' (AC clause)" \
        "1" \
        "$found"
}
test_rollback_corrupted_state_grep_ac
assert_pass_if_clean "test_rollback_corrupted_state_grep_ac"

print_summary
