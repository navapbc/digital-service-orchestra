#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-tk-dep-rm.sh
#
# Tests for `tk dep rm A B` — removes dependency of A on B.
#
# Bug: `tk dep rm A B` was silently adding the dependency instead of removing it
# because cmd_dep() had no branch for the `rm` subcommand, causing it to fall
# through to the add logic with id="rm", dep_id="A".
#
# Usage: bash lockpick-workflow/tests/scripts/test-tk-dep-rm.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
TK_SCRIPT="$PLUGIN_ROOT/scripts/tk"

source "$SCRIPT_DIR/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-tk-dep-rm.sh ==="

# ── Helpers ──────────────────────────────────────────────────────────────────

TICKETS_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TICKETS_DIR")
export TICKETS_DIR

make_ticket() {
    local id="$1"
    local deps="${2:-[]}"
    cat > "$TICKETS_DIR/${id}.md" <<EOF
---
id: ${id}
status: open
title: Ticket ${id}
deps: ${deps}
links: []
created: 2026-03-08T00:00:00Z
type: task
priority: 2
---
# Ticket ${id}
EOF
}

# ── Test 1 (RED): dep rm removes an existing dependency ─────────────────────
# This test currently FAILS because dep rm falls through to add behavior.

echo "Test 1: dep rm removes existing dependency"
TMPDIR_T1=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T1")
OLD_TICKETS_DIR="$TICKETS_DIR"
export TICKETS_DIR="$TMPDIR_T1"

make_ticket "ticket-aaa"
make_ticket "ticket-bbb"

# Add the dep first
"$TK_SCRIPT" dep ticket-aaa ticket-bbb > /dev/null 2>&1

# Confirm dep was added
deps_before=$(grep '^deps:' "$TMPDIR_T1/ticket-aaa.md")
if echo "$deps_before" | grep -q "ticket-bbb"; then
    echo "  setup: dep added OK ($deps_before)"
else
    echo "  FAIL: setup failed — dep not added ($deps_before)" >&2
    (( FAIL++ ))
    rm -rf "$TMPDIR_T1"
    TICKETS_DIR="$OLD_TICKETS_DIR"
    print_results
fi

# Now remove the dep
output=$("$TK_SCRIPT" dep rm ticket-aaa ticket-bbb 2>&1)
exit_code=$?

# Check dep is gone
deps_after=$(grep '^deps:' "$TMPDIR_T1/ticket-aaa.md")

if [[ "$exit_code" -eq 0 ]] && echo "$deps_after" | grep -q "^\s*deps: \[\]"; then
    echo "  PASS: dep rm removed dependency (deps now: $deps_after)"
    (( PASS++ ))
else
    echo "  FAIL: dep rm did not remove dependency" >&2
    echo "    exit_code=$exit_code" >&2
    echo "    output: $output" >&2
    echo "    deps_after: $deps_after" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T1"
TICKETS_DIR="$OLD_TICKETS_DIR"

# ── Test 2: dep rm on non-existent dependency returns error ──────────────────

echo "Test 2: dep rm on non-existent dependency returns non-zero exit"
TMPDIR_T2=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T2")
export TICKETS_DIR="$TMPDIR_T2"

make_ticket "ticket-ccc"
make_ticket "ticket-ddd"
# No dep added between ccc and ddd

output=$("$TK_SCRIPT" dep rm ticket-ccc ticket-ddd 2>&1)
exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
    echo "  PASS: dep rm on non-existent dep exits non-zero (got $exit_code)"
    (( PASS++ ))
else
    echo "  FAIL: dep rm on non-existent dep should exit non-zero, got 0" >&2
    echo "    output: $output" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T2"
TICKETS_DIR="$OLD_TICKETS_DIR"

# ── Test 3: dep add still works (no regression) ──────────────────────────────

echo "Test 3: dep add still works after fix (regression guard)"
TMPDIR_T3=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T3")
export TICKETS_DIR="$TMPDIR_T3"

make_ticket "ticket-eee"
make_ticket "ticket-fff"

output=$("$TK_SCRIPT" dep ticket-eee ticket-fff 2>&1)
exit_code=$?

deps=$(grep '^deps:' "$TMPDIR_T3/ticket-eee.md")
if [[ "$exit_code" -eq 0 ]] && echo "$deps" | grep -q "ticket-fff"; then
    echo "  PASS: dep add still works ($deps)"
    (( PASS++ ))
else
    echo "  FAIL: dep add regression" >&2
    echo "    exit_code=$exit_code output=$output deps=$deps" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T3"
TICKETS_DIR="$OLD_TICKETS_DIR"

# ── Report ────────────────────────────────────────────────────────────────────

print_results
