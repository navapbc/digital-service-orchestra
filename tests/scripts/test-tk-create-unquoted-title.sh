#!/usr/bin/env bash
# tests/scripts/test-tk-create-unquoted-title.sh
#
# Verifies that tk create accumulates multiple positional args into the title
# rather than using last-wins semantics.
#
# Bug: dso-i6dj — /dso:brainstorm created children with truncated titles and
# descriptions. Root cause: tk create arg parser overwrites `title` for each
# positional arg, so only the last word becomes the title when an LLM passes
# a multi-word title without quotes.
#
# Failure mode:
#   tk create Remove scripts. -t task
#   → title becomes "scripts." (last positional), not "Remove scripts."
#
# Fix: accumulate all non-flag positional args into the title with spaces.
#
# Usage: bash tests/scripts/test-tk-create-unquoted-title.sh

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

echo "=== test-tk-create-unquoted-title.sh ==="

# ── Test 1: Two positional args → title joined with space ─────────────────────
#
# Simulates LLM calling: tk create Remove scripts. -t task
# Expected title: "Remove scripts."

echo "Test 1: two positional args produce a joined title (not last-wins)"
TMPDIR_T1=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T1")
export TICKETS_DIR="$TMPDIR_T1"

stderr1="$TMPDIR_T1/stderr.txt"
ticket_id=$("$TK_SCRIPT" create Remove scripts. -t task 2>"$stderr1")
exit1=$?

if [[ "$exit1" -ne 0 ]]; then
    echo "  FAIL: tk create exited $exit1, stderr: $(cat "$stderr1")" >&2
    (( FAIL++ ))
else
    ticket_id=$(echo "$ticket_id" | tr -d '[:space:]')
    ticket_file=$(find "$TMPDIR_T1" -name "${ticket_id}.md" 2>/dev/null | head -1)
    if [[ -z "$ticket_file" ]]; then
        echo "  FAIL: ticket file for $ticket_id not found" >&2
        (( FAIL++ ))
    else
        actual_title=$(grep "^# " "$ticket_file" | head -1 | sed 's/^# //')
        if [[ "$actual_title" == "Remove scripts." ]]; then
            echo "  PASS: title is 'Remove scripts.' (joined)"
            (( PASS++ ))
        else
            echo "  FAIL: expected title 'Remove scripts.', got '$actual_title'" >&2
            cat "$ticket_file" >&2
            (( FAIL++ ))
        fi
    fi
fi

# ── Test 2: Three positional args → all joined as title ───────────────────────
#
# Simulates: tk create Add .claude/scripts/dso: shim -t task
# Expected title: "Add .claude/scripts/dso: shim"

echo "Test 2: three positional args produce a fully joined title"
TMPDIR_T2=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T2")
export TICKETS_DIR="$TMPDIR_T2"

stderr2="$TMPDIR_T2/stderr.txt"
ticket_id2=$("$TK_SCRIPT" create Add .claude/scripts/dso: shim -t task 2>"$stderr2")
exit2=$?

if [[ "$exit2" -ne 0 ]]; then
    echo "  FAIL: tk create exited $exit2, stderr: $(cat "$stderr2")" >&2
    (( FAIL++ ))
else
    ticket_id2=$(echo "$ticket_id2" | tr -d '[:space:]')
    ticket_file2=$(find "$TMPDIR_T2" -name "${ticket_id2}.md" 2>/dev/null | head -1)
    if [[ -z "$ticket_file2" ]]; then
        echo "  FAIL: ticket file for $ticket_id2 not found" >&2
        (( FAIL++ ))
    else
        actual_title2=$(grep "^# " "$ticket_file2" | head -1 | sed 's/^# //')
        if [[ "$actual_title2" == "Add .claude/scripts/dso: shim" ]]; then
            echo "  PASS: title is 'Add .claude/scripts/dso: shim' (joined)"
            (( PASS++ ))
        else
            echo "  FAIL: expected 'Add .claude/scripts/dso: shim', got '$actual_title2'" >&2
            cat "$ticket_file2" >&2
            (( FAIL++ ))
        fi
    fi
fi

# ── Test 3: Single quoted title still works ────────────────────────────────────

echo "Test 3: single quoted title still works correctly"
TMPDIR_T3=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T3")
export TICKETS_DIR="$TMPDIR_T3"

stderr3="$TMPDIR_T3/stderr.txt"
ticket_id3=$("$TK_SCRIPT" create "Harden shim CLAUDE_PLUGIN_ROOT guard" -t task 2>"$stderr3")
exit3=$?

if [[ "$exit3" -ne 0 ]]; then
    echo "  FAIL: tk create exited $exit3, stderr: $(cat "$stderr3")" >&2
    (( FAIL++ ))
else
    ticket_id3=$(echo "$ticket_id3" | tr -d '[:space:]')
    ticket_file3=$(find "$TMPDIR_T3" -name "${ticket_id3}.md" 2>/dev/null | head -1)
    if [[ -z "$ticket_file3" ]]; then
        echo "  FAIL: ticket file for $ticket_id3 not found" >&2
        (( FAIL++ ))
    else
        actual_title3=$(grep "^# " "$ticket_file3" | head -1 | sed 's/^# //')
        if [[ "$actual_title3" == "Harden shim CLAUDE_PLUGIN_ROOT guard" ]]; then
            echo "  PASS: quoted title preserved correctly"
            (( PASS++ ))
        else
            echo "  FAIL: expected 'Harden shim CLAUDE_PLUGIN_ROOT guard', got '$actual_title3'" >&2
            cat "$ticket_file3" >&2
            (( FAIL++ ))
        fi
    fi
fi

# ── Test 4: Mixed positional and flags ────────────────────────────────────────
#
# Simulates: tk create Replace resolution: logic -t task -p 1
# Expected title: "Replace resolution: logic"

echo "Test 4: positional args before flags are all joined as title"
TMPDIR_T4=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T4")
export TICKETS_DIR="$TMPDIR_T4"

stderr4="$TMPDIR_T4/stderr.txt"
ticket_id4=$("$TK_SCRIPT" create Replace resolution: logic -t task -p 1 2>"$stderr4")
exit4=$?

if [[ "$exit4" -ne 0 ]]; then
    echo "  FAIL: tk create exited $exit4, stderr: $(cat "$stderr4")" >&2
    (( FAIL++ ))
else
    ticket_id4=$(echo "$ticket_id4" | tr -d '[:space:]')
    ticket_file4=$(find "$TMPDIR_T4" -name "${ticket_id4}.md" 2>/dev/null | head -1)
    if [[ -z "$ticket_file4" ]]; then
        echo "  FAIL: ticket file for $ticket_id4 not found" >&2
        (( FAIL++ ))
    else
        actual_title4=$(grep "^# " "$ticket_file4" | head -1 | sed 's/^# //')
        if [[ "$actual_title4" == "Replace resolution: logic" ]]; then
            echo "  PASS: title is 'Replace resolution: logic' (joined)"
            (( PASS++ ))
        else
            echo "  FAIL: expected 'Replace resolution: logic', got '$actual_title4'" >&2
            cat "$ticket_file4" >&2
            (( FAIL++ ))
        fi
    fi
fi

# ── Report ────────────────────────────────────────────────────────────────────

print_results
