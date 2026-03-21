#!/usr/bin/env bash
# tests/scripts/test-archive-tombstone-e2e.sh
# E2E integration test: archive → tombstone → dep tree resolution flow.
#
# Story: w20-0qdg — E2E integration test for archive→tombstone→dep tree
# Epic:  w21-6llo  — As a developer, I can archive closed tickets without
#                    breaking dependency references
#
# Contract: plugins/dso/docs/contracts/tombstone-archive-format.md
#
# This test covers the end-to-end flow:
#   1. Create tickets with dependencies (closed tickets with no active dependents)
#   2. Archive the closed ticket via archive-closed-tickets.sh
#      → tombstone must be created at .tickets/archive/tombstones/<id>.json
#   3. Run `tk dep tree` on a ticket that references the archived dep and verify
#      the archived dep renders as "[archived: closed (<type>)]"
#      (NOT "[missing — treated as satisfied]")
#   4. Run `tk ready` and verify the dependent ticket is in the ready list
#      (the archived dep counts as satisfied)
#
# Key invariant (archive protection):
#   archive-closed-tickets.sh does NOT archive a closed ticket that is still
#   referenced in an active (open/in_progress) ticket's deps[] chain. To trigger
#   archival, the closed ticket must have no active direct/transitive dependents
#   at the time the archiver runs. In these E2E fixtures we simulate a "before
#   state" (active dep present → ticket protected) and an "after state" (dep
#   removed → ticket archived on next run).
#
# Usage: bash tests/scripts/test-archive-tombstone-e2e.sh
# Returns: exit 0 if all assertions pass, exit 1 if any fail.

# NOTE: -e is intentionally omitted — assert helpers return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
ARCHIVE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/archive-closed-tickets.sh"
TK_SCRIPT="$REPO_ROOT/plugins/dso/scripts/tk"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-archive-tombstone-e2e.sh ==="

# ── Pre-flight: verify required scripts exist ──────────────────────────────────

if [[ ! -f "$ARCHIVE_SCRIPT" ]]; then
    echo "FAIL: archive-closed-tickets.sh not found at $ARCHIVE_SCRIPT" >&2
    (( ++FAIL ))
    print_summary
fi

if [[ ! -f "$TK_SCRIPT" ]]; then
    echo "FAIL: tk script not found at $TK_SCRIPT" >&2
    (( ++FAIL ))
    print_summary
fi

# ── Temp dir cleanup ───────────────────────────────────────────────────────────

_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup EXIT

# ── Helper: create a minimal ticket .md file ──────────────────────────────────
# Usage: _make_ticket <dir> <id> <status> <type> <deps>
# deps must be a YAML array string, e.g. "[]" or "[dep-id-001]"
_make_ticket() {
    local dir="$1" id="$2" status="$3" type="$4" deps="$5"
    cat > "$dir/${id}.md" <<EOF
---
id: ${id}
status: ${status}
type: ${type}
deps: ${deps}
links: []
created: 2026-01-01T00:00:00Z
priority: 2
---
# Ticket ${id}
EOF
}

# ── Helper: make a fresh temp tickets dir ──────────────────────────────────────
_make_tickets_dir() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ══════════════════════════════════════════════════════════════════════════════
# Scenario A: Unblocking flow
#
# A closed ticket (dep-a) has no active dependents → gets archived → tombstone
# created. A separate open ticket (open-a) references dep-a in its deps list.
# After archival:
#   - dep-a is in .tickets/archive/ with a tombstone
#   - dep tree for open-a shows dep-a as "[archived: closed (task)]"
#   - tk ready includes open-a (archived dep treated as satisfied)
#
# Note: to trigger archival, dep-a must have no active dependents. Here open-a
# lists dep-a in deps[], which would ordinarily protect dep-a. So we simulate
# the correct "prior state": dep-a is created standalone and archived first
# (without open-a present), then open-a is introduced.
#
# Two-phase fixture:
#   Phase 1: dep-a alone (closed, no active dependents) → archiver runs → tombstone
#   Phase 2: open-a added (deps: [dep-a]) → dep tree + tk ready consulted
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "scenario_a_archive_then_dep_tree_and_ready"
_snapshot_fail

