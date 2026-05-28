#!/usr/bin/env bash
# tests/scripts/test-backfill-bug-types.sh
# Tests for plugins/dso/scripts/backfill-bug-types.sh.
#
# All tests FAIL until the script is implemented (RED phase).
#
# Usage: bash tests/scripts/test-backfill-bug-types.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TARGET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/backfill-bug-types.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-backfill-bug-types.sh ==="

# EXIT trap: clean up all temp dirs even when killed by SIGURG (tool timeout)
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ── JSON fixture helpers ───────────────────────────────────────────────────────
# Minimal ticket list JSON compatible with `ticket list --type=bug --status=closed`
_TWO_UNTAGGED_BUGS='[
  {"ticket_id":"abc1","ticket_type":"bug","title":"Test bug 1","status":"closed","tags":[]},
  {"ticket_id":"abc2","ticket_type":"bug","title":"Test bug 2","status":"closed","tags":[]}
]'

_ONE_TAGGED_ONE_UNTAGGED='[
  {"ticket_id":"abc1","ticket_type":"bug","title":"Already tagged bug","status":"closed","tags":["bug-type-scope-drift"]},
  {"ticket_id":"abc2","ticket_type":"bug","title":"Untagged bug","status":"closed","tags":[]}
]'

# ── make_mock_ticket_cmd fixture ───────────────────────────────────────────────
# Creates a temporary mock TICKET_CMD executable that prints the given JSON.
# Usage: make_mock_ticket_cmd <json_string>  (writes path to stdout)
make_mock_ticket_cmd() {
    local json="$1"
    local mock
    mock=$(mktemp "${TMPDIR:-/tmp}/mock-ticket-cmd.XXXXXX")
    cat > "$mock" << EOF
#!/usr/bin/env bash
printf '%s\n' '$json'
EOF
    chmod +x "$mock"
    echo "$mock"
}

# ── Test 1: script file exists ─────────────────────────────────────────────────
test_script_file_exists() {
    local actual
    if [ -f "$TARGET_SCRIPT" ]; then
        actual="exists"
    else
        actual="missing"
    fi
    assert_eq "test_script_file_exists: plugins/dso/scripts/backfill-bug-types.sh exists" \
        "exists" "$actual"
}
test_script_file_exists

# ── Test 2: executable bit set ─────────────────────────────────────────────────
test_script_is_executable() {
    local actual
    if [ -x "$TARGET_SCRIPT" ]; then
        actual="executable"
    else
        actual="not_executable"
    fi
    assert_eq "test_script_is_executable: backfill-bug-types.sh has executable bit" \
        "executable" "$actual"
}
test_script_is_executable

# ── Test 3: --dry-run flag exits 0 ────────────────────────────────────────────
test_dry_run_exits_0() {
    local mock_cmd
    mock_cmd=$(make_mock_ticket_cmd "$_TWO_UNTAGGED_BUGS")
    _CLEANUP_DIRS+=("$mock_cmd")  # single file; rm -rf a file is safe

    local exit_code=0
    SKIP_TICKETS_BRANCH_CHECK=1 TICKET_CMD="$mock_cmd" bash "$TARGET_SCRIPT" --dry-run >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_dry_run_exits_0: --dry-run exits with code 0" "0" "$exit_code"

    rm -f "$mock_cmd"
}
test_dry_run_exits_0

