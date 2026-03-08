#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-tk-sync-drift-check.sh
# Tests for _sync_drift_check() helper function.
#
# Verifies:
#   1. No drift reported when local and Jira hashes match (exit 0)
#   2. DRIFT lines printed when hashes differ (exit 1)
#   3. Tickets without jira_key are skipped with warning
#   4. Summary line with total tickets checked is output
#   5. acli failure is handled gracefully (warn + skip, no false "no drift")
#
# These tests source _sync_* helpers from scripts/tk using awk extraction
# and use a mock acli stub for Jira API calls.
#
# Usage: bash lockpick-workflow/tests/hooks/test-tk-sync-drift-check.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TK="$REPO_ROOT/lockpick-workflow/scripts/tk"
STUBS_DIR="$REPO_ROOT/scripts/tests/stubs"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# Helper: check_eq
# Like check_eq but prints PASS/FAIL with test name for AC grep patterns.
# ---------------------------------------------------------------------------
check_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  $label PASS"
        (( ++PASS ))
    else
        echo "  $label FAIL (expected=$expected actual=$actual)"
        (( ++FAIL ))
    fi
}

echo "=== test-tk-sync-drift-check.sh ==="
echo ""

# ---------------------------------------------------------------------------
# Helper: load_tk_sync_helpers
# Extracts _sync_* functions from scripts/tk using awk — avoids executing
# the main dispatch.
# ---------------------------------------------------------------------------
load_tk_sync_helpers() {
    export TK_SCRIPT="$TK"

    # Portable grep/rg shim
    if command -v rg &>/dev/null; then
        _grep() { rg "$@"; }
    else
        _grep() { grep "$@"; }
    fi

    # Extract all _sync_* function bodies
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

    if [[ -z "$sync_src" ]]; then
        echo "load_tk_sync_helpers: no _sync_* functions found in $TK" >&2
        return 1
    fi

    eval "$sync_src"
}

# ---------------------------------------------------------------------------
# Helper: make_ticket_file
# Creates a minimal .tickets/*.md file with frontmatter.
# Args: dir id status type priority jira_key
# ---------------------------------------------------------------------------
make_ticket_file() {
    local dir="$1" id="$2" status="$3" type="$4" priority="$5" jira_key="$6"
    cat > "$dir/$id.md" <<EOF
---
id: $id
status: $status
type: $type
priority: $priority
deps: []
links: []
$(if [[ -n "$jira_key" ]]; then echo "jira_key: $jira_key"; fi)
---
# Test ticket $id

Description for $id.
EOF
}

# ---------------------------------------------------------------------------
# Helper: make_acli_view_json
# Creates a Jira issue JSON matching the fields of a local ticket.
# Args: jira_key summary status_name type_name priority_name description
# ---------------------------------------------------------------------------
make_acli_view_json() {
    local key="$1" summary="$2" status="$3" type="$4" priority="$5" desc="$6"
    cat <<EOJSON
{"key":"$key","fields":{"summary":"$summary","description":"$desc","status":{"name":"$status"},"issuetype":{"name":"$type"},"priority":{"name":"$priority"}}}
EOJSON
}