TICKETS_DIR_A=$(_make_tickets_dir)

# Phase 1: only dep-a present (closed, no active ticket depends on it)
_make_ticket "$TICKETS_DIR_A" "dep-a" "closed" "task" "[]"

# Run archive — dep-a has no active dependents so it should be archived
TICKETS_DIR="$TICKETS_DIR_A" bash "$ARCHIVE_SCRIPT" >/dev/null 2>&1 || true

# Verify dep-a was archived
assert_eq \
    "scenario_a: dep-a no longer in active tickets/" \
    "0" \
    "$(test -f "$TICKETS_DIR_A/dep-a.md" && echo 1 || echo 0)"

assert_eq \
    "scenario_a: dep-a.md present in archive/" \
    "1" \
    "$(test -f "$TICKETS_DIR_A/archive/dep-a.md" && echo 1 || echo 0)"

# Verify tombstone was created
assert_eq \
    "scenario_a: tombstone created at archive/tombstones/dep-a.json" \
    "1" \
    "$(test -f "$TICKETS_DIR_A/archive/tombstones/dep-a.json" && echo 1 || echo 0)"

# Verify tombstone content
tombstone_a="$TICKETS_DIR_A/archive/tombstones/dep-a.json"
if [[ -f "$tombstone_a" ]]; then
    ts_a_id=$(python3 -c "import json; d=json.load(open('$tombstone_a')); print(d.get('id','MISSING'))" 2>&1)
    ts_a_type=$(python3 -c "import json; d=json.load(open('$tombstone_a')); print(d.get('type','MISSING'))" 2>&1)
    ts_a_status=$(python3 -c "import json; d=json.load(open('$tombstone_a')); print(d.get('final_status','MISSING'))" 2>&1)

    assert_eq "scenario_a: tombstone id = dep-a"          "dep-a"  "$ts_a_id"
    assert_eq "scenario_a: tombstone type = task"         "task"   "$ts_a_type"
    assert_eq "scenario_a: tombstone final_status = closed" "closed" "$ts_a_status"
fi

# Phase 2: introduce open-a that references dep-a (now archived)
_make_ticket "$TICKETS_DIR_A" "open-a" "open" "task" "[dep-a]"

# Verify dep tree shows dep-a as archived (not "missing")
dep_tree_a=$(TICKETS_DIR="$TICKETS_DIR_A" bash "$TK_SCRIPT" dep tree open-a 2>/dev/null) || true

assert_contains \
    "scenario_a: dep tree shows dep-a as [archived: closed (task)]" \
    "[archived: closed (task)]" \
    "$dep_tree_a"

# Ensure the "missing" fallback is NOT used
dep_missing_a=$(echo "$dep_tree_a" | grep "dep-a" | grep "missing" || true)
assert_eq \
    "scenario_a: dep tree does NOT render dep-a as missing" \
    "" \
    "$dep_missing_a"

# Verify tk ready includes open-a (dep-a archived = treated as satisfied)
ready_a=$(TICKETS_DIR="$TICKETS_DIR_A" bash "$TK_SCRIPT" ready 2>/dev/null) || true

assert_contains \
    "scenario_a: tk ready includes open-a (archived dep treated as satisfied)" \
    "open-a" \
    "$ready_a"

assert_pass_if_clean "scenario_a_archive_then_dep_tree_and_ready"

# ══════════════════════════════════════════════════════════════════════════════
# Scenario B: Chain — multiple closed tickets archived together, producing
# multiple tombstones. An open ticket referencing the direct dep sees it
# rendered as archived.
#
# Fixture (both closed tickets archived in one run):
#   dep-b1 — closed task  (no deps, no active dependents)
#   dep-b2 — closed story (no deps, no active dependents)
#   open-b — open task    (deps: [dep-b1]) — added AFTER archival
#
# Expected flow:
#   1. Archive dep-b1 and dep-b2 in one run → two tombstones
#   2. open-b introduced; dep tree for open-b shows dep-b1 as archived
#   3. tk ready includes open-b
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "scenario_b_multiple_closed_archived_one_run"
_snapshot_fail

