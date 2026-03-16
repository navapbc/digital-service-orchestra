#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-tk-index-rebuild.sh
#
# Tests for cmd_index_rebuild() in tk.
#
# Verifies that:
#   1. tk index-rebuild is a registered command (command exists in dispatch table)
#   2. tk index-rebuild populates the index from all ticket files in TICKETS_DIR
#
# Usage: bash lockpick-workflow/tests/scripts/test-tk-index-rebuild.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
TK_SCRIPT="$PLUGIN_ROOT/scripts/tk"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-tk-index-rebuild.sh ==="

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

# ── Test 1: test_index_rebuild_command_exists ────────────────────────────────
#
# Verify that 'index-rebuild' is a registered command in the tk dispatch table.
# Running 'tk index-rebuild' against a temporary empty tickets dir should exit 0
# and should NOT print "Unknown command".

echo "Test 1: test_index_rebuild_command_exists — index-rebuild is a registered command"
TMPDIR_T1=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T1"

output=$("$TK_SCRIPT" index-rebuild 2>&1)
exit_code=$?

if [[ $exit_code -ne 0 ]]; then
    echo "  FAIL: test_index_rebuild_command_exists — tk index-rebuild exited $exit_code" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
elif echo "$output" | grep -q "Unknown command"; then
    echo "  FAIL: test_index_rebuild_command_exists — got 'Unknown command': $output" >&2
    (( FAIL++ ))
else
    echo "  PASS: test_index_rebuild_command_exists — index-rebuild accepted without error"
    (( PASS++ ))
fi

rm -rf "$TMPDIR_T1"

# ── Test 2: test_index_rebuild_populates_all_tickets ────────────────────────
#
# Pre-populate a TICKETS_DIR with several ticket .md files (no index yet).
# Run 'tk index-rebuild' and verify that .index.json is created and contains
# an entry for every ticket, with the correct title, status, and type.

echo "Test 2: test_index_rebuild_populates_all_tickets — index contains all pre-existing tickets"
TMPDIR_T2=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T2"

# Create ticket files directly (bypassing tk create so there is no index yet)
make_ticket "$TMPDIR_T2" "rebuild-aaa" "open"        "task"    "Alpha Task"
make_ticket "$TMPDIR_T2" "rebuild-bbb" "in_progress" "feature" "Beta Feature"
make_ticket "$TMPDIR_T2" "rebuild-ccc" "closed"      "epic"    "Gamma Epic"

# Confirm there is no index yet
if [[ -f "$TMPDIR_T2/.index.json" ]]; then
    rm "$TMPDIR_T2/.index.json"
fi

# Run the rebuild command
"$TK_SCRIPT" index-rebuild >/dev/null 2>&1
rebuild_exit=$?

index_file="$TMPDIR_T2/.index.json"

if [[ $rebuild_exit -ne 0 ]]; then
    echo "  FAIL: test_index_rebuild_populates_all_tickets — tk index-rebuild exited $rebuild_exit" >&2
    (( FAIL++ ))
elif [[ ! -f "$index_file" ]]; then
    echo "  FAIL: test_index_rebuild_populates_all_tickets — .index.json not created" >&2
    (( FAIL++ ))
else
    # Verify all three tickets are present with correct fields
    result=$(python3 -c "
import json, sys
idx = json.load(open('$index_file'))
expected = {
    'rebuild-aaa': {'title': 'Alpha Task',    'status': 'open',        'type': 'task'},
    'rebuild-bbb': {'title': 'Beta Feature',  'status': 'in_progress', 'type': 'feature'},
    'rebuild-ccc': {'title': 'Gamma Epic',    'status': 'closed',      'type': 'epic'},
}
errors = []
for tid, want in expected.items():
    got = idx.get(tid)
    if got is None:
        errors.append(f'missing entry for {tid}')
        continue
    for field, val in want.items():
        if got.get(field) != val:
            errors.append(f'{tid}.{field}: expected {val!r}, got {got.get(field)!r}')
if errors:
    print('ERRORS: ' + '; '.join(errors))
    sys.exit(1)
else:
    print('OK: all ' + str(len(expected)) + ' tickets indexed correctly')
" 2>&1)
    result_exit=$?

    if [[ $result_exit -eq 0 ]]; then
        echo "  PASS: test_index_rebuild_populates_all_tickets — $result"
        (( PASS++ ))
    else
        echo "  FAIL: test_index_rebuild_populates_all_tickets — $result" >&2
        (( FAIL++ ))
    fi
fi

rm -rf "$TMPDIR_T2"

# ── Report ────────────────────────────────────────────────────────────────────

print_results
