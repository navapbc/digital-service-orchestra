#!/usr/bin/env bash
# tests/hooks/test-compute-diff-hash-tickets.sh
# Tests that .tickets-tracker/ and .sync-state.json files are EXCLUDED from compute-diff-hash.sh.
#
# Ticket metadata changes (checkpoint notes, status updates) must not invalidate
# code reviews. The diff hash should be stable across ticket-only changes.
#
# Tests:
#   test_compute_diff_hash_excludes_tickets_directory
#   test_compute_diff_hash_excludes_sync_state_json
#   test_non_reviewable_pattern_includes_tickets
#   test_tickets_exclusion_pathspec_exists
#   test_sync_state_exclusion_pathspec_exists

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Skip if not in a git repo with a working tree
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "SKIP: not inside a git work tree"
    exit 0
fi

# Work in a temp directory that is a fresh git repo so we don't pollute the
# real working tree with stray .tickets-tracker/ files.
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Initialise a minimal git repo with one commit so HEAD is valid
cd "$TMPDIR_TEST"
git init -q -b main
git config user.email "test@test.com"
git config user.name "Test"

# Create an initial commit so there's a HEAD
echo "init" > README.md
git add README.md
git commit -q -m "init"

# Create .tickets-tracker/ directory and an initial ticket file, then commit it
mkdir -p .tickets-tracker
echo "status: open" > .tickets-tracker/ticket-001.md
git add .tickets-tracker/ticket-001.md
git commit -q -m "add ticket"

# ============================================================
# test_compute_diff_hash_excludes_tickets_directory
# Modifying a .tickets-tracker/ file should NOT change the hash
# ============================================================
echo "--- test_compute_diff_hash_excludes_tickets_directory ---"

HASH_BEFORE=$(bash "$HOOK" 2>/dev/null)
assert_ne "hash produces non-empty output before" "" "$HASH_BEFORE"

# Modify the ticket file (unstaged change)
echo "status: closed" >> .tickets-tracker/ticket-001.md

HASH_AFTER=$(bash "$HOOK" 2>/dev/null)
assert_ne "hash produces non-empty output after" "" "$HASH_AFTER"

# Hashes must be EQUAL — .tickets-tracker/ is excluded from the hash
assert_eq "ticket change does not alter hash" "$HASH_BEFORE" "$HASH_AFTER"

# Reset the ticket change
git checkout -- .tickets-tracker/ticket-001.md

# ============================================================
# test_compute_diff_hash_excludes_sync_state_json
# Modifying .sync-state.json should NOT change the hash
# ============================================================
echo "--- test_compute_diff_hash_excludes_sync_state_json ---"

# Create and commit .sync-state.json
echo '{"last_sync": "2026-01-01"}' > .sync-state.json
git add .sync-state.json
git commit -q -m "add sync state"

HASH_BEFORE_SYNC=$(bash "$HOOK" 2>/dev/null)

# Modify sync state (unstaged change)
echo '{"last_sync": "2026-03-12"}' > .sync-state.json

HASH_AFTER_SYNC=$(bash "$HOOK" 2>/dev/null)

# Hashes must be EQUAL — .sync-state.json is excluded
assert_eq "sync-state change does not alter hash" "$HASH_BEFORE_SYNC" "$HASH_AFTER_SYNC"

# ============================================================
# test_non_reviewable_pattern_includes_tickets
# compute-diff-hash.sh must reference review-gate-allowlist.conf for pattern loading
# (NON_REVIEWABLE_PATTERN is now derived from the allowlist, not hardcoded)
# ============================================================
echo "--- test_non_reviewable_pattern_includes_tickets ---"

PATTERN_MATCH=$(grep 'review-gate-allowlist' \
    "$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "compute-diff-hash.sh references review-gate-allowlist" "true" \
    "$( [[ $PATTERN_MATCH -ge 1 ]] && echo true || echo false )"

# ============================================================
# test_tickets_exclusion_pathspec_exists
# The allowlist must contain a .tickets-tracker/ pattern (source of truth for pathspec exclusions)
# ============================================================
echo "--- test_tickets_exclusion_pathspec_exists ---"

ALLOWLIST="$DSO_PLUGIN_DIR/hooks/lib/review-gate-allowlist.conf"
PATHSPEC_MATCH=$(grep '\.tickets-tracker/' "$ALLOWLIST" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "review-gate-allowlist.conf contains .tickets-tracker/ pattern" "true" \
    "$( [[ $PATHSPEC_MATCH -ge 1 ]] && echo true || echo false )"

# ============================================================
# test_sync_state_exclusion_pathspec_exists
# The EXCLUDE_PATHSPECS must contain ':!.sync-state.json'
# ============================================================
echo "--- test_sync_state_exclusion_pathspec_exists ---"

PATHSPEC_MATCH=$(grep "':!\.sync-state\.json'" \
    "$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "EXCLUDE_PATHSPECS contains :!.sync-state.json" "1" "$PATHSPEC_MATCH"

# ============================================================
# test_capture_review_diff_excludes_tickets
# capture-review-diff.sh EXCLUDES array must contain the tickets pathspec exclusion
# ============================================================
echo "--- test_capture_review_diff_excludes_tickets ---"

_TICKETS_PATHSPEC=":!.tickets-tracker/"
CAPTURE_SCRIPT="$DSO_PLUGIN_DIR/scripts/capture-review-diff.sh"
CAPTURE_TICKETS=$(grep -F "$_TICKETS_PATHSPEC" "$CAPTURE_SCRIPT" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "capture-review-diff excludes .tickets-tracker/" "1" "$CAPTURE_TICKETS"

CAPTURE_SYNC=$(grep -F ':!.sync-state.json' "$CAPTURE_SCRIPT" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "capture-review-diff excludes .sync-state.json" "1" "$CAPTURE_SYNC"

# ============================================================
# test_record_review_excludes_tickets
# record-review.sh _RR_EXCLUDE must contain .tickets-tracker/ and .sync-state.json
# ============================================================
echo "--- test_record_review_excludes_tickets ---"

RECORD_SCRIPT="$DSO_PLUGIN_DIR/hooks/record-review.sh"
# _RR_EXCLUDE array is defined once and expanded by both git diff commands
RECORD_TICKETS=$(grep -F ':!.tickets-tracker/' "$RECORD_SCRIPT" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "record-review.sh _RR_EXCLUDE contains .tickets-tracker/ pathspec" "true" \
    "$( [[ $RECORD_TICKETS -ge 1 ]] && echo true || echo false )"

RECORD_SYNC=$(grep -F ':!.sync-state.json' "$RECORD_SCRIPT" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "record-review.sh _RR_EXCLUDE contains .sync-state.json pathspec" "true" \
    "$( [[ $RECORD_SYNC -ge 1 ]] && echo true || echo false )"

print_summary
