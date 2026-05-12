#!/usr/bin/env bash
# tests/scripts/test-pr-comment-response.sh — Unit tests for _handle_defer()
#
# Behavioral contracts:
#   1. Creates DSO tracking ticket and writes ticket_id to JSON before posting reply
#   2. Reply body includes ticket ID and <!-- dso-agent-reply --> sentinel
#   3. On retry (ticket_id already present), skips ticket creation
#   4. Ticket creation failure prevents posting a reply
#
# Usage:
#   bash tests/scripts/test-pr-comment-response.sh
#
# shellcheck disable=SC2016,SC2155

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/plugins/dso/scripts/pr-comment-response.sh"

echo "=== test-pr-comment-response.sh ==="

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

# Fixture: a single defer comment with root_comment_id already resolved
# (simulates a pre-normalized JSON from a prior fetch-normalize pass)
_DEFER_FIXTURE_COMMENTS='[
  {
    "comment_id": "comment-301",
    "in_reply_to_id": "comment-300",
    "body": "This approach seems problematic for edge cases.",
    "author": "reviewer-bob",
    "is_inline": false,
    "path": null,
    "position": null,
    "url": "https://github.com/test/repo/pull/42#issuecomment-301"
  }
]'

_make_stub_dir() {
    local stub_dir
    stub_dir=$(mktemp -d "/tmp/dso-defer-stubs.XXXXXX")
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
    # Return the fixture comments (set via env var or default)
    printf '%s\n' "${STUB_COMMENTS_JSON:-[]}"
elif [[ "$is_issues_fetch" == true ]]; then
    printf '[]\n'
else
    printf '{}\n'
fi
exit "$exit_code"
GHEOF
    chmod +x "$stub_dir/gh"

    # dso stub — records calls, returns a fake ticket ID line
    cat > "$stub_dir/dso" << 'DSOEOF'
#!/usr/bin/env bash
LOG="${DSO_CALL_LOG:-/dev/null}"
{
    printf 'CALL'
    for a in "$@"; do printf '\t%s' "$a"; done
    printf '\n'
} >> "$LOG" 2>/dev/null || true
echo "${DSO_TICKET_OUTPUT:-Created ticket fake-ticket-abc: PR comment deferred}"
exit "${DSO_EXIT_CODE:-0}"
DSOEOF
    chmod +x "$stub_dir/dso"

    echo "$stub_dir"
}

_make_defer_json() {
    # Create a normalized JSON object with comment-301 (defer, is_inline=false)
    local ticket_id="${1:-null}"
    cat << JSON
{
  "comments": [
    {
      "comment_id": "comment-301",
      "root_comment_id": "comment-300",
      "thread_url": "https://github.com/test/repo/pull/42",
      "body": "This approach seems problematic for edge cases.",
      "author": "reviewer-bob",
      "is_inline": false,
      "already_replied": false,
      "defense_comment_id": null,
      "path": null,
      "position": null,
      "ticket_id": ${ticket_id}
    }
  ],
  "skipped_count": 0
}
JSON
}

