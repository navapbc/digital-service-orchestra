#!/usr/bin/env bash
# tests/scripts/test-ticket-push-rebase-conflict.sh
# Tests for bugs 89dc-0913 and eb1d-0e5b:
# _push_tickets_branch gives up on rebase conflict instead of falling back to git merge.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"
source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"
echo "=== test-ticket-push-rebase-conflict.sh ==="
echo "Test 1: push fallback uses merge when rebase fails on diverged tickets branch"
test_merge_fallback_on_rebase_conflict() {
    local tmp; tmp=$(mktemp -d); _CLEANUP_DIRS+=("$tmp")
    git init -q --bare "$tmp/remote.git"
    clone_test_repo "$tmp/repo-a"
    git -C "$tmp/repo-a" remote add origin "$tmp/remote.git"
    git -C "$tmp/repo-a" push -q -u origin main 2>/dev/null
    git -C "$tmp/repo-a" checkout --orphan tickets-init 2>/dev/null
    git -C "$tmp/repo-a" rm -rf . --quiet 2>/dev/null || true
    git -C "$tmp/repo-a" checkout -b tickets 2>/dev/null || git -C "$tmp/repo-a" checkout tickets 2>/dev/null
    mkdir -p "$tmp/repo-a/ticket-aaa1"
    echo '{"event_type":"SNAPSHOT","uuid":"aaa1"}' > "$tmp/repo-a/ticket-aaa1/snapshot.json"
    git -C "$tmp/repo-a" add ticket-aaa1/snapshot.json
    git -C "$tmp/repo-a" -c user.email="test@test.com" -c user.name="Test" \
        commit -q -m "ticket: SNAPSHOT aaa1" 2>/dev/null
    git -C "$tmp/repo-a" push -q origin tickets 2>/dev/null
    clone_test_repo "$tmp/repo-b"
    git -C "$tmp/repo-b" remote add origin "$tmp/remote.git"
    git -C "$tmp/repo-b" push -q -u origin main 2>/dev/null
    git -C "$tmp/repo-b" fetch origin tickets --quiet 2>/dev/null
    git -C "$tmp/repo-b" checkout -b tickets origin/tickets 2>/dev/null
    mkdir -p "$tmp/repo-b/ticket-bbb2"
    echo '{"event_type":"CREATE","uuid":"bbb2"}' > "$tmp/repo-b/ticket-bbb2/create.json"
    git -C "$tmp/repo-b" add ticket-bbb2/create.json
    git -C "$tmp/repo-b" -c user.email="test@test.com" -c user.name="Test" \
        commit -q -m "ticket: CREATE bbb2" 2>/dev/null
    mkdir -p "$tmp/repo-a/ticket-aaa1"
    echo '{"event_type":"TRANSITION","uuid":"aaa3"}' > "$tmp/repo-a/ticket-aaa1/transition.json"
    git -C "$tmp/repo-a" add ticket-aaa1/transition.json
    git -C "$tmp/repo-a" -c user.email="test@test.com" -c user.name="Test" \
        commit -q -m "ticket: TRANSITION aaa1" 2>/dev/null
    git -C "$tmp/repo-a" push -q origin tickets 2>/dev/null
    local result; result=$(source "$TICKET_LIB" 2>/dev/null; _push_tickets_branch "$tmp/repo-b" 2>&1; echo "EXIT:$?") || true
    local exit_code; exit_code=$(echo "$result" | grep "^EXIT:" | cut -d: -f2)
    assert_eq "push_returns_zero_on_diverged_branch" "0" "$exit_code"
    git -C "$tmp/repo-a" fetch origin tickets --quiet 2>/dev/null || true
    local remote_has_b=0
    git -C "$tmp/repo-a" show origin/tickets:ticket-bbb2/create.json >/dev/null 2>&1 && remote_has_b=1 || true
    assert_eq "bbb2_event_pushed_to_remote_after_recovery" "1" "$remote_has_b"
}
test_merge_fallback_on_rebase_conflict
echo "Test 2: ticket-lib.sh _push_tickets_branch contains merge fallback"
test_merge_fallback_exists_in_lib() {
    local lib_content; lib_content=$(< "$TICKET_LIB")
    if echo "$lib_content" | grep -qE 'git.*merge.*origin/tickets|merge.*fallback'; then
        (( ++PASS )); echo "PASS: merge fallback present in _push_tickets_branch"
    else
        (( ++FAIL )); echo "FAIL: merge fallback NOT found in _push_tickets_branch" >&2
    fi
}
test_merge_fallback_exists_in_lib
echo "Test 3: rebase conflict handling continues to merge fallback (not immediate return)"
test_rebase_conflict_does_not_immediately_return() {
    local fn_body; fn_body=$(awk '/_push_tickets_branch\(\)/{found=1} found{print} found && /^}$/{found=0}' "$TICKET_LIB")
    local rebase_abort_line; rebase_abort_line=$(echo "$fn_body" | grep -n "rebase --abort" | head -1 | cut -d: -f1)
    if [ -z "$rebase_abort_line" ]; then (( ++FAIL )); echo "FAIL: rebase --abort not found" >&2; return; fi
    local line_after_abort; line_after_abort=$(echo "$fn_body" | sed -n "$((rebase_abort_line + 1))p" | tr -d ' \t')
    if [[ "$line_after_abort" == "return0"* ]]; then
        (( ++FAIL )); echo "FAIL: line after rebase --abort is 'return 0' - merge fallback not implemented" >&2
    else
        (( ++PASS )); echo "PASS: line after rebase --abort continues to fallback logic"
    fi
}
test_rebase_conflict_does_not_immediately_return
echo ""
print_summary
