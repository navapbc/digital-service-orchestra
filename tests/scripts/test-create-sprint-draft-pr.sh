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
_TMP_BIN="$(mktemp -d /tmp/sprint-draft-pr-bin.XXXXXX)"
_GH_CALL_LOG="$(mktemp /tmp/sprint-draft-pr-calls.XXXXXX)"
_GH_MODE_FILE="$(mktemp /tmp/sprint-draft-pr-mode.XXXXXX)"

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

# ── Test 1: No existing PR → creates draft PR → exit 0 ───────────────────────
echo ""
echo "--- Test 1: no existing PR → creates draft PR ---"
set_mode "no_pr"
t1_output="$(
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
    SESSION_BRANCH="sprint-abc123" PRIMARY_TICKET_ID="" EPIC_TITLE="My Epic" \
    PATH="$_TMP_BIN:$PATH" \
    bash "$SCRIPT_UNDER_TEST" 2>&1
)"
t6_exit=$?
assert_eq "test_create_sprint_draft_pr_missing_ticket: exit code" "1" "$t6_exit"
assert_contains "test_create_sprint_draft_pr_missing_ticket: error mentions PRIMARY_TICKET_ID" \
    "PRIMARY_TICKET_ID" "$t6_output"

echo ""
print_summary
