#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-tk-index.sh
#
# Tests for _update_ticket_index() in tk.
#
# Verifies that:
#   1. Index is updated incrementally when a ticket changes
#   2. Index self-heals when .index.json is corrupt
#   3. Index schema is valid (id -> {title, status, type})
#
# Usage: bash lockpick-workflow/tests/scripts/test-tk-index.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TK_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/tk"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-tk-index.sh ==="

# ── Helpers ──────────────────────────────────────────────────────────────────

make_ticket() {
    local dir="$1"
    local id="$2"
    local status="${3:-open}"
    local type="${4:-task}"
    local title="${5:-Ticket $id}"
    cat > "$dir/${id}.md" <<EOF
---
id: ${id}
status: ${status}
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: ${type}
priority: 2
---
# ${title}
EOF
}

# ── Test 1: test_index_incremental_update ─────────────────────────────────────
#
# After cmd_create creates a ticket, .index.json should contain an entry
# for that ticket with the correct title, status, and type.
# After cmd_status changes status, the index entry should reflect the new status.

echo "Test 1: test_index_incremental_update — index is updated on create and status change"
TMPDIR_T1=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T1"

# Create a ticket via tk create
output=$("$TK_SCRIPT" create "My Test Ticket" -t feature -p 2 2>&1)
created_id=$(echo "$output" | tr -d '[:space:]')

index_file="$TMPDIR_T1/.index.json"

# Verify index file was created
if [[ ! -f "$index_file" ]]; then
    echo "  FAIL: test_index_incremental_update — .index.json not created after tk create" >&2
    (( FAIL++ ))
