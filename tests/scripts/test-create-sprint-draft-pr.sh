#!/usr/bin/env bash
# tests/scripts/test-create-sprint-draft-pr.sh
# Behavioral tests for plugins/dso/scripts/create-sprint-draft-pr.sh
#
# Tests:
#   1. test_create_sprint_draft_pr_new_pr         — no existing PR → creates draft PR → exit 0
#   2. test_create_sprint_draft_pr_existing_draft  — draft PR already exists → idempotent, exits 0 without new PR
#   3. test_create_sprint_draft_pr_existing_nondraft — non-draft open PR → exits 0, no new PR created
#   4. test_create_sprint_draft_pr_gh_failure      — gh pr create fails → exits non-zero with error message
#   5. test_create_sprint_draft_pr_missing_branch  — SESSION_BRANCH absent → exits 1
#   6. test_create_sprint_draft_pr_missing_ticket  — PRIMARY_TICKET_ID absent → exits 1
#
# Strategy:
#   PATH-prepend a gh stub controlled by a mode-file. The stub simulates
#   gh pr list (returning jq-filtered output, since gh --jq runs jq internally)
#   and gh pr create.
#
# Usage: bash tests/scripts/test-create-sprint-draft-pr.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_UNDER_TEST="$REPO_ROOT/plugins/dso/scripts/create-sprint-draft-pr.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-create-sprint-draft-pr.sh ==="

# ── Prerequisite check ───────────────────────────────────────────────────────
if [[ ! -f "$SCRIPT_UNDER_TEST" ]]; then
    echo "NOTE: create-sprint-draft-pr.sh not found — running in RED phase" >&2
    print_summary
    exit 0
fi

# ── Sandbox setup ────────────────────────────────────────────────────────────
_TMP_BIN="$(mktemp -d "${TMPDIR:-/tmp}/sprint-draft-pr-bin.XXXXXX")"
_GH_CALL_LOG="$(mktemp "${TMPDIR:-/tmp}/sprint-draft-pr-calls.XXXXXX")"
_GH_MODE_FILE="$(mktemp "${TMPDIR:-/tmp}/sprint-draft-pr-mode.XXXXXX")"

cleanup() {
    rm -rf "$_TMP_BIN" "$_GH_CALL_LOG" "$_GH_MODE_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# ── Build gh stub ─────────────────────────────────────────────────────────────
# The stub simulates gh pr list with --jq filtering (gh runs jq internally).
# Mode-file controls behavior:
#   no_pr        — pr list (both jq filters) returns empty; pr create returns URL
#   draft_pr     — draft jq filter returns existing URL; create not called
#   nondraft_pr  — draft jq filter empty; any-pr jq filter returns URL
#   create_fail  — pr list returns empty; pr create exits 1
#
# NOTE: heredoc uses quoted delimiter ('GHEOF') to prevent variable expansion
# during stub creation; $_GH_CALL_LOG and $_GH_MODE_FILE are injected via sed.
build_gh_stub() {
    cat > "$_TMP_BIN/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "GH_CALL_LOG_PLACEHOLDER"
mode="$(cat "GH_MODE_FILE_PLACEHOLDER" 2>/dev/null || echo no_pr)"

case "$1" in
  pr)
    case "$2" in
      list)
        case "$mode" in
          draft_pr)
            # Script calls with --jq 'map(select(.isDraft == true))[0].url // empty'
            # In this mode there is a draft PR, so the filtered result is a URL.
            # Both jq queries would return the draft URL, but script exits after
            # finding the draft, so only first call matters.
            echo "https://github.com/example/repo/pull/7"
            exit 0
            ;;
          nondraft_pr)
            # Script makes two gh pr list calls:
            #   1st: --jq 'map(select(.isDraft == true))[0].url // empty'  → empty (no drafts)
            #   2nd: --jq '.[0].url // empty'                               → non-draft URL
            # Detect which call by inspecting the --jq argument value (last arg).
            # When isDraft is in the jq expression, this is the draft-filter call.
            last_arg="${*: -1}"
            if [[ "$last_arg" == *"isDraft"* ]]; then
                # Draft-filter call — return empty (no draft PRs)
                exit 0
            else
                # Any-PR filter call — return the non-draft URL
                echo "https://github.com/example/repo/pull/5"
                exit 0
            fi
            ;;
          no_pr|create_fail)
            # Both filters return empty
            exit 0
            ;;
        esac
        ;;
      create)
        case "$mode" in
          create_fail)
            echo "ERROR: gh pr create failed: GraphQL error" >&2
            exit 1
            ;;
          *)
            echo "https://github.com/example/repo/pull/99"
            exit 0
            ;;
        esac
        ;;
    esac
    ;;
