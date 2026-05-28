#!/usr/bin/env bash
# tests/scripts/test-review-github-defense-store-pr-keyed.sh
#
# GitHubPRDefenseStore (review-github-defense-store.sh) accepts pr_number key
#
# Testing Mode: RED
#
# Story DD Coverage:
#   DD3 (continued): GitHubPRDefenseStore reads/writes defenses keyed by
#   (pr_number, commit_sha). Existing PR-keyed defenses remain readable via
#   the sentinel-pr_number rule.
#
# Tests four behavioral contracts that FAIL before review-github-defense-store.sh
# is updated to support the --pr-number key:
#
#   1. test_github_defense_store_write_embeds_pr_number
#      github_defense_store_write with pr_number=42 embeds pr_number=42 in the
#      DEFENSE_RECORD comment body posted to the PR.
#
#   2. test_github_defense_store_list_pr42_returns_pr42_record
#      github_defense_store_list --pr-number 42 returns the v1.2.0 PR-42 defense
#      (written with pr_number=42 in the record).
#
#   3. test_github_defense_store_list_pr99_excludes_pr42_record
#      github_defense_store_list --pr-number 99 does NOT return the PR-42 defense
#      (no cross-PR leakage).
#
#   4. test_github_defense_store_list_pr99_returns_sentinel_record
#      github_defense_store_list --pr-number 99 DOES return a legacy/sentinel
#      record (pr_number absent or pr_number=0) — sentinel matches any pr query.
#
# Usage: bash tests/scripts/test-review-github-defense-store-pr-keyed.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail.

# NOTE: -e intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$REPO_ROOT/tests/lib"
SUBJECT="$REPO_ROOT/plugins/dso/scripts/review-github-defense-store.sh"

# shellcheck source=tests/lib/assert.sh
source "$LIB_DIR/assert.sh"

echo "=== test-review-github-defense-store-pr-keyed.sh ==="

# ---------------------------------------------------------------------------
# Isolation: all temp dirs cleaned on exit
# ---------------------------------------------------------------------------
_TEST_TMPDIRS=()
_cleanup() {
    local d
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "$d" ]] && rm -rf "$d"
    done
}
trap _cleanup EXIT

make_tmpdir() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/test-gh-defense-pr-keyed.XXXXXX")
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ---------------------------------------------------------------------------
# gh mock factory
#
# Creates a fake gh binary in a new temp dir that:
#   - Records every call to GH_CALL_LOG (default: /dev/null)
#   - Returns GH_EXIT_CODE (default: 0)
#   - For `gh pr view <pr> --json comments ...` calls returns GH_PR_COMMENTS_JSON
#   - For `gh pr comment ...` calls exits GH_EXIT_CODE and prints nothing
#
# Caller controls behavior via environment variables set around the call.
# Returns the directory containing the fake gh binary.
# ---------------------------------------------------------------------------
make_fake_gh_dir() {
    local fakedir
    fakedir=$(make_tmpdir)
    cat > "$fakedir/gh" <<'GHEOF'
#!/usr/bin/env bash
LOG="${GH_CALL_LOG:-/dev/null}"
{
    printf 'CALL'
    for a in "$@"; do printf '\t%s' "$a"; done
    printf '\n'
    # bug acff: github_defense_store_write switched from `--body <text>` to
    # `--body-file <path>`. Capture body-file contents into the call log so
    # tests that previously asserted against the argv-embedded body can keep
    # the same `grep <substring> "$calllog"` assertion shape against
    # body-file content. Body-file is mktemp'd and deleted by the caller —
    # we have to read it before that.
    _prev=""
    for a in "$@"; do
        if [[ "$_prev" == "--body-file" && -n "$a" && -r "$a" ]]; then
            printf 'BODY-FILE-CONTENTS<<\n'
            cat "$a" 2>/dev/null || true
            printf '\n>>BODY-FILE-CONTENTS\n'
        fi
        _prev="$a"
    done
} >> "$LOG" 2>/dev/null || true

exit_code="${GH_EXIT_CODE:-0}"

# Route: `gh pr view <N> --json comments ...` -> emit GH_PR_COMMENTS_JSON
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
    echo "${GH_PR_COMMENTS_JSON:-[]}"
    exit "$exit_code"
fi

# Route: `gh pr comment ...` -> success no-op (comment posted)
if [[ "${1:-}" == "pr" && "${2:-}" == "comment" ]]; then
    exit "$exit_code"
fi

# Fallback
exit "$exit_code"
GHEOF
    chmod +x "$fakedir/gh"
    echo "$fakedir"
}

