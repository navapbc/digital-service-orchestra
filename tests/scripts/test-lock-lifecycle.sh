#!/usr/bin/env bash
# tests/scripts/test-lock-lifecycle.sh
# Regression tests for lock-acquire TOCTOU race (001c-f1ed) and
# lock-release orphan sweep (b066-fdb2).
#
# Validates:
#   001c-f1ed: lock-acquire detects OPEN (not yet in_progress) LOCK tickets
#              as existing locks — blocks duplicate creation.
#   b066-fdb2: lock-release sweeps all orphaned open/in_progress LOCK tickets
#              for the same label after releasing the specific lock_id.
#
# Usage: bash tests/scripts/test-lock-lifecycle.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
LIFECYCLE="$DSO_PLUGIN_DIR/scripts/agent-batch-lifecycle.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-lock-lifecycle.sh ==="

# ── Setup: create a temp dir with mock bin and fake git ─────────────────────
TMPDIR_ROOT=$(mktemp -d /tmp/test-lock-lifecycle.XXXXXX)
FAKE_REPO="$TMPDIR_ROOT/repo"
MOCK_BIN="$TMPDIR_ROOT/mock-bin"
TICKET_LOG_FILE="$TMPDIR_ROOT/ticket.log"
TICKET_STATE_FILE="$TMPDIR_ROOT/ticket-state.json"

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
    TICKET_STATE_FILE="$TICKET_STATE_FILE" \
    bash "$LIFECYCLE" "$subcmd" "$@" 2>/dev/null
}

# ── test_lock_acquire_blocked_by_open_ticket (001c-f1ed) ─────────────────────
# Bug 001c-f1ed: lock-acquire only checks for in_progress tickets.
# If a LOCK ticket is in 'open' state (just created, not yet transitioned),
# the race window allows a second session to create a duplicate.
# After fix: lock-acquire must also detect 'open' status LOCK tickets.
_snapshot_fail

# Mock: list returns an 'open' status LOCK ticket (not yet in_progress)
# This simulates the TOCTOU race window where a ticket was just created
# but not yet transitioned to in_progress.
cat > "$MOCK_BIN/ticket" <<MOCKEOF_001C
#!/usr/bin/env bash
if [[ -n "\${TICKET_LOG_FILE:-}" ]]; then
    echo "\$*" >> "\$TICKET_LOG_FILE"
fi
case "\${1:-}" in
    list)
        # Return an open-status LOCK ticket (the race window scenario)
        printf '[{"ticket_id":"dso-open-lock1","ticket_type":"task","status":"open","title":"[LOCK] debug-everything","priority":0}]\n'
        ;;
    show)
        # Return a worktree that still exists on disk (live lock)
        printf '{"ticket_id":"%s","ticket_type":"task","status":"open","title":"[LOCK] debug-everything","priority":0,"comments":[{"body":"Session: 2026-04-09T00:00:00Z | Worktree: $TMPDIR_ROOT"}]}\n' "\${2:-dso-open-lock1}"
        ;;
    create) echo "mock-new-lock" ;;
    transition|comment) ;;
    *) ;;
esac
exit 0
MOCKEOF_001C
chmod +x "$MOCK_BIN/ticket"

> "$TICKET_LOG_FILE"

acquire_out_001c=""
acquire_exit_001c=0
acquire_out_001c=$(_run_lifecycle lock-acquire "debug-everything") || acquire_exit_001c=$?

# Should be blocked — the open ticket represents a live lock in the race window
assert_eq "001c_f1ed_blocked_exit: exit 1 when open LOCK ticket exists" "1" "$acquire_exit_001c"
assert_contains "001c_f1ed_blocked_output: LOCK_BLOCKED emitted for open ticket" "LOCK_BLOCKED:" "$acquire_out_001c"

# CRITICAL: must NOT call `ticket create` when blocked by an open ticket
ticket_calls_001c=$(cat "$TICKET_LOG_FILE" 2>/dev/null || echo "")
if [[ "$ticket_calls_001c" == *$'\ncreate '* ]] || [[ "$ticket_calls_001c" == create\ * ]]; then
    assert_eq "001c_f1ed_no_duplicate: must not call ticket create when open lock exists" "no_create" "called_create"
else
    assert_eq "001c_f1ed_no_duplicate: must not call ticket create when open lock exists" "no_create" "no_create"
fi
assert_pass_if_clean "test_lock_acquire_blocked_by_open_ticket"

# ── test_lock_release_sweeps_orphaned_tickets (b066-fdb2) ──────────────────
# Bug b066-fdb2: lock-release only closes the specific lock_id.
# Orphaned LOCK tickets from crashed sessions are never cleaned up.
# After fix: lock-release sweeps all remaining open/in_progress LOCK tickets
# for the same label after releasing the specific lock_id.
_snapshot_fail

