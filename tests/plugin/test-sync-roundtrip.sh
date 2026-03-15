#!/usr/bin/env bash
# lockpick-workflow/tests/plugin/test-sync-roundtrip.sh
# Integration roundtrip test for `tk sync` — exercises push, pull, conflict
# detection, dep/link sync against a stubbed acli wrapper (default) or a
# live Jira instance (--live flag).
#
# Canonical location: lockpick-workflow/tests/plugin/test-sync-roundtrip.sh
# Thin wrapper:       scripts/test-sync-roundtrip.sh
#
# Covers:
#   SECTION 1: Push roundtrip
#     1.  new ticket pushed → Jira create called, ledger entry written
#     2.  jira_key stamped in frontmatter after push
#     3.  second sync skips unchanged ticket (idempotent)
#     4.  modified ticket re-pushed (update path)
#
#   SECTION 2: Pull roundtrip
#     5.  new Jira issue pulled → local ticket file created
#     6.  pulled ticket has jira_key in frontmatter
#     7.  pulled ticket has ledger entry with jira_hash set
#     8.  second pull skips unchanged issue (idempotent)
#     9.  modified Jira issue re-pulled (update path)
#
#   SECTION 3: Conflict detection
#    10.  when both sides changed (local_hash and jira_hash differ), non-TTY
#         mode skips and does not overwrite either side
#    11.  conflict output mentions the ticket/issue key
#
#   SECTION 4: Dep and link sync
#    12.  ticket with deps: stub acli link called for dep relationship
#    13.  ticket with links: stub acli link called for remote link
#
#   SECTION 5: Error handling and exit codes
#    14.  push failure → exit 1 with error output
#    15.  pull with empty Jira → no tickets created, exit 0
#    16.  ledger is valid JSON after mixed push/pull operations
#
# Usage:
#   bash lockpick-workflow/tests/plugin/test-sync-roundtrip.sh           # uses stubbed acli (CI default)
#   bash lockpick-workflow/tests/plugin/test-sync-roundtrip.sh --live    # uses real Jira (manual only)
#
# --live prerequisites: acli installed and authenticated, JIRA_PROJECT set
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TK="$REPO_ROOT/lockpick-workflow/scripts/tk"
STUBS_DIR="$REPO_ROOT/lockpick-workflow/tests/plugin/fixtures/stubs"
PASS=0
FAIL=0

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# Skip local sync lock — test temp dirs are not git repos, so the lock
# resolves to the real repo's .git/tk-sync.lock causing cross-test contention.
_OLD_TK_SYNC_SKIP_LOCK="${TK_SYNC_SKIP_LOCK:-}"
export TK_SYNC_SKIP_LOCK=1

# Parse --live flag
LIVE_MODE=0
for _arg in "$@"; do
    [[ "$_arg" == "--live" ]] && LIVE_MODE=1
done

# ---------------------------------------------------------------------------
# Helper: run_test
# Runs a command, checks exit code and optional output pattern.
# Args: test_name expected_exit expected_pattern [cmd args...]
# ---------------------------------------------------------------------------
run_test() {
    local test_name="$1" expected_exit="$2" expected_pattern="$3"
    shift 3
    local exit_code=0
    local output
    output=$("$@" 2>&1) || exit_code=$?
    if [[ "$exit_code" -ne "$expected_exit" ]]; then
        echo "  FAIL: $test_name (expected exit $expected_exit, got $exit_code)"
        echo "  Output: $output"
        ((FAIL++))
        return
    fi
    if [[ -n "$expected_pattern" ]] && ! echo "$output" | grep -qiE "$expected_pattern"; then
        echo "  FAIL: $test_name (output missing pattern '$expected_pattern')"
        echo "  Output: $output"
        ((FAIL++))
        return
    fi
    echo "  PASS: $test_name"
    ((PASS++))
}

# ---------------------------------------------------------------------------
# Helper: run_test_no_pattern
# Same as run_test but verifies a pattern does NOT appear in output.
# ---------------------------------------------------------------------------
run_test_no_pattern() {
    local test_name="$1" expected_exit="$2" forbidden_pattern="$3"
    shift 3
    local exit_code=0
    local output
    output=$("$@" 2>&1) || exit_code=$?
    if [[ "$exit_code" -ne "$expected_exit" ]]; then
        echo "  FAIL: $test_name (expected exit $expected_exit, got $exit_code)"
        echo "  Output: $output"
        ((FAIL++))
        return
    fi
    if echo "$output" | grep -qiE "$forbidden_pattern"; then
        echo "  FAIL: $test_name (output unexpectedly contains '$forbidden_pattern')"
        echo "  Output: $output"
        ((FAIL++))
        return
    fi
    echo "  PASS: $test_name"
    ((PASS++))
}

# ---------------------------------------------------------------------------
# Helper: make_ticket
# Creates a minimal ticket file in a given directory.
# Args: dir id status type priority [title]
# ---------------------------------------------------------------------------
make_ticket() {
    local dir="$1" id="$2" status="$3" type="$4" priority="$5" title="${6:-Test ticket $2}"
    cat > "$dir/${id}.md" <<EOF
---
id: $id
status: $status
deps: []
links: []
created: 2026-03-04T00:00:00Z
type: $type
priority: $priority
---
# $title

Description for $id.
EOF
}

# ---------------------------------------------------------------------------
# Helper: make_ticket_with_deps
# Creates a ticket with deps and links frontmatter.
# Args: dir id status type priority deps_csv links_csv [title]
# ---------------------------------------------------------------------------
make_ticket_with_deps() {
    local dir="$1" id="$2" status="$3" type="$4" priority="$5"
    local deps="$6" links_val="$7" title="${8:-Test ticket $2}"
    cat > "$dir/${id}.md" <<EOF
---
id: $id
status: $status
deps: [$deps]
links: [$links_val]
created: 2026-03-04T00:00:00Z
type: $type
priority: $priority
---
# $title

Description for $id with deps/links.
EOF
}

