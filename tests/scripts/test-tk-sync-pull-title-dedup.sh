#!/usr/bin/env bash
# tests/scripts/test-tk-sync-pull-title-dedup.sh
#
# RED test: verify that _sync_pull_ticket does not create a duplicate local
# ticket when a Jira issue's summary matches an existing local ticket title —
# even when the existing ticket has NO jira_key in frontmatter.
#
# This exercises a known gap in _sync_pull_ticket: it checks the ledger for an
# existing mapping and scans frontmatter jira_key fields (batch 4 dedup), but
# does NOT scan existing ticket titles/summaries before creating a new ticket.
# When the ledger has no entry and frontmatter has no jira_key, the function
# currently creates a duplicate ticket whose title matches an existing local ticket.
#
# Expected behaviour (GREEN, not yet implemented):
#   - No new ticket file is created
#   - A warning is written to stderr mentioning both the Jira key ("DIG-TITLE-1")
#     and either "title" or "summary" and the matching local ticket ID ("test-title1")
#
# TDD: this test FAILS (RED) against the current implementation.
#
# SC3 ordering note (NEGATIVE assertion):
#   When a frontmatter jira_key ALSO matches (batch 4 dedup fires first),
#   the title-dedup warning must NOT appear — the jira_key check takes precedence.
#
# Note: this test calls _sync_pull_ticket directly (same pattern as
# test-tk-sync-pull-jira-key-dedup.sh) to isolate the pull path from the push
# path.  If we ran full `tk sync`, _sync_push_ticket runs first and would repair
# the ledger, potentially masking the bug.
#
# Usage: bash tests/scripts/test-tk-sync-pull-title-dedup.sh

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

echo "=== test-tk-sync-pull-title-dedup.sh ==="

# Skip local sync lock — temp dirs are not git repos; avoid cross-test contention
export TK_SYNC_SKIP_LOCK=1

# ---------------------------------------------------------------------------
# Helper: load_pull_helpers
# Extracts _sync_pull_ticket and its _sync_* / utility dependencies from
# the tk script using awk, so we can call _sync_pull_ticket directly in tests
# without running the full tk dispatch loop (same approach as
# test-tk-sync-pull-jira-key-dedup.sh).
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
# Calls _sync_pull_ticket in an isolated subshell (same as
# test-tk-sync-pull-jira-key-dedup.sh).
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
# Test SC1: sync_pull_dedup_by_title
#
# Setup:
#   1. Temp TICKETS_DIR with a ticket file "test-title1.md" titled
#      "Build Feature X" — NO jira_key in frontmatter.
#   2. An empty ledger (.sync-state.json = {}) — no entry for DIG-TITLE-1.
#   3. Jira issue JSON: key "DIG-TITLE-1", summary "Build Feature X".
#
# Call _sync_pull_ticket directly (bypasses _sync_push_ticket which would
# repair the ledger from frontmatter and mask the bug).
#
# Assertions:
#   A. No new ticket file is created (ticket count stays at 1).
#   B. Output mentions "DIG-TITLE-1" (the Jira key being deduplicated).
#   C. Output mentions "test-title1" (the existing local ticket ID).
#   D. Output mentions "title" or "summary" (indicates title-match code path).
# ---------------------------------------------------------------------------

echo "Test SC1: sync_pull_dedup_by_title"

_TDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TDIR")

# 1. Write a ticket file with title "Build Feature X" — NO jira_key in frontmatter
cat > "$_TDIR/test-title1.md" <<'EOFMD'
---
id: test-title1
status: open
deps: []
links: []
created: 2026-03-19T00:00:00Z
type: story
priority: 2
---
# Build Feature X

Description for test-title1.
EOFMD

# 2. Create an empty ledger — deliberately NO entry for DIG-TITLE-1
printf '{}' > "$_TDIR/.sync-state.json"

# 3. Jira issue JSON: key DIG-TITLE-1, summary "Build Feature X"
_ISSUE_JSON='{"key":"DIG-TITLE-1","fields":{"summary":"Build Feature X","status":{"name":"To Do"},"issuetype":{"name":"Story"},"priority":{"name":"Medium"},"description":""}}'

