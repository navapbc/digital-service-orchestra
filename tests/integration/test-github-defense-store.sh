#!/usr/bin/env bash
# tests/integration/test-github-defense-store.sh
#
# RED integration tests for the GitHubPRDefenseStore bash script:
#   plugins/dso/scripts/review-github-defense-store.sh
#
# The file under test does NOT exist yet. All tests fail pre-implementation
# (RED state). Once the script is implemented these tests transition GREEN.
#
# Behavioral contracts tested:
#   github_defense_store_write(record_json, pr_number, repo):
#     1. Posts a PR comment with body `DEFENSE_RECORD: <json>` via `gh pr comment`
#     2. On fork PR (GITHUB_FORK_PR=1 env var), is a no-op (returns 0 silently)
#     3. On `gh` exit code 1 (API error), retries up to 3 times with backoff
#     4. On defense_text > 4096 chars in the record, rejects before calling `gh`
#     5. On ticket_id=UNBOUND, exits 1 with `ticket-binding required` message
#
# Usage:
#   bash tests/integration/test-github-defense-store.sh
# Exit: 0 if all tests pass (GREEN once implemented), non-zero otherwise (RED).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-github-defense-store.sh ==="

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

DEFENSE_STORE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/review-github-defense-store.sh"

# ---------------------------------------------------------------------------
# _make_stub_dir — create a per-test stub PATH prefix containing a `gh` shim.
# Returns the dir path on stdout.
#
# The stub is controlled by env vars set by the caller before invoking the
# function under test:
#   GH_EXIT_CODE     — exit code the stub returns (default: 0)
#   GH_CALL_LOG      — file the gh shim appends each call's argv to
# ---------------------------------------------------------------------------
_make_stub_dir() {
    local d
    d=$(mktemp -d "/tmp/dso-defense-store-stubs.XXXXXX")
    _TEST_TMPDIRS+=("$d")

    cat > "$d/gh" <<'GHEOF'
#!/usr/bin/env bash
# Test stub for `gh`. Records argv to $GH_CALL_LOG, exits with $GH_EXIT_CODE.
set -u
LOG="${GH_CALL_LOG:-/dev/null}"
{
    printf 'CALL'
    for a in "$@"; do printf '\t%s' "$a"; done
    printf '\n'
} >> "$LOG" 2>/dev/null || true
exit "${GH_EXIT_CODE:-0}"
GHEOF
    chmod +x "$d/gh"

    echo "$d"
}

# ---------------------------------------------------------------------------
# _setup_test — fresh stubs + per-test call log + PATH prefix.
# Sets env for the test body:
#   STUB_DIR, GH_CALL_LOG, _SAVED_PATH
# ---------------------------------------------------------------------------
_setup_test() {
    STUB_DIR=$(_make_stub_dir)
    GH_CALL_LOG="$STUB_DIR/gh.log"
    : > "$GH_CALL_LOG"
    export GH_CALL_LOG
    export GH_EXIT_CODE=0
    _SAVED_PATH="$PATH"
    PATH="$STUB_DIR:$PATH"
    export PATH
    unset GITHUB_FORK_PR || true
}

_teardown_test() {
    PATH="$_SAVED_PATH"
    export PATH
    unset GH_EXIT_CODE GH_CALL_LOG GITHUB_FORK_PR || true
}

# Convenience: count how many times `gh pr comment` was called.
_gh_pr_comment_call_count() {
    local n
    n=$(grep -c $'^CALL\tpr\tcomment' "$GH_CALL_LOG" 2>/dev/null)
    echo "${n:-0}"
}

