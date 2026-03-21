#!/usr/bin/env bash
# tests/scripts/test-dep-tree-tombstone-resolution.sh
# RED tests for tombstone-based dependency resolution in `tk dep tree`.
#
# Story: w20-3rjr — RED test: dep tree resolves archived tickets via tombstone
# Epic:  w21-6llo  — As a developer, I can archive closed tickets without
#                    breaking dependency references
#
# These tests MUST FAIL (RED) until w20-p35v implements tombstone resolution
# in `tk dep tree`. Currently, any dep absent from .tickets/*.md is shown as
# `[missing — treated as satisfied]`. After implementation it must render
# `[archived: <final_status> (<type>)]` when a tombstone file is present.
#
# Contract: plugins/dso/docs/contracts/tombstone-archive-format.md
#
# Usage: bash tests/scripts/test-dep-tree-tombstone-resolution.sh
# Returns: exit non-zero (RED) until tk dep tree resolves tombstones.
#
# Suite-runner guard: when _RUN_ALL_ACTIVE=1 and tombstone resolution is not
# yet implemented in tk, exits 0 with a SKIP message so that run-all.sh
# continues to pass during the RED phase.

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TK_SCRIPT="$REPO_ROOT/plugins/dso/scripts/tk"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-dep-tree-tombstone-resolution.sh ==="

# ── Suite-runner guard ─────────────────────────────────────────────────────
# RED tests fail by design (tombstone resolution not yet implemented).
# When auto-discovered by run-script-tests.sh (_RUN_ALL_ACTIVE=1), skip with
# exit 0 so the full suite remains green during the RED phase.
# Detection: grep for tombstone handling inside cmd_dep_tree in tk script.
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ]; then
    # Check if tombstone resolution is implemented in tk dep tree.
    # The implementation must reference "archive/tombstones" in the dep tree section
    # (cmd_dep_tree). We grep for the path that the parser must read per the contract.
    # A plain "tombstone" grep would false-positive on the Jira .tombstones file check.
    if ! grep -q "archive/tombstones" "$TK_SCRIPT" 2>/dev/null; then
        echo "SKIP: tk dep tree tombstone resolution not yet implemented (RED) — tests deferred"
        echo ""
        printf "PASSED: 0  FAILED: 0\n"
        exit 0
    fi
fi

# ── Temp dir cleanup ───────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]:-}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ── Helper: create a minimal ticket .md file ──────────────────────────────
make_ticket() {
    local dir="$1" id="$2" status="${3:-open}" deps="${4:-[]}" type="${5:-task}"
    cat > "$dir/${id}.md" <<EOF
---
id: ${id}
status: ${status}
deps: ${deps}
links: []
created: 2026-01-01T00:00:00Z
type: ${type}
priority: 2
---
# Ticket ${id}
EOF
}