# ---------------------------------------------------------------------------
# Helper: load_cmd_sync_helpers
# Extracts cmd_sync + all _sync_* + _resolve_main_repo_root + find_tickets_dir
# from scripts/tk using awk — avoids executing the main dispatch.
# ---------------------------------------------------------------------------
load_cmd_sync_helpers() {
    local sync_src
    sync_src=$(awk '
        /^(cmd_sync|_sync_[a-zA-Z_]+|_resolve_main_repo_root|find_tickets_dir)[[:space:]]*\(\)/ {
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

    if [[ -z "$sync_src" ]]; then
        echo "load_cmd_sync_helpers: no functions found in $TK" >&2
        return 1
    fi

    eval "$sync_src"
}

# ---------------------------------------------------------------------------
# Helper: run_cmd_sync_check
# Runs cmd_sync --check in a subshell with overridden env and helpers.
# Args: tickets_dir sync_state_file acli_dir [extra_env...]
# Returns: output on stdout, exit code via $?
# ---------------------------------------------------------------------------
run_cmd_sync_check() {
    local tickets_dir="$1" sync_state_file="$2" acli_dir="$3"
    (
        export JIRA_PROJECT="TEST"
        export TICKETS_DIR="$tickets_dir"
        export SYNC_STATE_FILE="$sync_state_file"
        export PATH="$acli_dir:$PATH"
        _resolve_main_repo_root() { dirname "$SYNC_STATE_FILE"; }
        cmd_sync --check
    )
}

# Load helpers
load_tk_sync_helpers
load_cmd_sync_helpers

# ===========================================================================
# Test 1: No drift when local and Jira hashes match
# ===========================================================================
echo "Test 1: No drift when hashes match"
_T1_DIR=$(mktemp -d)
_T1_LEDGER="$_T1_DIR/.sync-state.json"
_T1_TICKETS="$_T1_DIR/tickets"
mkdir -p "$_T1_TICKETS"

# Create a ticket with jira_key
make_ticket_file "$_T1_TICKETS" "t1-abc1" "open" "task" "2" "TEST-1"

# Create acli stub that returns matching Jira fields
# Local: title="Test ticket t1-abc1", status=open->To Do, type=task->Task, priority=2->Medium
_T1_ACLI_DIR=$(mktemp -d)
cat > "$_T1_ACLI_DIR/acli" <<'STUBEOF'
#!/usr/bin/env bash
# Return Jira issue with fields matching local ticket
echo '{"key":"TEST-1","fields":{"summary":"Test ticket t1-abc1","description":"Description for t1-abc1.","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
STUBEOF
chmod +x "$_T1_ACLI_DIR/acli"

_T1_EXIT=0
_T1_OUTPUT=$(PATH="$_T1_ACLI_DIR:$PATH" _sync_drift_check "$_T1_TICKETS" "$_T1_LEDGER" 2>&1) || _T1_EXIT=$?

_T1_HAS_DRIFT=0
if echo "$_T1_OUTPUT" | grep -q "^DRIFT:"; then
    _T1_HAS_DRIFT=1
fi
check_eq "test_drift_check_no_drift_when_hashes_match" "0" "$_T1_EXIT"
check_eq "test_drift_check_no_drift_lines" "0" "$_T1_HAS_DRIFT"
rm -rf "$_T1_DIR" "$_T1_ACLI_DIR"

# ===========================================================================
# Test 2: Drift detected when hashes differ
# ===========================================================================
echo ""
echo "Test 2: Drift detected when hashes differ"
_T2_DIR=$(mktemp -d)
_T2_LEDGER="$_T2_DIR/.sync-state.json"
_T2_TICKETS="$_T2_DIR/tickets"
mkdir -p "$_T2_TICKETS"

make_ticket_file "$_T2_TICKETS" "t2-abc1" "open" "task" "2" "TEST-2"

# Create acli stub that returns DIFFERENT Jira fields (summary changed)
_T2_ACLI_DIR=$(mktemp -d)
cat > "$_T2_ACLI_DIR/acli" <<'STUBEOF'
#!/usr/bin/env bash
echo '{"key":"TEST-2","fields":{"summary":"CHANGED title on Jira","description":"Description for t2-abc1.","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
STUBEOF
chmod +x "$_T2_ACLI_DIR/acli"

_T2_EXIT=0
_T2_OUTPUT=$(PATH="$_T2_ACLI_DIR:$PATH" _sync_drift_check "$_T2_TICKETS" "$_T2_LEDGER" 2>&1) || _T2_EXIT=$?

_T2_HAS_DRIFT=0
if echo "$_T2_OUTPUT" | grep -q "^DRIFT:"; then
    _T2_HAS_DRIFT=1
fi
check_eq "test_drift_check_detects_local_drift" "1" "$_T2_EXIT"
check_eq "test_drift_check_has_drift_line" "1" "$_T2_HAS_DRIFT"
rm -rf "$_T2_DIR" "$_T2_ACLI_DIR"

# ===========================================================================
# Test 3: Tickets without jira_key are skipped with warning
# ===========================================================================
echo ""
echo "Test 3: Tickets without jira_key are skipped"
_T3_DIR=$(mktemp -d)
_T3_LEDGER="$_T3_DIR/.sync-state.json"
_T3_TICKETS="$_T3_DIR/tickets"
mkdir -p "$_T3_TICKETS"

# Create ticket WITHOUT jira_key
make_ticket_file "$_T3_TICKETS" "t3-abc1" "open" "task" "2" ""

# No acli calls needed — should skip this ticket
_T3_ACLI_DIR=$(mktemp -d)
cat > "$_T3_ACLI_DIR/acli" <<'STUBEOF'
#!/usr/bin/env bash
echo "ERROR: acli should not be called for tickets without jira_key" >&2
exit 1
STUBEOF
chmod +x "$_T3_ACLI_DIR/acli"

_T3_EXIT=0
_T3_OUTPUT=$(PATH="$_T3_ACLI_DIR:$PATH" _sync_drift_check "$_T3_TICKETS" "$_T3_LEDGER" 2>&1) || _T3_EXIT=$?

_T3_HAS_WARNING=0
if echo "$_T3_OUTPUT" | grep -qi "skip\|no jira_key"; then
    _T3_HAS_WARNING=1
fi
check_eq "test_drift_check_skips_no_jira_key" "0" "$_T3_EXIT"
check_eq "test_drift_check_warns_no_jira_key" "1" "$_T3_HAS_WARNING"
rm -rf "$_T3_DIR" "$_T3_ACLI_DIR"

# ===========================================================================
# Test 4: Summary line with total tickets checked
# ===========================================================================
echo ""
echo "Test 4: Summary line with total tickets checked"
_T4_DIR=$(mktemp -d)
_T4_LEDGER="$_T4_DIR/.sync-state.json"
_T4_TICKETS="$_T4_DIR/tickets"
mkdir -p "$_T4_TICKETS"

make_ticket_file "$_T4_TICKETS" "t4-abc1" "open" "task" "2" "TEST-4"
make_ticket_file "$_T4_TICKETS" "t4-abc2" "closed" "bug" "1" "TEST-5"

_T4_ACLI_DIR=$(mktemp -d)
cat > "$_T4_ACLI_DIR/acli" <<'STUBEOF'
#!/usr/bin/env bash
# Parse the key from args
_key=""
for _arg in "$@"; do
    if [[ "$_arg" =~ ^TEST- ]]; then
        _key="$_arg"
    fi
done
case "$_key" in
    TEST-4)
        echo '{"key":"TEST-4","fields":{"summary":"Test ticket t4-abc1","description":"Description for t4-abc1.","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
        ;;
    TEST-5)
        echo '{"key":"TEST-5","fields":{"summary":"Test ticket t4-abc2","description":"Description for t4-abc2.","status":{"name":"Done"},"issuetype":{"name":"Bug"},"priority":{"name":"High"}}}'
        ;;
    *)
        echo '{"key":"UNKNOWN","fields":{"summary":"Unknown","description":"","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
        ;;
