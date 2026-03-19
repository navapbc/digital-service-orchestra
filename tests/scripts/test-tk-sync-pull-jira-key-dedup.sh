#!/usr/bin/env bash
# tests/scripts/test-tk-sync-pull-jira-key-dedup.sh
#
# RED test: verify that _sync_pull_ticket does not create a duplicate local
# ticket when a Jira issue key (DIG-TEST-99) is already present in an existing
# ticket's frontmatter — even when the ledger has NO entry for that key.
#
# This exercises a known gap in _sync_pull_ticket: it checks the ledger for an
# existing mapping (reverse lookup: scan jira_key values) but does NOT scan
# existing ticket files for frontmatter jira_key fields.  When the ledger is
# empty/missing the entry, the function currently creates a duplicate ticket.
#
# Expected behaviour (GREEN, not yet implemented):
#   - No new ticket file is created
#   - A warning is written to stderr mentioning both "DIG-TEST-99" and the
#     existing local ticket ID ("test-abc1")
#
# TDD: this test FAILS (RED) against the current implementation.
#
# Note: this test calls _sync_pull_ticket directly (same pattern as
# test-sync-roundtrip.sh's pull_ticket_direct helper) to isolate the pull path
# from the push path.  If we ran full `tk sync`, _sync_push_ticket runs first
# and repairs the ledger from frontmatter — masking the bug.
#
# Usage: bash tests/scripts/test-tk-sync-pull-jira-key-dedup.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
TK="$DSO_PLUGIN_DIR/scripts/tk"

PASS=0
FAIL=0

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-tk-sync-pull-jira-key-dedup.sh ==="

# Skip local sync lock — temp dirs are not git repos; avoid cross-test contention
export TK_SYNC_SKIP_LOCK=1

# ---------------------------------------------------------------------------
# Helper: load_pull_helpers
# Extracts _sync_pull_ticket and its _sync_* / utility dependencies from
# the tk script using awk, so we can call _sync_pull_ticket directly in tests
# without running the full tk dispatch loop (same approach as test-sync-roundtrip.sh).
# ---------------------------------------------------------------------------
load_pull_helpers() {
    export TK_SCRIPT="$TK"

    # Extract all _sync_* functions
    local sync_src
    sync_src=$(awk '
        /^(_sync_[a-zA-Z_]+[[:space:]]*\(\)|function _sync_[a-zA-Z_]+)/ {
            capture = 1; depth = 0; buf = ""
        }
        capture {
            buf = buf $0 "\n"
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c == "{") depth++
                if (c == "}") {
                    depth--
                    if (depth == 0) { print buf; capture = 0; buf = ""; break }
                }
            }
        }
    ' "$TK")

    # Extract utility helpers needed by _sync_pull_ticket
    local util_src
    util_src=$(awk '
        /^(_sed_i|_iso_date|generate_id|ensure_dir|find_tickets_dir)[[:space:]]*\(\)/ {
            capture = 1; depth = 0; buf = ""
        }
        capture {
            buf = buf $0 "\n"
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c == "{") depth++
                if (c == "}") {
                    depth--
                    if (depth == 0) { print buf; capture = 0; buf = ""; break }
                }
            }
        }
    ' "$TK")

    [[ -z "$sync_src" ]] && return 1
    eval "$util_src"
    eval "$sync_src"
}

# ---------------------------------------------------------------------------
# Helper: pull_ticket_direct
# Calls _sync_pull_ticket in an isolated subshell (same as test-sync-roundtrip.sh).
# Args: tickets_dir ledger_file issue_json [path_prefix]
# ---------------------------------------------------------------------------
pull_ticket_direct() {
    local tickets_dir="$1" ledger_file="$2" issue_json="$3"
    local path_prefix="${4:-}"
    (
        [[ -n "$path_prefix" ]] && export PATH="$path_prefix:$PATH"
        export TICKETS_DIR="$tickets_dir" SYNC_STATE_FILE="$tickets_dir/.sync-state.json"
        load_pull_helpers
        _sync_pull_ticket "$issue_json" "$ledger_file" "$tickets_dir"
    ) 2>&1
}

