#!/usr/bin/env bash
# tests/scripts/test-commit-failure-tracker.sh
#
# Tests for hook_commit_failure_tracker() in pre-bash-functions.sh.
#
# Verifies that:
#   1. Index path: when .index.json exists and contains a matching entry,
#      the tracker finds the issue via the index (not grep -rl).
#   2. Fallback: when .index.json is absent, grep -rl is used as fallback.
#   3. Stale entry: when .index.json has an entry but the .md file is absent,
#      the entry is treated as found (index is authoritative; stale = tracked).
#
# Usage: bash tests/scripts/test-commit-failure-tracker.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
FUNCS="$PLUGIN_ROOT/hooks/lib/pre-bash-functions.sh"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-commit-failure-tracker.sh ==="

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a minimal git-commit Bash tool JSON input
make_input() {
    python3 -c "
import json, sys
print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': 'git commit -m \"test\"'}}))
"
}

# Write a minimal .index.json with the given ticket
make_index() {
    local dir="$1"
    local ticket_id="$2"
    local title="$3"
    local status="${4:-open}"
    local type="${5:-task}"
    python3 -c "
import json
idx = {'$ticket_id': {'title': '$title', 'status': '$status', 'type': '$type'}}
with open('$dir/.index.json', 'w') as f:
    json.dump(idx, f)
"
}

# Write a minimal .md ticket file
make_ticket_md() {
    local dir="$1"
    local id="$2"
    local title="${3:-Ticket $id}"
    local status="${4:-open}"
    cat > "$dir/${id}.md" <<EOF
---
id: ${id}
status: ${status}
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# ${title}
EOF
}

# Write a minimal validation status file showing failure with given category
make_status_file() {
    local status_file="$1"
    local category="$2"
    printf 'failed\nfailed_checks=%s\n' "$category" > "$status_file"
}

# ---------------------------------------------------------------------------
# Test 1: test_tracker_uses_index
#
# When .index.json exists and contains a matching title entry,
# the tracker should find it via the index and NOT warn.
# We verify the index path is used by providing an EMPTY .tickets/ dir
# (no .md files) — grep -rl over the dir would find nothing, but
# the index has the matching entry, so no warning should be emitted.
# ---------------------------------------------------------------------------
echo "Test 1: test_tracker_uses_index — index used when .index.json present with match"

TMPDIR_T1=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T1"' EXIT

TICKETS_DIR_T1="$TMPDIR_T1/tickets"
mkdir -p "$TICKETS_DIR_T1"

ARTIFACTS_DIR_T1="$TMPDIR_T1/artifacts"
mkdir -p "$ARTIFACTS_DIR_T1"

# Validation state: failed with category "unit-tests"
make_status_file "$ARTIFACTS_DIR_T1/status" "unit-tests"

# Index has a matching entry — title contains "unit-tests failure"
make_index "$TICKETS_DIR_T1" "proj-abc1" "Fix unit-tests failure in CI" "open" "task"

# NO .md files in the tickets dir — grep -rl would find nothing

# Capture stderr output from hook (never blocks, so exit 0)
INPUT=$(make_input)
STDERR_OUT=$(
    ARTIFACTS_DIR="$ARTIFACTS_DIR_T1" \
    TICKETS_DIR_OVERRIDE="$TICKETS_DIR_T1" \
    bash -c "
        source '$FUNCS'
        hook_commit_failure_tracker '$INPUT'
    " 2>&1 >/dev/null || true
)

# Should NOT warn because index found a matching entry
if echo "$STDERR_OUT" | grep -q "UNTRACKED VALIDATION"; then
    echo "  FAIL: test_tracker_uses_index — unexpected warning when index has match" >&2
    echo "  STDERR: $STDERR_OUT" >&2
    (( FAIL++ ))
else
    echo "  PASS: test_tracker_uses_index — no warning when index has matching entry"
    (( PASS++ ))
fi

rm -rf "$TMPDIR_T1"
trap - EXIT

# ---------------------------------------------------------------------------
# Test 2: test_tracker_falls_back_to_grep
#
# When .index.json is absent, the tracker falls back to grep -rl over .tickets/.
# We verify fallback by:
#   - No .index.json present
#   - A .md file exists with matching content
#   - No warning is emitted (grep found it)
# ---------------------------------------------------------------------------
echo "Test 2: test_tracker_falls_back_to_grep — grep fallback used when index absent"

TMPDIR_T2=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T2"' EXIT

TICKETS_DIR_T2="$TMPDIR_T2/tickets"
mkdir -p "$TICKETS_DIR_T2"

ARTIFACTS_DIR_T2="$TMPDIR_T2/artifacts"
mkdir -p "$ARTIFACTS_DIR_T2"

# Validation state: failed with category "lint"
make_status_file "$ARTIFACTS_DIR_T2/status" "lint"

# No .index.json — only a .md file with matching content
make_ticket_md "$TICKETS_DIR_T2" "proj-lint1" "Fix lint failure" "open"

INPUT=$(make_input)
STDERR_OUT=$(
    ARTIFACTS_DIR="$ARTIFACTS_DIR_T2" \
    TICKETS_DIR_OVERRIDE="$TICKETS_DIR_T2" \
    bash -c "
        source '$FUNCS'
        hook_commit_failure_tracker '$INPUT'
    " 2>&1 >/dev/null || true
)

# Should NOT warn because grep found the .md file
if echo "$STDERR_OUT" | grep -q "UNTRACKED VALIDATION"; then
    echo "  FAIL: test_tracker_falls_back_to_grep — unexpected warning; grep fallback not working" >&2
    echo "  STDERR: $STDERR_OUT" >&2
    (( FAIL++ ))
else
    echo "  PASS: test_tracker_falls_back_to_grep — no warning when .md file found via grep"
    (( PASS++ ))
