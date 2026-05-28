#!/usr/bin/env bash
# tests/scratch/test-scratch-show-flag.sh
# Behavioral tests for --include-scratch flag in plugins/dso/scripts/ticket-show.sh
#
# Testing Mode: RED → GREEN
# Usage: bash tests/scratch/test-scratch-show-flag.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SHOW="$REPO_ROOT/plugins/dso/scripts/ticket-show.sh"
SCRATCH_SET="$REPO_ROOT/plugins/dso/scripts/ticket-scratch-set.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-scratch-show-flag.sh: ticket-show.sh --include-scratch behavioral tests ==="

# ── Preflight ─────────────────────────────────────────────────────────────────
if [ ! -f "$TICKET_SHOW" ]; then
    echo "FATAL: ticket-show.sh not found at $TICKET_SHOW" >&2
    exit 1
fi
if [ ! -x "$TICKET_SHOW" ]; then
    echo "FATAL: ticket-show.sh is not executable: $TICKET_SHOW" >&2
    exit 1
fi
if [ ! -f "$SCRATCH_SET" ]; then
    echo "FATAL: ticket-scratch-set.sh not found at $SCRATCH_SET" >&2
    exit 1
fi

# ── Shared test infrastructure ────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# Create a minimal tickets tracker directory with one CREATE event so
# ticket-show.sh can reduce the ticket without a real repo.
_make_tracker_and_scratch() {
    local tmp_tracker
    tmp_tracker=$(mktemp -d "${TMPDIR:-/tmp}/show-flag-tracker-XXXXXX")
    _CLEANUP_DIRS+=("$tmp_tracker")

    local ticket_id="aaaa-1111-bbbb-2222"
    local ticket_dir="$tmp_tracker/$ticket_id"
    mkdir -p "$ticket_dir"

    # Minimal CREATE event that the reducer can compile
    python3 - "$ticket_dir" "$ticket_id" <<'PYEOF'
import json, os, time, uuid

ticket_dir = sys.argv[1] if False else __import__('sys').argv[1]
ticket_id  = __import__('sys').argv[2]

ts = int(time.time() * 1e9)
ev = str(uuid.uuid4())

event = {
    "event_type": "CREATE",
    "timestamp": ts,
    "uuid": ev,
    "env_id": "test-env-0000",
    "author": "test",
    "data": {
        "ticket_type": "task",
        "title": "Test scratch show flag",
        "ticket_id": ticket_id,
        "priority": 3
    }
}
fname = os.path.join(ticket_dir, f"{ts}-{ev}-CREATE.json")
with open(fname, 'w') as f:
    json.dump(event, f)
PYEOF

    # Return: line 1 = tracker dir, line 2 = ticket_id
    echo "$tmp_tracker"
    echo "$ticket_id"
}