else
    # Verify entry exists in index
    entry=$(python3 -c "
import json, sys
idx = json.load(open('$index_file'))
entry = idx.get('$created_id')
if entry is None:
    print('MISSING')
else:
    print(entry.get('status',''), entry.get('type',''), entry.get('title',''))
" 2>&1)

    if echo "$entry" | grep -q "open" && echo "$entry" | grep -q "feature"; then
        echo "  PASS: test_index_incremental_update — index entry created with correct status/type"
        (( PASS++ ))
    else
        echo "  FAIL: test_index_incremental_update — unexpected index entry: $entry" >&2
        (( FAIL++ ))
    fi

    # Change status and verify index is updated
    "$TK_SCRIPT" status "$created_id" "in_progress" >/dev/null 2>&1

    status_in_index=$(python3 -c "
import json
idx = json.load(open('$index_file'))
entry = idx.get('$created_id', {})
print(entry.get('status', 'MISSING'))
" 2>&1)

    if [[ "$status_in_index" == "in_progress" ]]; then
        echo "  PASS: test_index_incremental_update — index updated after status change"
        (( PASS++ ))
    else
        echo "  FAIL: test_index_incremental_update — index not updated after status change; got: $status_in_index" >&2
        (( FAIL++ ))
    fi
fi

rm -rf "$TMPDIR_T1"

# ── Test 2: test_index_self_heals_on_corruption ──────────────────────────────
#
# If .index.json is present but corrupt (invalid JSON), the next tk operation
# should rebuild the index rather than crashing.

echo "Test 2: test_index_self_heals_on_corruption — corrupt index triggers full rebuild"
TMPDIR_T2=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T2"

# Pre-populate a ticket file directly
make_ticket "$TMPDIR_T2" "heal-abc" "open" "task" "Heal Test Ticket"

# Write a corrupt .index.json
echo "THIS IS NOT VALID JSON {{{" > "$TMPDIR_T2/.index.json"

# Run an operation that triggers _update_ticket_index
"$TK_SCRIPT" status "heal-abc" "in_progress" >/dev/null 2>&1
exit_code=$?

# The command should succeed (not crash on corrupt index)
index_file="$TMPDIR_T2/.index.json"

if [[ $exit_code -ne 0 ]]; then
    echo "  FAIL: test_index_self_heals_on_corruption — tk status crashed (exit $exit_code)" >&2
    (( FAIL++ ))
elif [[ ! -f "$index_file" ]]; then
    echo "  FAIL: test_index_self_heals_on_corruption — .index.json missing after rebuild" >&2
    (( FAIL++ ))
else
    # Verify the rebuilt index is valid JSON
    python3 -c "import json; json.load(open('$index_file'))" 2>/dev/null
    json_valid=$?

    if [[ $json_valid -eq 0 ]]; then
        echo "  PASS: test_index_self_heals_on_corruption — corrupt index was rebuilt as valid JSON"
        (( PASS++ ))
    else
        echo "  FAIL: test_index_self_heals_on_corruption — rebuilt index is still invalid JSON" >&2
        (( FAIL++ ))
    fi
fi

rm -rf "$TMPDIR_T2"

# ── Test 3: test_index_schema_valid ──────────────────────────────────────────
#
# After creating a ticket, .index.json must contain entries with the correct
# schema: each key is a ticket ID, each value is a dict with title, status, type.

echo "Test 3: test_index_schema_valid — index schema is {id: {title, status, type}}"
TMPDIR_T3=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T3"

# Create two tickets to populate the index
id1=$("$TK_SCRIPT" create "Schema Test Alpha" -t task -p 2 2>&1 | tr -d '[:space:]')
id2=$("$TK_SCRIPT" create "Schema Test Beta" -t epic -p 1 2>&1 | tr -d '[:space:]')

index_file="$TMPDIR_T3/.index.json"

if [[ ! -f "$index_file" ]]; then
    echo "  FAIL: test_index_schema_valid — .index.json not created" >&2
    (( FAIL++ ))
else
    schema_check=$(python3 -c "
import json, sys
idx = json.load(open('$index_file'))
required_fields = {'title', 'status', 'type'}
errors = []
for ticket_id, entry in idx.items():
    missing = required_fields - set(entry.keys())
    if missing:
        errors.append(f'{ticket_id} missing fields: {missing}')
    if not isinstance(entry.get('title',''), str):
        errors.append(f'{ticket_id}: title is not a string')
    if not isinstance(entry.get('status',''), str):
        errors.append(f'{ticket_id}: status is not a string')
    if not isinstance(entry.get('type',''), str):
        errors.append(f'{ticket_id}: type is not a string')
if errors:
    print('ERRORS: ' + '; '.join(errors))
    sys.exit(1)
else:
    print('OK: ' + str(len(idx)) + ' entries validated')
" 2>&1)
    schema_exit=$?

    if [[ $schema_exit -eq 0 ]]; then
        echo "  PASS: test_index_schema_valid — $schema_check"
        (( PASS++ ))
    else
        echo "  FAIL: test_index_schema_valid — $schema_check" >&2
        (( FAIL++ ))
    fi
fi

rm -rf "$TMPDIR_T3"

# ── Test 4: test_index_atomic_write ──────────────────────────────────────────
#
# Verify that _update_ticket_index uses atomic write (.index.json.tmp then mv)
# by confirming the pattern exists in the tk script.

echo "Test 4: test_index_atomic_write — tk script uses .index.json.tmp for atomic write"
if grep -q '\.index\.json\.tmp' "$TK_SCRIPT"; then
    echo "  PASS: test_index_atomic_write — .index.json.tmp pattern found in tk"
    (( PASS++ ))
else
    echo "  FAIL: test_index_atomic_write — .index.json.tmp pattern not found in tk" >&2
    (( FAIL++ ))
fi

# ── Test 5: test_index_updated_on_close ──────────────────────────────────────
#
# Verify the index is updated when cmd_close changes a ticket's status.

echo "Test 5: test_index_updated_on_close — index reflects closed status after tk close"
TMPDIR_T5=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T5"

# Create a ticket
close_id=$("$TK_SCRIPT" create "Close Index Test" -t task 2>&1 | tr -d '[:space:]')

# Close it (TK_REPO_ROOT set to a dir without venv to avoid git/venv lookups hanging)
TK_REPO_ROOT="$TMPDIR_T5" "$TK_SCRIPT" close "$close_id" --reason="Test close" >/dev/null 2>&1

index_file="$TMPDIR_T5/.index.json"
if [[ ! -f "$index_file" ]]; then
    echo "  FAIL: test_index_updated_on_close — .index.json missing" >&2
    (( FAIL++ ))
else
    status_in_index=$(python3 -c "
import json
idx = json.load(open('$index_file'))
entry = idx.get('$close_id', {})
print(entry.get('status', 'MISSING'))
" 2>&1)

    if [[ "$status_in_index" == "closed" ]]; then
        echo "  PASS: test_index_updated_on_close — index shows closed status"
        (( PASS++ ))
    else
        echo "  FAIL: test_index_updated_on_close — expected closed, got: $status_in_index" >&2
        (( FAIL++ ))
    fi
fi

rm -rf "$TMPDIR_T5"

# ── Report ────────────────────────────────────────────────────────────────────

print_results