TICKETS_DIR_B=$(_make_tickets_dir)
_make_ticket "$TICKETS_DIR_B" "dep-b1" "closed" "task"  "[]"
_make_ticket "$TICKETS_DIR_B" "dep-b2" "closed" "story" "[]"

TICKETS_DIR="$TICKETS_DIR_B" bash "$ARCHIVE_SCRIPT" >/dev/null 2>&1 || true

# Both closed tickets archived
assert_eq \
    "scenario_b: dep-b1 archived" \
    "1" \
    "$(test -f "$TICKETS_DIR_B/archive/dep-b1.md" && echo 1 || echo 0)"

assert_eq \
    "scenario_b: dep-b2 archived" \
    "1" \
    "$(test -f "$TICKETS_DIR_B/archive/dep-b2.md" && echo 1 || echo 0)"

# Both tombstones exist
assert_eq \
    "scenario_b: tombstone for dep-b1 created" \
    "1" \
    "$(test -f "$TICKETS_DIR_B/archive/tombstones/dep-b1.json" && echo 1 || echo 0)"

assert_eq \
    "scenario_b: tombstone for dep-b2 created" \
    "1" \
    "$(test -f "$TICKETS_DIR_B/archive/tombstones/dep-b2.json" && echo 1 || echo 0)"

# Tombstone type for story
tombstone_b2="$TICKETS_DIR_B/archive/tombstones/dep-b2.json"
if [[ -f "$tombstone_b2" ]]; then
    ts_b2_type=$(python3 -c "import json; d=json.load(open('$tombstone_b2')); print(d.get('type','MISSING'))" 2>&1)
    assert_eq "scenario_b: tombstone type for story ticket = story" "story" "$ts_b2_type"
fi

# Introduce open-b referencing dep-b1 (now archived)
_make_ticket "$TICKETS_DIR_B" "open-b" "open" "task" "[dep-b1]"

dep_tree_b=$(TICKETS_DIR="$TICKETS_DIR_B" bash "$TK_SCRIPT" dep tree open-b 2>/dev/null) || true

assert_contains \
    "scenario_b: dep tree shows dep-b1 as [archived: closed (task)]" \
    "[archived: closed (task)]" \
    "$dep_tree_b"

ready_b=$(TICKETS_DIR="$TICKETS_DIR_B" bash "$TK_SCRIPT" ready 2>/dev/null) || true

assert_contains \
    "scenario_b: tk ready includes open-b" \
    "open-b" \
    "$ready_b"

assert_pass_if_clean "scenario_b_multiple_closed_archived_one_run"

# ══════════════════════════════════════════════════════════════════════════════
# Scenario C: Protected ticket — closed ticket with an open dependent must NOT
# be archived, and must NOT receive a tombstone.
#
# Fixture:
#   dep-c    — closed task  (no deps)
#   open-c   — open task    (deps: [dep-c])
#
# The archiver protects dep-c because open-c depends on it.
# After running the archiver:
#   - dep-c remains in .tickets/ (NOT archived)
#   - no tombstone created for dep-c
#   - dep tree for open-c shows dep-c as "[closed]" (still in active tickets)
#   - tk ready includes open-c (its dep dep-c is closed in active tickets)
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "scenario_c_protected_dep_not_archived"
_snapshot_fail

TICKETS_DIR_C=$(_make_tickets_dir)
_make_ticket "$TICKETS_DIR_C" "dep-c"  "closed" "task" "[]"
_make_ticket "$TICKETS_DIR_C" "open-c" "open"   "task" "[dep-c]"

TICKETS_DIR="$TICKETS_DIR_C" bash "$ARCHIVE_SCRIPT" >/dev/null 2>&1 || true

