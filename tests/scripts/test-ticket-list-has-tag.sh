#!/usr/bin/env bash
# tests/scripts/test-ticket-list-has-tag.sh
# RED tests for --has-tag filter in ticket list (both legacy ticket-list.sh and
# in-process ticket_list() in ticket-lib-api.sh).
#
# Covers 4 scenarios x 2 paths (legacy and in-process via `ticket` dispatcher):
#   1. Bug with detected_by:tests tag → appears in --has-tag=detected_by:tests results
#   2. Story (non-bug) with detected_by:tests tag → does NOT appear in
#      --has-tag=detected_by:tests results (detected_by namespace auto-intersects with bug type)
#   3. Story with detected_by:tests tag → DOES appear when filtering by a different
#      tag (no type-intersection for non-detected_by tags)
#   4. --has-tag with no matching tickets → exits 0 with empty result
#
# RED MARKER:
# tests/scripts/test-ticket-list-has-tag.sh [test_bug_with_detected_by_tag_appears]
# tests/scripts/test-ticket-list-has-tag.sh [test_non_bug_excluded_from_detected_by_filter]
# tests/scripts/test-ticket-list-has-tag.sh [test_non_bug_included_for_non_detected_by_tag]
# tests/scripts/test-ticket-list-has-tag.sh [test_no_matching_tickets_exits_0_empty]
# tests/scripts/test-ticket-list-has-tag.sh [test_inprocess_bug_with_detected_by_tag_appears]
# tests/scripts/test-ticket-list-has-tag.sh [test_inprocess_non_bug_excluded_from_detected_by_filter]
#
# Usage: bash tests/scripts/test-ticket-list-has-tag.sh
# Returns: exit 0 if all tests pass, exit non-zero if any fail

# NOTE: -e intentionally omitted — test assertions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TICKET_LIST_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/ticket-list.sh"
TICKET_DISPATCHER="$PLUGIN_ROOT/plugins/dso/scripts/ticket"
TICKET_REDUCER_DIR="$PLUGIN_ROOT/plugins/dso/scripts"

source "$SCRIPT_DIR/../lib/assert.sh"

echo "=== test-ticket-list-has-tag.sh ==="

# ── Cleanup ───────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup EXIT

# ── Fixture helpers ───────────────────────────────────────────────────────────

# _make_tracker — creates a temp dir with mock ticket event files.
# Writes deterministic ticket stubs (no real git ops needed) that ticket-list.sh
# can read via TICKETS_TRACKER_DIR env var.
#
# Ticket stubs written:
#   bug-tag-001   type=bug    tags=[detected_by:tests, regression]
#   story-tag-001 type=story  tags=[detected_by:tests]
#   story-tag-002 type=story  tags=[regression]
_make_tracker() {
    local tracker_dir
    tracker_dir=$(mktemp -d /tmp/test-ticket-list-has-tag.XXXXXX)
    _CLEANUP_DIRS+=("$tracker_dir")

    # ── Bug with detected_by:tests tag ────────────────────────────────────────
    mkdir -p "$tracker_dir/bug-tag-001"
    python3 -c "
import json
event = {
    'event_type': 'CREATE',
    'ticket_id': 'bug-tag-001',
    'timestamp': 1700000000000000000,
    'uuid': 'aaaaaaaa-0001-0001-0001-000000000001',
    'env_id': 'test-env',
    'author': 'Test',
    'data': {
        'ticket_id': 'bug-tag-001',
        'title': 'Bug with detected_by:tests tag',
        'ticket_type': 'bug',
        'status': 'open',
        'priority': 2,
        'parent_id': None,
        'tags': ['detected_by:tests', 'regression'],
        'description': '',
        'notes': '',
    }
}
with open('$tracker_dir/bug-tag-001/001-CREATE.json', 'w') as f:
    json.dump(event, f)
"

    # ── Story (non-bug) with detected_by:tests tag ────────────────────────────
    mkdir -p "$tracker_dir/story-tag-001"
    python3 -c "
import json
event = {
    'event_type': 'CREATE',
    'ticket_id': 'story-tag-001',
    'timestamp': 1700000001000000000,
    'uuid': 'bbbbbbbb-0001-0001-0001-000000000001',
    'env_id': 'test-env',
    'author': 'Test',
    'data': {
        'ticket_id': 'story-tag-001',
        'title': 'Story with detected_by:tests tag',
        'ticket_type': 'story',
        'status': 'open',
        'priority': 2,
        'parent_id': None,
        'tags': ['detected_by:tests'],
        'description': '',
        'notes': '',
    }
}
with open('$tracker_dir/story-tag-001/001-CREATE.json', 'w') as f:
    json.dump(event, f)
"

    # ── Story with regression tag (no detected_by:tests) ─────────────────────
    mkdir -p "$tracker_dir/story-tag-002"
    python3 -c "
import json
event = {
    'event_type': 'CREATE',
    'ticket_id': 'story-tag-002',
    'timestamp': 1700000002000000000,
    'uuid': 'cccccccc-0001-0001-0001-000000000001',
    'env_id': 'test-env',
    'author': 'Test',
    'data': {
        'ticket_id': 'story-tag-002',
        'title': 'Story with regression tag only',
        'ticket_type': 'story',
        'status': 'open',
        'priority': 2,
        'parent_id': None,
        'tags': ['regression'],
        'description': '',
        'notes': '',
    }
}
with open('$tracker_dir/story-tag-002/001-CREATE.json', 'w') as f:
    json.dump(event, f)
"

    echo "$tracker_dir"
}