# ── Test 4: live lock detected → exit 0 with informational message ─────────────
# The lock file contains PID 99999 which is almost certainly dead. Per the
# done-def, a dead-PID lock is treated as stale and the script proceeds
# (exits 0 after cleanup). A truly live PID lock exits 0 with an info message.
# Either behaviour satisfies the "exit 0 with info" contract; we verify exit 0
# and that the word "lock" (or "already" or "running") appears in output.
test_lock_exists_exits_0_with_info() {
    local tmp_root
    tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/backfill-lock-test.XXXXXX")
    _CLEANUP_DIRS+=("$tmp_root")

    mkdir -p "$tmp_root/.claude/locks"
    local lock_file="$tmp_root/.claude/locks/backfill-bug-types.lock"
    # Write a lock file with a non-running PID and timestamp
    printf '99999\n%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock_file"

    local mock_cmd
    mock_cmd=$(make_mock_ticket_cmd "$_TWO_UNTAGGED_BUGS")

    local output exit_code=0
    output=$(REPO_ROOT="$tmp_root" SKIP_TICKETS_BRANCH_CHECK=1 TICKET_CMD="$mock_cmd" \
        bash "$TARGET_SCRIPT" --dry-run 2>&1) || exit_code=$?

    assert_eq "test_lock_exists_exits_0_with_info: exit code is 0" "0" "$exit_code"

    local lower_output
    lower_output=$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')
    local info_present="no"
    if [[ "$lower_output" == *"lock"* ]] || \
       [[ "$lower_output" == *"already"* ]] || \
       [[ "$lower_output" == *"running"* ]] || \
       [[ "$lower_output" == *"stale"* ]] || \
       [[ "$lower_output" == *"proceed"* ]]; then
        info_present="yes"
    fi
    assert_eq "test_lock_exists_exits_0_with_info: output contains informational text" \
        "yes" "$info_present"

    rm -f "$mock_cmd"
}
test_lock_exists_exits_0_with_info

# ── Test 5: idempotency — already-tagged tickets skipped ─────────────────────
test_already_tagged_tickets_skipped() {
    local mock_cmd
    mock_cmd=$(make_mock_ticket_cmd "$_ONE_TAGGED_ONE_UNTAGGED")

    local output exit_code=0
    output=$(SKIP_TICKETS_BRANCH_CHECK=1 TICKET_CMD="$mock_cmd" bash "$TARGET_SCRIPT" --dry-run 2>&1) || exit_code=$?

    # Script must exit 0 for this test to be meaningful
    assert_eq "test_already_tagged_tickets_skipped: --dry-run exits 0" "0" "$exit_code"

    # The untagged ticket (abc2) should appear in output
    assert_contains "test_already_tagged_tickets_skipped: untagged ticket abc2 mentioned" \
        "abc2" "$output"

    # The already-tagged ticket (abc1) should NOT appear in dry-run output
    # (it is skipped as already processed). Guard: only check if exit was 0 so
    # the assertion is not trivially satisfied by an empty error output.
    if [ "$exit_code" -eq 0 ]; then
        assert_not_contains "test_already_tagged_tickets_skipped: tagged ticket abc1 NOT mentioned" \
            "abc1" "$output"
    else
        # Script failed; force a FAIL so the test is not silently green
        assert_eq "test_already_tagged_tickets_skipped: script must succeed for idempotency check" \
            "0" "$exit_code"
    fi

    rm -f "$mock_cmd"
}
test_already_tagged_tickets_skipped

# ── Test 6: lock file removed on EXIT ─────────────────────────────────────────
test_lock_cleaned_up_on_exit() {
    local tmp_root
    tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/backfill-lock-cleanup.XXXXXX")
    _CLEANUP_DIRS+=("$tmp_root")

    local mock_cmd
    mock_cmd=$(make_mock_ticket_cmd "$_TWO_UNTAGGED_BUGS")

    # Run with REPO_ROOT redirected so lock lands inside our temp dir
    local exit_code=0
    REPO_ROOT="$tmp_root" SKIP_TICKETS_BRANCH_CHECK=1 TICKET_CMD="$mock_cmd" \
        bash "$TARGET_SCRIPT" --dry-run >/dev/null 2>&1 || exit_code=$?

    # The script must have run successfully for the lock-cleanup assertion to
    # be meaningful.  If the script doesn't exist yet (exit 127), force a FAIL
    # here so this test is not silently green in the RED phase.
    assert_eq "test_lock_cleaned_up_on_exit: script ran successfully" "0" "$exit_code"

    local lock_file="$tmp_root/.claude/locks/backfill-bug-types.lock"
    local actual
    if [ -f "$lock_file" ]; then
        actual="lock_present"
    else
        actual="lock_absent"
    fi
    assert_eq "test_lock_cleaned_up_on_exit: lock file removed after run" \
        "lock_absent" "$actual"

    rm -f "$mock_cmd"
}
test_lock_cleaned_up_on_exit

