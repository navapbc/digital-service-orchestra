#!/usr/bin/env bash
# tests/scripts/test-cutover-migration-fields.sh
# RED tests for field migration correctness in cutover-tickets-migration.sh.
# Tests that title, parent, timestamp, priority, assignee, and jira_key
# are correctly extracted and written to v3 events.
#
# Usage: bash tests/scripts/test-cutover-migration-fields.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CUTOVER_SCRIPT="$REPO_ROOT/plugins/dso/scripts/cutover-tickets-migration.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-cutover-migration-fields.sh ==="

# =============================================================================
# Fixture helpers
# =============================================================================

_setup_migration_fixture() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"

    # Create .tickets directory for source tickets
    mkdir -p "$tmp/repo/.tickets"

    # Create .tickets-tracker directory (migration destination)
    mkdir -p "$tmp/repo/.tickets-tracker"

    # Create log dir
    mkdir -p "$tmp/repo/cutover-logs"

    echo "$tmp/repo"
}

_write_fixture_ticket() {
    local repo="$1" id="$2" content="$3"
    printf '%s' "$content" > "$repo/.tickets/${id}.md"
}

_run_migration() {
    local repo="$1"
    # Override CUTOVER_TICKETS_DIR and CUTOVER_TRACKER_DIR so the script
    # reads from our fixture .tickets/ and writes to our fixture .tickets-tracker/.
    # CUTOVER_SNAPSHOT_FILE must be set to avoid the verify phase failing on
    # a missing snapshot (we pre-create a minimal one).
    local snapshot_file="$repo/cutover-logs/snapshot.json"
    python3 -c "
import json
data = {'timestamp': '2026-01-01T00:00:00Z', 'ticket_count': 0, 'tickets': [], 'jira_mappings': {}}
print(json.dumps(data))
" > "$snapshot_file"

    (cd "$repo" && \
        CUTOVER_TICKETS_DIR="$repo/.tickets" \
        CUTOVER_TRACKER_DIR="$repo/.tickets-tracker" \
        CUTOVER_LOG_DIR="$repo/cutover-logs" \
        CUTOVER_STATE_FILE="$repo/cutover-logs/state.json" \
        CUTOVER_SNAPSHOT_FILE="$snapshot_file" \
        CUTOVER_TICKET_ID="${CUTOVER_TICKET_ID:-test-epic}" \
        bash "$CUTOVER_SCRIPT" --repo-root="$repo" 2>&1) || true
}