esac
exit 0
GHEOF
    # Inject the actual temp file paths
    sed -i.bak \
        -e "s|GH_CALL_LOG_PLACEHOLDER|${_GH_CALL_LOG}|g" \
        -e "s|GH_MODE_FILE_PLACEHOLDER|${_GH_MODE_FILE}|g" \
        "$_TMP_BIN/gh"
    rm -f "$_TMP_BIN/gh.bak"
    chmod +x "$_TMP_BIN/gh"
}

build_gh_stub

# ── Helper: set mode and reset call log ──────────────────────────────────────
set_mode() { echo "$1" > "$_GH_MODE_FILE"; : > "$_GH_CALL_LOG"; }
gh_was_called_with() { grep -qF "$1" "$_GH_CALL_LOG" 2>/dev/null; }

# ── Shared temp repo for tests that don't care about git state ───────────────
# The script-under-test now runs `git rev-list --count main..HEAD` to decide
# whether to write a sentinel commit. If tests ran in the actual worktree the
# sentinel logic would pollute it. Use a temp repo with 1 commit ahead of main
# so the sentinel block stays inactive for the gh-interaction tests.
_SHARED_REPO="$(mktemp -d "${TMPDIR:-/tmp}/sprint-draft-pr-shared.XXXXXX")"
(
    cd "$_SHARED_REPO" || exit
    git init --quiet --initial-branch=main
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false
    echo "initial" > README.md
    git add README.md
    git -c commit.gpgsign=false commit --quiet -m "initial commit"
    git checkout --quiet -b shared-session-branch
    echo "work" > work.txt
    git add work.txt
    git -c commit.gpgsign=false commit --quiet -m "real change on shared session branch"
)
cleanup_shared() { rm -rf "$_SHARED_REPO" 2>/dev/null || true; }
trap 'cleanup; cleanup_shared' EXIT

# ── Test 1: No existing PR → creates draft PR → exit 0 ───────────────────────
echo ""
echo "--- Test 1: no existing PR → creates draft PR ---"
set_mode "no_pr"
t1_output="$(
    cd "$_SHARED_REPO" && \
    SESSION_BRANCH="sprint-abc123" PRIMARY_TICKET_ID="epic-001" EPIC_TITLE="My Epic" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" 2>&1
)"
t1_exit=$?
assert_eq "test_create_sprint_draft_pr_new_pr: exit code" "0" "$t1_exit"
assert_contains "test_create_sprint_draft_pr_new_pr: output contains PR URL" \
    "https://github.com/example/repo/pull/99" "$t1_output"
if gh_was_called_with "pr create"; then
    (( PASS++ ))
else
    (( FAIL++ ))
    echo "FAIL: test_create_sprint_draft_pr_new_pr: gh pr create was not called" >&2
fi

# ── Test 2: Draft PR already exists → idempotent, exits 0 ────────────────────
echo ""
echo "--- Test 2: draft PR exists → idempotent (no new PR created) ---"
set_mode "draft_pr"
t2_output="$(
    cd "$_SHARED_REPO" && \
    SESSION_BRANCH="sprint-abc123" PRIMARY_TICKET_ID="epic-001" EPIC_TITLE="My Epic" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" 2>&1
)"
t2_exit=$?
assert_eq "test_create_sprint_draft_pr_existing_draft: exit code" "0" "$t2_exit"
assert_contains "test_create_sprint_draft_pr_existing_draft: prints existing draft URL" \
    "https://github.com/example/repo/pull/7" "$t2_output"
if gh_was_called_with "pr create"; then
    (( FAIL++ ))
    echo "FAIL: test_create_sprint_draft_pr_existing_draft: gh pr create should NOT have been called" >&2
else
    (( PASS++ ))
fi

