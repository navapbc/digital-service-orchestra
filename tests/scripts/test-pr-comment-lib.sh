#!/usr/bin/env bash
# tests/scripts/test-pr-comment-lib.sh
#
# RED unit tests for plugins/dso/scripts/lib/pr-comment-lib.sh
#
# Tests three behavioral contracts:
#   1. probe_mcp_server  — exits 0 when MCP tool responds; non-zero on failure
#   2. post_thread_reply — routes to pulls endpoint for is_inline=true;
#                          routes to issues endpoint for is_inline=false
#   3. resolve_root_comment_id — returns self when in_reply_to_id is null;
#                                walks chain to root for replies;
#                                terminates at max-depth on cycles
#
# All tests are RED: they FAIL because pr-comment-lib.sh does not exist yet.
# Once plugins/dso/scripts/lib/pr-comment-lib.sh is created (Task T2),
# these tests transition GREEN.
#
# Mock design:
#   A per-test temp dir prepended to PATH contains a gh stub recording
#   argv to $GH_CALL_LOG. GITHUB_TOKEN is set to a fake sentinel.
#
# Usage: bash tests/scripts/test-pr-comment-lib.sh
# Exit:  0 if all tests pass, non-zero if any fail
#
# shellcheck disable=SC2155

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

LIB_SCRIPT="$REPO_ROOT/plugins/dso/scripts/lib/pr-comment-lib.sh"

echo "=== test-pr-comment-lib.sh ==="
echo ""

# ---------------------------------------------------------------------------
# Shared setup / teardown
# ---------------------------------------------------------------------------
_TEST_TMPDIRS=()
_cleanup() {
    local d
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "${d:-}" && -d "$d" ]] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# Create a temp dir with a mock gh stub and prepend to PATH for one test.
# Sets GH_CALL_LOG env var pointing to the call log file.
# Args: $1=stub behaviour ("mcp_ok"|"mcp_fail"|"inline_reply"|"toplevel_reply"|"rate_limit")
_setup_mock_env() {
    local scenario="${1:-mcp_ok}"
    local tmpdir
    tmpdir=$(mktemp -d /tmp/pr-comment-lib-test.XXXXXX)
    _TEST_TMPDIRS+=("$tmpdir")

    export GH_CALL_LOG="$tmpdir/gh-calls.log"
    export STUB_GH_SCENARIO="$scenario"
    export GITHUB_TOKEN="FAKE_TOKEN_SENTINEL_DO_NOT_USE"

    # Write the gh stub
    cat > "$tmpdir/gh" << 'STUB'
#!/usr/bin/env bash
# gh stub — records all calls to $GH_CALL_LOG, emits canned JSON
echo "$*" >> "${GH_CALL_LOG:-/dev/null}"

scenario="${STUB_GH_SCENARIO:-mcp_ok}"
exit_code="${GH_EXIT_CODE:-0}"

case "$scenario" in
  mcp_ok)
    echo '{"data": {"repository": {"pullRequests": {"nodes": []}}}}'
    ;;
  mcp_fail)
    echo 'ERROR: tool not found' >&2
    exit 1
    ;;
  inline_reply)
    echo '{"id": "reply-999", "html_url": "https://github.com/org/repo/pull/42#discussion_r999"}'
    ;;
  toplevel_reply)
    echo '{"id": "comment-888"}'
    ;;
  rate_limit)
    echo 'rate limit exceeded' >&2
    exit 1
    ;;
  api_ok)
    echo '{"id": "comment-ok"}'
    ;;
esac
exit "${exit_code}"
STUB
    chmod +x "$tmpdir/gh"

    # Prepend stub dir to PATH so our gh overrides the real one
    export PATH="$tmpdir:$PATH"
}