# ── Scenario 1: Bug with detected_by:tests tag → appears in results ───────────
echo "Test 1: bug with detected_by:tests tag appears in --has-tag=detected_by:tests results"
test_bug_with_detected_by_tag_appears() {
    local tracker_dir
    tracker_dir=$(_make_tracker)

    local output exit_code=0
    output=$(TICKETS_TRACKER_DIR="$tracker_dir" bash "$TICKET_LIST_SCRIPT" \
        --has-tag=detected_by:tests 2>/dev/null) || exit_code=$?

    assert_eq "test1: --has-tag exits 0" "0" "$exit_code"

    local found
    found=$(python3 -c "
import json, sys
try:
    tickets = json.loads(sys.argv[1])
    ids = [t.get('ticket_id') for t in tickets if isinstance(t, dict)]
    print('found' if 'bug-tag-001' in ids else 'missing')
except Exception as e:
    print(f'error:{e}')
" "$output" 2>/dev/null || echo "error:parse")

    assert_eq "test1: bug-tag-001 found in --has-tag=detected_by:tests output" "found" "$found"
}
test_bug_with_detected_by_tag_appears

# ── Scenario 2: Non-bug (story) with detected_by:tests tag → NOT in results ───
echo "Test 2: non-bug story with detected_by:tests tag does NOT appear in --has-tag=detected_by:tests results"
test_non_bug_excluded_from_detected_by_filter() {
    local tracker_dir
    tracker_dir=$(_make_tracker)

    local output exit_code=0
    output=$(TICKETS_TRACKER_DIR="$tracker_dir" bash "$TICKET_LIST_SCRIPT" \
        --has-tag=detected_by:tests 2>/dev/null) || exit_code=$?

    assert_eq "test2: --has-tag exits 0" "0" "$exit_code"

    local found
    found=$(python3 -c "
import json, sys
try:
    tickets = json.loads(sys.argv[1])
    ids = [t.get('ticket_id') for t in tickets if isinstance(t, dict)]
    print('present' if 'story-tag-001' in ids else 'absent')
except Exception as e:
    print(f'error:{e}')
" "$output" 2>/dev/null || echo "error:parse")

    assert_eq "test2: story-tag-001 absent from --has-tag=detected_by:tests output (non-bug excluded)" "absent" "$found"
}
test_non_bug_excluded_from_detected_by_filter

# ── Scenario 3: Non-bug with detected_by:tests tag DOES appear for other tags ─
echo "Test 3: non-bug story appears in --has-tag=regression results (no type-intersection for non-detected_by tags)"
test_non_bug_included_for_non_detected_by_tag() {
    local tracker_dir
    tracker_dir=$(_make_tracker)

    local output exit_code=0
    output=$(TICKETS_TRACKER_DIR="$tracker_dir" bash "$TICKET_LIST_SCRIPT" \
        --has-tag=regression 2>/dev/null) || exit_code=$?

    assert_eq "test3: --has-tag=regression exits 0" "0" "$exit_code"

    local found_story found_bug
    found_story=$(python3 -c "
import json, sys
try:
    tickets = json.loads(sys.argv[1])
    ids = [t.get('ticket_id') for t in tickets if isinstance(t, dict)]
    print('found' if 'story-tag-002' in ids else 'missing')
except Exception as e:
    print(f'error:{e}')
" "$output" 2>/dev/null || echo "error:parse")

    found_bug=$(python3 -c "
import json, sys
try:
    tickets = json.loads(sys.argv[1])
    ids = [t.get('ticket_id') for t in tickets if isinstance(t, dict)]
    print('found' if 'bug-tag-001' in ids else 'missing')
except Exception as e:
    print(f'error:{e}')
" "$output" 2>/dev/null || echo "error:parse")

    assert_eq "test3: story-tag-002 found in --has-tag=regression output" "found" "$found_story"
    assert_eq "test3: bug-tag-001 also found in --has-tag=regression output (bug has regression tag too)" "found" "$found_bug"
}
test_non_bug_included_for_non_detected_by_tag

# ── Scenario 4: No matching tickets → exits 0 with empty result ───────────────
echo "Test 4: --has-tag with no matching tickets exits 0 with empty result"
test_no_matching_tickets_exits_0_empty() {
    local tracker_dir
    tracker_dir=$(_make_tracker)

    local output exit_code=0
    output=$(TICKETS_TRACKER_DIR="$tracker_dir" bash "$TICKET_LIST_SCRIPT" \
        --has-tag=nonexistent-tag-xyz 2>/dev/null) || exit_code=$?

    assert_eq "test4: --has-tag=nonexistent exits 0" "0" "$exit_code"

    local ticket_count
    ticket_count=$(python3 -c "
import json, sys
try:
    tickets = json.loads(sys.argv[1])
    print(len(tickets))
except Exception as e:
    print(f'error:{e}')
" "$output" 2>/dev/null || echo "error:parse")

    assert_eq "test4: result is empty array (0 tickets)" "0" "$ticket_count"
}
test_no_matching_tickets_exits_0_empty

# ── In-process path tests (ticket_list() in ticket-lib-api.sh) ────────────────
# These exercise the default (non-legacy) path used by `.claude/scripts/dso ticket list`.

# ── Scenario 5: in-process — bug with detected_by:tests appears ───────────────
echo "Test 5: [in-process] bug with detected_by:tests tag appears in --has-tag=detected_by:tests results"
test_inprocess_bug_with_detected_by_tag_appears() {
    local tracker_dir
    tracker_dir=$(_make_tracker)

    local output exit_code=0
    output=$(TICKETS_TRACKER_DIR="$tracker_dir" bash "$TICKET_DISPATCHER" list \
        --has-tag=detected_by:tests 2>/dev/null) || exit_code=$?

    assert_eq "test5: in-process --has-tag exits 0" "0" "$exit_code"

    local found
    found=$(python3 -c "
import json, sys
try:
    tickets = json.loads(sys.argv[1])
    ids = [t.get('ticket_id') for t in tickets if isinstance(t, dict)]
    print('found' if 'bug-tag-001' in ids else 'missing')
except Exception as e:
    print(f'error:{e}')
" "$output" 2>/dev/null || echo "error:parse")

    assert_eq "test5: bug-tag-001 found in in-process --has-tag=detected_by:tests output" "found" "$found"
}
test_inprocess_bug_with_detected_by_tag_appears

# ── Scenario 6: in-process — non-bug story EXCLUDED by detected_by auto-intersect ─
echo "Test 6: [in-process] non-bug story with detected_by:tests tag does NOT appear (auto-intersect with type=bug)"
test_inprocess_non_bug_excluded_from_detected_by_filter() {
    local tracker_dir
    tracker_dir=$(_make_tracker)

    local output exit_code=0
    output=$(TICKETS_TRACKER_DIR="$tracker_dir" bash "$TICKET_DISPATCHER" list \
        --has-tag=detected_by:tests 2>/dev/null) || exit_code=$?

    assert_eq "test6: in-process --has-tag exits 0" "0" "$exit_code"

    local found
    found=$(python3 -c "
import json, sys
try:
    tickets = json.loads(sys.argv[1])
    ids = [t.get('ticket_id') for t in tickets if isinstance(t, dict)]
    print('present' if 'story-tag-001' in ids else 'absent')
except Exception as e:
    print(f'error:{e}')
" "$output" 2>/dev/null || echo "error:parse")

    assert_eq "test6: story-tag-001 absent from in-process --has-tag=detected_by:tests output" "absent" "$found"
}
test_inprocess_non_bug_excluded_from_detected_by_filter

print_summary
