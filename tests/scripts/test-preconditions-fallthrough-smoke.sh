#!/usr/bin/env bash
# tests/scripts/test-preconditions-fallthrough-smoke.sh
# CI-repeatable smoke test: verifies that preconditions-record.sh emits a
# PRECONDITIONS event with data.degradation=true and correct degradation_type
# end-to-end using an isolated test repo with ticket-init.sh initialized.
#
# Usage: bash tests/scripts/test-preconditions-fallthrough-smoke.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
RECORD_SCRIPT="$REPO_ROOT/plugins/dso/scripts/preconditions-record.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-preconditions-fallthrough-smoke.sh ==="

_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]:-}"; do rm -rf "$d" 2>/dev/null; done; }
trap _cleanup EXIT

_make_smoke_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    echo "$tmp/repo"
}

_init_tickets() {
    local repo="$1"
    (cd "$repo" && bash "$REPO_ROOT/plugins/dso/scripts/ticket-init.sh" 2>/dev/null) || true
}

# ── test_preconditions_record_degradation_flag_emits_event ───────────────────
# Exercises the full preconditions-record.sh --degradation path in an isolated
# git repo, verifying data.degradation=true and degradation_type in the output file.
test_preconditions_record_degradation_flag_emits_event() {
    _snapshot_fail
    local repo ticket_id _exit=0
    repo=$(_make_smoke_repo)
    _init_tickets "$repo"
    ticket_id="smoke-deg-$$"

    local _out
    _out=$(cd "$repo" && DSO_TICKETS_TRACKER_DIR="$repo/.tickets-tracker" bash "$RECORD_SCRIPT" \
        --ticket-id "$ticket_id" \
        --gate-name sprint_preconditions_entry \
        --session-id "smoke-session-$$" \
        --worktree-id "smoke-worktree" \
        --tier minimal \
        --degradation \
        --degradation-type inferred_decision \
        --data '{}' 2>/dev/null) || _exit=$?

    assert_eq "exit 0" "0" "$_exit"
    assert_contains "output has Preconditions recorded" "Preconditions recorded" "$_out"

    local _found_file
    _found_file=$(find "$repo/.tickets-tracker/$ticket_id" -name '*-PRECONDITIONS.json' 2>/dev/null | head -1)
    assert_eq "PRECONDITIONS file created" "yes" "$(test -f "$_found_file" && echo yes || echo no)"

    if [[ -f "$_found_file" ]]; then
        local _deg _dtype
        _deg=$(python3 -c "
import json
with open('$_found_file') as f: d = json.load(f)
print(str(d.get('data', {}).get('degradation', False)).lower())
" 2>/dev/null)
        _dtype=$(python3 -c "
import json
with open('$_found_file') as f: d = json.load(f)
print(d.get('data', {}).get('degradation_type', ''))
" 2>/dev/null)
        assert_eq "data.degradation=true" "true" "$_deg"
        assert_eq "degradation_type=inferred_decision" "inferred_decision" "$_dtype"
    fi

    assert_pass_if_clean "test_preconditions_record_degradation_flag_emits_event"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_preconditions_record_degradation_flag_emits_event

print_summary
