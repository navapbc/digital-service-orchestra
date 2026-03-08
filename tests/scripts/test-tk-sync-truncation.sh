#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-tk-sync-truncation.sh
# Tests that _merge_ticket_file preserves description body from main when
# the local (worktree) file only has frontmatter + title (no description body).
#
# Regression test for: lockpick-doc-to-logic-gows
# Bug: worktree sync push silently truncates ticket descriptions to frontmatter
#      + title, dropping the entire description body from main.
#
# Usage: bash lockpick-workflow/tests/scripts/test-tk-sync-truncation.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Source the library under test
source "$REPO_ROOT/lockpick-workflow/scripts/tk-sync-lib.sh"

echo "=== test-tk-sync-truncation.sh ==="

# ── Helpers ───────────────────────────────────────────────────────────────────

# make_main_ticket <file>
# Creates a ticket with full frontmatter + title + description body + notes.
make_main_ticket() {
    local file="$1"
    cat > "$file" << 'EOF'
---
assignee: Joe Oakhart
created: 2026-03-05T12:00:00Z
deps: []
id: lockpick-doc-to-logic-test1
jira_key: LLD2L-999
links: []
parent: lockpick-doc-to-logic-parent
priority: 2
status: open
type: feature
---
# As a developer, I can do the thing

## Description

This is the full description from the main branch.
It has multiple lines with implementation details,
acceptance criteria, and done definitions.

## Done Definition

- [ ] Implementation step 1
- [ ] Implementation step 2

EOF
}

# make_worktree_ticket <file>
# Creates a ticket with only frontmatter + title (no description body),
# representing what a worktree ticket looks like after a status update.
make_worktree_ticket() {
    local file="$1"
    cat > "$file" << 'EOF'
---
assignee: Joe Oakhart
created: 2026-03-05T12:00:00Z
deps: []
id: lockpick-doc-to-logic-test1
jira_key: LLD2L-999
links: []
parent: lockpick-doc-to-logic-parent
priority: 2
status: in_progress
type: feature
---
# As a developer, I can do the thing
EOF
}

# make_main_ticket_with_notes <file>
# Creates a main ticket with a description body AND notes section.
make_main_ticket_with_notes() {
    local file="$1"
    cat > "$file" << 'EOF'
---
assignee: Joe Oakhart
created: 2026-03-05T12:00:00Z
deps: []
id: lockpick-doc-to-logic-test2
jira_key: LLD2L-998
links: []
parent: lockpick-doc-to-logic-parent
priority: 2
status: open
type: feature
---
# As a developer, I can do another thing

## Description

This description should be preserved during merge.
It has important details about the implementation.

## Notes

<!-- note-id: abc123 -->
<!-- timestamp: 2026-03-05T12:00:00Z -->
<!-- origin: agent -->
<!-- sync: synced -->

A note from main.
EOF
}

# make_worktree_ticket_with_notes <file>
# Creates a worktree ticket with only title + a different note (no description body).
make_worktree_ticket_with_notes() {
    local file="$1"
    cat > "$file" << 'EOF'
---
assignee: Joe Oakhart
created: 2026-03-05T12:00:00Z
deps: []
id: lockpick-doc-to-logic-test2
jira_key: LLD2L-998
links: []
parent: lockpick-doc-to-logic-parent
priority: 2
status: in_progress
type: feature
---
# As a developer, I can do another thing

## Notes

<!-- note-id: abc123 -->
<!-- timestamp: 2026-03-05T12:00:00Z -->
<!-- origin: agent -->
<!-- sync: synced -->

A note from main.

<!-- note-id: def456 -->
<!-- timestamp: 2026-03-05T13:00:00Z -->
<!-- origin: agent -->
<!-- sync: synced -->

A new note from the worktree.
EOF
}

# ── Test 1: Body from main is preserved when local has no description ─────────

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

LOCAL_FILE="$TMPDIR_TEST/local.md"
MAIN_FILE="$TMPDIR_TEST/main.md"
OUTPUT_FILE="$TMPDIR_TEST/output.md"

make_worktree_ticket "$LOCAL_FILE"
make_main_ticket "$MAIN_FILE"

_merge_ticket_file "$LOCAL_FILE" "$MAIN_FILE" "$OUTPUT_FILE"
merge_exit=$?

assert_eq "merge returns 0" "0" "$merge_exit"

# The output should contain the description from main
output_content=$(cat "$OUTPUT_FILE")