# ---------------------------------------------------------------------------
# test_probe_mcp_exits_0_on_success
# ---------------------------------------------------------------------------
test_probe_mcp_server_exits_0_on_success() {
    echo "--- test_probe_mcp_server_exits_0_on_success ---"
    _snapshot_fail

    if [[ ! -f "$LIB_SCRIPT" ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-lib.sh missing — test is RED (source not yet implemented)" >&2
        assert_pass_if_clean "test_probe_mcp_server_exits_0_on_success"
        return
    fi

    _setup_mock_env "mcp_ok"
    # shellcheck source=/dev/null
    source "$LIB_SCRIPT"

    local rc=0
    probe_mcp_server 42 || rc=$?
    assert_eq "probe_mcp_server exits 0 when MCP responds" "0" "$rc"

    assert_pass_if_clean "test_probe_mcp_server_exits_0_on_success"
}

# ---------------------------------------------------------------------------
# test_probe_mcp_server_exits_nonzero_on_failure
# ---------------------------------------------------------------------------
test_probe_mcp_server_exits_nonzero_on_failure() {
    echo "--- test_probe_mcp_server_exits_nonzero_on_failure ---"
    _snapshot_fail

    if [[ ! -f "$LIB_SCRIPT" ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-lib.sh missing — test is RED (source not yet implemented)" >&2
        assert_pass_if_clean "test_probe_mcp_server_exits_nonzero_on_failure"
        return
    fi

    _setup_mock_env "mcp_fail"
    # shellcheck source=/dev/null
    source "$LIB_SCRIPT"

    local rc=0
    probe_mcp_server 42 || rc=$?
    assert_ne "probe_mcp_server exits non-zero when tool-not-found" "0" "$rc"

    assert_pass_if_clean "test_probe_mcp_server_exits_nonzero_on_failure"
}

# ---------------------------------------------------------------------------
# test_post_thread_reply_routes_to_pulls_endpoint_for_inline
# ---------------------------------------------------------------------------
test_post_thread_reply_routes_to_pulls_endpoint_for_inline() {
    echo "--- test_post_thread_reply_routes_to_pulls_endpoint_for_inline ---"
    _snapshot_fail

    if [[ ! -f "$LIB_SCRIPT" ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-lib.sh missing — test is RED (source not yet implemented)" >&2
        assert_pass_if_clean "test_post_thread_reply_routes_to_pulls_endpoint_for_inline"
        return
    fi

    _setup_mock_env "inline_reply"
    # shellcheck source=/dev/null
    source "$LIB_SCRIPT"

    local rc=0
    post_thread_reply "42" "comment-100" "Test reply body" "true" || rc=$?
    assert_eq "post_thread_reply exits 0 for inline comment" "0" "$rc"

    # Verify the gh call used the pulls/comments/.../replies endpoint
    local gh_calls
    gh_calls=$(cat "${GH_CALL_LOG:-/dev/null}" 2>/dev/null || echo "")
    assert_contains "inline reply uses pulls endpoint" "pulls" "$gh_calls"
    assert_contains "inline reply includes root_comment_id in path" "comment-100" "$gh_calls"

    assert_pass_if_clean "test_post_thread_reply_routes_to_pulls_endpoint_for_inline"
}

# ---------------------------------------------------------------------------
# test_post_thread_reply_routes_to_issues_endpoint_for_toplevel
# ---------------------------------------------------------------------------
test_post_thread_reply_routes_to_issues_endpoint_for_toplevel() {
    echo "--- test_post_thread_reply_routes_to_issues_endpoint_for_toplevel ---"
    _snapshot_fail

    if [[ ! -f "$LIB_SCRIPT" ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-lib.sh missing — test is RED (source not yet implemented)" >&2
        assert_pass_if_clean "test_post_thread_reply_routes_to_issues_endpoint_for_toplevel"
        return
    fi

    _setup_mock_env "toplevel_reply"
    # shellcheck source=/dev/null
    source "$LIB_SCRIPT"

    local rc=0
    post_thread_reply "42" "comment-200" "Test top-level reply" "false" || rc=$?
    assert_eq "post_thread_reply exits 0 for top-level comment" "0" "$rc"

    # Verify the gh call used the issues/comments endpoint
    local gh_calls
    gh_calls=$(cat "${GH_CALL_LOG:-/dev/null}" 2>/dev/null || echo "")
    assert_contains "top-level reply uses issues endpoint" "issues" "$gh_calls"

    assert_pass_if_clean "test_post_thread_reply_routes_to_issues_endpoint_for_toplevel"
}

# ---------------------------------------------------------------------------
# test_resolve_root_comment_id_returns_self_when_no_parent
# ---------------------------------------------------------------------------
test_resolve_root_comment_id_returns_self_when_no_parent() {
    echo "--- test_resolve_root_comment_id_returns_self_when_no_parent ---"
    _snapshot_fail

    if [[ ! -f "$LIB_SCRIPT" ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-lib.sh missing — test is RED (source not yet implemented)" >&2
        assert_pass_if_clean "test_resolve_root_comment_id_returns_self_when_no_parent"
        return
    fi

    # shellcheck source=/dev/null
    source "$LIB_SCRIPT"

    # Fixture: single comment with no parent
    local comments_json='[{"comment_id":"comment-100","in_reply_to_id":null}]'
    local result
    result=$(resolve_root_comment_id "comment-100" "$comments_json")
    assert_eq "root of non-reply is itself" "comment-100" "$result"

    assert_pass_if_clean "test_resolve_root_comment_id_returns_self_when_no_parent"
}

# ---------------------------------------------------------------------------
# test_resolve_root_comment_id_walks_chain_to_root
# ---------------------------------------------------------------------------
test_resolve_root_comment_id_walks_chain_to_root() {
    echo "--- test_resolve_root_comment_id_walks_chain_to_root ---"
    _snapshot_fail

    if [[ ! -f "$LIB_SCRIPT" ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-lib.sh missing — test is RED (source not yet implemented)" >&2
        assert_pass_if_clean "test_resolve_root_comment_id_walks_chain_to_root"
        return
    fi

    # shellcheck source=/dev/null
    source "$LIB_SCRIPT"

    # Fixture: comment-301 replies to comment-300 (which has no parent)
    # root_comment_id of comment-301 must be comment-300
    local comments_json='[
      {"comment_id":"comment-300","in_reply_to_id":null},
      {"comment_id":"comment-301","in_reply_to_id":"comment-300"}
    ]'
    local result
    result=$(resolve_root_comment_id "comment-301" "$comments_json")
    assert_eq "chain-walk resolves reply to root" "comment-300" "$result"

    assert_pass_if_clean "test_resolve_root_comment_id_walks_chain_to_root"
}

# ---------------------------------------------------------------------------
# test_resolve_root_comment_id_terminates_on_cycle
# ---------------------------------------------------------------------------
test_resolve_root_comment_id_terminates_on_cycle() {
    echo "--- test_resolve_root_comment_id_terminates_on_cycle ---"
    _snapshot_fail

    if [[ ! -f "$LIB_SCRIPT" ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-lib.sh missing — test is RED (source not yet implemented)" >&2
        assert_pass_if_clean "test_resolve_root_comment_id_terminates_on_cycle"
        return
    fi

    # shellcheck source=/dev/null
    source "$LIB_SCRIPT"

    # Malformed fixture: A → B → A (circular)
    local comments_json='[
      {"comment_id":"comment-A","in_reply_to_id":"comment-B"},
      {"comment_id":"comment-B","in_reply_to_id":"comment-A"}
    ]'

    # Must terminate within a finite time (not hang forever)
    local rc=0
    local result
    result=$(timeout 5 bash -c "
        source '$LIB_SCRIPT'
        resolve_root_comment_id 'comment-A' '$comments_json'
    ") || rc=$?

    # As long as it terminates (not timeout rc=124) the cycle guard works
    assert_ne "cycle detection terminates (not timeout)" "124" "$rc"

    assert_pass_if_clean "test_resolve_root_comment_id_terminates_on_cycle"
}

# ---------------------------------------------------------------------------
# test_token_never_appears_in_probe_output
# ---------------------------------------------------------------------------
test_token_never_appears_in_probe_output() {
    echo "--- test_token_never_appears_in_probe_output ---"
    _snapshot_fail

    if [[ ! -f "$LIB_SCRIPT" ]]; then
        (( ++FAIL ))
        echo "FAIL: pr-comment-lib.sh missing — test is RED (source not yet implemented)" >&2
        assert_pass_if_clean "test_token_never_appears_in_probe_output"
        return
    fi

    _setup_mock_env "mcp_fail"
    export GITHUB_TOKEN="UNIQUE_CANARY_TOKEN_XYZ987"
    # shellcheck source=/dev/null
    source "$LIB_SCRIPT"

    local combined_output
    combined_output=$(probe_mcp_server 42 2>&1 || true)

    # The canary token value must not appear in any output
    assert_ne "GITHUB_TOKEN not leaked in probe output" \
        "true" "$( [[ "$combined_output" == *"UNIQUE_CANARY_TOKEN_XYZ987"* ]] && echo true || echo false )"

    assert_pass_if_clean "test_token_never_appears_in_probe_output"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_probe_mcp_server_exits_0_on_success
test_probe_mcp_server_exits_nonzero_on_failure
test_post_thread_reply_routes_to_pulls_endpoint_for_inline
test_post_thread_reply_routes_to_issues_endpoint_for_toplevel
test_resolve_root_comment_id_returns_self_when_no_parent
test_resolve_root_comment_id_walks_chain_to_root
test_resolve_root_comment_id_terminates_on_cycle
test_token_never_appears_in_probe_output

print_summary