# ---------------------------------------------------------------------------
# Test: sync_pull_dedup_by_frontmatter_jira_key
#
# Setup:
#   1. Temp TICKETS_DIR with a ticket file "test-abc1.md" containing
#      jira_key: DIG-TEST-99 in frontmatter.
#   2. An empty ledger (.sync-state.json = {}) — no entry for DIG-TEST-99.
#   3. Jira issue JSON for DIG-TEST-99.
#
# Call _sync_pull_ticket directly (bypasses _sync_push_ticket which would
# repair the ledger from frontmatter and mask the bug).
#
# Assertions:
#   A. No new ticket file is created (ticket count stays at 1).
#   B. Stderr mentions "DIG-TEST-99" (the Jira key being deduplicated).
#   C. Stderr mentions "test-abc1" (the existing local ticket ID).
# ---------------------------------------------------------------------------

echo "Test: sync_pull_dedup_by_frontmatter_jira_key"

_TDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TDIR")

# 1. Write a ticket file with jira_key: DIG-TEST-99 in frontmatter
cat > "$_TDIR/test-abc1.md" <<'EOFMD'
---
id: test-abc1
status: open
deps: []
links: []
created: 2026-03-19T00:00:00Z
type: story
priority: 2
jira_key: DIG-TEST-99
---
# Test Issue

Description for test-abc1.
EOFMD

# 2. Create an empty ledger — deliberately NO entry for DIG-TEST-99
printf '{}' > "$_TDIR/.sync-state.json"

# 3. Jira issue JSON for DIG-TEST-99 (the issue the pull is trying to process)
_ISSUE_JSON='{"key":"DIG-TEST-99","fields":{"summary":"Test Issue","status":{"name":"To Do"},"issuetype":{"name":"Story"},"priority":{"name":"Medium"},"description":""}}'

# Count ticket files before pull
_before_count=$(ls "$_TDIR"/*.md 2>/dev/null | wc -l | tr -d ' ')

# Call _sync_pull_ticket directly, capturing all output (stdout+stderr combined)
_output=$(pull_ticket_direct "$_TDIR" "$_TDIR/.sync-state.json" "$_ISSUE_JSON" 2>&1) || true

_after_count=$(ls "$_TDIR"/*.md 2>/dev/null | wc -l | tr -d ' ')

# Assertion A: no new ticket file created
if [[ "$_after_count" -le "$_before_count" ]]; then
    echo "  PASS: sync_pull_dedup_no_new_file (before=$_before_count after=$_after_count)"
    ((PASS++))
else
    echo "  FAIL: sync_pull_dedup_no_new_file — new ticket file(s) created (before=$_before_count after=$_after_count)"
    ls "$_TDIR"/*.md 2>/dev/null || true
    ((FAIL++))
fi

# Assertion B: output mentions DIG-TEST-99
if echo "$_output" | grep -q "DIG-TEST-99"; then
    echo "  PASS: sync_pull_dedup_output_mentions_jira_key"
    ((PASS++))
else
    echo "  FAIL: sync_pull_dedup_output_mentions_jira_key — 'DIG-TEST-99' not in output"
    echo "  output: $_output"
    ((FAIL++))
fi

# Assertion C: output mentions the existing local ticket ID
if echo "$_output" | grep -q "test-abc1"; then
    echo "  PASS: sync_pull_dedup_output_mentions_local_id"
    ((PASS++))
else
    echo "  FAIL: sync_pull_dedup_output_mentions_local_id — 'test-abc1' not in output"
    echo "  output: $_output"
    ((FAIL++))
fi

rm -rf "$_TDIR"
_CLEANUP_DIRS=()

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
