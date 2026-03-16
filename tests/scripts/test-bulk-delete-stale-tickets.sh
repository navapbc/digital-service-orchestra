#!/usr/bin/env bash
# tests/scripts/test-bulk-delete-stale-tickets.sh
# Tests for scripts/bulk-delete-stale-tickets.sh
#
# Usage: bash tests/scripts/test-bulk-delete-stale-tickets.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-bulk-delete-stale-tickets.sh ==="

SCRIPT="$REPO_ROOT/scripts/bulk-delete-stale-tickets.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: $SCRIPT not found"
    (( ++FAIL ))
    print_summary
    exit 1
fi

# ── Setup: create temp tickets dir with mock tickets ─────────────────────────
TMPDIR_TICKETS="$(mktemp -d)"
TMPDIR_HOOKS="$(mktemp -d)"

cleanup() {
    rm -rf "$TMPDIR_TICKETS" "$TMPDIR_HOOKS"
}
trap cleanup EXIT

# Auto-created ticket 1: Fix recurring hook errors
cat > "$TMPDIR_TICKETS/fake-aaaa.md" <<'EOF'
---
id: fake-aaaa
status: open
type: bug
---
# Fix recurring hook errors: test-hook.sh (12 in 24h)

Auto-created bug ticket.
EOF

# Auto-created ticket 2: Investigate recurring tool error
cat > "$TMPDIR_TICKETS/fake-bbbb.md" <<'EOF'
---
id: fake-bbbb
status: open
type: bug
---
# Investigate recurring tool error: some-tool (5 in 24h)

Auto-created bug ticket.
EOF

# Auto-created ticket 3: Investigate timeout
cat > "$TMPDIR_TICKETS/fake-cccc.md" <<'EOF'
---
id: fake-cccc
status: open
type: bug
---
# Investigate timeout: plugin exceeded 300s

Auto-created bug ticket.
EOF

# Auto-created ticket 4: Investigate pre-commit timeout
cat > "$TMPDIR_TICKETS/fake-dddd.md" <<'EOF'
---
id: fake-dddd
status: open
type: bug
---
# Investigate pre-commit timeout: ruff took 45s

Auto-created bug ticket.
EOF

# Auto-created ticket 5: Fix recurring hook errors (duplicate)
cat > "$TMPDIR_TICKETS/fake-eeee.md" <<'EOF'
---
id: fake-eeee
status: open
type: bug
---
# Fix recurring hook errors: auto-format.sh (11 in 24h)

Auto-created bug ticket.
EOF

# Real ticket 1: legitimate bug
cat > "$TMPDIR_TICKETS/fake-real1.md" <<'EOF'
---
id: fake-real1
status: open
type: bug
---
# Fix authentication bug in login flow

A real bug that should NOT be deleted.
EOF

# Real ticket 2: legitimate task
cat > "$TMPDIR_TICKETS/fake-real2.md" <<'EOF'
---
id: fake-real2
status: open
type: task
---
# Refactor pipeline config

A real task that should NOT be deleted. Mentions Investigate timeout: just in a note.
EOF

# Create mock marker files
touch "$TMPDIR_HOOKS/auto-format.sh.bug"
touch "$TMPDIR_HOOKS/test-hook.sh.bug"
touch "$TMPDIR_HOOKS/review-gate.bug"

# Count before
before_count=$(ls "$TMPDIR_TICKETS"/*.md 2>/dev/null | wc -l | tr -d ' ')
assert_eq "before: 7 ticket files exist" "7" "$before_count"

before_hooks=$(ls "$TMPDIR_HOOKS"/*.bug 2>/dev/null | wc -l | tr -d ' ')
assert_eq "before: 3 marker files exist" "3" "$before_hooks"

# ── Run the script with overridden paths ──────────────────────────────────────
TICKETS_DIR="$TMPDIR_TICKETS" HOOK_ERROR_BUGS_DIR="$TMPDIR_HOOKS" bash "$SCRIPT" 2>&1

# ── Assertions: auto-created tickets deleted ──────────────────────────────────
assert_eq "fake-aaaa deleted (Fix recurring hook errors)" "0" "$(test -f "$TMPDIR_TICKETS/fake-aaaa.md" && echo 1 || echo 0)"
assert_eq "fake-bbbb deleted (Investigate recurring tool error)" "0" "$(test -f "$TMPDIR_TICKETS/fake-bbbb.md" && echo 1 || echo 0)"
assert_eq "fake-cccc deleted (Investigate timeout)" "0" "$(test -f "$TMPDIR_TICKETS/fake-cccc.md" && echo 1 || echo 0)"
assert_eq "fake-dddd deleted (Investigate pre-commit timeout)" "0" "$(test -f "$TMPDIR_TICKETS/fake-dddd.md" && echo 1 || echo 0)"
assert_eq "fake-eeee deleted (Fix recurring hook errors duplicate)" "0" "$(test -f "$TMPDIR_TICKETS/fake-eeee.md" && echo 1 || echo 0)"

# ── Assertions: real tickets preserved ───────────────────────────────────────
assert_eq "fake-real1 preserved (legitimate bug)" "1" "$(test -f "$TMPDIR_TICKETS/fake-real1.md" && echo 1 || echo 0)"
assert_eq "fake-real2 preserved (legitimate task)" "1" "$(test -f "$TMPDIR_TICKETS/fake-real2.md" && echo 1 || echo 0)"

# ── Assertions: count reduced ─────────────────────────────────────────────────
after_count=$(ls "$TMPDIR_TICKETS"/*.md 2>/dev/null | wc -l | tr -d ' ')
assert_eq "after: only 2 real ticket files remain" "2" "$after_count"

# ── Assertions: marker files cleaned ─────────────────────────────────────────
after_hooks=$(ls "$TMPDIR_HOOKS"/*.bug 2>/dev/null | wc -l | tr -d ' ')
assert_eq "after: all marker files deleted" "0" "$after_hooks"

print_summary
