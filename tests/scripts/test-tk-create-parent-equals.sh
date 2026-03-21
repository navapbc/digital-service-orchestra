#!/usr/bin/env bash
# tests/scripts/test-tk-create-parent-equals.sh
#
# Verifies that tk create accepts --parent=<id> (equals form) as well as
# --parent <id> (space form) when specifying a parent ticket.
#
# Bug: dso-1aaa — tk create rejects --parent=id flag (only --parent id works)
#
# Usage: bash tests/scripts/test-tk-create-parent-equals.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
TK_SCRIPT="$DSO_PLUGIN_DIR/scripts/tk"

source "$SCRIPT_DIR/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-tk-create-parent-equals.sh ==="

# ── Setup: create a parent ticket to reference ────────────────────────────────

TMPDIR_BASE=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_BASE")
export TICKETS_DIR="$TMPDIR_BASE"

parent_id=$("$TK_SCRIPT" create "Parent epic for dso-1aaa test" -t epic 2>&1)
if [[ $? -ne 0 ]]; then
    echo "SKIP: could not create parent ticket: $parent_id" >&2
    exit 1
fi
parent_id=$(echo "$parent_id" | tr -d '[:space:]')

# ── Test 1: --parent=<id> equals form is accepted ────────────────────────────

echo "Test 1: --parent=<id> (equals form) is accepted without error"

TMPDIR_T1=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T1")
export TICKETS_DIR="$TMPDIR_T1"

# Copy parent ticket into the new TICKETS_DIR so ticket_path resolution works
cp -r "$TMPDIR_BASE/." "$TMPDIR_T1/"

stderr_file="$TMPDIR_T1/stderr.txt"
out=$("$TK_SCRIPT" create "Child story equals form" -t story "--parent=${parent_id}" 2>"$stderr_file")
exit_code=$?
stderr_content=$(cat "$stderr_file")

if echo "$stderr_content" | grep -q "Unknown option: --parent="; then
    echo "  FAIL: tk create rejected --parent= form with 'Unknown option: --parent=...'" >&2
    echo "    stderr: $stderr_content" >&2
    (( FAIL++ ))
elif [[ "$exit_code" -ne 0 ]]; then
    echo "  FAIL: tk create exited $exit_code unexpectedly" >&2
    echo "    stderr: $stderr_content" >&2
    (( FAIL++ ))
else
    echo "  PASS: --parent=<id> accepted, exited 0"
    (( PASS++ ))
fi

# ── Test 2: --parent=<id> equals form sets parent field in ticket file ────────

echo "Test 2: --parent=<id> equals form stores parent field in ticket frontmatter"

child_id=$(echo "$out" | tr -d '[:space:]')
if [[ -z "$child_id" ]]; then
    echo "  SKIP: no child ticket ID returned (test 1 may have failed)" >&2
    (( FAIL++ ))
else
    child_file=$(find "$TMPDIR_T1" -name "${child_id}.md" 2>/dev/null | head -1)
    if [[ -z "$child_file" ]]; then
        echo "  FAIL: child ticket file for $child_id not found" >&2
        (( FAIL++ ))
    elif grep -q "^parent: ${parent_id}" "$child_file"; then
        echo "  PASS: parent field '${parent_id}' stored in ticket frontmatter"
        (( PASS++ ))
    else
        echo "  FAIL: parent field not found or incorrect in ticket file" >&2
        cat "$child_file" >&2
        (( FAIL++ ))
    fi
fi

# ── Test 3: --parent <id> space form still works (regression guard) ───────────

echo "Test 3: --parent <id> (space form) still works"

TMPDIR_T3=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T3")
export TICKETS_DIR="$TMPDIR_T3"
cp -r "$TMPDIR_BASE/." "$TMPDIR_T3/"

stderr3="$TMPDIR_T3/stderr.txt"
out3=$("$TK_SCRIPT" create "Child story space form" -t story --parent "$parent_id" 2>"$stderr3")
exit3=$?
stderr3_content=$(cat "$stderr3")

if [[ "$exit3" -ne 0 ]]; then
    echo "  FAIL: --parent <id> (space form) exited $exit3 unexpectedly" >&2
    echo "    stderr: $stderr3_content" >&2
    (( FAIL++ ))
else
    echo "  PASS: --parent <id> accepted, exited 0"
    (( PASS++ ))
fi

# ── Test 4: invalid parent ID produces an error (not a silent failure) ─────────

echo "Test 4: invalid parent ID with --parent= produces an error"

TMPDIR_T4=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T4")
export TICKETS_DIR="$TMPDIR_T4"

stderr4="$TMPDIR_T4/stderr.txt"
out4=$("$TK_SCRIPT" create "Child with bad parent" -t story "--parent=nonexistent-xyz" 2>"$stderr4")
exit4=$?

if [[ "$exit4" -eq 0 ]]; then
    echo "  FAIL: expected non-zero exit for invalid parent ID, got 0" >&2
    (( FAIL++ ))
else
    echo "  PASS: invalid parent ID rejected with exit $exit4"
    (( PASS++ ))
fi

# ── Report ────────────────────────────────────────────────────────────────────

print_results
