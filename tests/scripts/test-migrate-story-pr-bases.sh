#!/usr/bin/env bash
# tests/scripts/test-migrate-story-pr-bases.sh
# RED-phase behavioral tests for plugins/dso/scripts/migrate-story-pr-bases.sh
#
# All tests FAIL until the script is implemented (RED gate confirmed).
#
# The script migrates story/* PRs targeting main to target the session branch instead:
#   1. Lists story/* PRs currently targeting main
#   2. For each such PR, PATCHes its base to the session branch
#   3. Skips PRs already targeting the session branch (idempotent)
#   4. Notes cache invalidation for migrated PRs
#   5. Exits non-zero when session branch resolution fails
#
# Usage: bash tests/scripts/test-migrate-story-pr-bases.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/migrate-story-pr-bases.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-migrate-story-pr-bases.sh ==="

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"

# Stub resolve-session-branch.sh that succeeds and outputs a session branch name
MOCK_SCRIPTS="$TMPDIR_TEST/scripts"
mkdir -p "$MOCK_SCRIPTS"

# ── Test 1: script exists ────────────────────────────────────────────────────
# RED: script does not exist yet — assert_eq will FAIL
test_script_exists() {
    local exists
    if [[ -f "$SCRIPT" ]]; then exists="yes"; else exists="no"; fi
    assert_eq "test_script_exists: migrate-story-pr-bases.sh exists" "yes" "$exists"
}

# ── Test 2: no PRs exits zero ────────────────────────────────────────────────
# When gh pr list returns empty, script exits 0 with a "No story/* PRs" message.
test_no_prs_exits_zero() {
    # Mock gh: pr list returns empty JSON array
    cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)
    echo "[]"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    # Mock resolve-session-branch.sh
    cat > "$MOCK_SCRIPTS/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-20260515-200444"
exit 0
MOCKEOF
    chmod +x "$MOCK_SCRIPTS/resolve-session-branch.sh"

    local exit_code=0
    local output
    output=$(PATH="$MOCK_BIN:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$MOCK_SCRIPTS/resolve-session-branch.sh" \
        bash "$SCRIPT" 2>&1) || exit_code=$?

    assert_eq "test_no_prs_exits_zero: exits 0 when no story/* PRs" "0" "$exit_code"

    local mentions_no_prs
    if echo "$output" | grep -qi "no story"; then
        mentions_no_prs="yes"
    else
        mentions_no_prs="no"
    fi
    assert_eq "test_no_prs_exits_zero: output mentions no story/* PRs targeting main" \
        "yes" "$mentions_no_prs"
}

# ── Test 3: detects story PR targeting main ──────────────────────────────────
# When one story/* PR targets main, script calls PATCH on that PR's base.
test_detects_story_pr_targeting_main() {
    local call_log="$TMPDIR_TEST/calls_test3.log"
    : > "$call_log"

    cat > "$MOCK_BIN/gh" << MOCKEOF
#!/usr/bin/env bash
echo "\$*" >> "$call_log"
case "\$*" in
  *"pr list"*)
    echo '[{"number":42,"headRefName":"story/epic-abc/story-xyz","baseRefName":"main"}]'
    exit 0
    ;;
  *"api"*"pulls/42"*)
    exit 0
    ;;
  *"workflow run"*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    cat > "$MOCK_SCRIPTS/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-20260515-200444"
exit 0
MOCKEOF
    chmod +x "$MOCK_SCRIPTS/resolve-session-branch.sh"

    PATH="$MOCK_BIN:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$MOCK_SCRIPTS/resolve-session-branch.sh" \
        bash "$SCRIPT" 2>&1 || true

    # Verify that a PATCH call was made for PR #42
    local patch_called
    if grep -q "api" "$call_log" && grep -q "pulls/42" "$call_log"; then
        patch_called="yes"
    else
        patch_called="no"
    fi
    assert_eq "test_detects_story_pr_targeting_main: PATCH called for PR targeting main" \
        "yes" "$patch_called"
}

# ── Test 4: patches base to session branch ───────────────────────────────────
# Script calls gh api PATCH .../pulls/{n} with base=<session_branch>.
test_patches_base_to_session_branch() {
    local call_log="$TMPDIR_TEST/calls_test4.log"
    : > "$call_log"

    cat > "$MOCK_BIN/gh" << MOCKEOF
#!/usr/bin/env bash
# Log all args for later inspection
echo "\$*" >> "$call_log"
case "\$*" in
  *"pr list"*)
    echo '[{"number":7,"headRefName":"story/ep/st","baseRefName":"main"}]'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    cat > "$MOCK_SCRIPTS/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-20260515-200444"