esac
STUBEOF
chmod +x "$_T4_ACLI_DIR/acli"

_T4_EXIT=0
_T4_OUTPUT=$(PATH="$_T4_ACLI_DIR:$PATH" _sync_drift_check "$_T4_TICKETS" "$_T4_LEDGER" 2>&1) || _T4_EXIT=$?

_T4_HAS_SUMMARY=0
if echo "$_T4_OUTPUT" | grep -qE "Checked [0-9]+ tickets"; then
    _T4_HAS_SUMMARY=1
fi
check_eq "test_drift_check_outputs_summary_count" "1" "$_T4_HAS_SUMMARY"
rm -rf "$_T4_DIR" "$_T4_ACLI_DIR"

# ===========================================================================
# Test 5: acli failure is handled gracefully
# ===========================================================================
echo ""
echo "Test 5: acli failure handled gracefully"
_T5_DIR=$(mktemp -d)
_T5_LEDGER="$_T5_DIR/.sync-state.json"
_T5_TICKETS="$_T5_DIR/tickets"
mkdir -p "$_T5_TICKETS"

make_ticket_file "$_T5_TICKETS" "t5-abc1" "open" "task" "2" "TEST-6"

# Create acli stub that always fails
_T5_ACLI_DIR=$(mktemp -d)
cat > "$_T5_ACLI_DIR/acli" <<'STUBEOF'
#!/usr/bin/env bash
echo "Error: connection timeout" >&2
exit 1
STUBEOF
chmod +x "$_T5_ACLI_DIR/acli"

_T5_EXIT=0
_T5_OUTPUT=$(PATH="$_T5_ACLI_DIR:$PATH" _sync_drift_check "$_T5_TICKETS" "$_T5_LEDGER" 2>&1) || _T5_EXIT=$?