# ── Test 7: window filtering — tickets outside window are skipped ──────────────
# Creates two untagged tickets: one recent (30 days old), one old (90 days old).
# With --window-days 60 only the recent ticket should appear in --dry-run output.
test_window_days_filters_old_tickets() {
    local recent_ts old_ts
    recent_ts=$(python3 -c "import time; print(int((time.time() - 30 * 86400) * 1e9))")
    old_ts=$(python3 -c "import time; print(int((time.time() - 90 * 86400) * 1e9))")

    local window_json
    window_json="[
      {\"ticket_id\":\"new1\",\"ticket_type\":\"bug\",\"title\":\"Recent bug\",\"status\":\"closed\",\"created_at\":${recent_ts},\"tags\":[]},
      {\"ticket_id\":\"old1\",\"ticket_type\":\"bug\",\"title\":\"Old bug\",\"status\":\"closed\",\"created_at\":${old_ts},\"tags\":[]}
    ]"

    local mock_cmd
    mock_cmd=$(mktemp "${TMPDIR:-/tmp}/mock-window-ticket.XXXXXX")
    cat > "$mock_cmd" << MOCK_EOF
#!/usr/bin/env bash
printf '%s\n' '$window_json'
MOCK_EOF
    chmod +x "$mock_cmd"
    _CLEANUP_DIRS+=("$mock_cmd")

    local output exit_code=0
    output=$(SKIP_TICKETS_BRANCH_CHECK=1 TICKET_CMD="$mock_cmd" bash "$TARGET_SCRIPT" --dry-run --window-days 60 2>&1) || exit_code=$?

    assert_eq "test_window_days_filters_old_tickets: exits 0" "0" "$exit_code"
    assert_contains "test_window_days_filters_old_tickets: recent ticket new1 mentioned" \
        "new1" "$output"
    assert_not_contains "test_window_days_filters_old_tickets: old ticket old1 excluded" \
        "old1" "$output"
}
test_window_days_filters_old_tickets

# ── Test 8: tickets-branch absent → exit 1 with informational message ──────────
# Creates a minimal git repo with no 'tickets' orphan branch. The script must
# exit 1 and emit an error message containing "tickets".
test_tickets_branch_absent_exits_1() {
    local tmp_repo mock_cmd
    tmp_repo=$(mktemp -d "${TMPDIR:-/tmp}/backfill-nobranch.XXXXXX")
    _CLEANUP_DIRS+=("$tmp_repo")

    # Initialize a bare-enough git repo (just needs .git) with no tickets branch
    git init -q "$tmp_repo" 2>/dev/null || true
    # Create an initial empty commit so HEAD is valid
    git -C "$tmp_repo" commit --allow-empty -m "init" -q \
        --author="Test <test@example.com>" 2>/dev/null || true

    mock_cmd=$(make_mock_ticket_cmd "$_TWO_UNTAGGED_BUGS")

    local output exit_code=0
    output=$(REPO_ROOT="$tmp_repo" TICKET_CMD="$mock_cmd" \
        bash "$TARGET_SCRIPT" 2>&1) || exit_code=$?

    assert_eq "test_tickets_branch_absent_exits_1: exits 1" "1" "$exit_code"

    local lower_output
    lower_output=$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')
    local msg_present="no"
    if [[ "$lower_output" == *"tickets"* ]]; then
        msg_present="yes"
    fi
    assert_eq "test_tickets_branch_absent_exits_1: error message mentions tickets" \
        "yes" "$msg_present"

    rm -f "$mock_cmd"
}
test_tickets_branch_absent_exits_1

print_summary