# ---------------------------------------------------------------------------
# Test 1: github_defense_store_write embeds pr_number=42 in the PR comment body
#
# current github_defense_store_write does not accept a --pr-number argument
# and does not embed pr_number in the DEFENSE_RECORD JSON it posts.
# ---------------------------------------------------------------------------
echo ""
echo "--- test_github_defense_store_write_embeds_pr_number ---"
_snapshot_fail

test_github_defense_store_write_embeds_pr_number() {
    local tmpdir fake_gh_dir calllog
    tmpdir=$(make_tmpdir)
    fake_gh_dir=$(make_fake_gh_dir)
    calllog="$tmpdir/gh-calls.log"

    local record_json='{"ticket_id":"t001","defense_text":"test defense","severity_history":["important"]}'

    local output exit_code=0
    # Pass --pr-number 42 as additional key argument to github_defense_store_write.
    # the current function signature is:
    #   github_defense_store_write record_json pr_number repo
    # and does NOT embed pr_number=42 in the DEFENSE_RECORD JSON body.
    output=$(
        GH_CMD="$fake_gh_dir/gh" \
        GH_CALL_LOG="$calllog" \
        bash -c "
            source '$SUBJECT'
            github_defense_store_write '$record_json' 42 'owner/repo' --pr-number 42
        " 2>&1
    ) || exit_code=$?

    # The PR comment must have been posted (gh pr comment call logged)
    local posted=0
    if grep -qF 'pr	comment' "$calllog" 2>/dev/null; then
        posted=1
    fi
    assert_eq "gh pr comment was called (exit $exit_code)" "1" "$posted"

    # The posted comment body must contain pr_number=42 inside the DEFENSE_RECORD JSON.
    # After bug acff (commit aba6542873), github_defense_store_write posts via
    # `--body-file` instead of `--body`, so the body content lives in the
    # `BODY-FILE-CONTENTS<<...>>BODY-FILE-CONTENTS` block the fake gh stub
    # captures, not directly on the `pr	comment` argv line.
    local has_pr_number=0
    if grep -qF '"pr_number": 42' "$calllog" 2>/dev/null || \
       grep -qF '"pr_number":42' "$calllog" 2>/dev/null; then
        has_pr_number=1
    fi
    assert_eq "DEFENSE_RECORD body embeds pr_number=42" "1" "$has_pr_number"
}

test_github_defense_store_write_embeds_pr_number
assert_pass_if_clean "test_github_defense_store_write_embeds_pr_number"

# ---------------------------------------------------------------------------
# Test 2: github_defense_store_list --pr-number 42 returns the PR-42 record
#
# Given: a PR with one comment containing a v1.2.0 DEFENSE_RECORD (pr_number=42)
# When:  github_defense_store_list --pr-number 42 is called
# Then:  the PR-42 defense record is emitted on stdout
#
# the current script has no github_defense_store_list function at all.
# ---------------------------------------------------------------------------
echo ""
echo "--- test_github_defense_store_list_pr42_returns_pr42_record ---"
_snapshot_fail

test_github_defense_store_list_pr42_returns_pr42_record() {
    local tmpdir fake_gh_dir
    tmpdir=$(make_tmpdir)
    fake_gh_dir=$(make_fake_gh_dir)

    # Mock gh pr view to return one comment with a pr_number=42 DEFENSE_RECORD
    local pr42_record
    pr42_record='{"ticket_id":"t001","pr_number":42,"commit_sha":"abc123","defense_text":"defense for PR 42","severity_history":["important"]}'
    local pr_comments_json
    pr_comments_json=$(printf '[{"body":"DEFENSE_RECORD: %s"}]' "$pr42_record")

    local output exit_code=0
    output=$(
        GH_CMD="$fake_gh_dir/gh" \
        GH_PR_COMMENTS_JSON="$pr_comments_json" \
        bash -c "
            source '$SUBJECT'
            github_defense_store_list --pr-number 42 --gh-pr 42 --repo 'owner/repo'
        " 2>&1
    ) || exit_code=$?

    # Should emit the DEFENSE_RECORD line for PR-42
    local has_record=0
    if echo "$output" | grep -qF '"pr_number":42' 2>/dev/null || \
       echo "$output" | grep -qF '"pr_number": 42' 2>/dev/null; then
        has_record=1
    fi
    assert_eq "github_defense_store_list --pr-number 42 returns PR-42 record" "1" "$has_record"
    assert_eq "github_defense_store_list --pr-number 42 exits 0" "0" "$exit_code"
}

test_github_defense_store_list_pr42_returns_pr42_record
assert_pass_if_clean "test_github_defense_store_list_pr42_returns_pr42_record"

# ---------------------------------------------------------------------------
# Test 3: github_defense_store_list --pr-number 99 excludes the PR-42 record
#
# Given: a PR with one comment containing a v1.2.0 DEFENSE_RECORD (pr_number=42)
# When:  github_defense_store_list --pr-number 99 is called
# Then:  the PR-42 defense is NOT emitted (no cross-PR leakage)
#
# the current script has no github_defense_store_list / pr_number filtering.
# ---------------------------------------------------------------------------
echo ""
echo "--- test_github_defense_store_list_pr99_excludes_pr42_record ---"
_snapshot_fail