_extract_create_field() {
    local tracker_dir="$1" ticket_id="$2" field_path="$3"
    local create_file
    create_file=$(find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-CREATE.json' ! -name '.*' 2>/dev/null | head -1)
    if [[ -z "$create_file" ]]; then
        echo "NO_CREATE_EVENT"
        return
    fi
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    evt = json.load(f)
# Navigate dotted path like 'data.title' or 'timestamp'
obj = evt
for key in sys.argv[2].split('.'):
    if isinstance(obj, dict):
        obj = obj.get(key, 'MISSING')
    else:
        obj = 'MISSING'
print(obj)
" "$create_file" "$field_path"
}

# =============================================================================
# Test 1: Title extracted from body heading, not frontmatter
#
# Bug: script uses fm.get("title", "") but title is not in frontmatter — it
#      lives on the # heading line in the body. Currently produces empty title.
# =============================================================================
test_migration_extracts_title_from_heading() {
    local repo
    repo=$(_setup_migration_fixture)

    _write_fixture_ticket "$repo" "dso-t001" "---
id: dso-t001
status: open
deps: []
links: []
created: 2026-03-20T10:00:00Z
type: task
priority: 2
---
# My Task Title

Description of the task."

    _run_migration "$repo"

    local title
    title=$(_extract_create_field "$repo/.tickets-tracker" "dso-t001" "data.title")
    assert_eq "title extracted from heading" "My Task Title" "$title"
}
test_migration_extracts_title_from_heading

# =============================================================================
# Test 2: parent_id written to CREATE event
#
# Bug: parent is parsed from frontmatter into _parse_result but never extracted
#      and never included in the CREATE event data dict.
# =============================================================================
test_migration_writes_parent_id() {
    local repo
    repo=$(_setup_migration_fixture)

    _write_fixture_ticket "$repo" "dso-t002" "---
id: dso-t002
status: open
deps: []
links: []
created: 2026-03-20T10:00:00Z
type: story
priority: 1
parent: dso-epic1
---
# Child Story

A child story."

    _run_migration "$repo"

    local parent
    parent=$(_extract_create_field "$repo/.tickets-tracker" "dso-t002" "data.parent_id")
    assert_eq "parent_id in CREATE event" "dso-epic1" "$parent"
}
test_migration_writes_parent_id

# =============================================================================
# Test 3: Original created timestamp used, not time.time()
#
# Bug: the Python block inside _phase_migrate uses ts = int(time.time()) instead
#      of parsing the "created" field from frontmatter. This discards the
#      original creation time.
# =============================================================================
test_migration_uses_original_timestamp() {
    local repo
    repo=$(_setup_migration_fixture)

    _write_fixture_ticket "$repo" "dso-t003" "---
id: dso-t003
status: open
deps: []
links: []
created: 2026-03-20T10:00:00Z
type: task
priority: 2
---
# Timestamp Test

Body."

    _run_migration "$repo"

    # 2026-03-20T10:00:00Z in epoch seconds
    local expected_ts
    expected_ts=$(python3 -c "
from datetime import datetime, timezone
dt = datetime(2026, 3, 20, 10, 0, 0, tzinfo=timezone.utc)
print(int(dt.timestamp()))
")

    local ts
    ts=$(_extract_create_field "$repo/.tickets-tracker" "dso-t003" "timestamp")

    if [[ "$ts" == "NO_CREATE_EVENT" || "$ts" == "MISSING" ]]; then
        assert_eq "uses original timestamp: CREATE event exists" "found" "missing"
        return
    fi

    # Check the timestamp matches the original created field (within 1s tolerance)
    local diff
    diff=$(python3 -c "print(abs($ts - $expected_ts))")
    if [[ "$diff" -le 1 ]]; then
        assert_eq "uses original timestamp (not time.time())" "old" "old"
    else
        # Also check it's NOT close to now (if it's recent, that's the bug)
        local now
        now=$(python3 -c "import time; print(int(time.time()))")
        local diff_from_now
        diff_from_now=$(( now - ts ))
        if [[ "$diff_from_now" -lt 3600 ]]; then
            assert_eq "uses original timestamp (not time.time())" "old_timestamp_diff_le_1s" "used_time.time()_diff_from_expected=${diff}s"
        else
            # Timestamp is old but doesn't match expected — wrong value
            assert_eq "uses original timestamp (not time.time())" "expected_ts=${expected_ts}" "actual_ts=${ts}"
        fi
    fi
}
test_migration_uses_original_timestamp

# =============================================================================
# Test 4: SYNC event written for tickets with jira_key in frontmatter
#
# Bug: jira_key is not parsed from frontmatter at all in _phase_migrate, so
#      no SYNC event is ever written.
# =============================================================================
test_migration_writes_sync_event_for_jira_key() {
    local repo
    repo=$(_setup_migration_fixture)

    _write_fixture_ticket "$repo" "dso-t004" "---
id: dso-t004
status: closed
deps: []
links: []
created: 2026-03-20T10:00:00Z
type: story
priority: 1
jira_key: DIG-42
---
# Jira Synced Story

Synced with Jira."

    _run_migration "$repo"

    local sync_file
    sync_file=$(find "$repo/.tickets-tracker/dso-t004" -maxdepth 1 -name '*-SYNC.json' ! -name '.*' 2>/dev/null | head -1)
    if [[ -n "$sync_file" ]]; then
        local jira_key
        jira_key=$(python3 -c "import json; print(json.load(open('$sync_file')).get('jira_key','MISSING'))")
        assert_eq "SYNC event has jira_key" "DIG-42" "$jira_key"
    else
        assert_eq "SYNC event exists for jira_key ticket" "exists" "missing"
    fi
}
test_migration_writes_sync_event_for_jira_key

# =============================================================================
# Test 5: Priority written to CREATE event
#
# Bug: priority is parsed into _parse_result but never extracted and passed
#      to the CREATE event data dict.
# =============================================================================
test_migration_writes_priority() {
    local repo
    repo=$(_setup_migration_fixture)

    _write_fixture_ticket "$repo" "dso-t005" "---
id: dso-t005
status: open
deps: []
links: []
created: 2026-03-20T10:00:00Z
type: task
priority: 0
---
# Critical Task

Very important."

    _run_migration "$repo"

    local priority
    priority=$(_extract_create_field "$repo/.tickets-tracker" "dso-t005" "data.priority")
    assert_eq "priority in CREATE event" "0" "$priority"
}
test_migration_writes_priority

# =============================================================================
# Test 6: Assignee written to CREATE event
#
# Bug: assignee is not parsed from frontmatter in _phase_migrate at all, so
#      it is never included in the CREATE event data.
# =============================================================================
test_migration_writes_assignee() {
    local repo
    repo=$(_setup_migration_fixture)

    _write_fixture_ticket "$repo" "dso-t006" "---
id: dso-t006
status: open
deps: []
links: []
created: 2026-03-20T10:00:00Z
type: task
priority: 2
assignee: Joe Oakhart
---
# Assigned Task

Has an assignee."

    _run_migration "$repo"

    local assignee
    assignee=$(_extract_create_field "$repo/.tickets-tracker" "dso-t006" "data.assignee")
    assert_eq "assignee in CREATE event" "Joe Oakhart" "$assignee"
}
test_migration_writes_assignee

# =============================================================================
# Test 7: Tickets with no heading (empty title) are skipped
#
# Bug: no guard for empty title — tickets with no # heading line produce a
#      CREATE event with an empty title string, which corrupts the event store.
# =============================================================================
test_migration_skips_empty_title_tickets() {
    local repo
    repo=$(_setup_migration_fixture)

    # Ticket with no heading line at all
    _write_fixture_ticket "$repo" "dso-t007" "---
id: dso-t007
status: open
deps: []
links: []
created: 2026-03-20T10:00:00Z
type: task
priority: 2
---

No heading here, just body text."

    _run_migration "$repo"

    # Should NOT have a CREATE event (ticket was skipped due to empty title)
    local create_file
    create_file=$(find "$repo/.tickets-tracker/dso-t007" -maxdepth 1 -name '*-CREATE.json' ! -name '.*' 2>/dev/null | head -1)
    if [[ -z "$create_file" ]]; then
        assert_eq "empty title ticket skipped" "skipped" "skipped"
    else
        # CREATE event exists — check if title is empty (the current bug)
        local title
        title=$(python3 -c "
import json
evt = json.load(open('$create_file'))
print(repr(evt.get('data', {}).get('title', '')))
")
        if [[ "$title" == "''" || "$title" == '""' || "$title" == "" ]]; then
            assert_eq "empty title ticket skipped" "skipped" "created_with_empty_title"
        else
            assert_eq "empty title ticket skipped" "skipped" "created_with_title: $title"
        fi
    fi
}
test_migration_skips_empty_title_tickets

# =============================================================================
# Summary
# =============================================================================
print_summary