_T5_HAS_WARNING=0
if echo "$_T5_OUTPUT" | grep -qi "warn\|skip\|failed"; then
    _T5_HAS_WARNING=1
fi
# acli failure should warn and skip, NOT report false "no drift"
# The function should still complete (exit 0) since it skipped — no drift confirmed
# But it should warn about the failure
check_eq "test_drift_check_handles_acli_failure" "0" "$_T5_EXIT"
check_eq "test_drift_check_warns_on_acli_failure" "1" "$_T5_HAS_WARNING"
rm -rf "$_T5_DIR" "$_T5_ACLI_DIR"

# ===========================================================================
# Test 6: tk sync --check exits 0 when no drift detected
# ===========================================================================
echo ""
echo "Test 6: tk sync --check exits 0 when no drift detected"
_T6_DIR=$(mktemp -d)
_T6_TICKETS="$_T6_DIR/tickets"
mkdir -p "$_T6_TICKETS"

make_ticket_file "$_T6_TICKETS" "t6-abc1" "open" "task" "2" "TEST-61"

# Create acli stub: connectivity check succeeds + view returns matching fields
_T6_ACLI_DIR=$(mktemp -d)
cat > "$_T6_ACLI_DIR/acli" <<'STUBEOF'
#!/usr/bin/env bash
# Handle both "search" (connectivity) and "view" (drift check) commands
if [[ "$*" == *"search"* ]]; then
    echo '{"issues":[]}'
    exit 0
fi
echo '{"key":"TEST-61","fields":{"summary":"Test ticket t6-abc1","description":"Description for t6-abc1.","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
STUBEOF
chmod +x "$_T6_ACLI_DIR/acli"

# We need to call cmd_sync --check, which requires JIRA_PROJECT and tickets_dir
# Source tk helpers and call cmd_sync directly
_T6_EXIT=0
_T6_OUTPUT=$(run_cmd_sync_check "$_T6_TICKETS" "$_T6_DIR/.sync-state.json" "$_T6_ACLI_DIR" 2>&1) || _T6_EXIT=$?

check_eq "test_sync_check_exits_zero_when_no_drift" "0" "$_T6_EXIT"
_T6_HAS_NO_DRIFT=0
if echo "$_T6_OUTPUT" | grep -qi "no drift detected"; then
    _T6_HAS_NO_DRIFT=1
fi
check_eq "test_sync_check_no_drift_message" "1" "$_T6_HAS_NO_DRIFT"
rm -rf "$_T6_DIR" "$_T6_ACLI_DIR"

# ===========================================================================
# Test 7: tk sync --check exits 1 when drift detected
# ===========================================================================
echo ""
echo "Test 7: tk sync --check exits 1 when drift detected"
_T7_DIR=$(mktemp -d)
_T7_TICKETS="$_T7_DIR/tickets"
mkdir -p "$_T7_TICKETS"

make_ticket_file "$_T7_TICKETS" "t7-abc1" "open" "task" "2" "TEST-71"

# Create acli stub: connectivity passes, view returns DIFFERENT title
_T7_ACLI_DIR=$(mktemp -d)
cat > "$_T7_ACLI_DIR/acli" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"search"* ]]; then
    echo '{"issues":[]}'
    exit 0
fi
echo '{"key":"TEST-71","fields":{"summary":"CHANGED on Jira side","description":"Description for t7-abc1.","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
STUBEOF
chmod +x "$_T7_ACLI_DIR/acli"

_T7_EXIT=0
_T7_OUTPUT=$(run_cmd_sync_check "$_T7_TICKETS" "$_T7_DIR/.sync-state.json" "$_T7_ACLI_DIR" 2>&1) || _T7_EXIT=$?

check_eq "test_sync_check_exits_nonzero_when_drift" "1" "$_T7_EXIT"
_T7_HAS_DRIFT_REPORT=0
if echo "$_T7_OUTPUT" | grep -qE "[0-9]+ of [0-9]+ tickets drifted"; then
    _T7_HAS_DRIFT_REPORT=1
fi
check_eq "test_sync_check_drift_report_count" "1" "$_T7_HAS_DRIFT_REPORT"
rm -rf "$_T7_DIR" "$_T7_ACLI_DIR"

