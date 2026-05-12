#!/usr/bin/env bash
# tests/scripts/test-pr-comment-response-accept.sh — Unit tests for _handle_accept()
#
# Behavioral contracts:
#   1. Commits staged change, pushes, and posts SHA reply with sentinel
#   2. Reply body contains <!-- dso-agent-reply --> sentinel and commit SHA
#   3. On push failure, reverts commit and does not post reply
#   4. On multi-file staged scope, does not commit and does not post reply
#
# Usage:
#   bash tests/scripts/test-pr-comment-response-accept.sh
#
# shellcheck disable=SC2016,SC2155

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/plugins/dso/scripts/pr-comment-response.sh"

echo "=== test-pr-comment-response-accept.sh ==="

# ---------------------------------------------------------------------------
# Stub infrastructure
# ---------------------------------------------------------------------------
_cleanup_dirs=()
_cleanup() {
    local d
    for d in "${_cleanup_dirs[@]:-}"; do
        [[ -n "${d:-}" && -d "$d" ]] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# Fixture: a single accept comment (not inline, root comment)
_ACCEPT_FIXTURE_COMMENTS='[
  {
    "comment_id": "comment-100",
    "in_reply_to_id": null,
    "body": "Please rename foo to bar",
    "author": "alice",
    "is_inline": false,
    "diff_hunk": "",
    "path": "src/foo.sh",
    "pull_request_review_id": null,
    "position": 1
  }
]'

_make_stub_dir() {
    local stub_dir
    stub_dir=$(mktemp -d "/tmp/dso-accept-stubs.XXXXXX")
    _cleanup_dirs+=("$stub_dir")

    # gh stub — records calls to GH_CALL_LOG; routes responses by call type:
    #   - version check: emits stub version string
    #   - pulls/{N}/comments (fetch): returns fixture comments array
    #   - issues/{N}/comments (fetch): returns empty array
    #   - POST (reply): returns {"id": 9999}
    #   - other: returns {}
    cat > "$stub_dir/gh" << 'GHEOF'
#!/usr/bin/env bash
LOG="${GH_CALL_LOG:-/dev/null}"
{
    printf 'CALL'
    for a in "$@"; do printf '\t%s' "$a"; done
    printf '\n'
} >> "$LOG" 2>/dev/null || true
exit_code="${GH_EXIT_CODE:-0}"
# version check
if [[ "${1:-}" == "--version" ]]; then
    echo "gh version 2.99.0 (2026-05-01)"
    exit "$exit_code"
fi
# detect fetch vs post by METHOD arg
method=""
is_pulls_fetch=false
is_issues_fetch=false
is_post=false
for a in "$@"; do
    case "$a" in
        GET)  method=GET ;;
        POST) method=POST; is_post=true ;;
    esac
    if [[ "$a" == *"/pulls/"*"/comments"* && "$a" != *"/replies"* ]]; then
        is_pulls_fetch=true
    fi
    if [[ "$a" == *"/issues/"*"/comments"* ]]; then
        is_issues_fetch=true
    fi
done
if [[ "$is_post" == true ]]; then
    printf '{"id": 9999}\n'
elif [[ "$is_pulls_fetch" == true ]]; then
    printf '%s\n' "${STUB_COMMENTS_JSON:-[]}"
elif [[ "$is_issues_fetch" == true ]]; then
    printf '[]\n'
else
    printf '{}\n'
fi
exit "$exit_code"
GHEOF
    chmod +x "$stub_dir/gh"

    # git stub — records calls to GIT_CALL_LOG; returns configurable output
    #   - git diff --cached --name-only: output controlled by GIT_DIFF_OUTPUT
    #   - git commit ...: exit code GIT_COMMIT_EXIT_CODE (default 0)
    #   - git push: exit code GIT_PUSH_EXIT_CODE (default 0)
    #   - git rev-parse HEAD: output GIT_SHA_OUTPUT (default "abc123def456")
    #   - git revert: exit code 0, record the call
    cat > "$stub_dir/git" << 'GITEOF'
#!/usr/bin/env bash
LOG="${GIT_CALL_LOG:-/dev/null}"
{
    printf 'CALL'
    for a in "$@"; do printf '\t%s' "$a"; done
    printf '\n'
} >> "$LOG" 2>/dev/null || true

# Route by subcommand
subcmd="${1:-}"
case "$subcmd" in
    -C)
        # git -C <dir> rev-parse --show-toplevel — used by SCRIPT_DIR resolution
        shift; shift
        subcmd="${1:-}"
        ;;
    *) ;;
esac

case "$subcmd" in
    diff)
        # git diff --cached --name-only
        printf '%s\n' "${GIT_DIFF_OUTPUT:-src/foo.sh}"
        exit 0
        ;;
    commit)
        exit "${GIT_COMMIT_EXIT_CODE:-0}"
        ;;
    push)
        exit "${GIT_PUSH_EXIT_CODE:-0}"
        ;;
    rev-parse)
        # Check if it's HEAD (SHA lookup) or --show-toplevel
        for a in "$@"; do
            if [[ "$a" == "--show-toplevel" ]]; then
                # Return a plausible repo root for script dir resolution
                printf '%s\n' "${REPO_ROOT_OUTPUT:-/tmp/fake-repo}"
                exit 0
            fi
        done
        printf '%s\n' "${GIT_SHA_OUTPUT:-abc123def456}"
        exit 0
        ;;
    revert)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