fi

rm -rf "$TMPDIR_T2"
trap - EXIT

# Also verify: no index + no matching .md => warning IS emitted
echo "Test 2b: test_tracker_falls_back_to_grep (no match) — warning emitted when grep finds nothing"

TMPDIR_T2B=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T2B"' EXIT

TICKETS_DIR_T2B="$TMPDIR_T2B/tickets"
mkdir -p "$TICKETS_DIR_T2B"

ARTIFACTS_DIR_T2B="$TMPDIR_T2B/artifacts"
mkdir -p "$ARTIFACTS_DIR_T2B"

make_status_file "$ARTIFACTS_DIR_T2B/status" "mypy"
# No index, no matching .md file

INPUT=$(make_input)
STDERR_OUT=$(
    ARTIFACTS_DIR="$ARTIFACTS_DIR_T2B" \
    TICKETS_DIR_OVERRIDE="$TICKETS_DIR_T2B" \
    bash -c "
        source '$FUNCS'
        hook_commit_failure_tracker '$INPUT'
    " 2>&1 >/dev/null || true
)

if echo "$STDERR_OUT" | grep -q "UNTRACKED VALIDATION"; then
    echo "  PASS: test_tracker_falls_back_to_grep (no match) — warning emitted when nothing found"
    (( PASS++ ))
else
    echo "  FAIL: test_tracker_falls_back_to_grep (no match) — warning missing when nothing found" >&2
    echo "  STDERR: $STDERR_OUT" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T2B"
trap - EXIT

# ---------------------------------------------------------------------------
# Test 3: test_tracker_index_stale_entry
#
# When .index.json has an entry matching the failure category but the
# corresponding .md file is absent (stale/deleted ticket), the index entry
# is treated as "found" (tracking issue existed). The tracker should NOT warn.
# Rationale: the index is authoritative; absence of .md is an index consistency
# issue, not a "no tracking issue" situation. Stale = still tracked.
# ---------------------------------------------------------------------------
echo "Test 3: test_tracker_index_stale_entry — stale index entry treated as tracked (no warning)"

TMPDIR_T3=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T3"' EXIT

TICKETS_DIR_T3="$TMPDIR_T3/tickets"
mkdir -p "$TICKETS_DIR_T3"

ARTIFACTS_DIR_T3="$TMPDIR_T3/artifacts"
mkdir -p "$ARTIFACTS_DIR_T3"

# Validation state: failed with category "coverage"
make_status_file "$ARTIFACTS_DIR_T3/status" "coverage"

# Index has a matching entry — but no corresponding .md file
make_index "$TICKETS_DIR_T3" "proj-stale1" "Fix coverage failure" "closed" "task"
# Intentionally: no proj-stale1.md file

INPUT=$(make_input)
STDERR_OUT=$(
    ARTIFACTS_DIR="$ARTIFACTS_DIR_T3" \
    TICKETS_DIR_OVERRIDE="$TICKETS_DIR_T3" \
    bash -c "
        source '$FUNCS'
        hook_commit_failure_tracker '$INPUT'
    " 2>&1 >/dev/null || true
)

# Should NOT warn — index entry found (even though .md is absent)
if echo "$STDERR_OUT" | grep -q "UNTRACKED VALIDATION"; then
    echo "  FAIL: test_tracker_index_stale_entry — unexpected warning for stale entry" >&2
    echo "  STDERR: $STDERR_OUT" >&2
    (( FAIL++ ))
else
    echo "  PASS: test_tracker_index_stale_entry — no warning for stale index entry"
    (( PASS++ ))
fi

rm -rf "$TMPDIR_T3"
trap - EXIT

# ---------------------------------------------------------------------------
# Test 4: test_tracker_index_no_match_but_md_exists
#
# When .index.json exists but does NOT contain a matching entry for the
# failure category, the tracker falls back to grep over .tickets/ and
# finds a matching .md file — should NOT warn.
# ---------------------------------------------------------------------------
echo "Test 4: test_tracker_index_no_match_but_md_exists — grep fallback used when index has no match"

TMPDIR_T4=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T4"' EXIT

TICKETS_DIR_T4="$TMPDIR_T4/tickets"
mkdir -p "$TICKETS_DIR_T4"

ARTIFACTS_DIR_T4="$TMPDIR_T4/artifacts"
mkdir -p "$ARTIFACTS_DIR_T4"

# Validation state: failed with category "e2e"
make_status_file "$ARTIFACTS_DIR_T4/status" "e2e"

# Index has an entry but for a DIFFERENT category
make_index "$TICKETS_DIR_T4" "proj-other1" "Fix lint failure" "open" "task"

# A .md file exists matching the e2e failure — grep fallback should find it
make_ticket_md "$TICKETS_DIR_T4" "proj-e2e1" "Fix e2e failure in CI" "open"

INPUT=$(make_input)
STDERR_OUT=$(
    ARTIFACTS_DIR="$ARTIFACTS_DIR_T4" \
    TICKETS_DIR_OVERRIDE="$TICKETS_DIR_T4" \
    bash -c "
        source '$FUNCS'
        hook_commit_failure_tracker '$INPUT'
    " 2>&1 >/dev/null || true
)

# Should NOT warn — grep fallback found the .md file
if echo "$STDERR_OUT" | grep -q "UNTRACKED VALIDATION"; then
    echo "  FAIL: test_tracker_index_no_match_but_md_exists — unexpected warning" >&2
    echo "  STDERR: $STDERR_OUT" >&2
    (( FAIL++ ))
else
    echo "  PASS: test_tracker_index_no_match_but_md_exists — no warning when grep fallback finds match"
    (( PASS++ ))
fi

rm -rf "$TMPDIR_T4"
trap - EXIT

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

print_results
