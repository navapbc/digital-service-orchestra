#!/usr/bin/env bash
# tests/scripts/test-tk-create-double-dash.sh
#
# Verifies that tk create -d treats double-dash (--) inside description text
# as literal characters, not as an option-flag separator.
#
# Bug: dso-3e30 — tk create -d interprets -- in description as option flags
#
# Two failure modes:
#   1. tk create receives -- as a discrete argument (from eval re-parsing in
#      nohup-launch.sh) and errors with "Unknown option: --"
#   2. tk create description string contains -- inline (less common, works
#      currently because quoting is preserved in direct invocation)
#
# Usage: bash tests/scripts/test-tk-create-double-dash.sh

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

echo "=== test-tk-create-double-dash.sh ==="

# ── Test 1: -- as a discrete argument does not error ─────────────────────────
#
# This is the primary failure mode: when nohup-launch.sh eval-expands a
# command like: tk create "title" -d "foo -- bar"
# eval splits "foo -- bar" into three tokens: foo  --  bar
# So tk receives: create "title" -d foo -- bar
# The bare -- hits the -*) catch-all and returns "Unknown option: --"

echo "Test 1: bare -- as discrete arg is treated as stop-opts sentinel (not an error)"
TMPDIR_T1=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T1")
export TICKETS_DIR="$TMPDIR_T1"

stderr_file="$TMPDIR_T1/stderr.txt"
# Pass -- as a discrete argument between -d value and remaining args
out=$("$TK_SCRIPT" create "Test title" -t task -d "foo" -- "bar" 2>"$stderr_file")
exit_code=$?
stderr_content=$(cat "$stderr_file")

if [[ "$exit_code" -ne 0 ]] && echo "$stderr_content" | grep -q "Unknown option: --"; then
    echo "  FAIL: tk create errored with 'Unknown option: --' when -- was passed as discrete arg" >&2
    echo "    stderr: $stderr_content" >&2
    (( FAIL++ ))
elif [[ "$exit_code" -ne 0 ]]; then
    echo "  FAIL: tk create exited $exit_code unexpectedly" >&2
    echo "    stderr: $stderr_content" >&2
    (( FAIL++ ))
else
    echo "  PASS: exited 0, -- treated as stop-options sentinel"
    (( PASS++ ))
fi

# ── Test 2: description containing -- inline is accepted and stored ───────────

echo "Test 2: description with -- inline is accepted and stored verbatim"
TMPDIR_T2=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T2")
export TICKETS_DIR="$TMPDIR_T2"

ticket_id=$("$TK_SCRIPT" create "Desc double-dash test" -t task -d "before -- after" 2>&1)
exit2=$?

if [[ "$exit2" -ne 0 ]]; then
    echo "  FAIL: tk create exited $exit2 (expected 0), output: $ticket_id" >&2
    (( FAIL++ ))
else
    ticket_id=$(echo "$ticket_id" | tr -d '[:space:]')
    ticket_file=$(find "$TMPDIR_T2" -name "${ticket_id}.md" 2>/dev/null | head -1)
    if [[ -z "$ticket_file" ]]; then
        echo "  FAIL: ticket file for $ticket_id not found in $TMPDIR_T2" >&2
        (( FAIL++ ))
    elif grep -q "before -- after" "$ticket_file"; then
        echo "  PASS: description 'before -- after' stored verbatim in ticket"
        (( PASS++ ))
    else
        echo "  FAIL: description not found or mangled in ticket file" >&2
        cat "$ticket_file" >&2
        (( FAIL++ ))
    fi
fi

# ── Test 3: nohup-launch eval simulation — discrete args with -- in value ─────
#
# Simulates what nohup-launch.sh does: joins args with IFS then eval-re-parses.
# Before the fix, "tk create title -d 'foo -- bar'" becomes:
#   eval "tk create title -d foo -- bar"
# After the fix, nohup-launch.sh uses "${@:5}" for multi-arg commands, so
# each argument is passed as a discrete token without re-parsing.
# This test verifies the tk parser handles -- as stop-opts when nohup-
# style invocation is used.

echo "Test 3: nohup-launch eval simulation — tk create survives -- in arg stream"
TMPDIR_T3=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T3")
export TICKETS_DIR="$TMPDIR_T3"

stderr3="$TMPDIR_T3/stderr.txt"
# Replicate what eval does: -- appears as a discrete word before remaining args
tid3=$("$TK_SCRIPT" create "Flag in desc test" -t task \
    -d "DSO_ROOT came from the config fallback" -- "when Claude Code sets it correctly" \
    2>"$stderr3")
exit3=$?
stderr3_content=$(cat "$stderr3")

if echo "$stderr3_content" | grep -q "Unknown option: --"; then
    echo "  FAIL: tk create errored 'Unknown option: --' in nohup eval simulation" >&2
    echo "    stderr: $stderr3_content" >&2
    (( FAIL++ ))
elif [[ "$exit3" -ne 0 ]]; then
    echo "  FAIL: tk create exited $exit3 unexpectedly" >&2
    echo "    stderr: $stderr3_content" >&2
    (( FAIL++ ))
else
    echo "  PASS: -- treated as stop-opts sentinel, ticket created"
    (( PASS++ ))
fi

# ── Report ────────────────────────────────────────────────────────────────────

print_results