# ===========================================================================
# Test 8: tk sync --check verifies connectivity before drift check
# ===========================================================================
echo ""
echo "Test 8: tk sync --check verifies connectivity first"
_T8_DIR=$(mktemp -d)
_T8_TICKETS="$_T8_DIR/tickets"
mkdir -p "$_T8_TICKETS"

make_ticket_file "$_T8_TICKETS" "t8-abc1" "open" "task" "2" "TEST-81"

# Create acli stub: connectivity FAILS (search returns error)
_T8_ACLI_DIR=$(mktemp -d)
cat > "$_T8_ACLI_DIR/acli" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"search"* ]]; then
    echo "Error: unauthorized" >&2
    exit 1
fi
# Should never reach here — connectivity check should fail first
echo "ERROR: should not reach drift check" >&2
exit 1
STUBEOF
chmod +x "$_T8_ACLI_DIR/acli"

_T8_EXIT=0
_T8_OUTPUT=$(run_cmd_sync_check "$_T8_TICKETS" "$_T8_DIR/.sync-state.json" "$_T8_ACLI_DIR" 2>&1) || _T8_EXIT=$?

# Should fail due to connectivity, NOT drift
check_eq "test_sync_check_connectivity_first" "1" "$_T8_EXIT"
_T8_NO_DRIFT_MSG=0
if echo "$_T8_OUTPUT" | grep -qi "drift"; then
    _T8_NO_DRIFT_MSG=1
fi
# Drift should NOT appear in output — connectivity failed before drift check
check_eq "test_sync_check_no_drift_when_connectivity_fails" "0" "$_T8_NO_DRIFT_MSG"
rm -rf "$_T8_DIR" "$_T8_ACLI_DIR"

# ===========================================================================
# Test 9: tk sync --check drift report format includes count
# ===========================================================================
echo ""
echo "Test 9: tk sync --check drift report format"
_T9_DIR=$(mktemp -d)
_T9_TICKETS="$_T9_DIR/tickets"
mkdir -p "$_T9_TICKETS"

# Create 2 tickets: one matching, one drifted
make_ticket_file "$_T9_TICKETS" "t9-abc1" "open" "task" "2" "TEST-91"
make_ticket_file "$_T9_TICKETS" "t9-abc2" "open" "bug" "1" "TEST-92"

_T9_ACLI_DIR=$(mktemp -d)
cat > "$_T9_ACLI_DIR/acli" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"search"* ]]; then
    echo '{"issues":[]}'
    exit 0
fi
# Parse key from args
_key=""
for _arg in "$@"; do
    if [[ "$_arg" =~ ^TEST- ]]; then
        _key="$_arg"
    fi
done
case "$_key" in
    TEST-91)
        # Matches local
        echo '{"key":"TEST-91","fields":{"summary":"Test ticket t9-abc1","description":"Description for t9-abc1.","status":{"name":"To Do"},"issuetype":{"name":"Task"},"priority":{"name":"Medium"}}}'
        ;;
    TEST-92)
        # Drifted — different title
        echo '{"key":"TEST-92","fields":{"summary":"CHANGED title","description":"Description for t9-abc2.","status":{"name":"To Do"},"issuetype":{"name":"Bug"},"priority":{"name":"High"}}}'
        ;;
esac
STUBEOF
chmod +x "$_T9_ACLI_DIR/acli"

_T9_EXIT=0
_T9_OUTPUT=$(run_cmd_sync_check "$_T9_TICKETS" "$_T9_DIR/.sync-state.json" "$_T9_ACLI_DIR" 2>&1) || _T9_EXIT=$?

check_eq "test_sync_check_drift_report_exit" "1" "$_T9_EXIT"
# Should contain the "M of N tickets drifted" format
_T9_HAS_FORMAT=0
if echo "$_T9_OUTPUT" | grep -qE "1 of 2 tickets drifted"; then
    _T9_HAS_FORMAT=1
fi
check_eq "test_sync_check_drift_report_format" "1" "$_T9_HAS_FORMAT"
# Should also contain the "OK: acli found" connectivity line
_T9_HAS_ACLI_OK=0
if echo "$_T9_OUTPUT" | grep -qi "OK.*acli"; then
    _T9_HAS_ACLI_OK=1
fi
check_eq "test_sync_check_acli_ok_before_drift" "1" "$_T9_HAS_ACLI_OK"
rm -rf "$_T9_DIR" "$_T9_ACLI_DIR"

# ===========================================================================
# Summary
# ===========================================================================
print_summary
