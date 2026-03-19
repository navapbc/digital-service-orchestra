#!/usr/bin/env bash
# tests/scripts/test-tk-create-title-dedup.sh
#
# RED phase: tests that tk create rejects a duplicate title.
#
# Verifies:
#   1. Second tk create with the same title exits non-zero
#   2. Stderr from the second call contains the first ticket's ID
#
# TDD: This test FAILS at RED phase because cmd_create has no title dedup check.
# The GREEN phase (w21-r8rd) will add the guard to cmd_create.
#
# Usage: bash tests/scripts/test-tk-create-title-dedup.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
TK_SCRIPT="$DSO_PLUGIN_DIR/scripts/tk"

source "$SCRIPT_DIR/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-tk-create-title-dedup.sh ==="

# ── Test 1: duplicate title is rejected ──────────────────────────────────────
#
# Create a ticket with "My Title", capture its ID.
# Attempt a second tk create with the same title.
# Assert: second call exits non-zero AND stderr contains the first ticket's ID.

echo "Test 1: duplicate title rejected — second create exits non-zero with first ID in stderr"
TMPDIR_T1=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T1")
export TICKETS_DIR="$TMPDIR_T1"

# Create the first ticket
first_output=$("$TK_SCRIPT" create "My Title" -t task -p 2 2>&1)
first_exit=$?
first_id=$(echo "$first_output" | tr -d '[:space:]')

if [[ "$first_exit" -ne 0 ]] || [[ -z "$first_id" ]]; then
    echo "  FAIL: setup — first tk create failed (exit=$first_exit, output=$first_output)" >&2
    (( FAIL++ ))
else
    echo "  setup: first ticket created: $first_id"

    # Attempt duplicate title
    # No set -e, so non-zero exit won't abort — capture exit code directly
    second_stderr=$("$TK_SCRIPT" create "My Title" -t task -p 2 2>"$TMPDIR_T1/stderr.txt")
    second_exit=$?
    second_stderr_content=$(cat "$TMPDIR_T1/stderr.txt")

    # Assert: exits non-zero
    if [[ "$second_exit" -eq 0 ]]; then
        echo "  FAIL: second create with duplicate title should exit non-zero, got 0" >&2
        echo "    stderr: $second_stderr_content" >&2
        (( FAIL++ ))
    else
        echo "  PASS (non-zero exit): second create exited $second_exit"

        # Assert: stderr contains first ticket's ID
        if echo "$second_stderr_content" | grep -q "$first_id"; then
            echo "  PASS (first ID in stderr): stderr contains '$first_id'"
            (( PASS++ ))
        else
            echo "  FAIL: stderr should contain first ticket's ID ('$first_id')" >&2
            echo "    stderr was: $second_stderr_content" >&2
            (( FAIL++ ))
        fi
    fi
fi

rm -rf "$TMPDIR_T1"

# ── Test 2: different titles are not rejected (no false positives) ────────────
#
# Guard against overly aggressive dedup: two distinct titles should both succeed.

echo "Test 2: distinct titles both accepted — no false positive rejection"
TMPDIR_T2=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T2")
export TICKETS_DIR="$TMPDIR_T2"

out1=$("$TK_SCRIPT" create "Title Alpha" -t task -p 2 2>&1)
exit1=$?
id1=$(echo "$out1" | tr -d '[:space:]')

out2=$("$TK_SCRIPT" create "Title Beta" -t task -p 2 2>&1)
exit2=$?
id2=$(echo "$out2" | tr -d '[:space:]')

if [[ "$exit1" -eq 0 ]] && [[ "$exit2" -eq 0 ]] && [[ -n "$id1" ]] && [[ -n "$id2" ]] && [[ "$id1" != "$id2" ]]; then
    echo "  PASS: both distinct titles accepted ($id1, $id2)"
    (( PASS++ ))
else
    echo "  FAIL: distinct titles should both be accepted" >&2
    echo "    exit1=$exit1 id1=$id1 exit2=$exit2 id2=$id2" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T2"

# ── Test 3: case-sensitive match — same case is duplicate ────────────────────
#
# "My Title" created twice should trigger the guard (exact-match dedup).

echo "Test 3: exact case match triggers dedup guard"
TMPDIR_T3=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T3")
export TICKETS_DIR="$TMPDIR_T3"

base_out=$("$TK_SCRIPT" create "Duplicate Guard Test" -t task -p 3 2>&1)
base_exit=$?
base_id=$(echo "$base_out" | tr -d '[:space:]')

if [[ "$base_exit" -ne 0 ]] || [[ -z "$base_id" ]]; then
    echo "  FAIL: setup — first create failed (exit=$base_exit output=$base_out)" >&2
    (( FAIL++ ))
else
    # No set -e, so non-zero exit won't abort — capture exit code directly
    dup_stderr=$("$TK_SCRIPT" create "Duplicate Guard Test" -t task -p 3 2>"$TMPDIR_T3/stderr3.txt")
    dup_exit=$?
    dup_stderr_content=$(cat "$TMPDIR_T3/stderr3.txt")

    if [[ "$dup_exit" -ne 0 ]] && echo "$dup_stderr_content" | grep -q "$base_id"; then
        echo "  PASS: duplicate rejected with ID '$base_id' in stderr"
        (( PASS++ ))
    else
        echo "  FAIL: expected non-zero exit and base_id in stderr" >&2
        echo "    dup_exit=$dup_exit stderr=$dup_stderr_content" >&2
        (( FAIL++ ))
    fi
fi

rm -rf "$TMPDIR_T3"

# ── Report ────────────────────────────────────────────────────────────────────

print_results
