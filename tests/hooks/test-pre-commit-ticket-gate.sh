#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2069
# tests/hooks/test-pre-commit-ticket-gate.sh
# Tests for hooks/pre-commit-ticket-gate.sh (TDD RED phase)
#
# pre-commit-ticket-gate.sh is a git pre-commit hook that blocks commits
# when the commit message does not reference a valid v3 ticket ID (XXXX-XXXX
# hex format, with a corresponding dir+CREATE event in the tracker).
#
# RED MARKER:
# tests/hooks/test-pre-commit-ticket-gate.sh [test_snapshot_ticket_accepted]
#
# Test cases (11):
#   1. test_blocks_missing_ticket_id          — commit msg with no ID exits non-zero for non-allowlisted files
#   2. test_blocks_invalid_ticket_format      — commit msg 'fix: ABC-123 bug' (wrong format) exits non-zero
#   3. test_allows_valid_v3_ticket_id         — valid XXXX-XXXX hex ID + matching dir+CREATE event exits 0
#   4. test_blocks_nonexistent_ticket         — valid format but no dir/CREATE event exits non-zero
#   5. test_skips_when_all_allowlisted        — all staged files match allowlist → exits 0 without ticket check
#   6. test_merge_commit_exempt               — MERGE_HEAD present → exits 0 unconditionally
#   7. test_graceful_degradation_no_tracker   — TICKET_TRACKER_OVERRIDE points to nonexistent path → exits 0
#   8. test_error_message_format_hint         — blocked output contains 'XXXX-XXXX' and 'ticket create' pointer
#   9. test_allows_multiple_ids_in_message    — multiple IDs in msg pass if at least one valid and exists
#  10. test_non_allowlisted_staged_files_trigger_check — non-allowlisted staged file with no ticket ID is blocked
#  11. test_snapshot_ticket_accepted           — ticket with only SNAPSHOT event (no CREATE) is accepted
#
# All tests use isolated temp git repos to avoid polluting the real repository.
#
# Env var injection:
#   TICKET_TRACKER_OVERRIDE   — path to fake/real tracker dir
#   CONF_OVERRIDE             — path to fake allowlist conf
#   COMMIT_MSG_FILE_OVERRIDE  — path to temp commit message file

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-ticket-gate.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# ── Prerequisite check ───────────────────────────────────────────────────────
# In RED phase, the gate hook does not exist yet. Tests that need it will
# handle the missing-file case explicitly (asserting failure). Tests that
# check structural properties can SKIP gracefully.
if [[ ! -f "$GATE_HOOK" ]]; then
    echo "NOTE: pre-commit-ticket-gate.sh not found — running in RED phase"
fi

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Helper: create a fresh isolated git repo ─────────────────────────────────
make_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    git -C "$tmpdir" config commit.gpgsign false
    echo "initial" > "$tmpdir/README.md"
    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -q -m "init"
    echo "$tmpdir"
}

# ── Helper: create a fresh artifacts directory ────────────────────────────────
make_artifacts_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    echo "$tmpdir"
}

# ── Helper: create a fake tracker with a valid ticket ────────────────────────
# Usage: make_fake_tracker <ticket_id>
# Creates a tracker directory with a per-ticket dir + CREATE event file,
# mimicking the v3 event-sourced ticket store format.
make_fake_tracker() {
    local ticket_id="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    mkdir -p "$tmpdir/$ticket_id"
    # CREATE event file — the hook checks for dir existence + CREATE event
    printf '{"type":"CREATE","id":"%s","timestamp":"2026-03-23T00:00:00Z"}\n' \
        "$ticket_id" > "$tmpdir/$ticket_id/0001-CREATE.json"
    echo "$tmpdir"
}

# ── Helper: create a fake allowlist conf (non-allowlisted by default) ─────────
# Returns path to a conf file that allowlists nothing (forces ticket check).
make_empty_allowlist_conf() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    # Minimal conf: only comments, no patterns
    printf '# empty allowlist for testing\n' > "$tmpdir/allowlist.conf"
    echo "$tmpdir/allowlist.conf"
}

# ── Helper: create an allowlist conf that matches everything ──────────────────
make_full_allowlist_conf() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    # Allowlist conf that matches any .md file (covers our test staged files)
    printf '*.md\n**/*.md\n' > "$tmpdir/allowlist.conf"
    echo "$tmpdir/allowlist.conf"
}

# ── Helper: write a commit message file ───────────────────────────────────────
make_commit_msg_file() {
    local message="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    printf '%s\n' "$message" > "$tmpdir/COMMIT_EDITMSG"
    echo "$tmpdir/COMMIT_EDITMSG"
}

