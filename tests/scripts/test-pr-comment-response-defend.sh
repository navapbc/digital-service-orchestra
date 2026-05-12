#!/usr/bin/env bash
# tests/scripts/test-pr-comment-response-defend.sh — Unit tests for _handle_defend()
#
# Behavioral contracts:
#   1. Posts PR review comment (inline endpoint) and writes defense_comment_id to JSON
#   2. Top-level comments use the issues endpoint instead of inline endpoint
#   3. On retry (defense_comment_id already set), skips review comment POST
#   4. 422 fallback: if inline endpoint fails, falls back to issues endpoint
#   5. Thread reply body includes <!-- dso-agent-reply --> sentinel and defense_comment_id
#
# Usage:
#   bash tests/scripts/test-pr-comment-response-defend.sh
#
# shellcheck disable=SC2016,SC2155

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/plugins/dso/scripts/pr-comment-response.sh"

echo "=== test-pr-comment-response-defend.sh ==="

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

# Fixture: a single defend comment, is_inline=true
_DEFEND_FIXTURE_COMMENTS_INLINE='[
  {
    "comment_id": "comment-200",
    "in_reply_to_id": null,
    "body": "This design decision is well thought out for performance reasons.",
    "author": "agent-bot",
    "is_inline": true,
    "path": "src/main.sh",
    "position": 5
  }
]'

# Fixture: a single defend comment, is_inline=false
_DEFEND_FIXTURE_COMMENTS_TOPLEVEL='[
  {
    "comment_id": "comment-200",
    "in_reply_to_id": null,
    "body": "This design decision is well thought out for performance reasons.",
    "author": "agent-bot",
    "is_inline": false,
    "path": null,
    "position": null
  }
]'

# Build a stub directory with gh stub that handles two POST calls:
#   1. POST to create defense review comment (returns {"id": 9001})
#   2. POST to post thread reply (via post_thread_reply)
# The stub records ALL calls to GH_CALL_LOG.
# GH_INLINE_FAIL=1 causes the inline (pulls/comments/*/replies) POST to fail.
_make_stub_dir() {
    local stub_dir
    stub_dir=$(mktemp -d "/tmp/dso-defend-stubs.XXXXXX")
    _cleanup_dirs+=("$stub_dir")

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

# Detect call type
method=""
is_pulls_fetch=false
is_issues_fetch=false
is_post=false
is_inline_reply=false
is_issues_post=false

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
    # Inline reply endpoint: pulls/{N}/comments/{id}/replies
    if [[ "$a" == *"/pulls/"*"/comments/"*"/replies"* ]]; then
        is_inline_reply=true
    fi
    # Issues POST endpoint
    if [[ "$a" == *"/issues/"*"/comments"* && "$method" == "POST" ]]; then
        is_issues_post=true
    fi
done

if [[ "$is_post" == true ]]; then
    # Check if this is the inline reply endpoint and we should simulate 422
    if [[ "$is_inline_reply" == true && "${GH_INLINE_FAIL:-0}" == "1" ]]; then
        echo '{"message": "Unprocessable Entity"}' >&2
        exit 1
    fi
    # Return defense comment id for POST calls
    printf '{"id": 9001}\n'
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

    echo "$stub_dir"
}

# Create normalized JSON for an inline defend comment (comment-200)
_make_defend_json_inline() {
    local def_id="${1:-null}"
    cat << JSON
{
  "comments": [
    {
      "comment_id": "comment-200",
      "root_comment_id": "comment-200",
      "thread_url": "https://github.com/test/repo/pull/42",
      "body": "This design decision is well thought out for performance reasons.",
      "author": "agent-bot",
      "is_inline": true,
      "already_replied": false,
      "defense_comment_id": ${def_id},
      "path": "src/main.sh",
      "position": 5,
      "ticket_id": null
    }
  ],
  "skipped_count": 0
}
JSON
}

