#!/usr/bin/env bash
# tests/scripts/test-lock-acquire-ticket-format.sh
# Tests that lock-acquire and lock-status correctly detect existing LOCK tickets
# using the actual ticket format (markdown H1 heading, not YAML frontmatter title:).
#
# Regression test for: dso-6q4p
# "agent-batch-lifecycle.sh lock-acquire fails to find lock ticket in worktree —
#  grep patterns don't match synced ticket format"
#
# Validates:
#   - lock-status finds an existing in_progress LOCK ticket (markdown H1 format)
#   - lock-acquire detects an existing lock (LOCK_BLOCKED, does NOT create duplicate)
#   - lock-acquire creates a new lock when none exists (LOCK_ID, calls tk create)
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

# ── Setup: create a temp git repo with a fake tickets dir ────────────────────
TMPDIR_ROOT=$(mktemp -d /tmp/test-lock-acquire.XXXXXX)
FAKE_REPO="$TMPDIR_ROOT/repo"
FAKE_TICKETS_DIR="$FAKE_REPO/.tickets"
FAKE_TK="$TMPDIR_ROOT/fake-tk.sh"
FAKE_GIT="$TMPDIR_ROOT/fake-git.sh"
TK_CALLS_FILE="$TMPDIR_ROOT/tk-calls.log"

mkdir -p "$FAKE_TICKETS_DIR"
# We use a fake `git` wrapper so we don't need a real git repo,
# which makes the test self-contained and portable.
cat > "$FAKE_GIT" <<FAKEGITEOF
#!/usr/bin/env bash
# Fake git: handle only what agent-batch-lifecycle.sh needs at startup
if [[ "\$*" == *"rev-parse --show-toplevel"* ]]; then
    echo "$FAKE_REPO"
    exit 0
fi
command git "\$@"
FAKEGITEOF
chmod +x "$FAKE_GIT"

cleanup() {
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

# Helper: run a lifecycle subcommand with the fake git and tk injected via PATH
_run_lifecycle() {
    local subcmd="$1"; shift
    PATH="$TMPDIR_ROOT:$PATH" \
    TK="$FAKE_TK" \
    TK_CALLS_LOG="$TK_CALLS_FILE" \
    bash "$LIFECYCLE" "$subcmd" "$@" 2>/dev/null
}

# Rename fake-git.sh to 'git' so it's found first in PATH
cp "$FAKE_GIT" "$TMPDIR_ROOT/git"
chmod +x "$TMPDIR_ROOT/git"

# ── test_lock_status_finds_markdown_h1_format ─────────────────────────────────
# lock-status should detect an in_progress LOCK ticket stored as markdown H1.
# This tests that the grep correctly matches `# [LOCK] <label>` not `title: ...`.
_snapshot_fail

# Create a fake LOCK ticket in the actual format tk produces (markdown H1 heading)
cat > "$FAKE_TICKETS_DIR/dso-testlk1.md" <<'TICKETEOF'
---
id: dso-testlk1
status: in_progress
deps: []
links: []
created: 2026-03-21T00:00:00Z
type: task
priority: 0
---
# [LOCK] debug-everything


## Notes

Session: 2026-03-21T00:00:00Z | Worktree: /some/worktree
TICKETEOF

# Simple fake tk (not needed for lock-status, but must exist)
cat > "$FAKE_TK" <<'FAKETKEOF'
#!/usr/bin/env bash
echo "$@" >> "${TK_CALLS_LOG:-/dev/null}"
FAKETKEOF
chmod +x "$FAKE_TK"

status_out=""
status_out=$(_run_lifecycle lock-status "debug-everything") || true

assert_contains "lock_status_markdown_h1: detects LOCKED" "LOCKED:" "$status_out"
assert_pass_if_clean "test_lock_status_finds_markdown_h1_format"

# ── test_lock_status_no_false_positive_when_closed ───────────────────────────
# A closed LOCK ticket should NOT be reported as LOCKED.
_snapshot_fail

cat > "$FAKE_TICKETS_DIR/dso-testlk_closed.md" <<'TICKETEOF'
---
id: dso-testlk_closed
status: closed
deps: []
links: []
created: 2026-03-21T00:00:00Z
type: task
priority: 0
---
# [LOCK] debug-everything
TICKETEOF

# Override testlk1 to have a different label so only closed ticket matches
cat > "$FAKE_TICKETS_DIR/dso-testlk1.md" <<'TICKETEOF'
---
id: dso-testlk1
status: in_progress
deps: []
links: []
---
# [LOCK] sprint
TICKETEOF

closed_status_out=""
closed_status_out=$(_run_lifecycle lock-status "debug-everything") || true

assert_contains "lock_status_closed_ticket: reports UNLOCKED for closed ticket" "UNLOCKED" "$closed_status_out"
assert_pass_if_clean "test_lock_status_no_false_positive_when_closed"

# Restore testlk1 to debug-everything label for next test
cat > "$FAKE_TICKETS_DIR/dso-testlk1.md" <<'TICKETEOF'
---
id: dso-testlk1
status: in_progress
deps: []
links: []
created: 2026-03-21T00:00:00Z
type: task
priority: 0
---
# [LOCK] debug-everything
TICKETEOF
rm -f "$FAKE_TICKETS_DIR/dso-testlk_closed.md"

# ── test_lock_acquire_detects_existing_lock_markdown_h1 ───────────────────────
# lock-acquire should detect an existing lock and emit LOCK_BLOCKED, NOT create a duplicate.
_snapshot_fail

# Create a live-worktree lock ticket (worktree path = TMPDIR_ROOT, which exists)
cat > "$FAKE_TICKETS_DIR/dso-testlk2.md" <<TICKETEOF
---
id: dso-testlk2
status: in_progress
deps: []
links: []
created: 2026-03-21T00:00:00Z
type: task
priority: 0
---
# [LOCK] sprint


## Notes

Session: 2026-03-21T00:00:00Z | Worktree: $TMPDIR_ROOT
TICKETEOF

# Fake tk: `show` returns the live worktree path so lock is NOT stale
cat > "$FAKE_TK" <<FAKETKEOF2
#!/usr/bin/env bash
echo "\$@" >> "\${TK_CALLS_LOG:-/dev/null}"
CMD="\$1"; shift || true
case "\$CMD" in
    create) echo "dso-newlock" ;;
    status|add-note|close) ;;
    show)
        # Emit live worktree path (directory exists on disk = live lock)
        echo "Worktree: $TMPDIR_ROOT"
        ;;
    *) echo "fake-tk: unknown \$CMD" >&2; exit 1 ;;