# dep-c must stay in active tickets (protected by open-c's dep reference)
assert_eq \
    "scenario_c: dep-c stays in active tickets/ (protected)" \
    "1" \
    "$(test -f "$TICKETS_DIR_C/dep-c.md" && echo 1 || echo 0)"

assert_eq \
    "scenario_c: dep-c NOT in archive/" \
    "0" \
    "$(test -f "$TICKETS_DIR_C/archive/dep-c.md" && echo 1 || echo 0)"

# No tombstone for a non-archived ticket
assert_eq \
    "scenario_c: no tombstone for dep-c (not archived)" \
    "0" \
    "$(test -f "$TICKETS_DIR_C/archive/tombstones/dep-c.json" && echo 1 || echo 0)"

# dep tree shows dep-c as [closed] — it's still in active tickets
dep_tree_c=$(TICKETS_DIR="$TICKETS_DIR_C" bash "$TK_SCRIPT" dep tree open-c 2>/dev/null) || true

assert_contains \
    "scenario_c: dep tree shows dep-c as [closed] (not archived)" \
    "dep-c [closed]" \
    "$dep_tree_c"

# No [archived:] label should appear
dep_archived_c=$(echo "$dep_tree_c" | grep "archived" || true)
assert_eq \
    "scenario_c: dep tree does not show archived label (dep-c not archived)" \
    "" \
    "$dep_archived_c"

# open-c must still appear in tk ready (dep-c is closed)
ready_c=$(TICKETS_DIR="$TICKETS_DIR_C" bash "$TK_SCRIPT" ready 2>/dev/null) || true

assert_contains \
    "scenario_c: tk ready includes open-c (dep is closed in active tickets)" \
    "open-c" \
    "$ready_c"

assert_pass_if_clean "scenario_c_protected_dep_not_archived"

# ══════════════════════════════════════════════════════════════════════════════
# Scenario D: Idempotency — running the archiver twice must not create
# duplicate tombstones or corrupt the tombstone file.
#
# Fixture:
#   dep-d — closed task (no deps, no active dependents)
#
# Expected flow:
#   1. First archiver run → dep-d archived, tombstone written
#   2. Second archiver run → no-op; tombstone unchanged; exactly 1 tombstone file
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "scenario_d_archiver_idempotency"
_snapshot_fail

TICKETS_DIR_D=$(_make_tickets_dir)
_make_ticket "$TICKETS_DIR_D" "dep-d" "closed" "task" "[]"

# First run
TICKETS_DIR="$TICKETS_DIR_D" bash "$ARCHIVE_SCRIPT" >/dev/null 2>&1 || true

# Second run (idempotent — dep-d already in archive/)
TICKETS_DIR="$TICKETS_DIR_D" bash "$ARCHIVE_SCRIPT" >/dev/null 2>&1 || true

# Still exactly one tombstone file (no duplicates)
tombstone_count_d=$(find "$TICKETS_DIR_D/archive/tombstones" -name "*.json" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
assert_eq \
    "scenario_d: exactly 1 tombstone file after two archiver runs" \
    "1" \
    "$tombstone_count_d"

# Tombstone content is still valid
tombstone_d="$TICKETS_DIR_D/archive/tombstones/dep-d.json"
if [[ -f "$tombstone_d" ]]; then
    ts_d_id=$(python3 -c "import json; d=json.load(open('$tombstone_d')); print(d.get('id','MISSING'))" 2>&1)
    assert_eq "scenario_d: tombstone id still correct after second run" "dep-d" "$ts_d_id"

    ts_d_count=$(python3 -c "import json; d=json.load(open('$tombstone_d')); print(len(d.keys()))" 2>&1)
    assert_eq "scenario_d: tombstone still has exactly 3 fields" "3" "$ts_d_count"
fi

assert_pass_if_clean "scenario_d_archiver_idempotency"

# ── Summary ────────────────────────────────────────────────────────────────────

print_summary