# ── Test 3: Non-draft open PR exists → exits 0, no new PR ────────────────────
echo ""
echo "--- Test 3: non-draft open PR exists → exits 0, no new PR ---"
set_mode "nondraft_pr"
t3_output="$(
    cd "$_SHARED_REPO" && \
    SESSION_BRANCH="sprint-abc123" PRIMARY_TICKET_ID="epic-001" EPIC_TITLE="My Epic" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" 2>&1
)"
t3_exit=$?
assert_eq "test_create_sprint_draft_pr_existing_nondraft: exit code" "0" "$t3_exit"
if gh_was_called_with "pr create"; then
    (( FAIL++ ))
    echo "FAIL: test_create_sprint_draft_pr_existing_nondraft: gh pr create should NOT have been called" >&2
else
    (( PASS++ ))
fi

# ── Test 4: gh pr create fails → exits non-zero with error message ────────────
echo ""
echo "--- Test 4: gh pr create fails → exits non-zero ---"
set_mode "create_fail"
t4_output="$(
    cd "$_SHARED_REPO" && \
    SESSION_BRANCH="sprint-abc123" PRIMARY_TICKET_ID="epic-001" EPIC_TITLE="My Epic" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" 2>&1
)"
t4_exit=$?
assert_ne "test_create_sprint_draft_pr_gh_failure: exit code is non-zero" "0" "$t4_exit"
assert_contains "test_create_sprint_draft_pr_gh_failure: error message in output" \
    "ERROR" "$t4_output"

# ── Test 5: SESSION_BRANCH missing → exits 1 ────────────────────────────────
echo ""
echo "--- Test 5: SESSION_BRANCH missing → exits 1 ---"
set_mode "no_pr"
t5_output="$(
    cd "$_SHARED_REPO" && \
    SESSION_BRANCH="" PRIMARY_TICKET_ID="epic-001" EPIC_TITLE="My Epic" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" 2>&1
)"
t5_exit=$?
assert_eq "test_create_sprint_draft_pr_missing_branch: exit code" "1" "$t5_exit"
assert_contains "test_create_sprint_draft_pr_missing_branch: error mentions SESSION_BRANCH" \
    "SESSION_BRANCH" "$t5_output"

# ── Test 6: PRIMARY_TICKET_ID missing → exits 1 ─────────────────────────────
echo ""
echo "--- Test 6: PRIMARY_TICKET_ID missing → exits 1 ---"
set_mode "no_pr"
t6_output="$(
    cd "$_SHARED_REPO" && \
    SESSION_BRANCH="sprint-abc123" PRIMARY_TICKET_ID="" EPIC_TITLE="My Epic" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" 2>&1
)"
t6_exit=$?
assert_eq "test_create_sprint_draft_pr_missing_ticket: exit code" "1" "$t6_exit"
assert_contains "test_create_sprint_draft_pr_missing_ticket: error mentions PRIMARY_TICKET_ID" \
    "PRIMARY_TICKET_ID" "$t6_output"

echo ""
echo "--- Test 7: DRAFT_PR_TITLE_PREFIX=Debug: → title uses custom prefix ---"
set_mode "no_pr"
t7_output="$(
    cd "$_SHARED_REPO" && \
    SESSION_BRANCH="sprint-abc123" PRIMARY_TICKET_ID="epic-001" EPIC_TITLE="My Epic" \
    DRAFT_PR_TITLE_PREFIX="Debug:" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" 2>&1
)"
t7_exit=$?
assert_eq "test_create_sprint_draft_pr_custom_title_prefix: exit code" "0" "$t7_exit"
if gh_was_called_with "Debug: My Epic"; then
    (( PASS++ ))
else
    (( FAIL++ ))
    echo "FAIL: test_create_sprint_draft_pr_custom_title_prefix: gh pr create title did not contain 'Debug: My Epic'" >&2
fi

echo ""
echo "--- Test 8: no DRAFT_PR_TITLE_PREFIX → default title contains Sprint: ---"
set_mode "no_pr"
t8_output="$(
    cd "$_SHARED_REPO" && \
    SESSION_BRANCH="sprint-abc123" PRIMARY_TICKET_ID="epic-001" EPIC_TITLE="My Epic" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" 2>&1
)"
t8_exit=$?
assert_eq "test_create_sprint_draft_pr_default_title_prefix: exit code" "0" "$t8_exit"
if gh_was_called_with "Sprint:"; then
    (( PASS++ ))
