#!/usr/bin/env bash
# tests/scripts/test-lock-acquire-ticket-format.sh
# Tests that lock-acquire and lock-status correctly detect existing LOCK tickets
# using the v3 ticket CLI (TICKET_CMD) and JSON responses.
#
# Regression test for: dso-6q4p
# "agent-batch-lifecycle.sh lock-acquire fails to find lock ticket in worktree —
#  grep patterns don't match synced ticket format"
#
# Validates:
#   - lock-status finds an existing in_progress LOCK ticket (via ticket list JSON)
#   - lock-acquire detects an existing lock (LOCK_BLOCKED, does NOT create duplicate)
#   - lock-acquire creates a new lock when none exists (LOCK_ID, calls ticket create)
#
# Usage: bash tests/scripts/test-lock-acquire-ticket-format.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
LIFECYCLE="$DSO_PLUGIN_DIR/scripts/agent-batch-lifecycle.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-lock-acquire-ticket-format.sh ==="

# ── Setup: create a temp dir with mock bin and fake git ─────────────────────
TMPDIR_ROOT=$(mktemp -d /tmp/test-lock-acquire.XXXXXX)
FAKE_REPO="$TMPDIR_ROOT/repo"
MOCK_BIN="$TMPDIR_ROOT/mock-bin"
TICKET_LOG_FILE="$TMPDIR_ROOT/ticket.log"

mkdir -p "$FAKE_REPO" "$MOCK_BIN"

# Fake git: handle only rev-parse --show-toplevel
cat > "$MOCK_BIN/git" <<FAKEGITEOF
#!/usr/bin/env bash
if [[ "\$*" == *"rev-parse --show-toplevel"* ]]; then
    echo "$FAKE_REPO"
    exit 0
fi
command git "\$@"
FAKEGITEOF
chmod +x "$MOCK_BIN/git"

cleanup() {
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

# Helper: run a lifecycle subcommand with mock TICKET_CMD and fake git injected
_run_lifecycle() {
    local subcmd="$1"; shift
    PATH="$MOCK_BIN:$PATH" \
    TICKET_CMD="$MOCK_BIN/ticket" \
    TICKET_LOG_FILE="$TICKET_LOG_FILE" \
    bash "$LIFECYCLE" "$subcmd" "$@" 2>/dev/null
}

# ── test_lock_status_finds_existing_lock ─────────────────────────────────────
# lock-status should detect an in_progress LOCK ticket returned by ticket list.
_snapshot_fail

# Mock ticket CLI: list returns one in_progress LOCK task for debug-everything
cat > "$MOCK_BIN/ticket" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ -n "${TICKET_LOG_FILE:-}" ]]; then
    echo "$*" >> "$TICKET_LOG_FILE"
fi
case "${1:-}" in
    list)
        printf '[{"ticket_id":"dso-testlk1","ticket_type":"task","status":"in_progress","title":"[LOCK] debug-everything","priority":0}]\n'
        ;;
    show)
        printf '{"ticket_id":"%s","ticket_type":"task","status":"in_progress","title":"[LOCK] debug-everything","priority":0,"comments":[]}\n' "${2:-dso-testlk1}"
        ;;
    create) echo "mock-xxxx" ;;
    *) ;;
esac
exit 0
MOCKEOF
chmod +x "$MOCK_BIN/ticket"

> "$TICKET_LOG_FILE"

status_out=""
status_out=$(_run_lifecycle lock-status "debug-everything") || true

assert_contains "lock_status_finds_lock: detects LOCKED" "LOCKED:" "$status_out"
assert_pass_if_clean "test_lock_status_finds_existing_lock"

# ── test_lock_status_no_false_positive_when_no_match ─────────────────────────
# lock-status should report UNLOCKED when no in_progress LOCK ticket matches the label.
_snapshot_fail

# Mock ticket CLI: list returns a closed ticket and an in_progress ticket for a different label
cat > "$MOCK_BIN/ticket" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ -n "${TICKET_LOG_FILE:-}" ]]; then
    echo "$*" >> "$TICKET_LOG_FILE"
fi
case "${1:-}" in
    list)
        printf '[{"ticket_id":"dso-testlk_closed","ticket_type":"task","status":"closed","title":"[LOCK] debug-everything","priority":0},{"ticket_id":"dso-testlk_sprint","ticket_type":"task","status":"in_progress","title":"[LOCK] sprint","priority":0}]\n'
        ;;
    show)
        printf '{"ticket_id":"%s","ticket_type":"task","status":"in_progress","title":"[LOCK] sprint","priority":0,"comments":[]}\n' "${2:-mock}"
        ;;
    create) echo "mock-xxxx" ;;
    *) ;;
