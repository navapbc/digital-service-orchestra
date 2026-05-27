#!/usr/bin/env bash
# tests/scripts/test-verdict-hash-gate.sh
# Integration tests for the verdict hash closure gate.
#
# Covers:
#   1. compute-verdict-hash.sh produces a 64-char hex hash
#   2. Same inputs produce same hash (deterministic)
#   3. Different ticket IDs produce different hashes
#   4. Story closure without --verdict-hash is blocked
#   5. Story closure with correct --verdict-hash succeeds
#   6. Story closure with wrong --verdict-hash is blocked
#   7. Story closure with --force-close succeeds (bypasses hash)
#   8. Bug closure does not require --verdict-hash
#   9. Task closure does not require --verdict-hash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
HASH_SCRIPT="$REPO_ROOT/plugins/dso/scripts/compute-verdict-hash.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-verdict-hash-gate.sh ==="

_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

_create_ticket() {
    local repo="$1"
    local ticket_type="${2:-story}"
    local title="${3:-Test ticket}"
    local out
    out=$(cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" create "$ticket_type" "$title" 2>/dev/null) || true
    echo "$out" | tail -1
}

# ── Test 1: compute-verdict-hash produces 64-char hex ────────────────────────
echo "Test 1: compute-verdict-hash produces 64-char hex hash"
test_hash_format() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local hash
    hash=$(cd "$repo" && PROJECT_ROOT="$repo" bash "$HASH_SCRIPT" "test-ticket" "PASS" 2>/dev/null)

    local len=${#hash}
    assert_eq "hash is 64 chars" "64" "$len"

    local is_hex=0
    echo "$hash" | grep -qE '^[0-9a-f]{64}$' && is_hex=1
    assert_eq "hash is lowercase hex" "1" "$is_hex"

    assert_pass_if_clean "test_hash_format"
}
test_hash_format

# ── Test 2: same inputs produce same hash ────────────────────────────────────
echo "Test 2: same inputs produce same hash (deterministic)"
test_deterministic() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local hash1 hash2
    hash1=$(cd "$repo" && PROJECT_ROOT="$repo" bash "$HASH_SCRIPT" "test-ticket" "PASS" 2>/dev/null)
    hash2=$(cd "$repo" && PROJECT_ROOT="$repo" bash "$HASH_SCRIPT" "test-ticket" "PASS" 2>/dev/null)

    assert_eq "same inputs produce same hash" "$hash1" "$hash2"

    assert_pass_if_clean "test_deterministic"
}
test_deterministic

# ── Test 3: different ticket IDs produce different hashes ────────────────────
echo "Test 3: different ticket IDs produce different hashes"
test_different_ids() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local hash1 hash2
    hash1=$(cd "$repo" && PROJECT_ROOT="$repo" bash "$HASH_SCRIPT" "ticket-aaa" "PASS" 2>/dev/null)
    hash2=$(cd "$repo" && PROJECT_ROOT="$repo" bash "$HASH_SCRIPT" "ticket-bbb" "PASS" 2>/dev/null)

    local different=0
    [ "$hash1" != "$hash2" ] && different=1
    assert_eq "different ticket IDs produce different hashes" "1" "$different"

    assert_pass_if_clean "test_different_ids"
}
test_different_ids

# ── Test 4: story closure without --verdict-hash is blocked ──────────────────
echo "Test 4: story closure without --verdict-hash is blocked"
test_story_blocked_without_hash() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_ticket "$repo" story "Test story")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created" "non-empty" "empty"
        assert_pass_if_clean "test_story_blocked_without_hash"
        return
    fi

    local exit_code=0
    (cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" transition "$ticket_id" open closed \
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq "story closure without hash exits non-zero" "1" "$exit_code"

    assert_pass_if_clean "test_story_blocked_without_hash"
}
test_story_blocked_without_hash

# ── Test 5: story closure with correct --verdict-hash succeeds ───────────────
echo "Test 5: story closure with correct --verdict-hash succeeds"
test_story_closes_with_correct_hash() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_ticket "$repo" story "Test story")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created" "non-empty" "empty"
        assert_pass_if_clean "test_story_closes_with_correct_hash"
        return
    fi

    local hash
    hash=$(cd "$repo" && PROJECT_ROOT="$repo" bash "$HASH_SCRIPT" "$ticket_id" "PASS" 2>/dev/null)

    local exit_code=0
    (cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" transition "$ticket_id" open closed --verdict-hash="$hash" \
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq "story closure with correct hash exits 0" "0" "$exit_code"

    assert_pass_if_clean "test_story_closes_with_correct_hash"
}
test_story_closes_with_correct_hash

# ── Test 6: story closure with wrong --verdict-hash is blocked ───────────────
echo "Test 6: story closure with wrong --verdict-hash is blocked"
test_story_blocked_with_wrong_hash() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_ticket "$repo" story "Test story")

    local exit_code=0
    (cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" transition "$ticket_id" open closed --verdict-hash="0000000000000000000000000000000000000000000000000000000000000000" \
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq "story closure with wrong hash exits non-zero" "1" "$exit_code"

    assert_pass_if_clean "test_story_blocked_with_wrong_hash"
}
test_story_blocked_with_wrong_hash

# ── Test 7: story closure with --force-close succeeds ────────────────────────
echo "Test 7: story closure with --force-close succeeds"
test_story_force_close() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_ticket "$repo" story "Test story")

    local exit_code=0
    (cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" transition "$ticket_id" open closed --force-close="verifier timed out" \
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq "story force-close exits 0" "0" "$exit_code"

    assert_pass_if_clean "test_story_force_close"
}
test_story_force_close

# ── Test 8: bug closure does not require --verdict-hash ──────────────────────
echo "Test 8: bug closure does not require --verdict-hash"
test_bug_no_hash_required() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_ticket "$repo" bug "Test bug")

    local exit_code=0
    (cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" transition "$ticket_id" open closed --reason="Fixed: test" \
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq "bug closure without hash exits 0" "0" "$exit_code"

    assert_pass_if_clean "test_bug_no_hash_required"
}
test_bug_no_hash_required

# ── Test 9: task closure does not require --verdict-hash ─────────────────────
echo "Test 9: task closure does not require --verdict-hash"
test_task_no_hash_required() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_ticket "$repo" task "Test task")

    local exit_code=0
    (cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" transition "$ticket_id" open closed \
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq "task closure without hash exits 0" "0" "$exit_code"

    assert_pass_if_clean "test_task_no_hash_required"
}
test_task_no_hash_required

echo ""
echo "=== test-verdict-hash-gate.sh complete ==="
print_summary