else
    (( FAIL++ ))
    echo "FAIL: test_create_sprint_draft_pr_default_title_prefix: gh pr create title did not contain 'Sprint:'" >&2
fi

echo ""
echo "--- Test 9: DRAFT_PR_BODY_TEMPLATE with placeholder → interpolated body ---"
set_mode "no_pr"
t9_output="$(
    cd "$_SHARED_REPO" && \
    SESSION_BRANCH="sprint-abc123" PRIMARY_TICKET_ID="epic-001" EPIC_TITLE="My Epic" \
    DRAFT_PR_BODY_TEMPLATE="Debug session for {{PRIMARY_TICKET_ID}}" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" 2>&1
)"
t9_exit=$?
assert_eq "test_create_sprint_draft_pr_custom_body_template: exit code" "0" "$t9_exit"
if gh_was_called_with "Debug session for epic-001"; then
    (( PASS++ ))
else
    (( FAIL++ ))
    echo "FAIL: test_create_sprint_draft_pr_custom_body_template: gh pr create body did not contain 'Debug session for epic-001'" >&2
fi

echo ""
echo "--- Test 10: no DRAFT_PR_BODY_TEMPLATE → default body preserved ---"
set_mode "no_pr"
t10_output="$(
    cd "$_SHARED_REPO" && \
    SESSION_BRANCH="sprint-abc123" PRIMARY_TICKET_ID="epic-001" EPIC_TITLE="My Epic" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" 2>&1
)"
t10_exit=$?
assert_eq "test_create_sprint_draft_pr_default_body_regression: exit code" "0" "$t10_exit"
if gh_was_called_with "Long-lived sprint draft PR. Epic: epic-001."; then
    (( PASS++ ))
else
    (( FAIL++ ))
    echo "FAIL: test_create_sprint_draft_pr_default_body_regression: default body not preserved" >&2
fi

echo ""
echo "--- Test 11: DRAFT_PR_BODY_TEMPLATE without placeholder → used as-is ---"
set_mode "no_pr"
t11_output="$(
    cd "$_SHARED_REPO" && \
    SESSION_BRANCH="sprint-abc123" PRIMARY_TICKET_ID="epic-001" EPIC_TITLE="My Epic" \
    DRAFT_PR_BODY_TEMPLATE="Custom body no placeholder" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" 2>&1
)"
t11_exit=$?
assert_eq "test_create_sprint_draft_pr_body_no_placeholder: exit code" "0" "$t11_exit"
if gh_was_called_with "Custom body no placeholder"; then
    (( PASS++ ))
else
    (( FAIL++ ))
    echo "FAIL: test_create_sprint_draft_pr_body_no_placeholder: custom body not used as-is" >&2
fi

echo ""
# ── Sentinel-commit tests (zero-divergence bootstrap) ────────────────────────
# When the session branch has 0 commits ahead of main, `gh pr create` fails with
# "No commits between main and <branch>". The script must create a `--allow-empty`
# sentinel commit with a `DSO-Sentinel:` trailer + `[skip ci]` before opening the PR.
# Tests use a real temp git repo (not just stubs) so we can observe the commit
# the script writes to the branch.

setup_temp_repo() {
    # Creates a fresh git repo with `main` branch (one commit) and `session-branch`
    # checked out. Returns the repo path on stdout. The caller is responsible for
    # `cd`ing into it.
    local repo_dir
    repo_dir=$(mktemp -d "${TMPDIR:-/tmp}/sprint-draft-pr-repo.XXXXXX")
    (
        cd "$repo_dir" || exit
        git init --quiet --initial-branch=main
        git config user.email "test@example.com"
        git config user.name "Test"
        git config commit.gpgsign false
        echo "initial" > README.md
        git add README.md
        git -c commit.gpgsign=false commit --quiet -m "initial commit"
        git checkout --quiet -b session-branch
    )
    echo "$repo_dir"
}