# ---------------------------------------------------------------------------
# TEST 1: Creates tracking ticket and writes ticket_id to JSON before reply
# Given:  defer-classified comment with no existing ticket_id
# When:   script processes --classify-as comment-301:defer
# Then:   dso ticket create is called; ticket_id is written to JSON
# ---------------------------------------------------------------------------
test_defer_creates_ticket_and_writes_ticket_id_before_reply() {
    _snapshot_fail
    echo ""
    echo "=== test_defer_creates_ticket_and_writes_ticket_id_before_reply ==="

    local stub_dir; stub_dir=$(_make_stub_dir)
    local out_json; out_json=$(mktemp "/tmp/dso-defer-out.XXXXXX")
    _cleanup_dirs+=("$out_json")
    local gh_log; gh_log=$(mktemp "/tmp/dso-defer-gh.XXXXXX")
    _cleanup_dirs+=("$gh_log")
    local dso_log; dso_log=$(mktemp "/tmp/dso-defer-dso.XXXXXX")
    _cleanup_dirs+=("$dso_log")

    _make_defer_json null > "$out_json"

    GH_CALL_LOG="$gh_log" DSO_CALL_LOG="$dso_log" \
        DSO_TICKET_OUTPUT="Created ticket test-defer-001: PR comment deferred" \
        STUB_COMMENTS_JSON="$_DEFER_FIXTURE_COMMENTS" \
        PATH="$stub_dir:$PATH" GITHUB_TOKEN="FAKE" \
        bash "$SCRIPT" --pr-number 42 --output "$out_json" --classify-as "comment-301:defer" 2>/dev/null || true

    # ticket_id must be written to JSON
    local ticket_id
    ticket_id=$(python3 -c "
import json, sys
d = json.load(open('$out_json'))
for c in d.get('comments', []):
    if c.get('comment_id') == 'comment-301':
        print(c.get('ticket_id') or '')
        sys.exit(0)
print('')
" 2>/dev/null || echo "")

    assert_ne "ticket_id should be written to JSON (not empty)" "" "$ticket_id"

    # dso ticket create should have been called
    local dso_calls; dso_calls=$(cat "$dso_log" 2>/dev/null || echo "")
    assert_contains "dso ticket create should have been called" "ticket" "$dso_calls"

    assert_pass_if_clean "test_defer_creates_ticket_and_writes_ticket_id_before_reply"
}

# ---------------------------------------------------------------------------
# TEST 2: Reply body includes ticket ID and sentinel
# Given:  defer-classified comment processed with ticket creation returning test-defer-002
# When:   script posts a thread reply
# Then:   gh call log contains <!-- dso-agent-reply --> and the ticket ID
# ---------------------------------------------------------------------------
test_defer_reply_includes_ticket_id_and_sentinel() {
    _snapshot_fail
    echo ""
    echo "=== test_defer_reply_includes_ticket_id_and_sentinel ==="

    local stub_dir; stub_dir=$(_make_stub_dir)
    local out_json; out_json=$(mktemp "/tmp/dso-defer-out.XXXXXX")
    _cleanup_dirs+=("$out_json")
    local gh_log; gh_log=$(mktemp "/tmp/dso-defer-gh.XXXXXX")
    _cleanup_dirs+=("$gh_log")
    local dso_log; dso_log=$(mktemp "/tmp/dso-defer-dso.XXXXXX")
    _cleanup_dirs+=("$dso_log")

    _make_defer_json null > "$out_json"

    GH_CALL_LOG="$gh_log" DSO_CALL_LOG="$dso_log" \
        DSO_TICKET_OUTPUT="Created ticket test-defer-002: PR comment deferred" \
        STUB_COMMENTS_JSON="$_DEFER_FIXTURE_COMMENTS" \
        PATH="$stub_dir:$PATH" GITHUB_TOKEN="FAKE" \
        bash "$SCRIPT" --pr-number 42 --output "$out_json" --classify-as "comment-301:defer" 2>/dev/null || true

    local gh_calls; gh_calls=$(cat "$gh_log" 2>/dev/null || echo "")
    assert_contains "reply body should contain sentinel" "dso-agent-reply" "$gh_calls"
    assert_contains "reply body should contain ticket ID" "test-defer-002" "$gh_calls"

    assert_pass_if_clean "test_defer_reply_includes_ticket_id_and_sentinel"
}

# ---------------------------------------------------------------------------
# TEST 3: Retry — skips ticket creation when ticket_id already present
# Given:  normalized JSON has ticket_id="existing-ticket-abc" for comment-301
# When:   script processes --classify-as comment-301:defer
# Then:   dso is NOT called; ticket_id remains "existing-ticket-abc"
# ---------------------------------------------------------------------------
test_defer_retry_skips_ticket_creation_when_ticket_id_present() {
    _snapshot_fail
    echo ""
    echo "=== test_defer_retry_skips_ticket_creation_when_ticket_id_present ==="

    local stub_dir; stub_dir=$(_make_stub_dir)
    local out_json; out_json=$(mktemp "/tmp/dso-defer-out.XXXXXX")
    _cleanup_dirs+=("$out_json")
    local gh_log; gh_log=$(mktemp "/tmp/dso-defer-gh.XXXXXX")
    _cleanup_dirs+=("$gh_log")
    local dso_log; dso_log=$(mktemp "/tmp/dso-defer-dso.XXXXXX")
    _cleanup_dirs+=("$dso_log")

    # Pre-populate ticket_id (retry case)
    _make_defer_json '"existing-ticket-abc"' > "$out_json"

    GH_CALL_LOG="$gh_log" DSO_CALL_LOG="$dso_log" \
        STUB_COMMENTS_JSON="$_DEFER_FIXTURE_COMMENTS" \
        PATH="$stub_dir:$PATH" GITHUB_TOKEN="FAKE" \
        bash "$SCRIPT" --pr-number 42 --output "$out_json" --classify-as "comment-301:defer" 2>/dev/null || true

    # ticket_id should remain "existing-ticket-abc"
    local ticket_id_after
    ticket_id_after=$(python3 -c "
import json, sys
d = json.load(open('$out_json'))
for c in d.get('comments', []):
    if c.get('comment_id') == 'comment-301':
        print(c.get('ticket_id') or '')
        sys.exit(0)
print('')
" 2>/dev/null || echo "")

    assert_eq "ticket_id should not change on retry" "existing-ticket-abc" "$ticket_id_after"

    # dso should NOT have been called (log must be empty)
    local dso_calls; dso_calls=$(cat "$dso_log" 2>/dev/null || echo "")
    assert_eq "dso ticket create should not be called when ticket_id already set" "" "$dso_calls"

    assert_pass_if_clean "test_defer_retry_skips_ticket_creation_when_ticket_id_present"
}

# ---------------------------------------------------------------------------
# TEST 4: Ticket creation failure prevents posting a reply
# Given:  dso stub exits non-zero (simulates ticket creation failure)
# When:   script processes --classify-as comment-301:defer
# Then:   no gh reply call is posted (gh log has no reply-related calls)
# ---------------------------------------------------------------------------
test_defer_ticket_failure_prevents_reply() {
    _snapshot_fail
    echo ""
    echo "=== test_defer_ticket_failure_prevents_reply ==="

    local stub_dir; stub_dir=$(_make_stub_dir)
    local out_json; out_json=$(mktemp "/tmp/dso-defer-out.XXXXXX")
    _cleanup_dirs+=("$out_json")
    local gh_log; gh_log=$(mktemp "/tmp/dso-defer-gh.XXXXXX")
    _cleanup_dirs+=("$gh_log")
    local dso_log; dso_log=$(mktemp "/tmp/dso-defer-dso.XXXXXX")
    _cleanup_dirs+=("$dso_log")

    _make_defer_json null > "$out_json"

    # Make dso stub exit non-zero to simulate ticket creation failure
    GH_CALL_LOG="$gh_log" DSO_CALL_LOG="$dso_log" DSO_EXIT_CODE=1 \
        STUB_COMMENTS_JSON="$_DEFER_FIXTURE_COMMENTS" \
        PATH="$stub_dir:$PATH" GITHUB_TOKEN="FAKE" \
        bash "$SCRIPT" --pr-number 42 --output "$out_json" --classify-as "comment-301:defer" 2>/dev/null || true

    # Reply gh call should NOT have been made — check only for POST calls
    local post_calls
    post_calls=$(grep $'\tPOST\t' "$gh_log" 2>/dev/null || echo "")
    assert_eq "no POST reply should be made when ticket creation fails" "" "$post_calls"

    assert_pass_if_clean "test_defer_ticket_failure_prevents_reply"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_defer_creates_ticket_and_writes_ticket_id_before_reply
test_defer_reply_includes_ticket_id_and_sentinel
test_defer_retry_skips_ticket_creation_when_ticket_id_present
test_defer_ticket_failure_prevents_reply

print_summary