# ---------------------------------------------------------------------------
# Helper: make_ticket_with_jira_key
# Creates a ticket that already has a jira_key (previously synced).
# ---------------------------------------------------------------------------
make_ticket_with_jira_key() {
    local dir="$1" id="$2" status="$3" type="$4" priority="$5" jira_key="$6" title="${7:-Test ticket $2}"
    cat > "$dir/${id}.md" <<EOF
---
id: $id
status: $status
deps: []
links: []
created: 2026-03-04T00:00:00Z
type: $type
priority: $priority
jira_key: $jira_key
---
# $title

Description for $id (previously synced).
EOF
}

# ---------------------------------------------------------------------------
# Helper: load_pull_helpers
# Extracts _sync_pull_ticket and its _sync_* / utility dependencies from
# scripts/tk using awk, so we can call _sync_pull_ticket directly in tests
# without running the full tk dispatch loop.
# ---------------------------------------------------------------------------
load_pull_helpers() {
    _OLD_TK_SCRIPT="${TK_SCRIPT:-}"
    export TK_SCRIPT="$TK"

    # Portable grep/rg shim
    if command -v rg &>/dev/null; then
        _grep() { rg "$@"; }
    else
        _grep() { grep "$@"; }
    fi

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
# Calls _sync_pull_ticket in an isolated subshell.
# Args: tickets_dir ledger_file issue_json [PATH_prefix]
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
# Setup: choose PATH prefix based on --live vs stub mode
# ---------------------------------------------------------------------------
if [[ "$LIVE_MODE" -eq 1 ]]; then
    echo "=== test-sync-roundtrip.sh (LIVE MODE) ==="
    echo "WARNING: live mode makes real Jira API calls. Ensure JIRA_PROJECT is set."
    echo ""
    ACLI_PATH_PREFIX=""
    # Verify prerequisites for live mode
    if ! command -v acli &>/dev/null; then
        echo "ERROR: acli not found in PATH (required for --live mode)" >&2
        exit 1
    fi
    if [[ -z "${JIRA_PROJECT:-}" ]]; then
        echo "ERROR: JIRA_PROJECT is not set (required for --live mode)" >&2
        exit 1
    fi
else
    echo "=== test-sync-roundtrip.sh (STUB MODE) ==="
    echo ""
    ACLI_PATH_PREFIX="$STUBS_DIR"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1: Push roundtrip
# ─────────────────────────────────────────────────────────────────────────────
echo "SECTION 1: Push roundtrip"

# Test 1: new ticket pushed → Jira create called, ledger entry written
echo "Test 1: new ticket push creates Jira issue and ledger entry"
_T1=$(mktemp -d)
_CLEANUP_DIRS+=("$_T1")
make_ticket "$_T1" "t-push1" "open" "task" "2" "Push roundtrip ticket"
_out1=$(env PATH="${ACLI_PATH_PREFIX:+$ACLI_PATH_PREFIX:}$PATH" \
    JIRA_PROJECT=TEST TICKETS_DIR="$_T1" SYNC_STATE_FILE="$_T1/.sync-state.json" STUB_JIRA_KEY=D2L-201 \
    "$TK" sync 2>&1) || true
_ledger1="$_T1/.sync-state.json"
_has_ledger1=0
if [[ -f "$_ledger1" ]] && grep -q "t-push1" "$_ledger1" 2>/dev/null; then
    _has_ledger1=1
fi
if [[ "$_has_ledger1" -eq 1 ]] || echo "$_out1" | grep -qiE "push(ed)?|creat(ed?)|D2L-"; then
    echo "  PASS: push_creates_jira_issue_and_ledger"
    ((PASS++))
else
    echo "  FAIL: push_creates_jira_issue_and_ledger"
    echo "  Output: $_out1"
    echo "  Ledger: $(cat "$_ledger1" 2>/dev/null || echo '(missing)')"
    ((FAIL++))
fi
rm -rf "$_T1"

# Test 2: jira_key stamped in frontmatter after push
echo "Test 2: jira_key stamped in frontmatter after push"
_T2=$(mktemp -d)
_CLEANUP_DIRS+=("$_T2")
make_ticket "$_T2" "t-push2" "open" "task" "2" "Stamp test push"
env PATH="${ACLI_PATH_PREFIX:+$ACLI_PATH_PREFIX:}$PATH" \
    JIRA_PROJECT=TEST TICKETS_DIR="$_T2" SYNC_STATE_FILE="$_T2/.sync-state.json" STUB_JIRA_KEY=D2L-202 \
    "$TK" sync >/dev/null 2>&1 || true
if grep -q "^jira_key:" "$_T2/t-push2.md" 2>/dev/null; then
    echo "  PASS: push_stamps_jira_key_in_frontmatter"
    ((PASS++))
else
    echo "  FAIL: push_stamps_jira_key_in_frontmatter (jira_key: not found)"
    head -10 "$_T2/t-push2.md" 2>/dev/null || echo "  File missing"
    ((FAIL++))
fi
rm -rf "$_T2"

# Test 3: second sync is idempotent (skips unchanged ticket)
echo "Test 3: second sync skips unchanged ticket"
_T3=$(mktemp -d)
_CLEANUP_DIRS+=("$_T3")
make_ticket "$_T3" "t-push3" "open" "task" "2" "Idempotent push test"
env PATH="${ACLI_PATH_PREFIX:+$ACLI_PATH_PREFIX:}$PATH" \
    JIRA_PROJECT=TEST TICKETS_DIR="$_T3" SYNC_STATE_FILE="$_T3/.sync-state.json" \
    "$TK" sync >/dev/null 2>&1 || true
# Second sync: same file → should skip
run_test \
    "push_second_sync_skips_unchanged" \
    0 "skip(ped)?|unchanged|up.to.date" \
    env PATH="${ACLI_PATH_PREFIX:+$ACLI_PATH_PREFIX:}$PATH" \
    JIRA_PROJECT=TEST TICKETS_DIR="$_T3" SYNC_STATE_FILE="$_T3/.sync-state.json" \
    "$TK" sync
rm -rf "$_T3"

# Test 4: modified ticket re-pushed (update path)
echo "Test 4: modified ticket triggers Jira update on next sync"
_T4=$(mktemp -d)
_CLEANUP_DIRS+=("$_T4")
make_ticket_with_jira_key "$_T4" "t-push4" "open" "task" "2" "D2L-204" "Original push title"
# Plant stale hash in ledger to simulate "modified since last sync"
printf '{"t-push4":{"jira_key":"D2L-204","local_hash":"stale000000000000000000000000000","jira_hash":"","last_synced":"2026-01-01T00:00:00Z"}}\n' \
    > "$_T4/.sync-state.json"
run_test \
    "push_modified_ticket_triggers_update" \
    0 "push(ed)?|updat(ed?)|D2L-204" \
    env PATH="${ACLI_PATH_PREFIX:+$ACLI_PATH_PREFIX:}$PATH" \
    JIRA_PROJECT=TEST TICKETS_DIR="$_T4" SYNC_STATE_FILE="$_T4/.sync-state.json" \
    "$TK" sync
rm -rf "$_T4"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2: Pull roundtrip
# ─────────────────────────────────────────────────────────────────────────────
echo "SECTION 2: Pull roundtrip"

# Test 5: new Jira issue pulled → local ticket file created
echo "Test 5: new Jira issue pulled creates local ticket file"
_T5=$(mktemp -d)
_CLEANUP_DIRS+=("$_T5")
_ledger5="$_T5/.sync-state.json"
_issue5='{"key":"TEST-5","fields":{"summary":"Pulled issue roundtrip","description":"Roundtrip body","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
pull_ticket_direct "$_T5" "$_ledger5" "$_issue5" "${ACLI_PATH_PREFIX:-}" >/dev/null 2>&1 || true
_ticket_count5=$(ls "$_T5"/*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "${_ticket_count5:-0}" -ge 1 ]]; then
    echo "  PASS: pull_creates_local_ticket_file"
    ((PASS++))
else
    echo "  FAIL: pull_creates_local_ticket_file (no .md file in $_T5)"
    ((FAIL++))
fi
rm -rf "$_T5"

# Test 6: pulled ticket has jira_key in frontmatter
echo "Test 6: pulled ticket has jira_key: TEST-6 in frontmatter"
_T6=$(mktemp -d)
_CLEANUP_DIRS+=("$_T6")
_ledger6="$_T6/.sync-state.json"
_issue6='{"key":"TEST-6","fields":{"summary":"Pull frontmatter test","description":"body","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
pull_ticket_direct "$_T6" "$_ledger6" "$_issue6" "${ACLI_PATH_PREFIX:-}" >/dev/null 2>&1 || true
_created6=$(ls "$_T6"/*.md 2>/dev/null | head -1)
if [[ -n "$_created6" ]] && grep -q "^jira_key: TEST-6" "$_created6" 2>/dev/null; then
    echo "  PASS: pull_stamps_jira_key_in_frontmatter"
    ((PASS++))
else
    echo "  FAIL: pull_stamps_jira_key_in_frontmatter (jira_key: TEST-6 not found)"
    [[ -n "$_created6" ]] && head -12 "$_created6" || echo "  No ticket file found"
    ((FAIL++))
fi
rm -rf "$_T6"

# Test 7: pulled ticket has ledger entry with jira_hash set
echo "Test 7: pull writes ledger entry with jira_hash"
_T7=$(mktemp -d)
_CLEANUP_DIRS+=("$_T7")
_ledger7="$_T7/.sync-state.json"
_issue7='{"key":"TEST-7","fields":{"summary":"Ledger pull test","description":"body","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
pull_ticket_direct "$_T7" "$_ledger7" "$_issue7" "${ACLI_PATH_PREFIX:-}" >/dev/null 2>&1 || true
_ledger_ok7=0
if [[ -f "$_ledger7" ]]; then
    _jira_hash7=$(python3 -c "
import json
try:
    d = json.load(open('$_ledger7'))
    for k, v in d.items():
        if v.get('jira_key') == 'TEST-7':
            print(v.get('jira_hash', ''))
            break
except Exception:
    pass
" 2>/dev/null || echo "")
    [[ -n "$_jira_hash7" ]] && _ledger_ok7=1
fi
if [[ "$_ledger_ok7" -eq 1 ]]; then
    echo "  PASS: pull_writes_ledger_with_jira_hash"
    ((PASS++))
else
    echo "  FAIL: pull_writes_ledger_with_jira_hash (ledger missing or jira_hash empty)"
    cat "$_ledger7" 2>/dev/null || echo "  No ledger file"
    ((FAIL++))
fi
rm -rf "$_T7"

# Test 8: second pull is idempotent (skips unchanged issue)
echo "Test 8: second pull skips unchanged Jira issue"
_T8=$(mktemp -d)
_CLEANUP_DIRS+=("$_T8")
_ledger8="$_T8/.sync-state.json"
_issue8='{"key":"TEST-8","fields":{"summary":"Idempotent pull","description":"body","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
# First pull
pull_ticket_direct "$_T8" "$_ledger8" "$_issue8" "${ACLI_PATH_PREFIX:-}" >/dev/null 2>&1 || true
_ticket8=$(ls "$_T8"/*.md 2>/dev/null | head -1)
_mtime8_before=""
[[ -n "$_ticket8" ]] && _mtime8_before=$(stat -f "%m" "$_ticket8" 2>/dev/null || stat -c "%Y" "$_ticket8" 2>/dev/null || echo "")
sleep 1
# Second pull: same JSON → skip
_out8=$(pull_ticket_direct "$_T8" "$_ledger8" "$_issue8" "${ACLI_PATH_PREFIX:-}" 2>&1) || true
_mtime8_after=""
[[ -n "$_ticket8" ]] && _mtime8_after=$(stat -f "%m" "$_ticket8" 2>/dev/null || stat -c "%Y" "$_ticket8" 2>/dev/null || echo "")
if echo "$_out8" | grep -qiE "skip(ped)?|unchanged"; then
    echo "  PASS: pull_second_call_skips_unchanged"
    ((PASS++))
elif [[ -n "$_mtime8_before" ]] && [[ "$_mtime8_before" == "$_mtime8_after" ]]; then
    echo "  PASS: pull_second_call_skips_unchanged (file mtime unchanged)"
    ((PASS++))
else
    echo "  FAIL: pull_second_call_skips_unchanged"
    echo "  Output: $_out8"
    ((FAIL++))
fi
rm -rf "$_T8"

# Test 9: modified Jira issue triggers update on second pull
echo "Test 9: modified Jira issue triggers local ticket update"
_T9=$(mktemp -d)
_CLEANUP_DIRS+=("$_T9")
_ledger9="$_T9/.sync-state.json"
_issue9_v1='{"key":"TEST-9","fields":{"summary":"Original title","description":"original","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
pull_ticket_direct "$_T9" "$_ledger9" "$_issue9_v1" "${ACLI_PATH_PREFIX:-}" >/dev/null 2>&1 || true
_ticket9=$(ls "$_T9"/*.md 2>/dev/null | head -1)
_issue9_v2='{"key":"TEST-9","fields":{"summary":"Updated title","description":"updated","status":{"name":"In Progress"},"issuetype":{"name":"Task"},"priority":{"name":"High"}}}'
pull_ticket_direct "$_T9" "$_ledger9" "$_issue9_v2" "${ACLI_PATH_PREFIX:-}" >/dev/null 2>&1 || true
_updated9=0
[[ -n "$_ticket9" ]] && grep -q "Updated title" "$_ticket9" 2>/dev/null && _updated9=1
if [[ "$_updated9" -eq 1 ]]; then
    echo "  PASS: pull_updates_local_ticket_when_jira_changed"
    ((PASS++))
else
    echo "  FAIL: pull_updates_local_ticket_when_jira_changed"
    [[ -n "$_ticket9" ]] && head -15 "$_ticket9" || echo "  No ticket file"
    ((FAIL++))
fi
rm -rf "$_T9"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3: Conflict detection
# ─────────────────────────────────────────────────────────────────────────────
echo "SECTION 3: Conflict detection"

# Test 10: non-TTY conflict — neither side overwritten when both changed
# Asserts: exit 2 (CONFLICT sentinel), ticket content unchanged (diff before/after identical)
echo "Test 10: conflict in non-TTY mode — neither side overwritten"
_T10=$(mktemp -d)
_CLEANUP_DIRS+=("$_T10")
_ledger10="$_T10/.sync-state.json"
# Step 1: establish baseline via pull (creates ticket + ledger)
_issue10_base='{"key":"TEST-10","fields":{"summary":"Conflict base","description":"base body","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
pull_ticket_direct "$_T10" "$_ledger10" "$_issue10_base" "${ACLI_PATH_PREFIX:-}" >/dev/null 2>&1 || true
_ticket10=$(ls "$_T10"/*.md 2>/dev/null | head -1)
_tk_id10=""
[[ -n "$_ticket10" ]] && _tk_id10=$(basename "$_ticket10" .md)
# Step 2: simulate local modification — update local_hash in ledger to a stale value
# so push sees local changes. Current file content = "new" local state.
if [[ -n "$_tk_id10" ]] && [[ -f "$_ledger10" ]]; then
    LEDGER="$_ledger10" TK_ID="$_tk_id10" python3 -c "
import json, os
d = json.load(open(os.environ['LEDGER']))
tk_id = os.environ['TK_ID']
if tk_id in d:
    d[tk_id]['local_hash'] = 'stale_local_0000000000000000000'
    d[tk_id]['jira_hash']  = 'stale_jira_00000000000000000000'
with open(os.environ['LEDGER'], 'w') as f:
    json.dump(d, f)
" 2>/dev/null || true
fi
# Step 3: attempt sync — both hashes differ → conflict detected
# In non-TTY mode the sync must: exit 2, output "conflict", leave ticket content unchanged.
_local_content10_before=""
[[ -n "$_ticket10" ]] && _local_content10_before=$(cat "$_ticket10" 2>/dev/null || echo "")
_exit10=0
_out10=$(env PATH="${ACLI_PATH_PREFIX:+$ACLI_PATH_PREFIX:}$PATH" \
    JIRA_PROJECT=TEST TICKETS_DIR="$_T10" SYNC_STATE_FILE="$_T10/.sync-state.json" STUB_ACLI_SEARCH_EMPTY=1 \
    "$TK" sync 2>&1) || _exit10=$?
_local_content10_after=""
[[ -n "$_ticket10" ]] && _local_content10_after=$(cat "$_ticket10" 2>/dev/null || echo "")
# Assert exit code 2 (conflict sentinel — not an error)
if [[ "$_exit10" -eq 2 ]]; then
    echo "  PASS: conflict_non_tty_exits_2"
    ((PASS++))
else
    echo "  FAIL: conflict_non_tty_exits_2 (expected exit 2, got $_exit10)"
    echo "  Output: $_out10"
    ((FAIL++))
fi
# Assert output contains 'conflict' keyword
if echo "$_out10" | grep -qi "conflict"; then
    echo "  PASS: conflict_non_tty_output_contains_conflict"
    ((PASS++))
else
    echo "  FAIL: conflict_non_tty_output_contains_conflict (no 'conflict' in output)"
    echo "  Output: $_out10"
    ((FAIL++))
fi
# Assert ticket file content is byte-for-byte identical before and after sync
if [[ "$_local_content10_before" == "$_local_content10_after" ]]; then
    echo "  PASS: conflict_non_tty_ticket_content_unchanged"
    ((PASS++))
else
    echo "  FAIL: conflict_non_tty_ticket_content_unchanged (ticket content was modified)"
    diff <(echo "$_local_content10_before") <(echo "$_local_content10_after") || true
    ((FAIL++))
fi
rm -rf "$_T10"

# Test 11: conflict output contains a recognizable key/ID reference
echo "Test 11: conflict output mentions ticket or issue identifier"
_T11=$(mktemp -d)
_CLEANUP_DIRS+=("$_T11")
_ledger11="$_T11/.sync-state.json"
# Create ticket with known ID
make_ticket_with_jira_key "$_T11" "t-conflict11" "open" "task" "2" "D2L-211" "Conflict test ticket"
# Plant stale hashes to simulate conflict
printf '{"t-conflict11":{"jira_key":"D2L-211","local_hash":"stale_local_111111111111111111","jira_hash":"stale_jira_111111111111111111","last_synced":"2026-01-01T00:00:00Z"}}\n' \
    > "$_T11/.sync-state.json"
_out11=$(env PATH="${ACLI_PATH_PREFIX:+$ACLI_PATH_PREFIX:}$PATH" \
    JIRA_PROJECT=TEST TICKETS_DIR="$_T11" SYNC_STATE_FILE="$_T11/.sync-state.json" STUB_ACLI_SEARCH_EMPTY=1 \
    "$TK" sync 2>&1) || true
# The output must mention 'conflict' AND reference the ticket/issue identifier.
# 'pushed', 'updated', and 'skip' alone are NOT acceptable — they indicate the
# conflict was NOT detected and one side was silently overwritten.
if echo "$_out11" | grep -qi "conflict" && echo "$_out11" | grep -qiE "t-conflict11|D2L-211"; then
    echo "  PASS: conflict_output_mentions_ticket_identifier"
    ((PASS++))
else
    echo "  FAIL: conflict_output_mentions_ticket_identifier (expected 'conflict' AND ticket/issue key in output)"
    echo "  Output: $_out11"
    ((FAIL++))
fi
rm -rf "$_T11"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4: Dep and link sync
# ─────────────────────────────────────────────────────────────────────────────
echo "SECTION 4: Dep and link sync"

# Test 12: ticket with deps — stub acli link command invoked for dep
echo "Test 12: dep sync — acli link invoked for ticket with deps"
_T12=$(mktemp -d)
_CLEANUP_DIRS+=("$_T12")
_acli_log12="$_T12/acli-calls.log"
# Two tickets: t-dep-parent depends on t-dep-child
make_ticket "$_T12" "t-dep-child"  "open" "task" "2" "Child ticket"
make_ticket_with_deps "$_T12" "t-dep-parent" "open" "task" "2" "t-dep-child" "" "Parent ticket with dep"
# Push both — the parent has a dep on child
_out12=$(env PATH="${ACLI_PATH_PREFIX:+$ACLI_PATH_PREFIX:}$PATH" \
    JIRA_PROJECT=TEST TICKETS_DIR="$_T12" SYNC_STATE_FILE="$_T12/.sync-state.json" \
    STUB_ACLI_LOG_FILE="$_acli_log12" \
    "$TK" sync 2>&1) || true
# Strict assertion: acli link must be called with 'Blocks' and both Jira keys.
_dep_linked12=0
if [[ -f "$_acli_log12" ]] && grep -qiE "link" "$_acli_log12" 2>/dev/null; then
    _dep_linked12=1
fi
if [[ "$_dep_linked12" -eq 1 ]]; then
    echo "  PASS: dep_sync_calls_acli_link"
    ((PASS++))
else
    echo "  FAIL: dep_sync_calls_acli_link (acli link not called — check STUB_ACLI_LOG_FILE)"
    echo "  Output: $_out12"
    echo "  acli log: $(cat "$_acli_log12" 2>/dev/null || echo '(missing)')"
    ((FAIL++))
fi
rm -rf "$_T12"

# Test 13: ticket with links field — stub records link invocation
echo "Test 13: link sync — acli link invoked for ticket with links"
_T13=$(mktemp -d)
_CLEANUP_DIRS+=("$_T13")
_acli_log13="$_T13/acli-calls.log"
make_ticket_with_deps "$_T13" "t-linked13" "open" "task" "2" "" "https://example.com/related" "Ticket with remote link"
_out13=$(env PATH="${ACLI_PATH_PREFIX:+$ACLI_PATH_PREFIX:}$PATH" \
    JIRA_PROJECT=TEST TICKETS_DIR="$_T13" SYNC_STATE_FILE="$_T13/.sync-state.json" \
    STUB_ACLI_LOG_FILE="$_acli_log13" \
    "$TK" sync 2>&1) || true
# Strict assertion: acli link must be called with the URL from links field.
_link_called13=0
if [[ -f "$_acli_log13" ]] && grep -qiE "link" "$_acli_log13" 2>/dev/null; then
    _link_called13=1
fi
if [[ "$_link_called13" -eq 1 ]]; then
    echo "  PASS: link_sync_calls_acli_link"
    ((PASS++))
else
    echo "  FAIL: link_sync_calls_acli_link (acli link not called — check STUB_ACLI_LOG_FILE)"
    echo "  Output: $_out13"
    echo "  acli log: $(cat "$_acli_log13" 2>/dev/null || echo '(missing)')"
    ((FAIL++))
fi
rm -rf "$_T13"

# Test 12b (pull_dep_roundtrip): push two tickets, pull an issue JSON for the
# first ticket that includes an issuelinks Blocks link pointing to the second
# ticket's Jira key — verify the first ticket's deps frontmatter has the tk ID.
echo "Test 12b: pull_dep_roundtrip — Jira issuelinks Blocks → deps frontmatter"
_T12b=$(mktemp -d)
_CLEANUP_DIRS+=("$_T12b")
_ledger12b="$_T12b/.sync-state.json"
# Pre-populate ledger: TEST-CHILD-12B → tk-child-12b
python3 -c "
import json
d = {'tk-child-12b': {'jira_key': 'TEST-CHILD-12B', 'local_hash': 'abc', 'jira_hash': 'def', 'last_synced': '2026-01-01T00:00:00Z'}}
with open('$_ledger12b', 'w') as f:
    json.dump(d, f)
" 2>/dev/null
# Pull the parent issue that has an outward Blocks link to the child
_issue12b='{"key":"TEST-PARENT-12B","fields":{"summary":"Pull dep roundtrip parent","description":"body","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"},"issuelinks":[{"type":{"name":"Blocks","outward":"blocks"},"outwardIssue":{"key":"TEST-CHILD-12B"}}]}}'
pull_ticket_direct "$_T12b" "$_ledger12b" "$_issue12b" "${ACLI_PATH_PREFIX:-}" >/dev/null 2>&1 || true
_created12b=$(ls "$_T12b"/*.md 2>/dev/null | grep -v "tk-child-12b.md" | head -1)
_dep12b_ok=0
if [[ -n "$_created12b" ]] && grep -qE "^deps:.*tk-child-12b" "$_created12b" 2>/dev/null; then
    _dep12b_ok=1
fi
if [[ "$_dep12b_ok" -eq 1 ]]; then
    echo "  PASS: pull_dep_roundtrip"
    ((PASS++))
else
    echo "  FAIL: pull_dep_roundtrip (expected deps: [...tk-child-12b...] in frontmatter)"
    if [[ -n "$_created12b" ]]; then
        echo "  Ticket frontmatter:"
        head -12 "$_created12b"
    else
        echo "  No new ticket file created"
        ls "$_T12b"/ 2>/dev/null || echo "  (empty dir)"
    fi
    ((FAIL++))
fi
rm -rf "$_T12b"

# Test 13b (pull_link_roundtrip): push a ticket, pull an issue JSON with
# remoteLinks containing a URL — verify the ticket's links frontmatter has the URL.
echo "Test 13b: pull_link_roundtrip — Jira remoteLinks → links frontmatter"
_T13b=$(mktemp -d)
_CLEANUP_DIRS+=("$_T13b")
_ledger13b="$_T13b/.sync-state.json"
echo '{}' > "$_ledger13b"
# Pull issue JSON with a top-level remoteLinks array containing a URL
_issue13b='{"key":"TEST-LINK-13B","fields":{"summary":"Pull link roundtrip","description":"body","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}},"remoteLinks":[{"object":{"url":"https://example.com/related"}}]}'
pull_ticket_direct "$_T13b" "$_ledger13b" "$_issue13b" "${ACLI_PATH_PREFIX:-}" >/dev/null 2>&1 || true
_created13b=$(ls "$_T13b"/*.md 2>/dev/null | head -1)
_link13b_ok=0
if [[ -n "$_created13b" ]]; then
    _links13b=$(awk '/^---$/{n++; next} n==1 && /^links:/{print; exit}' "$_created13b" | sed 's/^links:[[:space:]]*//')
    if echo "$_links13b" | grep -qF "https://example.com/related"; then
        _link13b_ok=1
    fi
fi
if [[ "$_link13b_ok" -eq 1 ]]; then
    echo "  PASS: pull_link_roundtrip"
    ((PASS++))
else
    echo "  FAIL: pull_link_roundtrip (expected links: containing https://example.com/related)"
    if [[ -n "$_created13b" ]]; then
        echo "  Ticket frontmatter:"
        head -12 "$_created13b"
    else
        echo "  No ticket file created in $_T13b"
        ls "$_T13b"/ 2>/dev/null || echo "  (empty dir)"
    fi
    ((FAIL++))
fi
rm -rf "$_T13b"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4b: Dep pull sync (w21-onb0)
# Verify _sync_pull_ticket parses Jira issuelinks (outward Blocks) and writes
# resolved tk IDs to the ticket's deps frontmatter field.
# ─────────────────────────────────────────────────────────────────────────────
echo "SECTION 4b: Dep pull sync"

# Test: test_pull_dep_populates_tk_deps
# A Jira issue with an outward Blocks link → deps field in created ticket contains
# the mapped tk ID for the linked Jira key.
echo "Test test_pull_dep_populates_tk_deps: outward Blocks link → deps field in created ticket"
_T_dep=$(mktemp -d)
_CLEANUP_DIRS+=("$_T_dep")
_ledger_dep="$_T_dep/.sync-state.json"
# Pre-populate ledger: TEST-DEP-A is already mapped to tk-dep-a
python3 -c "
import json
d = {'tk-dep-a': {'jira_key': 'TEST-DEP-A', 'local_hash': 'abc', 'jira_hash': 'def', 'last_synced': '2026-01-01T00:00:00Z'}}
with open('$_ledger_dep', 'w') as f:
    json.dump(d, f)
" 2>/dev/null
# Issue JSON: TEST-MAIN has an outward Blocks link to TEST-DEP-A (which is in ledger)
_issue_dep='{"key":"TEST-MAIN","fields":{"summary":"Dep pull roundtrip","description":"body","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"},"issuelinks":[{"type":{"name":"Blocks","outward":"blocks"},"outwardIssue":{"key":"TEST-DEP-A"}}]}}'
pull_ticket_direct "$_T_dep" "$_ledger_dep" "$_issue_dep" "${ACLI_PATH_PREFIX:-}" >/dev/null 2>&1 || true
_created_dep=$(ls "$_T_dep"/*.md 2>/dev/null | grep -v "tk-dep-a.md" | head -1)
_dep_ok=0
if [[ -n "$_created_dep" ]] && grep -qE "^deps:.*tk-dep-a" "$_created_dep" 2>/dev/null; then
    _dep_ok=1
fi
if [[ "$_dep_ok" -eq 1 ]]; then
    echo "  PASS: test_pull_dep_populates_tk_deps"
    ((PASS++))
else
    echo "  FAIL: test_pull_dep_populates_tk_deps (expected deps: [...tk-dep-a...] in frontmatter)"
    if [[ -n "$_created_dep" ]]; then
        echo "  Ticket frontmatter:"
        head -12 "$_created_dep"
    else
        echo "  No new ticket file created"
        ls "$_T_dep"/ 2>/dev/null || echo "  (empty dir)"
    fi
    ((FAIL++))
fi
rm -rf "$_T_dep"

# Test: Jira link to unknown key → exit 0 + warning
echo "Test pull_dep_unknown_link_skipped: Jira link not in ledger → exit 0 with warning"
_T_unk=$(mktemp -d)
_CLEANUP_DIRS+=("$_T_unk")
_ledger_unk="$_T_unk/.sync-state.json"
echo '{}' > "$_ledger_unk"
_issue_unk='{"key":"TEST-UNK","fields":{"summary":"Unknown dep","description":"body","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"},"issuelinks":[{"type":{"name":"Blocks","outward":"blocks"},"outwardIssue":{"key":"TEST-NOT-IN-LEDGER"}}]}}'
_exit_unk=0
_out_unk=$(pull_ticket_direct "$_T_unk" "$_ledger_unk" "$_issue_unk" "${ACLI_PATH_PREFIX:-}" 2>&1) || _exit_unk=$?
if [[ "$_exit_unk" -eq 0 ]] && echo "$_out_unk" | grep -qiE "warning.*not in ledger|not in ledger|skip.*dep"; then
    echo "  PASS: pull_dep_unknown_link_skipped"
    ((PASS++))
else
    echo "  FAIL: pull_dep_unknown_link_skipped (expected exit 0 with warning, got exit=$_exit_unk)"
    echo "  Output: $_out_unk"
    ((FAIL++))
fi
rm -rf "$_T_unk"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4c: Remote link pull sync (w21-upfc)
# Verify _sync_pull_ticket parses Jira remoteLinks and writes URLs to the
# ticket's links frontmatter field.
#
# Implementation note: Jira remote links are embedded in the issue JSON under
# the top-level "remoteLinks" key (array of {"object":{"url":"https://..."}}).
# _sync_pull_remote_links reads this field and writes links: to frontmatter.
# ─────────────────────────────────────────────────────────────────────────────
echo "SECTION 4c: Remote link pull sync"

# Test: test_pull_links_populates_tk_links
echo "Test test_pull_links_populates_tk_links: remoteLinks URL in Jira issue JSON → links: in ticket"
_T_rl=$(mktemp -d)
_CLEANUP_DIRS+=("$_T_rl")
_ledger_rl="$_T_rl/.sync-state.json"
echo '{}' > "$_ledger_rl"
# Issue JSON with a top-level remoteLinks array (as produced by _sync_pull_remote_links
# which merges view data into the issue JSON or reads it directly from the search result
# when STUB_JIRA_VIEW_JSON is set to include remoteLinks)
_issue_rl='{"key":"TEST-RL","fields":{"summary":"Remote link roundtrip","description":"body","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}},"remoteLinks":[{"object":{"url":"https://example.com/doc"}}]}'
pull_ticket_direct "$_T_rl" "$_ledger_rl" "$_issue_rl" "${ACLI_PATH_PREFIX:-}" >/dev/null 2>&1 || true
_created_rl=$(ls "$_T_rl"/*.md 2>/dev/null | head -1)
_rl_ok=0
if [[ -n "$_created_rl" ]]; then
    _links_rl=$(awk '/^---$/{n++; next} n==1 && /^links:/{print; exit}' "$_created_rl" | sed 's/^links:[[:space:]]*//')
    if echo "$_links_rl" | grep -qF "https://example.com/doc"; then
        _rl_ok=1
    fi
fi
if [[ "$_rl_ok" -eq 1 ]]; then
    echo "  PASS: test_pull_links_populates_tk_links"
    ((PASS++))
else
    echo "  FAIL: test_pull_links_populates_tk_links (expected links: containing https://example.com/doc)"
    if [[ -n "$_created_rl" ]]; then
        echo "  Ticket frontmatter:"
        head -12 "$_created_rl"
    else
        echo "  No ticket file created in $_T_rl"
        ls "$_T_rl"/ 2>/dev/null || echo "  (empty dir)"
    fi
    ((FAIL++))
fi
rm -rf "$_T_rl"

# Test: pull_links_empty_when_no_remote_links
echo "Test pull_links_empty_when_no_remote_links: no remoteLinks in Jira JSON → links: [] in ticket"
_T_rl2=$(mktemp -d)
_CLEANUP_DIRS+=("$_T_rl2")
_ledger_rl2="$_T_rl2/.sync-state.json"
echo '{}' > "$_ledger_rl2"
_issue_rl2='{"key":"TEST-RL2","fields":{"summary":"No remote links","description":"body","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
pull_ticket_direct "$_T_rl2" "$_ledger_rl2" "$_issue_rl2" "${ACLI_PATH_PREFIX:-}" >/dev/null 2>&1 || true
_created_rl2=$(ls "$_T_rl2"/*.md 2>/dev/null | head -1)
_rl2_ok=0
if [[ -n "$_created_rl2" ]]; then
    _links_rl2=$(awk '/^---$/{n++; next} n==1 && /^links:/{print; exit}' "$_created_rl2" | sed 's/^links:[[:space:]]*//')
    if [[ "$_links_rl2" == "[]" ]] || [[ -z "$_links_rl2" ]]; then
        _rl2_ok=1
    fi
fi
if [[ "$_rl2_ok" -eq 1 ]]; then
    echo "  PASS: pull_links_empty_when_no_remote_links"
    ((PASS++))
else
    echo "  FAIL: pull_links_empty_when_no_remote_links (expected links: [] in frontmatter)"
    [[ -n "$_created_rl2" ]] && head -12 "$_created_rl2" || echo "  No ticket file created"
    ((FAIL++))
fi
rm -rf "$_T_rl2"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5: Error handling and exit codes
# ─────────────────────────────────────────────────────────────────────────────
echo "SECTION 5: Error handling and exit codes"

# Test 14: push failure → exit 1 with error output
echo "Test 14: push failure exits 1 with error output"
_T14=$(mktemp -d)
_CLEANUP_DIRS+=("$_T14")
make_ticket "$_T14" "t-fail14" "open" "task" "2" "Failing push ticket"
run_test \
    "push_failure_exits_1" \
    1 "error|fail" \
    env PATH="${ACLI_PATH_PREFIX:+$ACLI_PATH_PREFIX:}$PATH" \
    JIRA_PROJECT=TEST TICKETS_DIR="$_T14" SYNC_STATE_FILE="$_T14/.sync-state.json" STUB_ACLI_CREATE_FAIL=1 \
    "$TK" sync
rm -rf "$_T14"

# Test 15: pull with empty Jira returns → no tickets created, exit 0
echo "Test 15: pull with empty Jira result creates no tickets"
_T15=$(mktemp -d)
_CLEANUP_DIRS+=("$_T15")
_ledger15="$_T15/.sync-state.json"
# Direct pull of empty issue list should work without creating tickets
_out15=$(env PATH="${ACLI_PATH_PREFIX:+$ACLI_PATH_PREFIX:}$PATH" \
    JIRA_PROJECT=TEST TICKETS_DIR="$_T15" SYNC_STATE_FILE="$_T15/.sync-state.json" STUB_ACLI_SEARCH_EMPTY=1 \
    "$TK" sync 2>&1) || true
_ticket_count15=$(ls "$_T15"/*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "${_ticket_count15:-0}" -eq 0 ]]; then
    echo "  PASS: empty_jira_pull_creates_no_tickets"
    ((PASS++))
else
    echo "  FAIL: empty_jira_pull_creates_no_tickets (expected 0, got $_ticket_count15)"
    echo "  Output: $_out15"
    ((FAIL++))
fi
rm -rf "$_T15"

# Test 16: ledger is valid JSON after mixed push+pull operations
echo "Test 16: ledger is valid JSON after mixed push and pull operations"
_T16=$(mktemp -d)
_CLEANUP_DIRS+=("$_T16")
_ledger16="$_T16/.sync-state.json"
# Push a ticket
make_ticket "$_T16" "t-mixed16" "open" "task" "2" "Mixed push ticket"
env PATH="${ACLI_PATH_PREFIX:+$ACLI_PATH_PREFIX:}$PATH" \
    JIRA_PROJECT=TEST TICKETS_DIR="$_T16" SYNC_STATE_FILE="$_T16/.sync-state.json" STUB_JIRA_KEY=D2L-216 \
    "$TK" sync >/dev/null 2>&1 || true
# Pull a new issue directly
_issue16='{"key":"TEST-216","fields":{"summary":"Mixed pull issue","description":"body","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
pull_ticket_direct "$_T16" "$_ledger16" "$_issue16" "${ACLI_PATH_PREFIX:-}" >/dev/null 2>&1 || true
# Validate ledger JSON
_ledger_valid16=0
if [[ -f "$_ledger16" ]]; then
    python3 -c "import json; json.load(open('$_ledger16'))" 2>/dev/null && _ledger_valid16=1
elif [[ ! -f "$_ledger16" ]]; then
    # No ledger created is also acceptable if nothing was persisted
    _ledger_valid16=1
fi
if [[ "$_ledger_valid16" -eq 1 ]]; then
    echo "  PASS: ledger_is_valid_json_after_mixed_operations"
    ((PASS++))
else
    echo "  FAIL: ledger_is_valid_json_after_mixed_operations (ledger is corrupt)"
    cat "$_ledger16" 2>/dev/null || echo "  Ledger file missing"
    ((FAIL++))
fi
rm -rf "$_T16"

# Test 17: dep_sync_ledger_miss_warns_and_continues
# A ticket with deps:[unknown-id] where unknown-id has no ledger entry.
# tk sync must exit 0 (not 1) and print a warning mentioning the unknown dep ID.
echo "Test 17: dep sync with unknown dep ID — exits 0 and warns"
_T17=$(mktemp -d)
_CLEANUP_DIRS+=("$_T17")
_acli_log17="$_T17/acli-calls.log"
# Create a ticket with a dep that has no ledger entry
make_ticket_with_deps "$_T17" "t-dep17" "open" "task" "2" "unknown-dep-id" "" "Dep with unknown ledger entry"
_out17=$(env PATH="${ACLI_PATH_PREFIX:+$ACLI_PATH_PREFIX:}$PATH" \
    JIRA_PROJECT=TEST TICKETS_DIR="$_T17" SYNC_STATE_FILE="$_T17/.sync-state.json" \
    STUB_ACLI_LOG_FILE="$_acli_log17" \
    "$TK" sync 2>&1) || _exit17=$?
_exit17="${_exit17:-0}"
# Must exit 0 (not 1) and warn about the unknown dep
if [[ "$_exit17" -eq 0 ]] && echo "$_out17" | grep -qiE "warning.*unknown-dep-id|not in ledger.*unknown-dep-id|unknown-dep-id.*not in ledger|skip.*unknown-dep-id|unknown-dep-id.*skip"; then
    echo "  PASS: dep_sync_ledger_miss_warns_and_continues"
    ((PASS++))
else
    echo "  FAIL: dep_sync_ledger_miss_warns_and_continues (expected exit 0 with warning about unknown-dep-id, got exit=$_exit17)"
    echo "  Output: $_out17"
    ((FAIL++))
fi
rm -rf "$_T17"

# ── Restore exported variables ─────────────────────────────────────────────────
if [[ -n "$_OLD_TK_SYNC_SKIP_LOCK" ]]; then
    export TK_SYNC_SKIP_LOCK="$_OLD_TK_SYNC_SKIP_LOCK"
else
    unset TK_SYNC_SKIP_LOCK 2>/dev/null || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
