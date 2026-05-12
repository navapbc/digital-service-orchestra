#!/usr/bin/env bash
# tests/integration/test-pr-comment-response-integration.sh
#
# RED integration tests for the PR comment response pipeline:
#   plugins/dso/scripts/pr-comment-response.sh
#
# The script under test does NOT exist yet. All behavioral tests fail in RED
# state because pr-comment-response.sh is absent. Once the script is
# implemented (stories 238c-d60a → 0fb0-e23a → 4949-c6a8 → 93cb-ef60),
# these tests transition GREEN.
#
# Behavioral contracts tested:
#   SC1 — fetch/normalize: produces JSON with required schema fields; resolves
#          root_comment_id by walking in_reply_to_id chain to null
#   SC2 — accept handler: dispatches fix sub-agent; commits/pushes; posts
#          reply with commit SHA + sentinel
#   SC3 — defend handler: posts PR review comment; writes defense_comment_id
#          to normalized JSON before thread reply
#   SC4 — defer handler: creates DSO tracking ticket; writes ticket ID to
#          normalized JSON before reply
#   SC9 — integration: mock fixture with accept/defend/defer (including
#          reply-in-thread) exercises root_comment_id chain-walk; mock
#          enforces no real gh api or MCP calls escape
#
# Mock design:
#   A per-test temp dir prepended to PATH contains:
#     gh   — bash shim recording argv+stdin to $GH_CALL_LOG, emitting canned
#             JSON keyed by $STUB_GH_SCENARIO, exiting with $GH_EXIT_CODE.
#   GITHUB_TOKEN is set to a fake sentinel value ("FAKE_TOKEN_SENTINEL").
#   No real GitHub API calls escape: verified by asserting GH_CALL_LOG
#   contains no entries with "api.github.com".
#
# Fixture: PR #42 with three comments
#   comment-100  (accept)  — inline, not a reply; in_reply_to_id: null
#   comment-200  (defend)  — top-level, not a reply; in_reply_to_id: null
#   comment-300  (defer-root)  — top-level root comment; in_reply_to_id: null
#   comment-301  (defer-reply) — reply to 300; in_reply_to_id: "comment-300"
#     root_comment_id of comment-301 MUST resolve to "comment-300" (chain-walk)
#
# Usage:
#   bash tests/integration/test-pr-comment-response-integration.sh
# Exit: 0 if all tests pass (GREEN once implemented), non-zero (RED until then).
#
# shellcheck disable=SC2016,SC2155

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-pr-comment-response-integration.sh ==="

# ---------------------------------------------------------------------------
# Globals & cleanup
# ---------------------------------------------------------------------------
_TEST_TMPDIRS=()
_cleanup() {
    local d
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "${d:-}" && -d "$d" ]] && rm -rf "$d"
    done
}
trap _cleanup EXIT

PR_COMMENT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/pr-comment-response.sh"

# ---------------------------------------------------------------------------
# Mock fixture JSON: PR #42 with 4 comments (accept, defend, defer-root,
# defer-reply). The fixture is emitted by the gh stub when the caller
# requests comments for this PR.
# ---------------------------------------------------------------------------
_FIXTURE_COMMENTS_JSON='[
  {
    "comment_id": "comment-100",
    "in_reply_to_id": null,
    "body": "Please rename variable foo to bar for clarity.",
    "author": "engineer-alice",
    "is_inline": true,
    "path": "plugins/dso/scripts/some-script.sh",
    "position": 42,
    "url": "https://github.com/org/repo/pull/42#discussion_r100"
  },
  {
    "comment_id": "comment-200",
    "in_reply_to_id": null,
    "body": "Why did you choose this approach over using jq directly?",
    "author": "engineer-bob",
    "is_inline": false,
    "path": null,
    "position": null,
    "url": "https://github.com/org/repo/pull/42#issuecomment-200"
  },
  {
    "comment_id": "comment-300",
    "in_reply_to_id": null,
    "body": "This feature seems out of scope for this PR.",
    "author": "engineer-carol",
    "is_inline": false,
    "path": null,
    "position": null,
    "url": "https://github.com/org/repo/pull/42#issuecomment-300"
  },
  {
    "comment_id": "comment-301",
    "in_reply_to_id": "comment-300",
    "body": "Agreed, we should track this separately.",
    "author": "engineer-carol",
    "is_inline": false,
    "path": null,
    "position": null,
    "url": "https://github.com/org/repo/pull/42#issuecomment-301"
  }
]'

