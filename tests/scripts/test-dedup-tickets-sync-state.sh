#!/usr/bin/env bash
# tests/scripts/test-dedup-tickets-sync-state.sh
#
# Tests that dedup-tickets.sh handles non-dict entries in .sync-state.json
# (e.g., "last_sync_commit": "<sha>") without crashing.
#
# Bug: Part A iterates all sync-state entries calling .get("jira_key"),
# which crashes with AttributeError on string values.
#
# Usage: bash tests/scripts/test-dedup-tickets-sync-state.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
DEDUP_SCRIPT="$REPO_ROOT/plugins/dso/scripts/dedup-tickets.sh"

source "$SCRIPT_DIR/../lib/run_test.sh"

_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-dedup-tickets-sync-state.sh ==="

# ── Helper: create a temp git repo with tickets ──────────────────────────

_setup_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.tickets"
    cd "$tmpdir" && git init -q .
    echo "$tmpdir"
}

_create_ticket() {
    local dir="$1" id="$2" title="$3" body="${4:-}"
    cat > "$dir/.tickets/$id.md" <<TICKET
---
id: $id
status: open
type: task
priority: 2
---
# $title
$body
TICKET
}

# ── Test 1: dry-run does not crash on string entries in sync-state ────────

echo "Test 1: dedup-tickets.sh --dry-run handles string entries in sync-state"
TMPDIR_T1=$(_setup_repo)

cat > "$TMPDIR_T1/.tickets/.sync-state.json" <<'EOF'
{
  "last_sync_commit": "abc123deadbeef",
  "tk-aaa": {"jira_key": "TEST-1", "local_hash": "aaa", "jira_hash": "aaa", "last_synced": "2026-01-01T00:00:00Z"},
  "tk-bbb": {"jira_key": "TEST-2", "local_hash": "bbb", "jira_hash": "bbb", "last_synced": "2026-01-01T00:00:00Z"}
}
EOF
_create_ticket "$TMPDIR_T1" "tk-aaa" "Ticket A"
_create_ticket "$TMPDIR_T1" "tk-bbb" "Ticket B"

cd "$TMPDIR_T1"

run_test "dry-run exits 0 with string entries in sync-state" \
    0 "Part A:" \
    bash "$DEDUP_SCRIPT" --dry-run

run_test "Part B header reached (Part A completed without crash)" \
    0 "Part B:" \
    bash "$DEDUP_SCRIPT" --dry-run

# ── Test 2: Part A finds jira_key dupes alongside string entries ──────────

echo "Test 2: Part A detects jira_key duplicates when string entries are present"
TMPDIR_T2=$(_setup_repo)

cat > "$TMPDIR_T2/.tickets/.sync-state.json" <<'EOF'
{
  "last_sync_commit": "abc123deadbeef",
  "tk-dup1": {"jira_key": "TEST-99", "local_hash": "aaa", "jira_hash": "aaa", "last_synced": "2026-01-01T00:00:00Z"},
  "tk-dup2": {"jira_key": "TEST-99", "local_hash": "bbb", "jira_hash": "bbb", "last_synced": "2026-01-01T00:00:00Z"}
}
EOF
_create_ticket "$TMPDIR_T2" "tk-dup1" "Duplicate ticket" "This has more content.\n\n## Notes\nSome notes."
_create_ticket "$TMPDIR_T2" "tk-dup2" "Duplicate ticket"

cd "$TMPDIR_T2"

run_test "reports 1 jira_key duplicate" \
    0 "1 jira_key duplicates found" \
    bash "$DEDUP_SCRIPT" --dry-run

run_test "identifies tk-dup2 for deletion" \
    0 "DELETE tk-dup2" \
    bash "$DEDUP_SCRIPT" --dry-run

run_test "identifies tk-dup1 as keeper" \
    0 "KEEP tk-dup1" \
    bash "$DEDUP_SCRIPT" --dry-run

# ── Test 3: Part B catches same-title pairs (threshold = 2) ──────────────

echo "Test 3: Part B detects same-title duplicate pairs, not just triples"
TMPDIR_T3=$(_setup_repo)

# No jira_key duplicates — these are local-only tickets with the same title
cat > "$TMPDIR_T3/.tickets/.sync-state.json" <<'EOF'
{
  "last_sync_commit": "abc123deadbeef",
  "tk-pair1": {"jira_key": "TEST-10", "local_hash": "aaa", "jira_hash": "aaa", "last_synced": "2026-01-01T00:00:00Z"}
}
EOF
_create_ticket "$TMPDIR_T3" "tk-pair1" "Same title epic" "Has real content.\n\n## Notes\nSome notes."
_create_ticket "$TMPDIR_T3" "tk-pair2" "Same title epic"

cd "$TMPDIR_T3"

run_test "Part B reports 1 spam title group for a pair" \
    0 "1 spam title groups found" \
    bash "$DEDUP_SCRIPT" --dry-run

run_test "Part B identifies tk-pair2 for closure" \
    0 "CLOSE: tk-pair2" \
    bash "$DEDUP_SCRIPT" --dry-run

run_test "Part B keeps tk-pair1 (has content)" \
    0 "KEEP: tk-pair1" \
    bash "$DEDUP_SCRIPT" --dry-run

print_results