test_github_defense_store_list_pr99_excludes_pr42_record() {
    local tmpdir fake_gh_dir
    tmpdir=$(make_tmpdir)
    fake_gh_dir=$(make_fake_gh_dir)

    local pr42_record
    pr42_record='{"ticket_id":"t001","pr_number":42,"commit_sha":"abc123","defense_text":"defense for PR 42","severity_history":["important"]}'
    local pr_comments_json
    pr_comments_json=$(printf '[{"body":"DEFENSE_RECORD: %s"}]' "$pr42_record")

    local output exit_code=0
    output=$(
        GH_CMD="$fake_gh_dir/gh" \
        GH_PR_COMMENTS_JSON="$pr_comments_json" \
        bash -c "
            source '$SUBJECT'
            github_defense_store_list --pr-number 99 --gh-pr 42 --repo 'owner/repo'
        " 2>&1
    ) || exit_code=$?

    # Should NOT emit the PR-42 record when querying for PR-99
    local has_pr42_record=0
    if echo "$output" | grep -qF '"pr_number":42' 2>/dev/null || \
       echo "$output" | grep -qF '"pr_number": 42' 2>/dev/null; then
        has_pr42_record=1
    fi
    assert_eq "github_defense_store_list --pr-number 99 excludes PR-42 record" "0" "$has_pr42_record"
}

test_github_defense_store_list_pr99_excludes_pr42_record
assert_pass_if_clean "test_github_defense_store_list_pr99_excludes_pr42_record"

# ---------------------------------------------------------------------------
# Test 4: github_defense_store_list --pr-number 99 returns sentinel records
#
# Given: a PR with two comments:
#   - One v1.1.0 legacy DEFENSE_RECORD (no pr_number field = sentinel)
#   - One v1.2.0 DEFENSE_RECORD with pr_number=42
# When:  github_defense_store_list --pr-number 99 is called
# Then:  the sentinel/legacy record IS returned (sentinel matches any pr query)
#        but the PR-42 record is NOT returned
#
# the current script has no github_defense_store_list / sentinel logic.
# ---------------------------------------------------------------------------
echo ""
echo "--- test_github_defense_store_list_pr99_returns_sentinel_record ---"
_snapshot_fail

test_github_defense_store_list_pr99_returns_sentinel_record() {
    local tmpdir fake_gh_dir
    tmpdir=$(make_tmpdir)
    fake_gh_dir=$(make_fake_gh_dir)

    # Sentinel: legacy v1.1.0-style record with no pr_number field
    local sentinel_record
    sentinel_record='{"ticket_id":"t000","commit_sha":"old456","defense_text":"legacy defense no pr_number","severity_history":["important"]}'
    # PR-42 specific record
    local pr42_record
    pr42_record='{"ticket_id":"t001","pr_number":42,"commit_sha":"abc123","defense_text":"defense for PR 42","severity_history":["important"]}'

    local pr_comments_json
    pr_comments_json=$(printf '[{"body":"DEFENSE_RECORD: %s"},{"body":"DEFENSE_RECORD: %s"}]' \
        "$sentinel_record" "$pr42_record")

    local output exit_code=0
    output=$(
        GH_CMD="$fake_gh_dir/gh" \
        GH_PR_COMMENTS_JSON="$pr_comments_json" \
        bash -c "
            source '$SUBJECT'
            github_defense_store_list --pr-number 99 --gh-pr 42 --repo 'owner/repo'
        " 2>&1
    ) || exit_code=$?

    # The sentinel (no pr_number) should be emitted — sentinel matches any PR
    local has_sentinel=0
    if echo "$output" | grep -qF '"ticket_id":"t000"' 2>/dev/null || \
       echo "$output" | grep -qF '"ticket_id": "t000"' 2>/dev/null; then
        has_sentinel=1
    fi
    assert_eq "github_defense_store_list --pr-number 99 returns sentinel record" "1" "$has_sentinel"

    # The PR-42 specific record should NOT be emitted
    local has_pr42=0
    if echo "$output" | grep -qF '"pr_number":42' 2>/dev/null || \
       echo "$output" | grep -qF '"pr_number": 42' 2>/dev/null; then
        has_pr42=1
    fi
    assert_eq "github_defense_store_list --pr-number 99 excludes PR-42 record (sentinel test)" "0" "$has_pr42"
}

test_github_defense_store_list_pr99_returns_sentinel_record
assert_pass_if_clean "test_github_defense_store_list_pr99_returns_sentinel_record"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