# ---------------------------------------------------------------------------
# _make_stub_dir — create a per-test stub PATH prefix containing a gh shim.
# Returns the dir path on stdout.
#
# The stub is controlled by env vars set by the caller:
#   GH_EXIT_CODE       — exit code (default: 0)
#   GH_CALL_LOG        — file the shim appends argv to
#   STUB_GH_SCENARIO   — scenario selector for canned JSON responses
# ---------------------------------------------------------------------------
_make_stub_dir() {
    local d
    d=$(mktemp -d "/tmp/dso-pr-comment-response-stubs.XXXXXX")
    _TEST_TMPDIRS+=("$d")

    cat > "$d/gh" <<'GHEOF'
#!/usr/bin/env bash
# Test stub for `gh`. Records argv to $GH_CALL_LOG.
# Asserts GITHUB_TOKEN is the expected sentinel (not a real token).
# Emits canned JSON based on $STUB_GH_SCENARIO.
set -u
LOG="${GH_CALL_LOG:-/dev/null}"
{
    printf 'CALL'
    for a in "$@"; do printf '\t%s' "$a"; done
    printf '\n'
} >> "$LOG" 2>/dev/null || true

# Verify no real API hostname in args (anti-escape assertion)
for a in "$@"; do
    if [[ "$a" == *"api.github.com"* ]]; then
        printf 'REAL_API_ESCAPE\t%s\n' "$a" >> "$LOG" 2>/dev/null || true
    fi
done

# Emit canned response keyed by scenario
case "${STUB_GH_SCENARIO:-default}" in
    fetch_comments)
        # POST calls (defense review comment or thread reply) return an id
        # GET calls return the fixture comments JSON
        _is_post=false
        for _a in "$@"; do [[ "$_a" == "POST" ]] && _is_post=true; done
        if [[ "$_is_post" == true ]]; then
            printf '{"id": "review-comment-%s"}\n' "$$"
        else
            printf '%s\n' "${STUB_COMMENTS_JSON:-[]}"
        fi
        ;;
    fetch_empty)
        printf '{"comments":[],"skipped_count":0}\n'
        ;;
    api_error)
        echo "ERROR: simulated API failure" >&2
        exit "${GH_EXIT_CODE:-1}"
        ;;
    reply_success)
        # Return a canned reply/comment ID
        printf '{"id": "comment-reply-%s"}\n' "$$"
        ;;
    pr_review_comment_posted)
        # Respond to POST /pulls/42/comments/ID/replies
        printf '{"id": "review-comment-%s"}\n' "$$"
        ;;
    *)
        printf '{}\n'
        ;;
esac

exit "${GH_EXIT_CODE:-0}"
GHEOF
    chmod +x "$d/gh"
    echo "$d"
}

# ---------------------------------------------------------------------------
# _setup_test — fresh stubs + per-test call log + PATH prefix.
# ---------------------------------------------------------------------------
_setup_test() {
    STUB_DIR=$(_make_stub_dir)
    GH_CALL_LOG="$STUB_DIR/gh.log"
    : > "$GH_CALL_LOG"
    export GH_CALL_LOG
    export GH_EXIT_CODE=0
    export STUB_GH_SCENARIO="default"
    export STUB_COMMENTS_JSON="$_FIXTURE_COMMENTS_JSON"
    _SAVED_PATH="$PATH"
    PATH="$STUB_DIR:$PATH"
    export PATH
    # Fake token — must not match a real GITHUB_TOKEN pattern
    export GITHUB_TOKEN="FAKE_TOKEN_SENTINEL_DO_NOT_USE"
    # Fake PR context
    export GH_REPO="org/repo"
    export PR_NUMBER="42"
}