GITEOF
    chmod +x "$stub_dir/git"

    echo "$stub_dir"
}

_make_accept_json() {
    # Create a normalized JSON object with comment-100 (accept, is_inline=false)
    cat << JSON
{
  "comments": [
    {
      "comment_id": "comment-100",
      "root_comment_id": "comment-100",
      "thread_url": "https://github.com/test/repo/pull/42",
      "body": "Please rename foo to bar",
      "author": "alice",
      "is_inline": false,
      "already_replied": false,
      "defense_comment_id": null,
      "path": "src/foo.sh",
      "position": 1,
      "ticket_id": null
    }
  ],
  "skipped_count": 0
}
JSON
}

# ---------------------------------------------------------------------------
# TEST 1: Commits staged change, pushes, and posts reply with SHA
# Given:  1 staged file; git commit succeeds; git push succeeds; known SHA
# When:   pr-comment-response.sh --classify-as "comment-100:accept"
# Then:   git commit was called; gh reply was posted; reply body contains SHA
# ---------------------------------------------------------------------------
test_accept_commits_and_replies_with_sha() {
    _snapshot_fail
    echo ""
    echo "=== test_accept_commits_and_replies_with_sha ==="

    local stub_dir; stub_dir=$(_make_stub_dir)
    local out_json; out_json=$(mktemp "/tmp/dso-accept-out.XXXXXX")
    _cleanup_dirs+=("$out_json")
    local gh_log; gh_log=$(mktemp "/tmp/dso-accept-gh.XXXXXX")
    _cleanup_dirs+=("$gh_log")
    local git_log; git_log=$(mktemp "/tmp/dso-accept-git.XXXXXX")
    _cleanup_dirs+=("$git_log")

    _make_accept_json > "$out_json"

    GH_CALL_LOG="$gh_log" GIT_CALL_LOG="$git_log" \
        GIT_DIFF_OUTPUT="src/foo.sh" \
        GIT_COMMIT_EXIT_CODE=0 GIT_PUSH_EXIT_CODE=0 \
        GIT_SHA_OUTPUT="deadbeef1234" \
        STUB_COMMENTS_JSON="$_ACCEPT_FIXTURE_COMMENTS" \
        PATH="$stub_dir:$PATH" GITHUB_TOKEN="FAKE" \
        bash "$SCRIPT" --pr-number 42 --output "$out_json" --classify-as "comment-100:accept" 2>/dev/null || true

    # git commit should have been called
    local git_calls; git_calls=$(cat "$git_log" 2>/dev/null || echo "")
    assert_contains "git commit should have been called" "commit" "$git_calls"

    # gh reply (POST) should have been made
    local gh_calls; gh_calls=$(cat "$gh_log" 2>/dev/null || echo "")
    local post_calls
    post_calls=$(grep $'\tPOST\t' "$gh_log" 2>/dev/null || echo "")
    assert_ne "gh POST reply should have been made" "" "$post_calls"

    # reply body should contain the SHA
    assert_contains "reply should contain the SHA" "deadbeef1234" "$gh_calls"

    assert_pass_if_clean "test_accept_commits_and_replies_with_sha"
}

# ---------------------------------------------------------------------------
# TEST 2: Reply body contains sentinel and SHA
# Given:  1 staged file; commit+push succeed; known fake SHA
# When:   accept handler runs
# Then:   gh call log contains "<!-- dso-agent-reply -->" and the fake SHA
# ---------------------------------------------------------------------------
test_accept_reply_body_contains_sentinel_and_sha() {
    _snapshot_fail
    echo ""
    echo "=== test_accept_reply_body_contains_sentinel_and_sha ==="

    local stub_dir; stub_dir=$(_make_stub_dir)
    local out_json; out_json=$(mktemp "/tmp/dso-accept-out.XXXXXX")
    _cleanup_dirs+=("$out_json")
    local gh_log; gh_log=$(mktemp "/tmp/dso-accept-gh.XXXXXX")
    _cleanup_dirs+=("$gh_log")
    local git_log; git_log=$(mktemp "/tmp/dso-accept-git.XXXXXX")
    _cleanup_dirs+=("$git_log")

    _make_accept_json > "$out_json"

    GH_CALL_LOG="$gh_log" GIT_CALL_LOG="$git_log" \
        GIT_DIFF_OUTPUT="src/foo.sh" \
        GIT_COMMIT_EXIT_CODE=0 GIT_PUSH_EXIT_CODE=0 \
        GIT_SHA_OUTPUT="cafebabe9876" \
        STUB_COMMENTS_JSON="$_ACCEPT_FIXTURE_COMMENTS" \
        PATH="$stub_dir:$PATH" GITHUB_TOKEN="FAKE" \
        bash "$SCRIPT" --pr-number 42 --output "$out_json" --classify-as "comment-100:accept" 2>/dev/null || true

    local gh_calls; gh_calls=$(cat "$gh_log" 2>/dev/null || echo "")
    assert_contains "reply body should contain sentinel" "dso-agent-reply" "$gh_calls"
    assert_contains "reply body should contain the fake SHA" "cafebabe9876" "$gh_calls"

    assert_pass_if_clean "test_accept_reply_body_contains_sentinel_and_sha"
}