# Track which tickets get transitioned to 'closed'
CLOSED_FILE="$TMPDIR_ROOT/closed-tickets.log"
> "$CLOSED_FILE"

# Mock: 3 LOCK tickets exist for "debug-everything":
#   dso-orphan1: open (crashed session 1)
#   dso-orphan2: open (crashed session 2, from TOCTOU race)
#   dso-current: in_progress (current session's lock — the one being released)
cat > "$MOCK_BIN/ticket" <<MOCKEOF_B066
#!/usr/bin/env bash
if [[ -n "\${TICKET_LOG_FILE:-}" ]]; then
    echo "\$*" >> "\$TICKET_LOG_FILE"
fi
case "\${1:-}" in
    list)
        # Return all 3 LOCK tickets; the subcommand filters by status via flags.
        # The sweep logic in lock-release calls list with --status=open and
        # --status=in_progress separately or combined. Return appropriate tickets
        # based on the status filter argument.
        if [[ "\$*" == *"--status=open"* ]]; then
            printf '[{"ticket_id":"dso-orphan1","ticket_type":"task","status":"open","title":"[LOCK] debug-everything","priority":0},{"ticket_id":"dso-orphan2","ticket_type":"task","status":"open","title":"[LOCK] debug-everything","priority":0}]\n'
        elif [[ "\$*" == *"--status=in_progress"* ]]; then
            # Current lock is still in_progress until we transition it
            printf '[{"ticket_id":"dso-current","ticket_type":"task","status":"in_progress","title":"[LOCK] debug-everything","priority":0}]\n'
        else
            # Default: return all
            printf '[{"ticket_id":"dso-orphan1","ticket_type":"task","status":"open","title":"[LOCK] debug-everything","priority":0},{"ticket_id":"dso-orphan2","ticket_type":"task","status":"open","title":"[LOCK] debug-everything","priority":0},{"ticket_id":"dso-current","ticket_type":"task","status":"in_progress","title":"[LOCK] debug-everything","priority":0}]\n'
        fi
        ;;
    show)
        local tid="\${2:-dso-current}"
        case "\$tid" in
            dso-orphan1)
                printf '{"ticket_id":"dso-orphan1","ticket_type":"task","status":"open","title":"[LOCK] debug-everything","priority":0,"comments":[]}\n'
                ;;
            dso-orphan2)
                printf '{"ticket_id":"dso-orphan2","ticket_type":"task","status":"open","title":"[LOCK] debug-everything","priority":0,"comments":[]}\n'
                ;;
            *)
                printf '{"ticket_id":"dso-current","ticket_type":"task","status":"in_progress","title":"[LOCK] debug-everything","priority":0,"comments":[]}\n'
                ;;
        esac
        ;;
    transition)
        # Record which tickets get transitioned to closed
        if [[ "\${4:-}" == "closed" ]]; then
            echo "\${2:-}" >> "$CLOSED_FILE"
        fi
        ;;
    comment) ;;
    *) ;;
esac
exit 0
MOCKEOF_B066
chmod +x "$MOCK_BIN/ticket"

> "$TICKET_LOG_FILE"
> "$CLOSED_FILE"

release_out=""
release_exit=0
release_out=$(_run_lifecycle lock-release "dso-current" "cleanup") || release_exit=$?

assert_eq "b066_release_exit: lock-release exits 0" "0" "$release_exit"
assert_contains "b066_release_output: LOCK_RELEASED emitted" "LOCK_RELEASED:" "$release_out"

# Check that ALL 3 tickets were closed (specific + orphans)
closed_tickets=$(cat "$CLOSED_FILE" 2>/dev/null || echo "")

if [[ "$closed_tickets" == *"dso-current"* ]]; then
    assert_eq "b066_closes_current: current lock ticket closed" "closed" "closed"
else
    assert_eq "b066_closes_current: current lock ticket closed" "closed" "not_closed"
fi

if [[ "$closed_tickets" == *"dso-orphan1"* ]]; then
    assert_eq "b066_closes_orphan1: orphaned open ticket 1 swept closed" "closed" "closed"
else
    assert_eq "b066_closes_orphan1: orphaned open ticket 1 swept closed" "closed" "not_closed"
fi

if [[ "$closed_tickets" == *"dso-orphan2"* ]]; then
    assert_eq "b066_closes_orphan2: orphaned open ticket 2 swept closed" "closed" "closed"
else
    assert_eq "b066_closes_orphan2: orphaned open ticket 2 swept closed" "closed" "not_closed"
fi

assert_pass_if_clean "test_lock_release_sweeps_orphaned_tickets"

print_summary