esac
FAKETKEOF2
chmod +x "$FAKE_TK"

> "$TK_CALLS_FILE"

acquire_out=""
acquire_exit=0
acquire_out=$(_run_lifecycle lock-acquire "sprint") || acquire_exit=$?

# Should be blocked (exit 1) and emit LOCK_BLOCKED
assert_eq "lock_acquire_blocked_exit: exit 1 when lock exists" "1" "$acquire_exit"
assert_contains "lock_acquire_blocked_output: LOCK_BLOCKED emitted" "LOCK_BLOCKED:" "$acquire_out"

# CRITICAL: lock-acquire must NOT call `tk create` when blocked
tk_calls=$(cat "$TK_CALLS_FILE" 2>/dev/null || echo "")
if echo "$tk_calls" | grep -q "^create "; then
    assert_eq "lock_acquire_no_duplicate: must not call tk create when blocked" "no_create" "called_create"
else
    assert_eq "lock_acquire_no_duplicate: must not call tk create when blocked" "no_create" "no_create"
fi
assert_pass_if_clean "test_lock_acquire_detects_existing_lock_markdown_h1"

# ── test_lock_acquire_creates_new_when_no_existing_lock ───────────────────────
# When no lock ticket exists, lock-acquire should create a new one.
_snapshot_fail

# Remove the fake lock ticket
rm -f "$FAKE_TICKETS_DIR/dso-testlk2.md" "$FAKE_TICKETS_DIR/dso-testlk1.md"
> "$TK_CALLS_FILE"

# Simple fake tk that returns a ticket ID for create
cat > "$FAKE_TK" <<'FAKETKEOF3'
#!/usr/bin/env bash
echo "$@" >> "${TK_CALLS_LOG:-/dev/null}"
CMD="$1"; shift || true
case "$CMD" in
    create) echo "dso-newlock2" ;;
    status|add-note|close) ;;
    show) echo "Worktree: /nonexistent" ;;
    *) echo "fake-tk: unknown $CMD" >&2; exit 1 ;;
esac
FAKETKEOF3
chmod +x "$FAKE_TK"

acquire_out2=""
acquire_exit2=0
acquire_out2=$(_run_lifecycle lock-acquire "sprint") || acquire_exit2=$?

assert_eq "lock_acquire_new: exit 0 when no existing lock" "0" "$acquire_exit2"
assert_contains "lock_acquire_new: LOCK_ID emitted" "LOCK_ID:" "$acquire_out2"

# Should call `tk create`
tk_calls2=$(cat "$TK_CALLS_FILE" 2>/dev/null || echo "")
if echo "$tk_calls2" | grep -q "^create "; then
    assert_eq "lock_acquire_new: calls tk create" "called_create" "called_create"
else
    assert_eq "lock_acquire_new: calls tk create" "called_create" "no_create"
fi
assert_pass_if_clean "test_lock_acquire_creates_new_when_no_existing_lock"

print_summary