# ---------------------------------------------------------------------------
# TEST 3: Reverts commit on push failure; no reply posted
# Given:  git push stub exits 1 (non-fast-forward rejection)
# When:   accept handler runs
# Then:   git revert was called; no reply with SHA posted
# ---------------------------------------------------------------------------
test_accept_reverts_on_non_fast_forward_push() {
    _snapshot_fail
    echo ""
    echo "=== test_accept_reverts_on_non_fast_forward_push ==="

    local stub_dir; stub_dir=$(_make_stub_dir)
    local out_json; out_json=$(mktemp "/tmp/dso-accept-out.XXXXXX")
    _cleanup_dirs+=("$out_json")
    local gh_log; gh_log=$(mktemp "/tmp/dso-accept-gh.XXXXXX")
    _cleanup_dirs+=("$gh_log")
    local git_log; git_log=$(mktemp "/tmp/dso-accept-git.XXXXXX")
    _cleanup_dirs+=("$git_log")

    _make_accept_json > "$out_json"

    GH_CALL_LOG="$gh_log" GIT_CALL_LOG="$git_log" \
        GIT_DIFF_OUTPUT="src/foo.sh" \
        GIT_COMMIT_EXIT_CODE=0 GIT_PUSH_EXIT_CODE=1 \
        GIT_SHA_OUTPUT="aabbccdd1122" \
        STUB_COMMENTS_JSON="$_ACCEPT_FIXTURE_COMMENTS" \
        PATH="$stub_dir:$PATH" GITHUB_TOKEN="FAKE" \
        bash "$SCRIPT" --pr-number 42 --output "$out_json" --classify-as "comment-100:accept" 2>/dev/null || true

    # git revert should have been called
    local git_calls; git_calls=$(cat "$git_log" 2>/dev/null || echo "")
    assert_contains "git revert should have been called on push failure" "revert" "$git_calls"

    # No POST reply should have been made with the SHA
    local post_calls
    post_calls=$(grep $'\tPOST\t' "$gh_log" 2>/dev/null || echo "")
    assert_eq "no POST reply should be made when push fails" "" "$post_calls"

    assert_pass_if_clean "test_accept_reverts_on_non_fast_forward_push"
}

# ---------------------------------------------------------------------------
# TEST 4: Multi-file staged scope — no commit, no reply
# Given:  git diff --cached --name-only returns 2 files
# When:   accept handler runs
# Then:   git commit NOT called; no reply with SHA posted
# ---------------------------------------------------------------------------
test_accept_rejects_multi_file_scope() {
    _snapshot_fail
    echo ""
    echo "=== test_accept_rejects_multi_file_scope ==="

    local stub_dir; stub_dir=$(_make_stub_dir)
    local out_json; out_json=$(mktemp "/tmp/dso-accept-out.XXXXXX")
    _cleanup_dirs+=("$out_json")
    local gh_log; gh_log=$(mktemp "/tmp/dso-accept-gh.XXXXXX")
    _cleanup_dirs+=("$gh_log")
    local git_log; git_log=$(mktemp "/tmp/dso-accept-git.XXXXXX")
    _cleanup_dirs+=("$git_log")

    _make_accept_json > "$out_json"

    # Two staged files
    GH_CALL_LOG="$gh_log" GIT_CALL_LOG="$git_log" \
        GIT_DIFF_OUTPUT="$(printf 'src/foo.sh\nsrc/bar.sh')" \
        GIT_COMMIT_EXIT_CODE=0 GIT_PUSH_EXIT_CODE=0 \
        GIT_SHA_OUTPUT="11223344aabb" \
        STUB_COMMENTS_JSON="$_ACCEPT_FIXTURE_COMMENTS" \
        PATH="$stub_dir:$PATH" GITHUB_TOKEN="FAKE" \
        bash "$SCRIPT" --pr-number 42 --output "$out_json" --classify-as "comment-100:accept" 2>/dev/null || true

    # git commit should NOT have been called
    local git_calls; git_calls=$(cat "$git_log" 2>/dev/null || echo "")
    assert_not_contains "git commit should NOT be called for multi-file scope" "commit" "$git_calls"

    # No POST reply should have been made
    local post_calls
    post_calls=$(grep $'\tPOST\t' "$gh_log" 2>/dev/null || echo "")
    assert_eq "no POST reply should be made when scope is multi-file" "" "$post_calls"

    assert_pass_if_clean "test_accept_rejects_multi_file_scope"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_accept_commits_and_replies_with_sha
test_accept_reply_body_contains_sentinel_and_sha
test_accept_reverts_on_non_fast_forward_push
test_accept_rejects_multi_file_scope

print_summary
