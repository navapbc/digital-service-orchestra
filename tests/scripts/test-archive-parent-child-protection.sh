#!/usr/bin/env bash
# tests/scripts/test-archive-parent-child-protection.sh
# Tests that archive-closed-tickets.sh does NOT archive a closed epic that
# has an open child ticket (parent field only — no deps relationship).
#
# Also includes a regression fixture for the existing deps-based protection.
#
# Usage: bash tests/scripts/test-archive-parent-child-protection.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# TDD: This test is written RED — it should FAIL against the current
# implementation because archive-closed-tickets.sh only checks deps[], not
# the parent field on child tickets.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-archive-parent-child-protection.sh ==="

SCRIPT="$DSO_PLUGIN_DIR/scripts/archive-closed-tickets.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: $SCRIPT not found"
    (( ++FAIL ))
    print_summary
    exit 1
fi

# ── Setup: temp tickets directory ─────────────────────────────────────────────
TMPDIR_TICKETS="$(mktemp -d)"

cleanup() {
    rm -rf "$TMPDIR_TICKETS"
}
trap cleanup EXIT

# ── Fixture 1: parent-child protection (NO deps relationship) ─────────────────
# Closed epic with no deps[] — only referenced via child's parent field.
cat > "$TMPDIR_TICKETS/epic-001.md" <<'EOF'
---
id: epic-001
status: closed
type: epic
deps: []
---
# Closed Epic

This epic is closed but has an open child ticket.
EOF

# Open child that declares epic-001 as parent (NOT in deps[]).
cat > "$TMPDIR_TICKETS/child-001.md" <<'EOF'
---
id: child-001
status: open
type: story
parent: epic-001
deps: []
---
# Open Child Story

This story is open and belongs to epic-001 via the parent field.
EOF

# ── Fixture 2: deps-based protection regression ───────────────────────────────
# Closed ticket that IS transitively depended on by an open ticket.
cat > "$TMPDIR_TICKETS/dep-prot-001.md" <<'EOF'
---
id: dep-prot-001
status: closed
type: task
deps: [open-001]
---
# Closed task with dep on open ticket

This ticket is closed but listed in open-001's dep chain.
EOF

# Open ticket that depends on dep-prot-001 (so dep-prot-001 is in its chain).
# NOTE: The BFS walks from active tickets outward through their deps[].
# open-001 is active and has no deps[], but dep-prot-001 has deps:[open-001]
# which means open-001 is a dep OF dep-prot-001, not the other way around.
# To actually protect dep-prot-001 via the existing mechanism, open-001 must
# list dep-prot-001 in its deps[].
cat > "$TMPDIR_TICKETS/open-001.md" <<'EOF'
---
id: open-001
status: open
type: task
deps: [dep-prot-001]
---
# Open task that depends on dep-prot-001

This task is open and lists dep-prot-001 as a dependency.
EOF

# ── Run the archive script once, capturing stderr separately ──────────────────
stdout_out="$(TICKETS_DIR="$TMPDIR_TICKETS" bash "$SCRIPT" 2>/tmp/archive-test-stderr.txt)" || true
stderr_out="$(cat /tmp/archive-test-stderr.txt)"
rm -f /tmp/archive-test-stderr.txt

# ── Assertions: parent-child protection ───────────────────────────────────────

# epic-001 must NOT be in archive/ — it has an open child (child-001)
assert_eq \
    "epic-001 NOT archived (has open child child-001 via parent field)" \
    "0" \
    "$(test -f "$TMPDIR_TICKETS/archive/epic-001.md" && echo 1 || echo 0)"

# child-001 must remain in active tickets (it is open)
assert_eq \
    "child-001 stays in active tickets (it is open)" \
    "1" \
    "$(test -f "$TMPDIR_TICKETS/child-001.md" && echo 1 || echo 0)"

# stderr must mention child-001 as the reason epic-001 was protected
assert_contains \
    "stderr mentions child-001 when protecting epic-001" \
    "child-001" \
    "$stderr_out"

# ── Assertions: deps-based protection regression ──────────────────────────────

# dep-prot-001 must NOT be archived — open-001 lists it as a dep
assert_eq \
    "dep-prot-001 NOT archived (open-001 depends on it via deps[])" \
    "0" \
    "$(test -f "$TMPDIR_TICKETS/archive/dep-prot-001.md" && echo 1 || echo 0)"

# open-001 must remain active
assert_eq \
    "open-001 stays in active tickets (it is open)" \
    "1" \
    "$(test -f "$TMPDIR_TICKETS/open-001.md" && echo 1 || echo 0)"

print_summary
