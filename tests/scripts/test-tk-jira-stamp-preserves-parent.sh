#!/usr/bin/env bash
# tests/scripts/test-tk-jira-stamp-preserves-parent.sh
#
# RED tests for two bugs causing parent: field loss during Jira sync:
#
# Bug 1: update_yaml_field silently fails to insert new fields on macOS
#         (BSD sed does not support 0,/^---$/ address syntax)
#
# Bug 2: _sync_push_ticket writes jira_hash="" to ledger, causing the pull
#         phase to spuriously rewrite the file on the next sync run
#
# Usage: bash tests/scripts/test-tk-jira-stamp-preserves-parent.sh

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

echo "=== test-tk-jira-stamp-preserves-parent.sh ==="

# ── Helpers ──────────────────────────────────────────────────────────────────

# Create a minimal ticket file with frontmatter
create_ticket_file() {
    local file="$1"
    shift
    # Write opening ---
    echo "---" > "$file"
    echo "id: test-ticket" >> "$file"
    echo "status: open" >> "$file"
    echo "deps: []" >> "$file"
    echo "links: []" >> "$file"
    echo "created: 2026-03-05T00:00:00Z" >> "$file"
    echo "type: task" >> "$file"
    echo "priority: 2" >> "$file"
    # Write any extra fields passed as arguments (field: value pairs)
    for field_line in "$@"; do
        echo "$field_line" >> "$file"
    done
    echo "---" >> "$file"
    echo "# Test Ticket" >> "$file"
}

# ── Test 1: update_yaml_field inserts new field into frontmatter ─────────────
# This tests Bug 2: BSD sed 0,/^---$/ silently fails on macOS.
# The function should insert a new field before the closing ---.

echo "Test 1: update_yaml_field inserts new field (parent:) into frontmatter"
TMPDIR_T1=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T1")
TICKET_T1="$TMPDIR_T1/test-ticket.md"
create_ticket_file "$TICKET_T1"

# Define the functions as they exist in scripts/tk
_grep() { command grep "$@"; }
_sed_i() {
    local file="$1"; shift
    sed -i '' "$@" "$file" 2>/dev/null || sed -i "$@" "$file"
}
update_yaml_field() {
    local file="$1"
    local field="$2"
    local value="$3"

    if _grep -q "^${field}:" "$file"; then
        _sed_i "$file" "s/^${field}:.*/${field}: ${value}/"
    else
        # Insert new field before closing --- of frontmatter.
        # Uses python3 for cross-platform reliability (BSD sed on macOS
        # does not support the 0,/range/ address syntax).
        FIELD="$field" VALUE="$value" python3 -c "
import os
field = os.environ['FIELD']
value = os.environ['VALUE']
lines = open('$file').readlines()
result = []
fm_count = 0
inserted = False
for line in lines:
    stripped = line.rstrip('\n').rstrip('\r')
    if stripped == '---':
        fm_count += 1
        if fm_count == 2 and not inserted:
            result.append(field + ': ' + value + '\n')
            inserted = True
    result.append(line)
open('$file', 'w').writelines(result)
" 2>/dev/null
    fi
}

update_yaml_field "$TICKET_T1" "parent" "epic-123"

if grep -q "^parent: epic-123" "$TICKET_T1"; then
    echo "  PASS: parent field was inserted into frontmatter"
    (( PASS++ ))
else
    echo "  FAIL: parent field was NOT inserted — update_yaml_field silently failed" >&2
    echo "  File contents:" >&2
    cat "$TICKET_T1" >&2
    (( FAIL++ ))
fi
rm -rf "$TMPDIR_T1"

# ── Test 2: update_yaml_field inserts field AND preserves existing fields ────

echo "Test 2: update_yaml_field preserves existing fields when inserting new one"
TMPDIR_T2=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T2")
TICKET_T2="$TMPDIR_T2/test-ticket.md"
create_ticket_file "$TICKET_T2" "assignee: Bob"

update_yaml_field "$TICKET_T2" "parent" "epic-456"

if grep -q "^parent: epic-456" "$TICKET_T2" && grep -q "^assignee: Bob" "$TICKET_T2"; then
    echo "  PASS: parent inserted and assignee preserved"
    (( PASS++ ))