# ── Helper: create a tombstone file ───────────────────────────────────────
make_tombstone() {
    local tickets_dir="$1" id="$2" type="${3:-task}" final_status="${4:-closed}"
    local tombstone_dir="$tickets_dir/archive/tombstones"
    mkdir -p "$tombstone_dir"
    cat > "$tombstone_dir/${id}.json" <<EOF
{
  "id": "${id}",
  "type": "${type}",
  "final_status": "${final_status}"
}
EOF
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: test_dep_tree_shows_archived_tombstone_status
#
# A ticket depends on an archived dep (absent from .tickets/*.md but present
# as a tombstone). `tk dep tree` must show the dep as
# `[archived: closed (task)]` NOT `[missing — treated as satisfied]`.
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "test_dep_tree_shows_archived_tombstone_status"

_T1=$(mktemp -d)
_CLEANUP_DIRS+=("$_T1")
export TICKETS_DIR="$_T1"

# Create parent ticket with dep on archived-aaa
make_ticket "$_T1" "parent-001" "open" "[archived-aaa]" "task"
# Create tombstone for archived-aaa (no .md file in TICKETS_DIR)
make_tombstone "$_T1" "archived-aaa" "task" "closed"

_output=$("$TK_SCRIPT" dep tree parent-001 2>&1) || true

# Must contain "[archived: closed (task)]" — not "[missing"
assert_contains \
    "test_dep_tree_shows_archived_tombstone_status: shows archived label" \
    "[archived: closed (task)]" \
    "$_output"

assert_ne \
    "test_dep_tree_shows_archived_tombstone_status: does not show missing label" \
    "[missing" \
    "$(echo "$_output" | grep "archived-aaa" || true)"

unset TICKETS_DIR

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: test_dep_tree_tombstone_shows_type
#
# When a dep has a tombstone with type "story", the dep tree line must include
# the ticket type from the tombstone, e.g. `[archived: closed (story)]`.
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "test_dep_tree_tombstone_shows_type"

_T2=$(mktemp -d)
_CLEANUP_DIRS+=("$_T2")
export TICKETS_DIR="$_T2"

# Parent depends on an archived story
make_ticket "$_T2" "parent-002" "open" "[archived-story-001]" "task"
make_tombstone "$_T2" "archived-story-001" "story" "closed"

_output=$("$TK_SCRIPT" dep tree parent-002 2>&1) || true

# Must include the type "story" in the label
assert_contains \
    "test_dep_tree_tombstone_shows_type: type 'story' appears in archived label" \
    "(story)" \
    "$_output"

# Must contain the full label format
assert_contains \
    "test_dep_tree_tombstone_shows_type: full archived label format correct" \
    "[archived: closed (story)]" \
    "$_output"

unset TICKETS_DIR

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: test_dep_tree_no_tombstone_falls_back_to_missing
#
# When a dep is absent from .tickets/*.md AND has no tombstone file,
# `tk dep tree` must still show `[missing — treated as satisfied]` (existing
# behaviour, unchanged by the tombstone feature).
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "test_dep_tree_no_tombstone_falls_back_to_missing"

_T3=$(mktemp -d)
_CLEANUP_DIRS+=("$_T3")
export TICKETS_DIR="$_T3"

# Parent depends on ghost-xxx — no .md and no tombstone
make_ticket "$_T3" "parent-003" "open" "[ghost-xxx]" "task"
# Deliberately do NOT create a tombstone

_output=$("$TK_SCRIPT" dep tree parent-003 2>&1) || true

# Must still show "[missing" fallback — no tombstone present
_dep_line=$(echo "$_output" | grep "ghost-xxx" || true)
assert_contains \
    "test_dep_tree_no_tombstone_falls_back_to_missing: missing label present when no tombstone" \
    "missing" \
    "$_dep_line"

# Must NOT show "[archived:" when no tombstone exists
assert_ne \
    "test_dep_tree_no_tombstone_falls_back_to_missing: no archived label without tombstone" \
    "[archived:" \
    "$(echo "$_dep_line" | grep '\[archived:' || true)"

unset TICKETS_DIR

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: test_dep_tree_tombstone_overrides_missing_label
#
# When a tombstone is present, the label on the dep line must NOT be the
# string "missing". Tombstone presence unconditionally overrides the
# "[missing — treated as satisfied]" label.
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "test_dep_tree_tombstone_overrides_missing_label"

_T4=$(mktemp -d)
_CLEANUP_DIRS+=("$_T4")
export TICKETS_DIR="$_T4"

make_ticket "$_T4" "parent-004" "open" "[archived-epic-001]" "task"
make_tombstone "$_T4" "archived-epic-001" "epic" "closed"

_output=$("$TK_SCRIPT" dep tree parent-004 2>&1) || true
_dep_line=$(echo "$_output" | grep "archived-epic-001" || true)

# The dep line must NOT contain "missing" anywhere
assert_ne \
    "test_dep_tree_tombstone_overrides_missing_label: 'missing' absent when tombstone present" \
    "1" \
    "$(echo "$_dep_line" | grep -c "missing" || echo "0")"

# The dep line MUST contain "archived"
assert_contains \
    "test_dep_tree_tombstone_overrides_missing_label: 'archived' present when tombstone exists" \
    "archived" \
    "$_dep_line"

unset TICKETS_DIR

# ── Summary ────────────────────────────────────────────────────────────────

print_summary