echo "--- Test 12: zero divergence from main → script creates a DSO-Sentinel: commit ---"
set_mode "no_pr"
T12_REPO=$(setup_temp_repo)
(
    cd "$T12_REPO" || exit
    SESSION_BRANCH="session-branch" PRIMARY_TICKET_ID="epic-042" EPIC_TITLE="My Epic" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" > /tmp/t12.out 2>&1
)
t12_exit=$?
# Inspect the resulting commit on session-branch
t12_div=$(git -C "$T12_REPO" rev-list --count main..session-branch 2>/dev/null || echo "?")
t12_body=$(git -C "$T12_REPO" log -1 --format=%B session-branch 2>/dev/null || echo "")
assert_eq "test_create_sprint_draft_pr_sentinel_exit_zero" "0" "$t12_exit"
assert_eq "test_create_sprint_draft_pr_sentinel_one_commit_ahead" "1" "$t12_div"
assert_contains "test_create_sprint_draft_pr_sentinel_trailer_present" \
    "DSO-Sentinel:" "$t12_body"
assert_contains "test_create_sprint_draft_pr_sentinel_skip_ci_present" \
    "[skip ci]" "$t12_body"
if gh_was_called_with "pr create"; then
    (( PASS++ ))
else
    (( FAIL++ ))
    echo "FAIL: test_create_sprint_draft_pr_sentinel_calls_gh_create: gh pr create not called after sentinel" >&2
fi
rm -rf "$T12_REPO" /tmp/t12.out 2>/dev/null || true

echo ""
echo "--- Test 13: nonzero divergence → no sentinel created (preserves existing behavior) ---"
set_mode "no_pr"
T13_REPO=$(setup_temp_repo)
(
    cd "$T13_REPO" || exit
    echo "real work" > work.txt
    git add work.txt
    git -c commit.gpgsign=false commit --quiet -m "real change on session-branch"
    SESSION_BRANCH="session-branch" PRIMARY_TICKET_ID="epic-042" EPIC_TITLE="My Epic" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" > /tmp/t13.out 2>&1
)
t13_exit=$?
t13_div=$(git -C "$T13_REPO" rev-list --count main..session-branch 2>/dev/null || echo "?")
# Should be exactly 1 (the pre-existing real commit) — NOT 2, no sentinel added
t13_body=$(git -C "$T13_REPO" log -1 --format=%B session-branch 2>/dev/null || echo "")
assert_eq "test_create_sprint_draft_pr_sentinel_skipped_exit_zero" "0" "$t13_exit"
assert_eq "test_create_sprint_draft_pr_sentinel_skipped_no_extra_commit" "1" "$t13_div"
if echo "$t13_body" | grep -q "DSO-Sentinel:"; then
    (( FAIL++ ))
    echo "FAIL: test_create_sprint_draft_pr_sentinel_skipped_no_trailer: sentinel was added despite nonzero divergence" >&2
else
    (( PASS++ ))
fi
rm -rf "$T13_REPO" /tmp/t13.out 2>/dev/null || true

echo ""
echo "--- Test 14: sentinel already on HEAD → idempotent, no second sentinel ---"
set_mode "no_pr"
T14_REPO=$(setup_temp_repo)
(
    cd "$T14_REPO" || exit
    # Pre-seed a sentinel commit so the script sees divergence==1 but it's a sentinel
    git -c commit.gpgsign=false commit --quiet --allow-empty \
        -m "chore(epic-042): open umbrella PR [skip ci]" \
        -m "DSO-Sentinel: epic-bootstrap"
    SESSION_BRANCH="session-branch" PRIMARY_TICKET_ID="epic-042" EPIC_TITLE="My Epic" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" > /tmp/t14.out 2>&1
)
t14_exit=$?
t14_div=$(git -C "$T14_REPO" rev-list --count main..session-branch 2>/dev/null || echo "?")
# Should still be 1 — pre-existing sentinel, no new sentinel added
t14_sentinel_count=$(git -C "$T14_REPO" log main..session-branch --format=%B 2>/dev/null \
    | grep -c "^DSO-Sentinel:" || true)
assert_eq "test_create_sprint_draft_pr_sentinel_idempotent_exit_zero" "0" "$t14_exit"
assert_eq "test_create_sprint_draft_pr_sentinel_idempotent_one_commit" "1" "$t14_div"
assert_eq "test_create_sprint_draft_pr_sentinel_idempotent_one_sentinel" "1" "$t14_sentinel_count"
rm -rf "$T14_REPO" /tmp/t14.out 2>/dev/null || true

echo ""
print_summary