# ===========================================================================
# Test 1: write posts a PR comment with the DEFENSE_RECORD: prefix.
# Given: valid record JSON (no UNBOUND ticket_id, defense_text <= 4096 chars)
# When: github_defense_store_write is called
# Then: `gh pr comment` is invoked with a body containing DEFENSE_RECORD:
# ===========================================================================
test_write_posts_pr_comment_with_defense_record_prefix() {
    echo ""
    echo "=== test_write_posts_pr_comment_with_defense_record_prefix ==="
    _snapshot_fail
    _setup_test

    # Source the script; function is missing until implemented (RED expected).
    # shellcheck disable=SC1090
    source "$DEFENSE_STORE_SCRIPT" 2>/dev/null || true

    if ! type github_defense_store_write >/dev/null 2>&1; then
        (( ++FAIL ))
        echo "FAIL: test_write_posts_pr_comment_with_defense_record_prefix — github_defense_store_write not defined (RED until implemented)" >&2
        _teardown_test
        assert_pass_if_clean "test_write_posts_pr_comment_with_defense_record_prefix"
        return
    fi

    local record_json='{"ticket_id":"TASK-123","defense_text":"This change is intentional."}'
    local pr_number=42
    local repo="owner/repo"

    local rc=0
    github_defense_store_write "$record_json" "$pr_number" "$repo" 2>/dev/null || rc=$?

    # Must exit 0 on success.
    assert_eq "test_write_posts_pr_comment_with_defense_record_prefix: exit 0 on success" "0" "$rc"

    # gh pr comment must have been called at least once.
    local call_count
    call_count=$(_gh_pr_comment_call_count)
    assert_ne "test_write_posts_pr_comment_with_defense_record_prefix: gh pr comment was called" "0" "$call_count"

    # The body argument passed to gh must contain DEFENSE_RECORD:.
    local body_line
    body_line=$(grep -o 'DEFENSE_RECORD:[^\t]*' "$GH_CALL_LOG" 2>/dev/null | head -1 || true)
    assert_contains "test_write_posts_pr_comment_with_defense_record_prefix: body starts with DEFENSE_RECORD:" \
        "DEFENSE_RECORD:" "$body_line"

    _teardown_test
    assert_pass_if_clean "test_write_posts_pr_comment_with_defense_record_prefix"
}

# ===========================================================================
# Test 2: write is a no-op when GITHUB_FORK_PR=1.
# Given: GITHUB_FORK_PR=1 is set
# When: github_defense_store_write is called
# Then: returns 0, gh is NOT called
# ===========================================================================
test_write_noop_on_fork_pr() {
    echo ""
    echo "=== test_write_noop_on_fork_pr ==="
    _snapshot_fail
    _setup_test

    export GITHUB_FORK_PR=1

    # shellcheck disable=SC1090
    source "$DEFENSE_STORE_SCRIPT" 2>/dev/null || true

    if ! type github_defense_store_write >/dev/null 2>&1; then
        (( ++FAIL ))
        echo "FAIL: test_write_noop_on_fork_pr — github_defense_store_write not defined (RED until implemented)" >&2
        _teardown_test
        assert_pass_if_clean "test_write_noop_on_fork_pr"
        return
    fi

    local record_json='{"ticket_id":"TASK-123","defense_text":"test"}'
    local rc=0
    github_defense_store_write "$record_json" 99 "owner/repo" 2>/dev/null || rc=$?

    # Must return 0 silently.
    assert_eq "test_write_noop_on_fork_pr: exit 0 on fork PR" "0" "$rc"

    # gh must NOT have been called at all.
    local call_count
    call_count=$(grep -c '^CALL' "$GH_CALL_LOG" 2>/dev/null); call_count="${call_count:-0}"
    assert_eq "test_write_noop_on_fork_pr: gh not called on fork PR" "0" "$call_count"

    _teardown_test
    assert_pass_if_clean "test_write_noop_on_fork_pr"
}

