#!/usr/bin/env bash
# tests/scripts/test-commit-failure-tracker.sh
#
# Tests for hook_commit_failure_tracker() in pre-bash-functions.sh.
#
# Verifies that:
#   1. Grep search: when a .md file exists with matching content, no warning.
#   2. No match: when no matching ticket exists, warning is emitted.
#
# Usage: bash tests/scripts/test-commit-failure-tracker.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
FUNCS="$DSO_PLUGIN_DIR/hooks/lib/pre-bash-functions.sh"

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
# Test 1: test_tracker_finds_matching_md
#
# When a .md file exists with matching content, the tracker should find it
# via grep -rl and NOT warn.
# ---------------------------------------------------------------------------
echo "Test 1: test_tracker_finds_matching_md — no warning when .md file found"

TMPDIR_T2=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T2"' EXIT

TICKETS_DIR_T2="$TMPDIR_T2/tickets"
mkdir -p "$TICKETS_DIR_T2"

ARTIFACTS_DIR_T2="$TMPDIR_T2/artifacts"
mkdir -p "$ARTIFACTS_DIR_T2"

# Validation state: failed with category "lint"
make_status_file "$ARTIFACTS_DIR_T2/status" "lint"

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
    echo "  FAIL: test_tracker_finds_matching_md — unexpected warning" >&2
    echo "  STDERR: $STDERR_OUT" >&2
    (( FAIL++ ))
else
    echo "  PASS: test_tracker_finds_matching_md — no warning when .md file found"
    (( PASS++ ))
fi

rm -rf "$TMPDIR_T2"
trap - EXIT

# Also verify: no matching .md => warning IS emitted
echo "Test 2: test_tracker_warns_when_no_match — warning emitted when no match found"

TMPDIR_T2B=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T2B"' EXIT

TICKETS_DIR_T2B="$TMPDIR_T2B/tickets"
mkdir -p "$TICKETS_DIR_T2B"

ARTIFACTS_DIR_T2B="$TMPDIR_T2B/artifacts"
mkdir -p "$ARTIFACTS_DIR_T2B"

make_status_file "$ARTIFACTS_DIR_T2B/status" "mypy"
# No matching .md file

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
    echo "  PASS: test_tracker_warns_when_no_match — warning emitted when nothing found"
    (( PASS++ ))
else
    echo "  FAIL: test_tracker_warns_when_no_match — warning missing when nothing found" >&2
    echo "  STDERR: $STDERR_OUT" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T2B"
trap - EXIT

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

print_results
