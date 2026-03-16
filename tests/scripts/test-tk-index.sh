#!/usr/bin/env bash
# tests/scripts/test-tk-index.sh
#
# Tests for _update_ticket_index() in tk.
#
# Verifies that:
#   1. Index is updated incrementally when a ticket changes
#   2. Index self-heals when .index.json is corrupt
#   3. Index schema is valid (id -> {title, status, type})
#
# Usage: bash tests/scripts/test-tk-index.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
TK_SCRIPT="$PLUGIN_ROOT/scripts/tk"

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

# ── Test 6: test_index_priority_field ────────────────────────────────────────
#
# After creating a ticket with -p 3, the index entry must contain a priority
# field with integer value 3.

echo "Test 6: test_index_priority_field — index entry contains priority integer"
TMPDIR_T6=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T6"

prio_id=$("$TK_SCRIPT" create "Priority Index Test" -t task -p 3 2>&1 | tr -d '[:space:]')

index_file="$TMPDIR_T6/.index.json"

if [[ ! -f "$index_file" ]]; then
    echo "  FAIL: test_index_priority_field — .index.json not created" >&2
    (( FAIL++ ))
else
    prio_check=$(python3 -c "
import json, sys
idx = json.load(open('$index_file'))
entry = idx.get('$prio_id')
if entry is None:
    print('MISSING_ENTRY')
    sys.exit(1)
if 'priority' not in entry:
    print('MISSING_PRIORITY_FIELD')
    sys.exit(1)
p = entry['priority']
if not isinstance(p, int):
    print(f'NOT_INT: {type(p).__name__}={p!r}')
    sys.exit(1)
if p != 3:
    print(f'WRONG_VALUE: expected 3, got {p}')
    sys.exit(1)
print('OK: priority=' + str(p))
" 2>&1)
    prio_exit=$?

    if [[ $prio_exit -eq 0 ]]; then
        echo "  PASS: test_index_priority_field — $prio_check"
        (( PASS++ ))
    else
        echo "  FAIL: test_index_priority_field — $prio_check" >&2
        (( FAIL++ ))
    fi
fi

rm -rf "$TMPDIR_T6"

# ── Test 7: test_index_deps_field ─────────────────────────────────────────────
#
# After creating two tickets and adding a dependency, the index entry for the
# dependent ticket must contain a deps field that is a list of strings.

echo "Test 7: test_index_deps_field — index entry contains deps array of strings"
TMPDIR_T7=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T7"

# Create two tickets
dep_src=$("$TK_SCRIPT" create "Deps Source Ticket" -t task -p 2 2>&1 | tr -d '[:space:]')
dep_tgt=$("$TK_SCRIPT" create "Deps Target Ticket" -t task -p 2 2>&1 | tr -d '[:space:]')

# Add dependency: dep_src depends on dep_tgt
"$TK_SCRIPT" dep "$dep_src" "$dep_tgt" >/dev/null 2>&1

index_file="$TMPDIR_T7/.index.json"

if [[ ! -f "$index_file" ]]; then
    echo "  FAIL: test_index_deps_field — .index.json not created" >&2
    (( FAIL++ ))
else
    deps_check=$(python3 -c "
import json, sys
idx = json.load(open('$index_file'))
entry = idx.get('$dep_src')
if entry is None:
    print('MISSING_ENTRY')
    sys.exit(1)
if 'deps' not in entry:
    print('MISSING_DEPS_FIELD')
    sys.exit(1)
d = entry['deps']
if not isinstance(d, list):
    print(f'NOT_LIST: {type(d).__name__}={d!r}')
    sys.exit(1)
if not all(isinstance(x, str) for x in d):
    print(f'NOT_ALL_STRINGS: {d!r}')
    sys.exit(1)
if '$dep_tgt' not in d:
    print(f'DEP_NOT_PRESENT: expected $dep_tgt in {d!r}')
    sys.exit(1)
print('OK: deps=' + str(d))
" 2>&1)
    deps_exit=$?

    if [[ $deps_exit -eq 0 ]]; then
        echo "  PASS: test_index_deps_field — $deps_check"
        (( PASS++ ))
    else
        echo "  FAIL: test_index_deps_field — $deps_check" >&2
        (( FAIL++ ))
    fi
fi

rm -rf "$TMPDIR_T7"

# ── Test 8: test_index_priority_null_default ──────────────────────────────────
#
# When a ticket file has no priority field (edge case), _tk_build_full_index
# should produce null for priority rather than crashing.

echo "Test 8: test_index_priority_null_default — missing priority field yields null in full rebuild"
TMPDIR_T8=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T8"

# Write a ticket file without a priority field
cat > "$TMPDIR_T8/no-prio-abc.md" <<'EOFMD'
---
id: no-prio-abc
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
---
# No Priority Ticket
EOFMD

# Trigger full rebuild
"$TK_SCRIPT" status "no-prio-abc" "in_progress" >/dev/null 2>&1 || true

index_file="$TMPDIR_T8/.index.json"

if [[ ! -f "$index_file" ]]; then
    echo "  FAIL: test_index_priority_null_default — .index.json not created" >&2
    (( FAIL++ ))
else
    null_check=$(python3 -c "
import json, sys
idx = json.load(open('$index_file'))
entry = idx.get('no-prio-abc')
if entry is None:
    print('MISSING_ENTRY')
    sys.exit(1)
if 'priority' not in entry:
    print('MISSING_PRIORITY_FIELD')
    sys.exit(1)
p = entry['priority']
if p is not None:
    print(f'EXPECTED_NULL: got {p!r}')
    sys.exit(1)
print('OK: priority is null as expected')
" 2>&1)
    null_exit=$?

    if [[ $null_exit -eq 0 ]]; then
        echo "  PASS: test_index_priority_null_default — $null_check"
        (( PASS++ ))
    else
        echo "  FAIL: test_index_priority_null_default — $null_check" >&2
        (( FAIL++ ))
    fi
fi

rm -rf "$TMPDIR_T8"

# ── Test 9: test_index_deps_empty_default ─────────────────────────────────────
#
# A ticket with deps: [] in its frontmatter should produce an empty list in the
# index (not null, not a string).

echo "Test 9: test_index_deps_empty_default — ticket with empty deps produces [] in index"
TMPDIR_T9=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T9"

nodep_id=$("$TK_SCRIPT" create "No Deps Ticket" -t task -p 1 2>&1 | tr -d '[:space:]')

index_file="$TMPDIR_T9/.index.json"

if [[ ! -f "$index_file" ]]; then
    echo "  FAIL: test_index_deps_empty_default — .index.json not created" >&2
    (( FAIL++ ))
else
    empty_deps_check=$(python3 -c "
import json, sys
idx = json.load(open('$index_file'))
entry = idx.get('$nodep_id')
if entry is None:
    print('MISSING_ENTRY')
    sys.exit(1)
if 'deps' not in entry:
    print('MISSING_DEPS_FIELD')
    sys.exit(1)
d = entry['deps']
if not isinstance(d, list):
    print(f'NOT_LIST: {type(d).__name__}={d!r}')
    sys.exit(1)
if len(d) != 0:
    print(f'EXPECTED_EMPTY: got {d!r}')
    sys.exit(1)
print('OK: deps is empty list')
" 2>&1)
    empty_deps_exit=$?

    if [[ $empty_deps_exit -eq 0 ]]; then
        echo "  PASS: test_index_deps_empty_default — $empty_deps_check"
        (( PASS++ ))
    else
        echo "  FAIL: test_index_deps_empty_default — $empty_deps_check" >&2
        (( FAIL++ ))
    fi
fi

rm -rf "$TMPDIR_T9"

# ── Test 10: test_index_full_rebuild_includes_priority_and_deps ───────────────
#
# cmd_index_rebuild (which calls _tk_build_full_index) must produce entries
# with both priority and deps fields.

echo "Test 10: test_index_full_rebuild_includes_priority_and_deps — tk index-rebuild produces priority+deps"
TMPDIR_T10=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T10"

# Create ticket with deps
rb_id1=$("$TK_SCRIPT" create "Rebuild Test One" -t task -p 0 2>&1 | tr -d '[:space:]')
rb_id2=$("$TK_SCRIPT" create "Rebuild Test Two" -t task -p 4 2>&1 | tr -d '[:space:]')
"$TK_SCRIPT" dep "$rb_id2" "$rb_id1" >/dev/null 2>&1

# Force full rebuild
"$TK_SCRIPT" index-rebuild >/dev/null 2>&1

index_file="$TMPDIR_T10/.index.json"

if [[ ! -f "$index_file" ]]; then
    echo "  FAIL: test_index_full_rebuild_includes_priority_and_deps — .index.json not created" >&2
    (( FAIL++ ))
else
    rebuild_check=$(python3 -c "
import json, sys
idx = json.load(open('$index_file'))
errors = []
for tid in ['$rb_id1', '$rb_id2']:
    entry = idx.get(tid)
    if entry is None:
        errors.append(f'{tid}: missing from index')
        continue
    if 'priority' not in entry:
        errors.append(f'{tid}: missing priority')
    if 'deps' not in entry:
        errors.append(f'{tid}: missing deps')
    elif not isinstance(entry['deps'], list):
        errors.append(f'{tid}: deps is not a list')

# Check rb_id2 has rb_id1 in its deps
entry2 = idx.get('$rb_id2', {})
if '$rb_id1' not in entry2.get('deps', []):
    errors.append(f'$rb_id2: expected $rb_id1 in deps, got {entry2.get(\"deps\")}')

# Check rb_id1 has priority 0
entry1 = idx.get('$rb_id1', {})
if entry1.get('priority') != 0:
    errors.append(f'$rb_id1: expected priority=0, got {entry1.get(\"priority\")}')

if errors:
    print('ERRORS: ' + '; '.join(errors))
    sys.exit(1)
else:
    print('OK: all entries have priority and deps')
" 2>&1)
    rebuild_exit=$?

    if [[ $rebuild_exit -eq 0 ]]; then
        echo "  PASS: test_index_full_rebuild_includes_priority_and_deps — $rebuild_check"
        (( PASS++ ))
    else
        echo "  FAIL: test_index_full_rebuild_includes_priority_and_deps — $rebuild_check" >&2
        (( FAIL++ ))
    fi
fi

rm -rf "$TMPDIR_T10"

# ── Report ────────────────────────────────────────────────────────────────────

print_results