# Count ticket files before pull
_before_count=$(ls "$_TDIR"/*.md 2>/dev/null | wc -l | tr -d ' ')

# Call _sync_pull_ticket directly, capturing all output (stdout+stderr combined)
_output=$(pull_ticket_direct "$_TDIR" "$_TDIR/.sync-state.json" "$_ISSUE_JSON" 2>&1) || true

_after_count=$(ls "$_TDIR"/*.md 2>/dev/null | wc -l | tr -d ' ')

# Assertion A: no new ticket file created
if [[ "$_after_count" -le "$_before_count" ]]; then
    echo "  PASS: SC1_title_dedup_no_new_file (before=$_before_count after=$_after_count)"
    ((PASS++))
else
    echo "  FAIL: SC1_title_dedup_no_new_file — new ticket file(s) created (before=$_before_count after=$_after_count)"
    ls "$_TDIR"/*.md 2>/dev/null || true
    ((FAIL++))
fi

# Assertion B: output mentions DIG-TITLE-1
if echo "$_output" | grep -q "DIG-TITLE-1"; then
    echo "  PASS: SC1_title_dedup_output_mentions_jira_key"
    ((PASS++))
else
    echo "  FAIL: SC1_title_dedup_output_mentions_jira_key — 'DIG-TITLE-1' not in output"
    echo "  output: $_output"
    ((FAIL++))
fi

# Assertion C: output mentions the existing local ticket ID
if echo "$_output" | grep -q "test-title1"; then
    echo "  PASS: SC1_title_dedup_output_mentions_local_id"
    ((PASS++))
else
    echo "  FAIL: SC1_title_dedup_output_mentions_local_id — 'test-title1' not in output"
    echo "  output: $_output"
    ((FAIL++))
fi

# Assertion D: output mentions "title" or "summary" (title-match code path)
if echo "$_output" | grep -qiE "title|summary"; then
    echo "  PASS: SC1_title_dedup_output_mentions_title_or_summary"
    ((PASS++))
else
    echo "  FAIL: SC1_title_dedup_output_mentions_title_or_summary — neither 'title' nor 'summary' in output"
    echo "  output: $_output"
    ((FAIL++))
fi

rm -rf "$_TDIR"
_CLEANUP_DIRS=()

# ---------------------------------------------------------------------------
# Test SC2: sync_pull_title_dedup_case_insensitive
#
# Same as SC1 but the local ticket title uses different casing ("build feature x")
# to verify the title comparison is case-insensitive.
#
# Assertions:
#   A. No new ticket file is created (title match is case-insensitive).
# ---------------------------------------------------------------------------

echo "Test SC2: sync_pull_title_dedup_case_insensitive"

_TDIR2=$(mktemp -d)
_CLEANUP_DIRS+=("$_TDIR2")

cat > "$_TDIR2/test-title2.md" <<'EOFMD'
---
id: test-title2
status: open
deps: []
links: []
created: 2026-03-19T00:00:00Z
type: story
priority: 2
---
# build feature x

Description for test-title2 (lowercase title).
EOFMD

printf '{}' > "$_TDIR2/.sync-state.json"

# Jira issue has mixed-case summary matching the lowercase local title
_ISSUE_JSON2='{"key":"DIG-TITLE-2","fields":{"summary":"Build Feature X","status":{"name":"To Do"},"issuetype":{"name":"Story"},"priority":{"name":"Medium"},"description":""}}'

_before_count2=$(ls "$_TDIR2"/*.md 2>/dev/null | wc -l | tr -d ' ')
_output2=$(pull_ticket_direct "$_TDIR2" "$_TDIR2/.sync-state.json" "$_ISSUE_JSON2" 2>&1) || true
_after_count2=$(ls "$_TDIR2"/*.md 2>/dev/null | wc -l | tr -d ' ')

if [[ "$_after_count2" -le "$_before_count2" ]]; then
    echo "  PASS: SC2_title_dedup_case_insensitive_no_new_file (before=$_before_count2 after=$_after_count2)"
    ((PASS++))
else
    echo "  FAIL: SC2_title_dedup_case_insensitive_no_new_file — new ticket file(s) created (before=$_before_count2 after=$_after_count2)"
    ls "$_TDIR2"/*.md 2>/dev/null || true
    ((FAIL++))
fi

rm -rf "$_TDIR2"
_CLEANUP_DIRS=()

# ---------------------------------------------------------------------------
# Test SC3: NEGATIVE assertion — jira_key match takes precedence over title dedup
#
# Setup:
#   1. Temp TICKETS_DIR with a ticket that has BOTH a matching title ("Build Feature X")
#      AND jira_key: DIG-TITLE-3 in frontmatter.
#   2. Empty ledger (batch 4 frontmatter jira_key dedup must fire, not title dedup).
#   3. Jira issue JSON: key "DIG-TITLE-3", summary "Build Feature X".
#
# The jira_key frontmatter check (batch 4) fires first and deduplicates.
# The title-match warning must NOT appear — it means the title-dedup code
# path was NOT reached (jira_key check took precedence, as required by SC3 ordering).
#
# Assertions:
#   A. No new ticket file is created (dedup fires, just not via title path).
#   B. Output does NOT contain title-dedup warning keywords ("title match"/"summary match").
# ---------------------------------------------------------------------------

echo "Test SC3: jira_key_match_takes_precedence_over_title_dedup (NEGATIVE)"

_TDIR3=$(mktemp -d)
_CLEANUP_DIRS+=("$_TDIR3")

# Ticket with BOTH matching title AND jira_key in frontmatter
cat > "$_TDIR3/test-title3.md" <<'EOFMD'
---
id: test-title3
status: open
deps: []
links: []
created: 2026-03-19T00:00:00Z
type: story
priority: 2
jira_key: DIG-TITLE-3
---
# Build Feature X

Description for test-title3 (has jira_key — jira_key dedup fires first).
EOFMD

# Empty ledger — jira_key frontmatter scan (batch 4) must catch it
printf '{}' > "$_TDIR3/.sync-state.json"

_ISSUE_JSON3='{"key":"DIG-TITLE-3","fields":{"summary":"Build Feature X","status":{"name":"To Do"},"issuetype":{"name":"Story"},"priority":{"name":"Medium"},"description":""}}'

_before_count3=$(ls "$_TDIR3"/*.md 2>/dev/null | wc -l | tr -d ' ')
_output3=$(pull_ticket_direct "$_TDIR3" "$_TDIR3/.sync-state.json" "$_ISSUE_JSON3" 2>&1) || true
_after_count3=$(ls "$_TDIR3"/*.md 2>/dev/null | wc -l | tr -d ' ')

# Assertion A: no new ticket created (deduplication still fires, via jira_key path)
if [[ "$_after_count3" -le "$_before_count3" ]]; then
    echo "  PASS: SC3_jira_key_precedence_no_new_file (before=$_before_count3 after=$_after_count3)"
    ((PASS++))
else
    echo "  FAIL: SC3_jira_key_precedence_no_new_file — new ticket file(s) created (before=$_before_count3 after=$_after_count3)"
    ls "$_TDIR3"/*.md 2>/dev/null || true
    ((FAIL++))
fi

# Assertion B: title-dedup warning does NOT appear (jira_key check fired, not title check)
# "title match" and "summary match" are the expected warning phrases from the title-dedup code path.
if echo "$_output3" | grep -qiE "title match|summary match|matched.*title|matched.*summary|title.*dedup|summary.*dedup"; then
    echo "  FAIL: SC3_jira_key_precedence_no_title_warning — title-dedup warning appeared (jira_key check should have fired first)"
    echo "  output: $_output3"
    ((FAIL++))
else
    echo "  PASS: SC3_jira_key_precedence_no_title_warning (title-dedup warning correctly absent)"
    ((PASS++))
fi

rm -rf "$_TDIR3"
_CLEANUP_DIRS=()

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