_make_scratch_base() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/show-flag-scratch-XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: No --include-scratch flag → JSON output does NOT contain a "scratch" key
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 1: no flag → JSON has no 'scratch' key ──"
test_no_flag_no_scratch_key() {
    local tracker_lines ticket_id tracker_dir scratch_base
    tracker_lines=$(_make_tracker_and_scratch)
    tracker_dir=$(echo "$tracker_lines" | head -1)
    ticket_id=$(echo "$tracker_lines" | tail -1)
    scratch_base=$(_make_scratch_base)

    local output exit_code=0
    output=$(TICKETS_TRACKER_DIR="$tracker_dir" SCRATCH_BASE_DIR="$scratch_base" \
        bash "$TICKET_SHOW" "$ticket_id" 2>/dev/null) || exit_code=$?

    assert_eq "exit 0 for no-flag show" "0" "$exit_code"

    local has_scratch
    has_scratch=$(echo "$output" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print('yes' if 'scratch' in d else 'no')
" 2>/dev/null || echo "error")

    assert_eq "no scratch key without flag" "no" "$has_scratch"
}
test_no_flag_no_scratch_key

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: --include-scratch with NO scratch entries → JSON has scratch key = {}
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 2: --include-scratch with empty scratch dir → scratch: {} ──"
test_include_scratch_empty() {
    local tracker_lines ticket_id tracker_dir scratch_base
    tracker_lines=$(_make_tracker_and_scratch)
    tracker_dir=$(echo "$tracker_lines" | head -1)
    ticket_id=$(echo "$tracker_lines" | tail -1)
    scratch_base=$(_make_scratch_base)

    local output exit_code=0
    output=$(TICKETS_TRACKER_DIR="$tracker_dir" SCRATCH_BASE_DIR="$scratch_base" \
        bash "$TICKET_SHOW" "$ticket_id" --include-scratch 2>/dev/null) || exit_code=$?

    assert_eq "exit 0 with include-scratch (empty)" "0" "$exit_code"

    local has_scratch
    has_scratch=$(echo "$output" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print('yes' if 'scratch' in d else 'no')
" 2>/dev/null || echo "error")

    assert_eq "scratch key present when flag given" "yes" "$has_scratch"

    # Value must be an empty object {} (not absent, not a list)
    local scratch_type scratch_len
    scratch_type=$(echo "$output" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
v = d.get('scratch')
print(type(v).__name__)
" 2>/dev/null || echo "error")

    scratch_len=$(echo "$output" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
v = d.get('scratch', None)
print(len(v) if v is not None else -1)
" 2>/dev/null || echo "error")

    assert_eq "scratch value is a dict (not list)" "dict" "$scratch_type"
    assert_eq "scratch value is empty dict" "0" "$scratch_len"
}
test_include_scratch_empty

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: --include-scratch with TWO scratch entries → JSON enumerates both
#   with {ts, value} fields per entry
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 3: --include-scratch with entries → scratch.k1 and scratch.k2 present ──"
test_include_scratch_with_entries() {
    local tracker_lines ticket_id tracker_dir scratch_base
    tracker_lines=$(_make_tracker_and_scratch)
    tracker_dir=$(echo "$tracker_lines" | head -1)
    ticket_id=$(echo "$tracker_lines" | tail -1)
    scratch_base=$(_make_scratch_base)

    # Write two scratch entries via ticket-scratch-set.sh
    SCRATCH_BASE_DIR="$scratch_base" bash "$SCRATCH_SET" "$ticket_id" "k1" "hello" >/dev/null 2>&1
    SCRATCH_BASE_DIR="$scratch_base" bash "$SCRATCH_SET" "$ticket_id" "k2" "world" >/dev/null 2>&1

    local output exit_code=0
    output=$(TICKETS_TRACKER_DIR="$tracker_dir" SCRATCH_BASE_DIR="$scratch_base" \
        bash "$TICKET_SHOW" "$ticket_id" --include-scratch 2>/dev/null) || exit_code=$?

    assert_eq "exit 0 with include-scratch (entries)" "0" "$exit_code"

    # k1 must be present with correct value
    local k1_value k2_value
    k1_value=$(echo "$output" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
s = d.get('scratch', {})
print(s.get('k1', {}).get('value', ''))
" 2>/dev/null || echo "error")

    k2_value=$(echo "$output" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
s = d.get('scratch', {})
print(s.get('k2', {}).get('value', ''))
" 2>/dev/null || echo "error")

    assert_eq "scratch.k1.value = hello" "hello" "$k1_value"
    assert_eq "scratch.k2.value = world" "world" "$k2_value"

    # Each entry must have a non-empty ts field
    local k1_ts k2_ts
    k1_ts=$(echo "$output" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
s = d.get('scratch', {})
print(s.get('k1', {}).get('ts', ''))
" 2>/dev/null || echo "error")

    k2_ts=$(echo "$output" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
s = d.get('scratch', {})
print(s.get('k2', {}).get('ts', ''))
" 2>/dev/null || echo "error")

    assert_ne "scratch.k1.ts is non-empty" "" "$k1_ts"
    assert_ne "scratch.k2.ts is non-empty" "" "$k2_ts"

    # Total scratch entry count must be exactly 2
    local scratch_count
    scratch_count=$(echo "$output" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
s = d.get('scratch', {})
print(len(s))
" 2>/dev/null || echo "error")

    assert_eq "scratch has exactly 2 entries" "2" "$scratch_count"
}
test_include_scratch_with_entries

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: WITHOUT flag, even when scratch entries exist → no scratch key
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 4: no flag but scratch entries exist → still no scratch key ──"
test_no_flag_with_existing_entries() {
    local tracker_lines ticket_id tracker_dir scratch_base
    tracker_lines=$(_make_tracker_and_scratch)
    tracker_dir=$(echo "$tracker_lines" | head -1)
    ticket_id=$(echo "$tracker_lines" | tail -1)
    scratch_base=$(_make_scratch_base)

    # Write a scratch entry
    SCRATCH_BASE_DIR="$scratch_base" bash "$SCRATCH_SET" "$ticket_id" "k1" "hello" >/dev/null 2>&1

    # Run WITHOUT --include-scratch
    local output exit_code=0
    output=$(TICKETS_TRACKER_DIR="$tracker_dir" SCRATCH_BASE_DIR="$scratch_base" \
        bash "$TICKET_SHOW" "$ticket_id" 2>/dev/null) || exit_code=$?

    assert_eq "exit 0 without flag (entries exist)" "0" "$exit_code"

    local has_scratch
    has_scratch=$(echo "$output" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print('yes' if 'scratch' in d else 'no')
" 2>/dev/null || echo "error")

    assert_eq "no scratch key without flag even when entries exist" "no" "$has_scratch"
}
test_no_flag_with_existing_entries

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
print_summary