# Create normalized JSON for a top-level defend comment (is_inline=false)
_make_defend_json_toplevel() {
    local def_id="${1:-null}"
    cat << JSON
{
  "comments": [
    {
      "comment_id": "comment-200",
      "root_comment_id": "comment-200",
      "thread_url": "https://github.com/test/repo/pull/42",
      "body": "This design decision is well thought out for performance reasons.",
      "author": "agent-bot",
      "is_inline": false,
      "already_replied": false,
      "defense_comment_id": ${def_id},
      "path": null,
      "position": null,
      "ticket_id": null
    }
  ],
  "skipped_count": 0
}
JSON
}

# ---------------------------------------------------------------------------
# TEST 1: Posts review comment (inline endpoint) and writes defense_comment_id
# Given:  JSON with comment-200 (defend, is_inline=true, root_comment_id=comment-200)
#         gh stub returns {"id":9001} for the POST call
# When:   pr-comment-response.sh --classify-as "comment-200:defend"
# Then:   defense_comment_id in output JSON equals "9001"; gh was called with
#         POST to pulls path
# ---------------------------------------------------------------------------
test_defend_posts_review_comment_and_writes_defense_comment_id() {
    _snapshot_fail
    echo ""
    echo "=== test_defend_posts_review_comment_and_writes_defense_comment_id ==="

    local stub_dir; stub_dir=$(_make_stub_dir)
    local out_json; out_json=$(mktemp "/tmp/dso-defend-out.XXXXXX")
    _cleanup_dirs+=("$out_json")
    local gh_log; gh_log=$(mktemp "/tmp/dso-defend-gh.XXXXXX")
    _cleanup_dirs+=("$gh_log")

    _make_defend_json_inline null > "$out_json"

    GH_CALL_LOG="$gh_log" \
        STUB_COMMENTS_JSON="$_DEFEND_FIXTURE_COMMENTS_INLINE" \
        PATH="$stub_dir:$PATH" GITHUB_TOKEN="FAKE" \
        bash "$SCRIPT" --pr-number 42 --output "$out_json" --classify-as "comment-200:defend" 2>/dev/null || true

    # defense_comment_id must be written to JSON
    local def_id
    def_id=$(python3 -c "
import json, sys
d = json.load(open('$out_json'))
for c in d.get('comments', []):
    if c.get('comment_id') == 'comment-200':
        print(str(c.get('defense_comment_id') or ''))
        sys.exit(0)
print('')
" 2>/dev/null || echo "")

    assert_eq "defense_comment_id should be written to JSON as 9001" "9001" "$def_id"

    # gh should have been called with POST to pulls path
    local gh_calls; gh_calls=$(cat "$gh_log" 2>/dev/null || echo "")
    assert_contains "gh should be called with POST to pulls path" "pulls" "$gh_calls"

    assert_pass_if_clean "test_defend_posts_review_comment_and_writes_defense_comment_id"
}

# ---------------------------------------------------------------------------
# TEST 2: Top-level comment uses issues endpoint (not pulls)
# Given:  JSON with comment-200 where is_inline=false
# When:   handler runs
# Then:   gh was called with POST to .../issues/{PR}/comments (NOT pulls);
#         defense_comment_id written
# ---------------------------------------------------------------------------
test_defend_top_level_uses_issues_endpoint() {
    _snapshot_fail
    echo ""
    echo "=== test_defend_top_level_uses_issues_endpoint ==="

    local stub_dir; stub_dir=$(_make_stub_dir)
    local out_json; out_json=$(mktemp "/tmp/dso-defend-out.XXXXXX")
    _cleanup_dirs+=("$out_json")
    local gh_log; gh_log=$(mktemp "/tmp/dso-defend-gh.XXXXXX")
    _cleanup_dirs+=("$gh_log")

    _make_defend_json_toplevel null > "$out_json"

    GH_CALL_LOG="$gh_log" \
        STUB_COMMENTS_JSON="$_DEFEND_FIXTURE_COMMENTS_TOPLEVEL" \
        PATH="$stub_dir:$PATH" GITHUB_TOKEN="FAKE" \
        bash "$SCRIPT" --pr-number 42 --output "$out_json" --classify-as "comment-200:defend" 2>/dev/null || true

    # gh calls should reference issues endpoint for the defense comment POST
    local gh_calls; gh_calls=$(cat "$gh_log" 2>/dev/null || echo "")

    # Filter to only POST calls
    local post_calls
    post_calls=$(grep $'\tPOST\t' "$gh_log" 2>/dev/null || echo "")
    assert_contains "POST should go to issues endpoint" "issues" "$post_calls"

    # defense_comment_id must be written
    local def_id
    def_id=$(python3 -c "
import json, sys
d = json.load(open('$out_json'))
for c in d.get('comments', []):
    if c.get('comment_id') == 'comment-200':
        print(str(c.get('defense_comment_id') or ''))
        sys.exit(0)
print('')
" 2>/dev/null || echo "")

    assert_ne "defense_comment_id should be written (non-empty)" "" "$def_id"

    assert_pass_if_clean "test_defend_top_level_uses_issues_endpoint"
}

# ---------------------------------------------------------------------------
# TEST 3: Retry — skips review comment POST when defense_comment_id already set
# Given:  JSON where comment-200 already has defense_comment_id: "existing-9001"
# When:   handler runs
# Then:   gh NOT called for a NEW review comment POST (only reply call);
#         defense_comment_id still "existing-9001"
# ---------------------------------------------------------------------------
test_defend_retry_skips_review_comment_when_defense_id_present() {
    _snapshot_fail
    echo ""
    echo "=== test_defend_retry_skips_review_comment_when_defense_id_present ==="

    local stub_dir; stub_dir=$(_make_stub_dir)
    local out_json; out_json=$(mktemp "/tmp/dso-defend-out.XXXXXX")
    _cleanup_dirs+=("$out_json")
    local gh_log; gh_log=$(mktemp "/tmp/dso-defend-gh.XXXXXX")
    _cleanup_dirs+=("$gh_log")

    # Pre-populate defense_comment_id (retry case)
    _make_defend_json_inline '"existing-9001"' > "$out_json"

    GH_CALL_LOG="$gh_log" \
        STUB_COMMENTS_JSON="$_DEFEND_FIXTURE_COMMENTS_INLINE" \
        PATH="$stub_dir:$PATH" GITHUB_TOKEN="FAKE" \
        bash "$SCRIPT" --pr-number 42 --output "$out_json" --classify-as "comment-200:defend" 2>/dev/null || true

    # defense_comment_id should remain "existing-9001"
    local def_id_after
    def_id_after=$(python3 -c "
import json, sys
d = json.load(open('$out_json'))
for c in d.get('comments', []):
    if c.get('comment_id') == 'comment-200':
        print(str(c.get('defense_comment_id') or ''))
        sys.exit(0)
print('')
" 2>/dev/null || echo "")

    assert_eq "defense_comment_id should not change on retry" "existing-9001" "$def_id_after"

    # Should NOT have made a NEW POST to create a review comment
    # (only the thread reply POST is allowed)
    # Count POST calls to pulls/comments/*/replies (inline review endpoint for defense)
    local defense_posts
    defense_posts=$(grep $'\tPOST\t' "$gh_log" 2>/dev/null | grep "replies" | grep -v "dso-agent-reply" || echo "")
    assert_eq "no new defense comment POST should be made on retry" "" "$defense_posts"

    assert_pass_if_clean "test_defend_retry_skips_review_comment_when_defense_id_present"
}

# ---------------------------------------------------------------------------
# TEST 4: 422 fallback — if inline endpoint fails, falls back to issues endpoint
# Given:  gh stub exits 1 for inline (pulls/comments/*/replies) POST; is_inline=true
# When:   handler runs
# Then:   gh falls back to issues endpoint; defense_comment_id written; no failure
# ---------------------------------------------------------------------------
test_defend_422_fallback_uses_issues_endpoint() {
    _snapshot_fail
    echo ""
    echo "=== test_defend_422_fallback_uses_issues_endpoint ==="

    local stub_dir; stub_dir=$(_make_stub_dir)
    local out_json; out_json=$(mktemp "/tmp/dso-defend-out.XXXXXX")
    _cleanup_dirs+=("$out_json")
    local gh_log; gh_log=$(mktemp "/tmp/dso-defend-gh.XXXXXX")
    _cleanup_dirs+=("$gh_log")

    _make_defend_json_inline null > "$out_json"

    # GH_INLINE_FAIL=1 makes the inline endpoint fail
    GH_CALL_LOG="$gh_log" GH_INLINE_FAIL=1 \
        STUB_COMMENTS_JSON="$_DEFEND_FIXTURE_COMMENTS_INLINE" \
        PATH="$stub_dir:$PATH" GITHUB_TOKEN="FAKE" \
        bash "$SCRIPT" --pr-number 42 --output "$out_json" --classify-as "comment-200:defend" 2>/dev/null || true

    # Should have called issues endpoint as fallback
    local gh_calls; gh_calls=$(cat "$gh_log" 2>/dev/null || echo "")
    local issues_posts
    issues_posts=$(grep $'\tPOST\t' "$gh_log" 2>/dev/null | grep "issues" || echo "")
    assert_ne "should fall back to issues endpoint POST" "" "$issues_posts"

    # defense_comment_id must still be written
    local def_id
    def_id=$(python3 -c "
import json, sys
d = json.load(open('$out_json'))
for c in d.get('comments', []):
    if c.get('comment_id') == 'comment-200':
        print(str(c.get('defense_comment_id') or ''))
        sys.exit(0)
print('')
" 2>/dev/null || echo "")

    assert_ne "defense_comment_id should be written after fallback" "" "$def_id"

    assert_pass_if_clean "test_defend_422_fallback_uses_issues_endpoint"
}

# ---------------------------------------------------------------------------
# TEST 5: Thread reply body includes sentinel and defense_comment_id
# Given:  gh stub returns {"id":9001} for the review comment call; is_inline=true
# When:   handler runs end-to-end
# Then:   gh call log for the thread reply contains "<!-- dso-agent-reply -->"
#         and "9001"
# ---------------------------------------------------------------------------
test_defend_reply_body_includes_sentinel_and_defense_comment_id() {
    _snapshot_fail
    echo ""
    echo "=== test_defend_reply_body_includes_sentinel_and_defense_comment_id ==="

    local stub_dir; stub_dir=$(_make_stub_dir)
    local out_json; out_json=$(mktemp "/tmp/dso-defend-out.XXXXXX")
    _cleanup_dirs+=("$out_json")
    local gh_log; gh_log=$(mktemp "/tmp/dso-defend-gh.XXXXXX")
    _cleanup_dirs+=("$gh_log")

    _make_defend_json_inline null > "$out_json"

    GH_CALL_LOG="$gh_log" \
        STUB_COMMENTS_JSON="$_DEFEND_FIXTURE_COMMENTS_INLINE" \
        PATH="$stub_dir:$PATH" GITHUB_TOKEN="FAKE" \
        bash "$SCRIPT" --pr-number 42 --output "$out_json" --classify-as "comment-200:defend" 2>/dev/null || true

    local gh_calls; gh_calls=$(cat "$gh_log" 2>/dev/null || echo "")
    assert_contains "reply body should contain sentinel" "dso-agent-reply" "$gh_calls"
    assert_contains "reply body should contain defense_comment_id" "9001" "$gh_calls"

    assert_pass_if_clean "test_defend_reply_body_includes_sentinel_and_defense_comment_id"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_defend_posts_review_comment_and_writes_defense_comment_id
test_defend_top_level_uses_issues_endpoint
test_defend_retry_skips_review_comment_when_defense_id_present
test_defend_422_fallback_uses_issues_endpoint
test_defend_reply_body_includes_sentinel_and_defense_comment_id

print_summary