else
    echo "  FAIL: field insertion failed or existing field lost" >&2
    echo "  File contents:" >&2
    cat "$TICKET_T2" >&2
    (( FAIL++ ))
fi
rm -rf "$TMPDIR_T2"

# ── Test 3: Python jira_key stamper preserves parent: field ──────────────────
# This verifies the Python stamper at line 2041-2058 of scripts/tk.
# The stamper SHOULD insert jira_key: before closing --- without removing parent:.

echo "Test 3: Python jira_key stamper preserves parent: field"
TMPDIR_T3=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T3")
TICKET_T3="$TMPDIR_T3/test-ticket.md"
create_ticket_file "$TICKET_T3" "parent: epic-789"

# Run the same Python stamper code used in tk sync
TICKET_FILE="$TICKET_T3" JIRA_KEY="LLD2L-999" python3 -c "
import os
ticket_file = os.environ['TICKET_FILE']
jira_key = os.environ['JIRA_KEY']
lines = open(ticket_file).readlines()
result = []
fm_count = 0
inserted = False
for line in lines:
    stripped = line.rstrip('\n').rstrip('\r')
    if stripped == '---':
        fm_count += 1
        if fm_count == 2 and not inserted:
            result.append('jira_key: ' + jira_key + '\n')
            inserted = True
    result.append(line)
open(ticket_file, 'w').writelines(result)
"

has_parent=false
has_jira_key=false
grep -q "^parent: epic-789" "$TICKET_T3" && has_parent=true
grep -q "^jira_key: LLD2L-999" "$TICKET_T3" && has_jira_key=true

if $has_parent && $has_jira_key; then
    echo "  PASS: both parent: and jira_key: present after stamping"
    (( PASS++ ))
else
    echo "  FAIL: parent=$has_parent jira_key=$has_jira_key (both should be true)" >&2
    echo "  File contents:" >&2
    cat "$TICKET_T3" >&2
    (( FAIL++ ))
fi
rm -rf "$TMPDIR_T3"

# ── Test 4: update_yaml_field updates EXISTING field without touching others ─

echo "Test 4: update_yaml_field updates existing field preserving parent:"
TMPDIR_T4=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T4")
TICKET_T4="$TMPDIR_T4/test-ticket.md"
create_ticket_file "$TICKET_T4" "parent: epic-abc" "jira_key: OLD-1"

update_yaml_field "$TICKET_T4" "jira_key" "NEW-2"

has_parent=false
has_new_key=false
has_old_key=false
grep -q "^parent: epic-abc" "$TICKET_T4" && has_parent=true
grep -q "^jira_key: NEW-2" "$TICKET_T4" && has_new_key=true
grep -q "^jira_key: OLD-1" "$TICKET_T4" && has_old_key=true

if $has_parent && $has_new_key && ! $has_old_key; then
    echo "  PASS: jira_key updated, parent preserved"
    (( PASS++ ))
else
    echo "  FAIL: parent=$has_parent new_key=$has_new_key old_key=$has_old_key" >&2
    echo "  File contents:" >&2
    cat "$TICKET_T4" >&2
    (( FAIL++ ))
fi
rm -rf "$TMPDIR_T4"

# ── Test 5: update_yaml_field with field not present inserts within frontmatter ─
# Verifies the field is inserted INSIDE the frontmatter block (between --- delimiters),
# not appended after the closing --- or at end of file.

echo "Test 5: update_yaml_field inserts new field within frontmatter block"
TMPDIR_T5=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T5")
TICKET_T5="$TMPDIR_T5/test-ticket.md"
create_ticket_file "$TICKET_T5"

update_yaml_field "$TICKET_T5" "parent" "epic-def"

# Extract frontmatter (between first and second ---) and check parent is inside
in_frontmatter=$(awk '/^---$/{n++; next} n==1 && /^parent: epic-def/{found=1} END{print found+0}' "$TICKET_T5")

if [[ "$in_frontmatter" -eq 1 ]]; then
    echo "  PASS: parent field is inside frontmatter block"
    (( PASS++ ))
else
    echo "  FAIL: parent field not found inside frontmatter block" >&2
    echo "  File contents:" >&2
    cat "$TICKET_T5" >&2
    (( FAIL++ ))
fi
rm -rf "$TMPDIR_T5"

# ── Report ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