# ── Helper: run the gate hook in a test repo ──────────────────────────────────
# Returns exit code on stdout.
run_gate_hook() {
    local repo_dir="$1"
    local commit_msg_file="$2"
    local tracker_dir="${3:-}"
    local conf_file="${4:-}"
    local exit_code=0
    (
        cd "$repo_dir"
        [[ -n "$tracker_dir" ]] && export TICKET_TRACKER_OVERRIDE="$tracker_dir"
        [[ -n "$conf_file" ]]   && export CONF_OVERRIDE="$conf_file"
        export COMMIT_MSG_FILE_OVERRIDE="$commit_msg_file"
        export TICKET_SHIM_OVERRIDE="$PLUGIN_ROOT/.claude/scripts/dso"
        # Ensure the shim can locate the DSO plugin root even when the working
        # directory is a fake isolated test repo (which has no dso-config.conf).
        export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
        bash "$GATE_HOOK" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# ── Helper: capture stderr from the gate hook ─────────────────────────────────
run_gate_hook_stderr() {
    local repo_dir="$1"
    local commit_msg_file="$2"
    local tracker_dir="${3:-}"
    local conf_file="${4:-}"
    (
        cd "$repo_dir"
        [[ -n "$tracker_dir" ]] && export TICKET_TRACKER_OVERRIDE="$tracker_dir"
        [[ -n "$conf_file" ]]   && export CONF_OVERRIDE="$conf_file"
        export COMMIT_MSG_FILE_OVERRIDE="$commit_msg_file"
        export TICKET_SHIM_OVERRIDE="$PLUGIN_ROOT/.claude/scripts/dso"
        export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
        bash "$GATE_HOOK" 2>&1 >/dev/null
    ) || true
}

# ── Helper: stage a non-allowlisted source file in a repo ────────────────────
stage_source_file() {
    local repo_dir="$1"
    local filename="${2:-feature.sh}"
    printf '#!/usr/bin/env bash\necho hello\n' > "$repo_dir/$filename"
    git -C "$repo_dir" add "$filename"
}

# ============================================================
# TEST 1: test_blocks_missing_ticket_id
# Commit message with no ticket ID should exit non-zero when
# non-allowlisted files are staged.
# ============================================================
test_blocks_missing_ticket_id() {
    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_blocks_missing_ticket_id: hook present" "present" "absent"
        return
    fi

    local _repo _tracker _conf _msg_file
    _repo=$(make_test_repo)
    _tracker=$(make_fake_tracker "ab12-cd34")
    _conf=$(make_empty_allowlist_conf)
    _msg_file=$(make_commit_msg_file "fix: improve error handling")

    stage_source_file "$_repo"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_msg_file" "$_tracker" "$_conf")
    assert_eq "test_blocks_missing_ticket_id" "1" "$exit_code"
}

# ============================================================
# TEST 2: test_blocks_invalid_ticket_format
# Commit message with wrong format (ABC-123, not XXXX-XXXX hex)
# should exit non-zero when non-allowlisted files are staged.
# ============================================================
test_blocks_invalid_ticket_format() {
    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_blocks_invalid_ticket_format: hook present" "present" "absent"
        return
    fi

    local _repo _tracker _conf _msg_file
    _repo=$(make_test_repo)
    _tracker=$(make_fake_tracker "ab12-cd34")
    _conf=$(make_empty_allowlist_conf)
    # Wrong format: Jira-style uppercase with numbers, not 4+4 hex
    _msg_file=$(make_commit_msg_file "fix: ABC-123 bug description")

    stage_source_file "$_repo"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_msg_file" "$_tracker" "$_conf")
    assert_eq "test_blocks_invalid_ticket_format" "1" "$exit_code"
}

# ============================================================
# TEST 3: test_allows_valid_v3_ticket_id
# Commit message with a valid XXXX-XXXX hex ID and matching
# dir+CREATE event in tracker should exit 0.
# ============================================================
test_allows_valid_v3_ticket_id() {
    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_allows_valid_v3_ticket_id: hook present" "present" "absent"
        return
    fi

    local _repo _tracker _conf _msg_file
    _repo=$(make_test_repo)
    _tracker=$(make_fake_tracker "ab12-cd34")
    _conf=$(make_empty_allowlist_conf)
    # Valid v3 ticket ID embedded in commit message
    _msg_file=$(make_commit_msg_file "feat(ab12-cd34): implement new feature")

    stage_source_file "$_repo"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_msg_file" "$_tracker" "$_conf")
    assert_eq "test_allows_valid_v3_ticket_id" "0" "$exit_code"
}

# ============================================================
# TEST 4: test_blocks_nonexistent_ticket
# Commit message has valid XXXX-XXXX format but no matching
# dir/CREATE event in tracker — should exit non-zero.
# ============================================================
test_blocks_nonexistent_ticket() {
    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_blocks_nonexistent_ticket: hook present" "present" "absent"
        return
    fi

    local _repo _tracker _conf _msg_file
    _repo=$(make_test_repo)
    # Tracker has ticket ab12-cd34 but commit refs ff00-ee11 (does not exist)
    _tracker=$(make_fake_tracker "ab12-cd34")
    _conf=$(make_empty_allowlist_conf)
    _msg_file=$(make_commit_msg_file "feat(ff00-ee11): reference nonexistent ticket")

    stage_source_file "$_repo"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_msg_file" "$_tracker" "$_conf")
    assert_eq "test_blocks_nonexistent_ticket" "1" "$exit_code"
}

# ============================================================
# TEST 5: test_skips_when_all_allowlisted
# All staged files match allowlist → exits 0 without checking
# ticket reference at all.
# ============================================================
test_skips_when_all_allowlisted() {
    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_skips_when_all_allowlisted: hook present" "present" "absent"
        return
    fi

    local _repo _tracker _conf _msg_file
    _repo=$(make_test_repo)
    # Tracker is empty — no valid tickets
    local _empty_tracker
    _empty_tracker=$(mktemp -d)
    _TEST_TMPDIRS+=("$_empty_tracker")
    # Allowlist conf matches all .md files
    _conf=$(make_full_allowlist_conf)
    # Commit message has no ticket ID — would fail if check ran
    _msg_file=$(make_commit_msg_file "chore: update documentation")

    # Stage only .md files (allowlisted)
    printf '# Updated docs\n' > "$_repo/notes.md"
    git -C "$_repo" add "notes.md"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_msg_file" "$_empty_tracker" "$_conf")
    assert_eq "test_skips_when_all_allowlisted" "0" "$exit_code"
}

# ============================================================
# TEST 6: test_merge_commit_exempt
# MERGE_HEAD file present in .git → exits 0 unconditionally,
# regardless of commit message or staged files.
# ============================================================
test_merge_commit_exempt() {
    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_merge_commit_exempt: hook present" "present" "absent"
        return
    fi

    local _repo _tracker _conf _msg_file
    _repo=$(make_test_repo)
    _tracker=$(make_fake_tracker "ab12-cd34")
    _conf=$(make_empty_allowlist_conf)
    # Commit message with no ticket ID — would block if MERGE_HEAD exemption didn't apply
    _msg_file=$(make_commit_msg_file "Merge branch 'main' into feature-branch")

    # Write MERGE_HEAD to simulate an in-progress merge.
    # Use a fake SHA that differs from HEAD so ms_is_merge_in_progress does not
    # reject it via the MERGE_HEAD==HEAD self-referencing guard. An unresolvable
    # SHA triggers the fail-open path in ms_is_merge_in_progress (returns 0 =
    # merge in progress), which is the correct behavior for this exemption test.
    echo "0000000000000000000000000000000000000001" > "$_repo/.git/MERGE_HEAD"

    stage_source_file "$_repo"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_msg_file" "$_tracker" "$_conf")
    assert_eq "test_merge_commit_exempt" "0" "$exit_code"

    rm -f "$_repo/.git/MERGE_HEAD"
}

# ============================================================
# TEST 7: test_graceful_degradation_no_tracker
# TICKET_TRACKER_OVERRIDE points to nonexistent path.
# Hook should exit 0 (fail-open) with a warning on stderr.
# ============================================================
test_graceful_degradation_no_tracker() {
    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_graceful_degradation_no_tracker: hook present" "present" "absent"
        return
    fi

    local _repo _conf _msg_file
    _repo=$(make_test_repo)
    _conf=$(make_empty_allowlist_conf)
    # Valid format but tracker path does not exist
    local _nonexistent_tracker="/tmp/dso-test-nonexistent-tracker-$$"
    _msg_file=$(make_commit_msg_file "feat(ab12-cd34): some feature")

    stage_source_file "$_repo"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_msg_file" "$_nonexistent_tracker" "$_conf")
    assert_eq "test_graceful_degradation_no_tracker" "0" "$exit_code"

    # Also verify a warning appears on stderr (graceful degradation)
    local stderr_out
    stderr_out=$(run_gate_hook_stderr "$_repo" "$_msg_file" "$_nonexistent_tracker" "$_conf")
    assert_contains "test_graceful_degradation_no_tracker: warning on stderr" \
        "WARNING" "$stderr_out"
}

# ============================================================
# TEST 8: test_error_message_format_hint
# When blocked, the error output must contain:
#   - 'XXXX-XXXX' (showing expected format)
#   - 'ticket create' (pointer to create a ticket)
# ============================================================
test_error_message_format_hint() {
    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_error_message_format_hint: hook present" "present" "absent"
        return
    fi

    local _repo _tracker _conf _msg_file
    _repo=$(make_test_repo)
    _tracker=$(make_fake_tracker "ab12-cd34")
    _conf=$(make_empty_allowlist_conf)
    # No ticket ID in message — will be blocked
    _msg_file=$(make_commit_msg_file "fix: something without a ticket reference")

    stage_source_file "$_repo"

    local stderr_out
    stderr_out=$(run_gate_hook_stderr "$_repo" "$_msg_file" "$_tracker" "$_conf")

    assert_contains "test_error_message_format_hint: XXXX-XXXX format hint" \
        "XXXX-XXXX" "$stderr_out"
    assert_contains "test_error_message_format_hint: ticket create pointer" \
        "ticket create" "$stderr_out"
}

# ============================================================
# TEST 9: test_allows_multiple_ids_in_message
# Commit message with multiple ticket IDs: passes if at least
# one is valid (has dir+CREATE event in tracker).
# ============================================================
test_allows_multiple_ids_in_message() {
    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_allows_multiple_ids_in_message: hook present" "present" "absent"
        return
    fi

    local _repo _tracker _conf _msg_file
    _repo=$(make_test_repo)
    # Tracker has ab12-cd34 but not ff00-ee11
    _tracker=$(make_fake_tracker "ab12-cd34")
    _conf=$(make_empty_allowlist_conf)
    # Message contains two IDs: one invalid/missing + one valid
    _msg_file=$(make_commit_msg_file "feat(ff00-ee11, ab12-cd34): related changes")

    stage_source_file "$_repo"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_msg_file" "$_tracker" "$_conf")
    assert_eq "test_allows_multiple_ids_in_message" "0" "$exit_code"
}

# ============================================================
# TEST 10: test_non_allowlisted_staged_files_trigger_check
# Non-allowlisted staged file with no ticket ID must be blocked.
# This is the fundamental invariant: reviewable files require a ticket.
# ============================================================
test_non_allowlisted_staged_files_trigger_check() {
    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_non_allowlisted_staged_files_trigger_check: hook present" "present" "absent"
        return
    fi

    local _repo _tracker _conf _msg_file
    _repo=$(make_test_repo)
    _tracker=$(make_fake_tracker "ab12-cd34")
    _conf=$(make_empty_allowlist_conf)
    # No ticket ID in message
    _msg_file=$(make_commit_msg_file "refactor: clean up internals")

    # Stage a clearly non-allowlisted .py file
    printf 'def main(): pass\n' > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_msg_file" "$_tracker" "$_conf")
    assert_eq "test_non_allowlisted_staged_files_trigger_check" "1" "$exit_code"
}

# ============================================================
# TEST 11: test_snapshot_ticket_accepted  [RED MARKER]
# A ticket directory that contains only a SNAPSHOT event file
# (no CREATE event) must be accepted by the gate after dceb-2566
# refactors the gate to use `ticket exists` (which checks both
# CREATE and SNAPSHOT). Currently the gate only checks CREATE,
# so this test is RED.
# ============================================================
test_snapshot_ticket_accepted() {
    if [[ ! -f "$GATE_HOOK" ]]; then
        assert_eq "test_snapshot_ticket_accepted: hook present" "present" "absent"
        return
    fi

    local _tracker_dir _repo _conf _msg_file
    _tracker_dir=$(mktemp -d)
    _TEST_TMPDIRS+=("$_tracker_dir")

    # Create a ticket directory with ONLY a SNAPSHOT event — no CREATE event.
    mkdir -p "$_tracker_dir/abcd-1234"
    cat > "$_tracker_dir/abcd-1234/001-SNAPSHOT.json" << 'EOF'
{"event_type":"SNAPSHOT","ticket_id":"abcd-1234","timestamp":1700000000000000000,"data":{"title":"Test Snapshot Ticket","status":"open"}}
EOF

    _repo=$(make_test_repo)
    _conf=$(make_empty_allowlist_conf)
    _msg_file=$(make_commit_msg_file "feat(abcd-1234): implement snapshot-ticket feature")

    stage_source_file "$_repo"

    local exit_code
    exit_code=$(run_gate_hook "$_repo" "$_msg_file" "$_tracker_dir" "$_conf")
    # Gate should accept the commit because the ticket exists (via SNAPSHOT).
    # This assertion FAILS in RED phase (gate only checks CREATE, not SNAPSHOT).
    assert_eq "test_snapshot_ticket_accepted" "0" "$exit_code"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_blocks_missing_ticket_id
test_blocks_invalid_ticket_format
test_allows_valid_v3_ticket_id
test_blocks_nonexistent_ticket
test_skips_when_all_allowlisted
test_merge_commit_exempt
test_graceful_degradation_no_tracker
test_error_message_format_hint
test_allows_multiple_ids_in_message
test_non_allowlisted_staged_files_trigger_check
test_snapshot_ticket_accepted

print_summary