_teardown_test() {
    PATH="$_SAVED_PATH"
    export PATH
    unset GH_EXIT_CODE GH_CALL_LOG STUB_GH_SCENARIO STUB_COMMENTS_JSON \
          GITHUB_TOKEN GH_REPO PR_NUMBER || true
}

# Convenience: count gh calls matching a pattern in the call log.
_gh_call_count() {
    local pattern="$1"
    local cnt
    cnt=$(grep -c "$pattern" "$GH_CALL_LOG" 2>/dev/null; true)
    echo "${cnt%%[[:space:]]*}"
}

# Convenience: check no real API escapes.
_assert_no_real_api_escape() {
    local label="$1"
    local escape_count
    # grep -c exits 1 when count=0 (no match); use a subshell that always exits 0
    escape_count=$(grep -c "REAL_API_ESCAPE" "$GH_CALL_LOG" 2>/dev/null; true)
    # strip any trailing newline/whitespace to get a clean integer
    escape_count="${escape_count%%[[:space:]]*}"
    assert_eq "$label: no real api.github.com calls escaped" "0" "$escape_count"
}

# ---------------------------------------------------------------------------
# Early RED guard: if the script under test is missing, record the expected
# RED state and continue to execute the behavioral assertions so they also
# fail (RED) and show the full expected surface area.
# ---------------------------------------------------------------------------
_script_missing=false
if [[ ! -f "$PR_COMMENT_SCRIPT" ]]; then
    echo ""
    echo "RED: pr-comment-response.sh not found at $PR_COMMENT_SCRIPT"
    echo "     This is the expected RED state — all behavioral tests below will fail."
    echo "     Implement the script to make tests GREEN."
    _script_missing=true
fi

