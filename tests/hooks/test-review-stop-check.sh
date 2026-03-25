#!/usr/bin/env bash
# tests/hooks/test-review-stop-check.sh
# Tests for .claude/hooks/review-stop-check.sh — specifically the v2 .tickets/
# path exemption that should be removed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/review-stop-check.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# --- test_review_stop_no_tickets_v2_skip ---
# RED: .tickets/ path changes should NOT be silently excluded from the
# "uncommitted changes" check in review-stop-check.sh.
#
# Currently, the hook filters out '^\.tickets/' via grep -v before deciding
# whether there are uncommitted changes. This means a session with ONLY
# .tickets/ modifications exits silently (no review reminder). After removing
# the v2 .tickets/ skip, the hook should output a REMINDER for .tickets/ changes.
#
# Test setup: create an isolated fake git repo where a .tickets/ file has an
# uncommitted modification. Run the hook from within that repo (so git
# rev-parse returns the fake root). Assert that the output contains a REMINDER.
#
# Currently this test FAILS because the .tickets/ filter suppresses the warning.

# Create an isolated fake git repo for this test
FAKE_REPO=$(mktemp -d "${TMPDIR:-/tmp}/test-review-stop-check-XXXXXX")
trap 'rm -rf "$FAKE_REPO"' EXIT

git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" config user.email "test@example.com"
git -C "$FAKE_REPO" config user.name "Test"

# Create and commit an initial file (needed so HEAD exists)
echo "initial" > "$FAKE_REPO/README.md"
git -C "$FAKE_REPO" add README.md
git -C "$FAKE_REPO" commit -q -m "init"

# Create a .tickets/ file and commit it
mkdir -p "$FAKE_REPO/.tickets/abc-0001"
printf "# Test Ticket\nstatus: open\n" > "$FAKE_REPO/.tickets/abc-0001/ticket.md"
git -C "$FAKE_REPO" add .tickets/
git -C "$FAKE_REPO" commit -q -m "add ticket"

# Modify the .tickets/ file (uncommitted change)
echo "modified" >> "$FAKE_REPO/.tickets/abc-0001/ticket.md"

# Use an isolated artifacts dir so review-status state doesn't bleed in
ISOLATED_ARTIFACTS=$(mktemp -d "${TMPDIR:-/tmp}/test-review-stop-artifacts-XXXXXX")

# Run the hook from within the fake repo; capture output
HOOK_OUTPUT=""
HOOK_OUTPUT=$(cd "$FAKE_REPO" && WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ISOLATED_ARTIFACTS" bash "$HOOK" 2>/dev/null || true)

# After removing the v2 .tickets/ skip, the hook should output a REMINDER.
# Currently it exits silently (empty output) because .tickets/ changes are filtered.
assert_contains "test_review_stop_no_tickets_v2_skip" "REMINDER" "$HOOK_OUTPUT"

# Cleanup isolated artifacts dir
rm -rf "$ISOLATED_ARTIFACTS" 2>/dev/null || true

print_summary