assert_contains() {
    local label="$1" substring="$2" string="$3"
    if [[ "$string" == *"$substring"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: %s\n  expected to contain: %s\n  actual output:\n%s\n" \
            "$label" "$substring" "$string" >&2
    fi
}

assert_not_contains() {
    local label="$1" substring="$2" string="$3"
    if [[ "$string" != *"$substring"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: %s\n  expected NOT to contain: %s\n  actual output:\n%s\n" \
            "$label" "$substring" "$string" >&2
    fi
}

assert_contains \
    "merged output contains main description body" \
    "This is the full description from the main branch." \
    "$output_content"

assert_contains \
    "merged output contains main done definition" \
    "Implementation step 1" \
    "$output_content"

assert_contains \
    "merged output contains title" \
    "# As a developer, I can do the thing" \
    "$output_content"

# The status should come from local (in_progress > open)
assert_contains \
    "merged output has local status (in_progress)" \
    "status: in_progress" \
    "$output_content"

# ── Test 2: Body from local is preserved when local has more content ──────────

LOCAL_FILE2="$TMPDIR_TEST/local2.md"
MAIN_FILE2="$TMPDIR_TEST/main2.md"
OUTPUT_FILE2="$TMPDIR_TEST/output2.md"

# Local has a LONGER body than main
cat > "$LOCAL_FILE2" << 'EOF'
---
assignee: Joe Oakhart
created: 2026-03-05T12:00:00Z
deps: []
id: lockpick-doc-to-logic-test3
links: []
parent: lockpick-doc-to-logic-parent
priority: 2
status: in_progress
type: feature
---
# Title for test 3

## Description

Local has a longer description with more detail.
This includes several paragraphs of useful content
that should be preserved during the merge.

## Done Definition

- [ ] Step A
- [ ] Step B
- [ ] Step C

EOF

cat > "$MAIN_FILE2" << 'EOF'
---
assignee: Joe Oakhart
created: 2026-03-05T12:00:00Z
deps: []
id: lockpick-doc-to-logic-test3
links: []
parent: lockpick-doc-to-logic-parent
priority: 2
status: open
type: feature
---
# Title for test 3

## Description

Main has a shorter description.

EOF

_merge_ticket_file "$LOCAL_FILE2" "$MAIN_FILE2" "$OUTPUT_FILE2"
output2_content=$(cat "$OUTPUT_FILE2")

assert_contains \
    "when local has more body, local description preserved" \
    "Local has a longer description with more detail." \
    "$output2_content"

assert_contains \
    "when local has more body, local done definition preserved" \
    "Step A" \
    "$output2_content"

# ── Test 3: Safety check — >50% size reduction aborts sync ───────────────────
# This validates the file-size safety guard added to prevent silent data loss.

LOCAL_FILE3="$TMPDIR_TEST/local3.md"
MAIN_FILE3="$TMPDIR_TEST/main3.md"
OUTPUT_FILE3="$TMPDIR_TEST/output3.md"

# Main has a large description; local is minimal (title only)
make_worktree_ticket "$LOCAL_FILE3"
make_main_ticket "$MAIN_FILE3"

# After fix: merged output should NOT be smaller than 50% of main's size
main_size=$(wc -c < "$MAIN_FILE3")
_merge_ticket_file "$LOCAL_FILE3" "$MAIN_FILE3" "$OUTPUT_FILE3"
output3_size=$(wc -c < "$OUTPUT_FILE3")

# Output must be at least 50% the size of main
min_size=$(( main_size / 2 ))
if [[ "$output3_size" -ge "$min_size" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: safety check — merged output too small\n  main_size: %d bytes\n  output_size: %d bytes\n  min_required: %d bytes\n" \
        "$main_size" "$output3_size" "$min_size" >&2
fi

# ── Test 4: Description NOT duplicated when both have same content ────────────

LOCAL_FILE4="$TMPDIR_TEST/local4.md"
MAIN_FILE4="$TMPDIR_TEST/main4.md"
OUTPUT_FILE4="$TMPDIR_TEST/output4.md"

# Both have same description body
make_main_ticket "$LOCAL_FILE4"
make_main_ticket "$MAIN_FILE4"
# Update local status to in_progress
sed -i '' 's/status: open/status: in_progress/' "$LOCAL_FILE4"

_merge_ticket_file "$LOCAL_FILE4" "$MAIN_FILE4" "$OUTPUT_FILE4"
output4_content=$(cat "$OUTPUT_FILE4")

# Count occurrences of unique description line — should be exactly 1
count=$(grep -c "This is the full description from the main branch." "$OUTPUT_FILE4" || echo "0")
assert_eq "description not duplicated when both have same body" "1" "$count"

# ── Test 5: Notes merged from local + main with descriptions preserved ────────

LOCAL_FILE5="$TMPDIR_TEST/local5.md"
MAIN_FILE5="$TMPDIR_TEST/main5.md"
OUTPUT_FILE5="$TMPDIR_TEST/output5.md"

make_main_ticket_with_notes "$MAIN_FILE5"
make_worktree_ticket_with_notes "$LOCAL_FILE5"

_merge_ticket_file "$LOCAL_FILE5" "$MAIN_FILE5" "$OUTPUT_FILE5"
output5_content=$(cat "$OUTPUT_FILE5")

assert_contains \
    "notes+body merge: description from main preserved in notes test" \
    "This description should be preserved during merge." \
    "$output5_content"

assert_contains \
    "notes+body merge: original note preserved" \
    "A note from main." \
    "$output5_content"

assert_contains \
    "notes+body merge: new worktree note preserved" \
    "A new note from the worktree." \
    "$output5_content"

# ── Summary ───────────────────────────────────────────────────────────────────

print_summary() {
    printf "\nPASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
    if [[ "$FAIL" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

print_summary