esac
exit 0
MOCKEOF
chmod +x "$MOCK_BIN/ticket"

> "$TICKET_LOG_FILE"

closed_status_out=""
closed_status_out=$(_run_lifecycle lock-status "debug-everything") || true

assert_contains "lock_status_no_false_positive: reports UNLOCKED when no in_progress match" "UNLOCKED" "$closed_status_out"
assert_pass_if_clean "test_lock_status_no_false_positive_when_no_match"

# ── test_lock_acquire_detects_existing_lock ───────────────────────────────────
# lock-acquire should detect an existing lock and emit LOCK_BLOCKED, NOT create a duplicate.
_snapshot_fail

# Mock ticket CLI: list returns live in_progress LOCK for sprint;
# show returns a comment with a worktree path that actually exists on disk (TMPDIR_ROOT)
cat > "$MOCK_BIN/ticket" <<MOCKEOF2
#!/usr/bin/env bash
if [[ -n "\${TICKET_LOG_FILE:-}" ]]; then
    echo "\$*" >> "\$TICKET_LOG_FILE"
fi
case "\${1:-}" in
    list)
        printf '[{"ticket_id":"dso-testlk2","ticket_type":"task","status":"in_progress","title":"[LOCK] sprint","priority":0}]\n'
        ;;
    show)
        # Emit a live worktree path (directory exists on disk = live lock)
        printf '{"ticket_id":"%s","ticket_type":"task","status":"in_progress","title":"[LOCK] sprint","priority":0,"comments":[{"body":"Session: 2026-03-21T00:00:00Z | Worktree: $TMPDIR_ROOT"}]}\n' "\${2:-dso-testlk2}"
        ;;
    create) echo "mock-xxxx" ;;
    transition|comment) ;;
    *) ;;
esac
exit 0
MOCKEOF2
chmod +x "$MOCK_BIN/ticket"

> "$TICKET_LOG_FILE"

acquire_out=""
acquire_exit=0
acquire_out=$(_run_lifecycle lock-acquire "sprint") || acquire_exit=$?

# Should be blocked (exit 1) and emit LOCK_BLOCKED
assert_eq "lock_acquire_blocked_exit: exit 1 when lock exists" "1" "$acquire_exit"
assert_contains "lock_acquire_blocked_output: LOCK_BLOCKED emitted" "LOCK_BLOCKED:" "$acquire_out"

# CRITICAL: lock-acquire must NOT call `ticket create` when blocked
ticket_calls=$(cat "$TICKET_LOG_FILE" 2>/dev/null || echo "")
if echo "$ticket_calls" | grep -q "^create "; then
    assert_eq "lock_acquire_no_duplicate: must not call ticket create when blocked" "no_create" "called_create"
else
    assert_eq "lock_acquire_no_duplicate: must not call ticket create when blocked" "no_create" "no_create"
fi
assert_pass_if_clean "test_lock_acquire_detects_existing_lock"

# ── test_lock_acquire_creates_new_when_no_existing_lock ───────────────────────
# When no lock ticket exists, lock-acquire should create a new one via ticket create.
_snapshot_fail

# Mock ticket CLI: list returns empty array; create returns a new ticket ID
cat > "$MOCK_BIN/ticket" <<'MOCKEOF3'
#!/usr/bin/env bash
if [[ -n "${TICKET_LOG_FILE:-}" ]]; then
    echo "$*" >> "$TICKET_LOG_FILE"
fi
case "${1:-}" in
    list)
        printf '[]\n'
        ;;
    show)
        printf '{"ticket_id":"%s","ticket_type":"task","status":"open","title":"[LOCK] sprint","priority":0,"comments":[]}\n' "${2:-mock-newlock}"
        ;;
    create) echo "mock-newlock" ;;
    transition|comment) ;;
    *) ;;
esac
exit 0
MOCKEOF3
chmod +x "$MOCK_BIN/ticket"

> "$TICKET_LOG_FILE"

acquire_out2=""
acquire_exit2=0
acquire_out2=$(_run_lifecycle lock-acquire "sprint") || acquire_exit2=$?

assert_eq "lock_acquire_new: exit 0 when no existing lock" "0" "$acquire_exit2"
assert_contains "lock_acquire_new: LOCK_ID emitted" "LOCK_ID:" "$acquire_out2"

# Should call `ticket create`
ticket_calls2=$(cat "$TICKET_LOG_FILE" 2>/dev/null || echo "")
if echo "$ticket_calls2" | grep -q "^create "; then
    assert_eq "lock_acquire_new: calls ticket create" "called_create" "called_create"
else
    assert_eq "lock_acquire_new: calls ticket create" "called_create" "no_create"
fi
assert_pass_if_clean "test_lock_acquire_creates_new_when_no_existing_lock"

print_summary