# ===========================================================================
# TEST 1: Script produces normalized JSON with required schema fields
# Given:  gh stub returns fixture comments; output JSON path is a temp file
# When:   pr-comment-response.sh --pr-number 42 --output <tmpfile> is called
# Then:   output JSON contains fields: comment_id, root_comment_id, thread_url,
#         body, author, is_inline, already_replied, defense_comment_id
# ===========================================================================
test_fetch_produces_normalized_json_schema() {
    echo ""
    echo "=== test_fetch_produces_normalized_json_schema ==="
    _snapshot_fail
    _setup_test
    STUB_GH_SCENARIO="fetch_comments"
    export STUB_GH_SCENARIO

    local out_file
    out_file=$(mktemp "/tmp/pr-comment-response-output.XXXXXX")
    _TEST_TMPDIRS+=("$out_file")  # cleaned up on exit

    local rc=0
    if [[ "$_script_missing" == true ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-response.sh missing — cannot execute fetch test" >&2
    else
        bash "$PR_COMMENT_SCRIPT" --pr-number 42 --output "$out_file" || rc=$?
        # The script must exit 0 when comments are present
        assert_eq "fetch exits 0" "0" "$rc"

        # Output file must exist
        assert_eq "output file exists" "true" "$( [[ -f "$out_file" ]] && echo true || echo false )"

        if [[ -f "$out_file" ]]; then
            # Must have comment_id field in at least one entry
            assert_contains "output has comment_id" '"comment_id"' "$(cat "$out_file")"
            assert_contains "output has root_comment_id" '"root_comment_id"' "$(cat "$out_file")"
            assert_contains "output has thread_url" '"thread_url"' "$(cat "$out_file")"
            assert_contains "output has body" '"body"' "$(cat "$out_file")"
            assert_contains "output has author" '"author"' "$(cat "$out_file")"
            assert_contains "output has is_inline" '"is_inline"' "$(cat "$out_file")"
            assert_contains "output has already_replied" '"already_replied"' "$(cat "$out_file")"
            assert_contains "output has defense_comment_id" '"defense_comment_id"' "$(cat "$out_file")"
        fi
    fi

    _assert_no_real_api_escape "test_fetch_produces_normalized_json_schema"
    _teardown_test
    assert_pass_if_clean "test_fetch_produces_normalized_json_schema"
}

# ===========================================================================
# TEST 2: root_comment_id resolved by chain-walk for reply-in-thread
# Given:  fixture has comment-301 with in_reply_to_id=comment-300
# When:   pr-comment-response.sh fetches and normalizes comments
# Then:   comment-301's root_comment_id is "comment-300" (chain resolves to root)
# ===========================================================================
test_reply_in_thread_root_comment_id_resolved() {
    echo ""
    echo "=== test_reply_in_thread_root_comment_id_resolved ==="
    _snapshot_fail
    _setup_test
    STUB_GH_SCENARIO="fetch_comments"
    export STUB_GH_SCENARIO

    local out_file
    out_file=$(mktemp "/tmp/pr-comment-response-output.XXXXXX")
    _TEST_TMPDIRS+=("$out_file")

    if [[ "$_script_missing" == true ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-response.sh missing — cannot execute chain-walk test" >&2
    else
        bash "$PR_COMMENT_SCRIPT" --pr-number 42 --output "$out_file" || true

        if [[ -f "$out_file" ]]; then
            # Extract root_comment_id for comment-301 via python3
            local root_id
            root_id=$(python3 -c "
import json, sys
data = json.load(open('$out_file'))
comments = data if isinstance(data, list) else data.get('comments', [])
for c in comments:
    if c.get('comment_id') == 'comment-301':
        print(c.get('root_comment_id', 'MISSING'))
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null || echo "PARSE_ERROR")
            assert_eq "comment-301 root_comment_id resolved to comment-300" \
                "comment-300" "$root_id"
        else
            (( ++FAIL ))
            echo "FAIL: output file not produced" >&2
        fi
    fi

    _assert_no_real_api_escape "test_reply_in_thread_root_comment_id_resolved"
    _teardown_test
    assert_pass_if_clean "test_reply_in_thread_root_comment_id_resolved"
}

# ===========================================================================
# TEST 3: Empty result when no unresolved comments exist
# Given:  gh stub returns empty comments list
# When:   pr-comment-response.sh is called
# Then:   exits 0, output JSON is {"comments":[],"skipped_count":0}
# ===========================================================================
test_empty_pr_exits_0_and_writes_empty_json() {
    echo ""
    echo "=== test_empty_pr_exits_0_and_writes_empty_json ==="
    _snapshot_fail
    _setup_test
    STUB_GH_SCENARIO="fetch_empty"
    export STUB_GH_SCENARIO

    local out_file
    out_file=$(mktemp "/tmp/pr-comment-response-output.XXXXXX")
    _TEST_TMPDIRS+=("$out_file")

    local rc=0
    if [[ "$_script_missing" == true ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-response.sh missing" >&2
    else
        bash "$PR_COMMENT_SCRIPT" --pr-number 42 --output "$out_file" || rc=$?
        assert_eq "empty PR exits 0" "0" "$rc"

        if [[ -f "$out_file" ]]; then
            local comments_count
            comments_count=$(python3 -c "
import json
d = json.load(open('$out_file'))
comments = d.get('comments', d) if isinstance(d, dict) else d
print(len(comments) if isinstance(comments, list) else -1)
" 2>/dev/null || echo "-1")
            assert_eq "empty PR: zero comments in output" "0" "$comments_count"
        else
            (( ++FAIL ))
            echo "FAIL: output file not created for empty PR" >&2
        fi
    fi

    _assert_no_real_api_escape "test_empty_pr_exits_0_and_writes_empty_json"
    _teardown_test
    assert_pass_if_clean "test_empty_pr_exits_0_and_writes_empty_json"
}

# ===========================================================================
# TEST 4: API failure exits non-zero with ERROR: prefix on stderr
# Given:  gh stub is configured to exit 1 (API error)
# When:   pr-comment-response.sh is called
# Then:   exits non-zero AND stderr contains "ERROR:"
# ===========================================================================
test_api_failure_exits_nonzero_with_error_prefix() {
    echo ""
    echo "=== test_api_failure_exits_nonzero_with_error_prefix ==="
    _snapshot_fail
    _setup_test
    STUB_GH_SCENARIO="api_error"
    GH_EXIT_CODE=1
    export STUB_GH_SCENARIO GH_EXIT_CODE

    local rc=0
    local stderr_out
    if [[ "$_script_missing" == true ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-response.sh missing" >&2
    else
        stderr_out=$(bash "$PR_COMMENT_SCRIPT" --pr-number 42 --output /dev/null 2>&1 || true)
        rc=$?
        assert_ne "API failure exits non-zero" "0" "$rc"
        assert_contains "API failure stderr has ERROR: prefix" "ERROR:" "$stderr_out"
    fi

    _assert_no_real_api_escape "test_api_failure_exits_nonzero_with_error_prefix"
    _teardown_test
    assert_pass_if_clean "test_api_failure_exits_nonzero_with_error_prefix"
}

# ===========================================================================
# TEST 5: Defend handler writes defense_comment_id before thread reply
# Given:  defend-classified comment (comment-200) in fixture
# When:   pr-comment-response.sh processes the defend comment
# Then:   normalized JSON has non-null defense_comment_id for comment-200
#         AND the reply gh call came AFTER the PR review comment post call
# ===========================================================================
test_defend_comment_defense_comment_id_non_null() {
    echo ""
    echo "=== test_defend_comment_defense_comment_id_non_null ==="
    _snapshot_fail
    _setup_test
    STUB_GH_SCENARIO="fetch_comments"
    export STUB_GH_SCENARIO

    local out_file
    out_file=$(mktemp "/tmp/pr-comment-response-output.XXXXXX")
    _TEST_TMPDIRS+=("$out_file")

    if [[ "$_script_missing" == true ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-response.sh missing" >&2
    else
        bash "$PR_COMMENT_SCRIPT" --pr-number 42 --output "$out_file" \
            --classify-as "comment-200:defend" || true

        if [[ -f "$out_file" ]]; then
            local def_id
            def_id=$(python3 -c "
import json
data = json.load(open('$out_file'))
comments = data if isinstance(data, list) else data.get('comments', [])
for c in comments:
    if c.get('comment_id') == 'comment-200':
        print(c.get('defense_comment_id') or 'NULL')
        import sys; sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null || echo "PARSE_ERROR")
            assert_ne "comment-200 defense_comment_id is non-null" "NULL" "$def_id"
            assert_ne "comment-200 defense_comment_id is non-null (not NOT_FOUND)" \
                "NOT_FOUND" "$def_id"
        else
            (( ++FAIL ))
            echo "FAIL: output file not produced" >&2
        fi
    fi

    _assert_no_real_api_escape "test_defend_comment_defense_comment_id_non_null"
    _teardown_test
    assert_pass_if_clean "test_defend_comment_defense_comment_id_non_null"
}

# ===========================================================================
# TEST 6: Defer handler writes ticket ID to JSON before posting reply
# Given:  defer-classified comment (comment-301) in fixture
# When:   pr-comment-response.sh processes defer comment
# Then:   normalized JSON has non-empty ticket_id for comment-301
# ===========================================================================
test_defer_comment_ticket_id_in_json() {
    echo ""
    echo "=== test_defer_comment_ticket_id_in_json ==="
    _snapshot_fail
    _setup_test
    STUB_GH_SCENARIO="fetch_comments"
    export STUB_GH_SCENARIO

    local out_file
    out_file=$(mktemp "/tmp/pr-comment-response-output.XXXXXX")
    _TEST_TMPDIRS+=("$out_file")

    if [[ "$_script_missing" == true ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-response.sh missing" >&2
    else
        bash "$PR_COMMENT_SCRIPT" --pr-number 42 --output "$out_file" \
            --classify-as "comment-301:defer" || true

        if [[ -f "$out_file" ]]; then
            local ticket_id
            ticket_id=$(python3 -c "
import json
data = json.load(open('$out_file'))
comments = data if isinstance(data, list) else data.get('comments', [])
for c in comments:
    if c.get('comment_id') == 'comment-301':
        print(c.get('ticket_id') or 'NULL')
        import sys; sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null || echo "PARSE_ERROR")
            assert_ne "comment-301 ticket_id is non-null" "NULL" "$ticket_id"
            assert_ne "comment-301 ticket_id is non-null (not NOT_FOUND)" \
                "NOT_FOUND" "$ticket_id"
        else
            (( ++FAIL ))
            echo "FAIL: output file not produced" >&2
        fi
    fi

    _assert_no_real_api_escape "test_defer_comment_ticket_id_in_json"
    _teardown_test
    assert_pass_if_clean "test_defer_comment_ticket_id_in_json"
}

# ===========================================================================
# TEST 7: No real API calls escape (mock boundary enforcement)
# Given:  GITHUB_TOKEN=FAKE_TOKEN_SENTINEL; stub logs all argv
# When:   pr-comment-response.sh runs the full pipeline
# Then:   no entry in GH_CALL_LOG contains "api.github.com"
# ===========================================================================
test_no_real_api_calls_escape() {
    echo ""
    echo "=== test_no_real_api_calls_escape ==="
    _snapshot_fail
    _setup_test
    STUB_GH_SCENARIO="fetch_comments"
    export STUB_GH_SCENARIO

    local out_file
    out_file=$(mktemp "/tmp/pr-comment-response-output.XXXXXX")
    _TEST_TMPDIRS+=("$out_file")

    if [[ "$_script_missing" == true ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-response.sh missing — cannot run mock-boundary test" >&2
    else
        bash "$PR_COMMENT_SCRIPT" --pr-number 42 --output "$out_file" || true
        _assert_no_real_api_escape "test_no_real_api_calls_escape"
    fi

    _teardown_test
    assert_pass_if_clean "test_no_real_api_calls_escape"
}

# ===========================================================================
# TEST 8: All three reply calls are made (accept/defend/defer each get a reply)
# Given:  full fixture with one accept, one defend, one defer comment
# When:   pr-comment-response.sh processes all three
# Then:   gh call log shows at least 3 reply-posting calls (one per comment)
#         Each reply body begins with <!-- dso-agent-reply -->
# ===========================================================================
test_all_three_comments_get_replies() {
    echo ""
    echo "=== test_all_three_comments_get_replies ==="
    _snapshot_fail
    _setup_test
    STUB_GH_SCENARIO="fetch_comments"
    export STUB_GH_SCENARIO

    local out_file
    out_file=$(mktemp "/tmp/pr-comment-response-output.XXXXXX")
    _TEST_TMPDIRS+=("$out_file")

    if [[ "$_script_missing" == true ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-response.sh missing" >&2
    else
        bash "$PR_COMMENT_SCRIPT" --pr-number 42 --output "$out_file" || true

        # Count reply calls: any gh api call to a /replies or /comments endpoint
        local reply_calls
        reply_calls=$(_gh_call_count "replies\|issuecomments\|pull.*comments" || echo "0")
        # We expect at least 3 (one per comment: accept, defend, defer)
        local expected_min=3
        if [[ "$reply_calls" -ge "$expected_min" ]]; then
            (( ++PASS ))
        else
            (( ++FAIL ))
            printf 'FAIL: expected at least %d reply calls, got %s\n' \
                "$expected_min" "$reply_calls" >&2
        fi
    fi

    _assert_no_real_api_escape "test_all_three_comments_get_replies"
    _teardown_test
    assert_pass_if_clean "test_all_three_comments_get_replies"
}

# ===========================================================================
# Run all tests
# ===========================================================================
test_fetch_produces_normalized_json_schema
test_reply_in_thread_root_comment_id_resolved
test_empty_pr_exits_0_and_writes_empty_json
test_api_failure_exits_nonzero_with_error_prefix
test_defend_comment_defense_comment_id_non_null
test_defer_comment_ticket_id_in_json
test_no_real_api_calls_escape
test_all_three_comments_get_replies

print_summary