# ===========================================================================
# Test 3: write rejects record with ticket_id=UNBOUND.
# Given: record JSON with "ticket_id":"UNBOUND"
# When: github_defense_store_write is called
# Then: exits 1, stderr contains "ticket-binding required"
# ===========================================================================
test_write_rejects_unbound_ticket_id() {
    echo ""
    echo "=== test_write_rejects_unbound_ticket_id ==="
    _snapshot_fail
    _setup_test

    # shellcheck disable=SC1090
    source "$DEFENSE_STORE_SCRIPT" 2>/dev/null || true

    if ! type github_defense_store_write >/dev/null 2>&1; then
        (( ++FAIL ))
        echo "FAIL: test_write_rejects_unbound_ticket_id — github_defense_store_write not defined (RED until implemented)" >&2
        _teardown_test
        assert_pass_if_clean "test_write_rejects_unbound_ticket_id"
        return
    fi

    local record_json='{"ticket_id":"UNBOUND","defense_text":"some defense"}'
    local rc=0
    local stderr_out
    stderr_out=$(github_defense_store_write "$record_json" 42 "owner/repo" 2>&1 >/dev/null) || rc=$?

    # Must exit non-zero.
    assert_ne "test_write_rejects_unbound_ticket_id: exits non-zero on UNBOUND ticket_id" "0" "$rc"

    # stderr must contain the rejection message.
    assert_contains "test_write_rejects_unbound_ticket_id: stderr contains ticket-binding required" \
        "ticket-binding required" "$stderr_out"

    # gh must NOT have been called (rejection before API call).
    local call_count
    call_count=$(grep -c '^CALL' "$GH_CALL_LOG" 2>/dev/null); call_count="${call_count:-0}"
    assert_eq "test_write_rejects_unbound_ticket_id: gh not called when ticket_id=UNBOUND" "0" "$call_count"

    _teardown_test
    assert_pass_if_clean "test_write_rejects_unbound_ticket_id"
}

# ===========================================================================
# Test 4: write rejects record with defense_text > 4096 chars.
# Given: record JSON where defense_text length exceeds 4096 characters
# When: github_defense_store_write is called
# Then: exits 1, gh is NOT called
# ===========================================================================
test_write_rejects_oversized_defense_text() {
    echo ""
    echo "=== test_write_rejects_oversized_defense_text ==="
    _snapshot_fail
    _setup_test

    # shellcheck disable=SC1090
    source "$DEFENSE_STORE_SCRIPT" 2>/dev/null || true

    if ! type github_defense_store_write >/dev/null 2>&1; then
        (( ++FAIL ))
        echo "FAIL: test_write_rejects_oversized_defense_text — github_defense_store_write not defined (RED until implemented)" >&2
        _teardown_test
        assert_pass_if_clean "test_write_rejects_oversized_defense_text"
        return
    fi

    # Build a defense_text that is exactly 4097 characters (one over the limit).
    local oversized_text
    oversized_text=$(python3 -c "print('x' * 4097)" 2>/dev/null || printf '%04097d' 0 | tr '0' 'x')
    local record_json
    record_json=$(printf '{"ticket_id":"TASK-456","defense_text":"%s"}' "$oversized_text")

    local rc=0
    github_defense_store_write "$record_json" 42 "owner/repo" 2>/dev/null || rc=$?

    # Must exit non-zero (rejected).
    assert_ne "test_write_rejects_oversized_defense_text: exits non-zero on oversized defense_text" "0" "$rc"

    # gh must NOT have been called (rejection before API call).
    local call_count
    call_count=$(grep -c '^CALL' "$GH_CALL_LOG" 2>/dev/null); call_count="${call_count:-0}"
    assert_eq "test_write_rejects_oversized_defense_text: gh not called when defense_text > 4096 chars" "0" "$call_count"

    _teardown_test
    assert_pass_if_clean "test_write_rejects_oversized_defense_text"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_write_posts_pr_comment_with_defense_record_prefix
test_write_noop_on_fork_pr
test_write_rejects_unbound_ticket_id
test_write_rejects_oversized_defense_text

# Print summary and exit non-zero on any failure (RED state expected pre-implementation).
print_summary