exit 0
MOCKEOF
    chmod +x "$MOCK_SCRIPTS/resolve-session-branch.sh"

    PATH="$MOCK_BIN:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$MOCK_SCRIPTS/resolve-session-branch.sh" \
        bash "$SCRIPT" 2>&1 || true

    # The PATCH body must include the session branch name as the new base
    local has_session_branch_base
    if grep -q "worktree-20260515-200444" "$call_log"; then
        has_session_branch_base="yes"
    else
        has_session_branch_base="no"
    fi
    assert_eq "test_patches_base_to_session_branch: PATCH body contains session branch as new base" \
        "yes" "$has_session_branch_base"
}

# test_triggers_workflow_run: test removed; restoration covered by remediation
# epic (per-branch-review.yml was deleted in story 20d7-09d6-b831-4c3a; the
# migrate script no longer triggers a workflow run since ci.yml llm-review
# fires automatically when the PR targets main).

# ── Test 6: idempotent — already migrated PR is skipped ─────────────────────
# PR that already has base=session_branch is skipped (no PATCH, no workflow run).
test_idempotent_already_migrated() {
    local call_log="$TMPDIR_TEST/calls_test6.log"
    : > "$call_log"

    # PR base is already the session branch — not main
    cat > "$MOCK_BIN/gh" << MOCKEOF
#!/usr/bin/env bash
echo "\$*" >> "$call_log"
case "\$*" in
  *"pr list"*)
    echo '[{"number":99,"headRefName":"story/ep/already","baseRefName":"worktree-20260515-200444"}]'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    cat > "$MOCK_SCRIPTS/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-20260515-200444"
exit 0
MOCKEOF
    chmod +x "$MOCK_SCRIPTS/resolve-session-branch.sh"

    local exit_code=0
    PATH="$MOCK_BIN:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$MOCK_SCRIPTS/resolve-session-branch.sh" \
        bash "$SCRIPT" 2>&1 || exit_code=$?

    assert_eq "test_idempotent_already_migrated: exits 0 for already-migrated PR" \
        "0" "$exit_code"

    # PATCH must NOT be called for the already-migrated PR
    local patch_called
    if grep -q "api" "$call_log" && grep -q "pulls/99" "$call_log"; then
        patch_called="yes"
    else
        patch_called="no"
    fi
    assert_eq "test_idempotent_already_migrated: PATCH NOT called for already-migrated PR" \
        "no" "$patch_called"

    # Workflow run must NOT be triggered for the already-migrated PR
    local workflow_triggered
    if grep -q "workflow run" "$call_log"; then
        workflow_triggered="yes"
    else
        workflow_triggered="no"
    fi
    assert_eq "test_idempotent_already_migrated: workflow run NOT triggered for already-migrated PR" \
        "no" "$workflow_triggered"
}

# ── Test 7: clears review status cache ──────────────────────────────────────
# Script outputs a message about cache or DefenseStore invalidation for migrated PRs.
test_clears_review_status_cache() {
    cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)
    echo '[{"number":12,"headRefName":"story/ep/cache-test","baseRefName":"main"}]'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    cat > "$MOCK_SCRIPTS/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-20260515-200444"
exit 0
MOCKEOF
    chmod +x "$MOCK_SCRIPTS/resolve-session-branch.sh"

    local output
    output=$(PATH="$MOCK_BIN:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$MOCK_SCRIPTS/resolve-session-branch.sh" \
        bash "$SCRIPT" 2>&1) || true

    # Output must mention cache invalidation (review-status, cache, DefenseStore, or similar)
    local mentions_cache
    if echo "$output" | grep -qiE "cache|defense.?store|review.?status"; then
        mentions_cache="yes"
    else
        mentions_cache="no"
    fi
    assert_eq "test_clears_review_status_cache: output mentions cache/DefenseStore invalidation" \
        "yes" "$mentions_cache"
}

# ── Test 8: session branch resolution failure exits non-zero ─────────────────
# When resolve-session-branch.sh fails, script exits non-zero with error message.
test_session_branch_resolution_failure_exits_nonzero() {
    cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    # Stub resolve-session-branch.sh to fail
    cat > "$MOCK_SCRIPTS/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "ERROR: could not resolve SPRINT_SESSION_ID" >&2
exit 1
MOCKEOF
    chmod +x "$MOCK_SCRIPTS/resolve-session-branch.sh"

    local exit_code=0
    local output
    output=$(PATH="$MOCK_BIN:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$MOCK_SCRIPTS/resolve-session-branch.sh" \
        bash "$SCRIPT" 2>&1) || exit_code=$?

    assert_ne "test_session_branch_resolution_failure_exits_nonzero: exits non-zero when resolution fails" \
        "0" "$exit_code"

    local has_error_message
    if echo "$output" | grep -qi "error\|fail\|could not\|unable"; then
        has_error_message="yes"
    else
        has_error_message="no"
    fi
    assert_eq "test_session_branch_resolution_failure_exits_nonzero: error message present" \
        "yes" "$has_error_message"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_script_exists
test_no_prs_exits_zero
test_detects_story_pr_targeting_main
test_patches_base_to_session_branch
test_idempotent_already_migrated
test_clears_review_status_cache
test_session_branch_resolution_failure_exits_nonzero

print_summary
