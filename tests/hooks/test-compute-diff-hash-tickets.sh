#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-compute-diff-hash-tickets.sh
# Tests that .tickets/ files ARE included in the compute-diff-hash.sh output.
#
# After removing automatic ticket sync, .tickets/ files flow through normal
# commits and must be included in diff hashes so code review covers them.
#
# TDD Protocol:
#   RED  (before change): hashes are EQUAL — .tickets/ is excluded, so modifying
#        a .tickets/ file does not change the hash.
#   GREEN (after change):  hashes are DIFFERENT — .tickets/ is included, so
#        modifying a .tickets/ file changes the hash.

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/compute-diff-hash.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Skip if not in a git repo with a working tree
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "SKIP: not inside a git work tree"
    exit 0
fi

# Work in a temp directory that is a fresh git repo so we don't pollute the
# real working tree with stray .tickets/ files.
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Initialise a minimal git repo with one commit so HEAD is valid
cd "$TMPDIR_TEST"
git init -q
git config user.email "test@test.com"
git config user.name "Test"

# Create an initial commit so there's a HEAD
echo "init" > README.md
git add README.md
git commit -q -m "init"

# Create .tickets/ directory and an initial ticket file, then commit it
mkdir -p .tickets
echo "status: open" > .tickets/ticket-001.md
git add .tickets/ticket-001.md
git commit -q -m "add ticket"

# Capture hash BEFORE modifying the ticket
HASH_BEFORE=$(bash "$HOOK" 2>/dev/null)
assert_ne "test_compute_diff_hash_produces_non_empty_output_before" "" "$HASH_BEFORE"

# Modify the ticket file (unstaged change)
echo "status: closed" >> .tickets/ticket-001.md

# Capture hash AFTER modifying the ticket
HASH_AFTER=$(bash "$HOOK" 2>/dev/null)
assert_ne "test_compute_diff_hash_produces_non_empty_output_after" "" "$HASH_AFTER"

# GREEN assertion: hashes must DIFFER — .tickets/ is now included in the hash
assert_ne "test_compute_diff_hash_includes_tickets_directory" \
    "$HASH_BEFORE" "$HASH_AFTER"

# Also verify that the NON_REVIEWABLE_PATTERN does not contain .tickets/
# (regression guard — if the pattern is ever re-added this test fails)
PATTERN_MATCH=$(grep 'NON_REVIEWABLE_PATTERN.*tickets\|tickets.*NON_REVIEWABLE' \
    "$REPO_ROOT/lockpick-workflow/hooks/compute-diff-hash.sh" 2>/dev/null || echo "")
assert_eq "test_non_reviewable_pattern_excludes_tickets" \
    "" "$PATTERN_MATCH"

# Verify no ':!.tickets/' exclusion pathspec exists in the script
PATHSPEC_MATCH=$(grep ':\!\.tickets/' \
    "$REPO_ROOT/lockpick-workflow/hooks/compute-diff-hash.sh" 2>/dev/null || echo "")
assert_eq "test_no_tickets_exclusion_pathspec_in_compute_diff_hash" \
    "" "$PATHSPEC_MATCH"

print_summary
