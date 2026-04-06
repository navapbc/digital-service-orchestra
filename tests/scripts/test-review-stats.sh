#!/usr/bin/env bash
# tests/scripts/test-review-stats.sh
# RED tests for plugins/dso/scripts/review-stats.sh (does NOT exist yet).
#
# Covers: default 30-day window, --since flag filtering, --all flag,
# graceful handling of empty/missing .review-events/ directory.
#
# Usage: bash tests/scripts/test-review-stats.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

_CLEANUP_DIRS=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
STATS_SCRIPT="$REPO_ROOT/plugins/dso/scripts/review-stats.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-review-stats.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ──────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: write fixture review event JSONL files into .review-events/ ──────
# Creates events with different timestamps so date-filtering can be tested.
_populate_fixture_events() {
    local events_dir="$1"
    mkdir -p "$events_dir"

    # Event 1: recent (within 30 days) — review_result, standard tier
    python3 -c "
import json, sys, datetime
ts = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=5)).strftime('%Y-%m-%dT%H:%M:%SZ')
data = {
    'schema_version': 1,
    'event_type': 'review_result',
    'timestamp': ts,
    'session_id': 'sess-fixture-001',
    'epic_id': 'abcd-1234',
    'tier': 'standard',
    'reviewer_agent': 'dso:code-reviewer-standard',
    'finding_count': 3,
    'critical_count': 1,
    'important_count': 1,
    'suggestion_count': 1,
    'dimensions_scored': ['correctness', 'verification', 'hygiene', 'design', 'maintainability'],
    'pass': True,
    'resolution_attempts': 2,
    'diff_hash': 'aabb1122'
}
json.dump(data, sys.stdout)
" > "$events_dir/2026-04-01T00-00-00Z-sess-fixture-001.jsonl"

    # Event 2: recent (within 30 days) — review_result, deep tier
    python3 -c "
import json, sys, datetime
ts = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=10)).strftime('%Y-%m-%dT%H:%M:%SZ')
data = {
    'schema_version': 1,
    'event_type': 'review_result',
    'timestamp': ts,
    'session_id': 'sess-fixture-002',
    'epic_id': 'abcd-1234',
    'tier': 'deep',
    'reviewer_agent': 'dso:code-reviewer-deep-arch',
    'finding_count': 5,
    'critical_count': 0,
    'important_count': 3,
    'suggestion_count': 2,
    'dimensions_scored': ['correctness', 'verification', 'hygiene', 'design', 'maintainability'],
    'pass': True,
    'resolution_attempts': 1,
    'diff_hash': 'ccdd3344'
}
json.dump(data, sys.stdout)
" > "$events_dir/2026-03-27T00-00-00Z-sess-fixture-002.jsonl"

    # Event 3: old (90 days ago) — should be excluded by 30-day default window
    python3 -c "
import json, sys, datetime
ts = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=90)).strftime('%Y-%m-%dT%H:%M:%SZ')
data = {
    'schema_version': 1,
    'event_type': 'review_result',
    'timestamp': ts,
    'session_id': 'sess-fixture-003',
    'epic_id': 'efgh-5678',
    'tier': 'light',
    'reviewer_agent': 'dso:code-reviewer-light',
    'finding_count': 1,
    'critical_count': 0,
    'important_count': 0,
    'suggestion_count': 1,
    'dimensions_scored': ['correctness', 'hygiene'],
    'pass': True,
    'resolution_attempts': 0,
    'diff_hash': 'eeff5566'
}
json.dump(data, sys.stdout)
" > "$events_dir/2026-01-06T00-00-00Z-sess-fixture-003.jsonl"
}

# ── Test 1: default 30-day window ──────────────────────────────────────────────
echo "Test 1: review-stats.sh default 30-day window shows recent events only"
test_review_stats_default_30_day_window() {
    # review-stats.sh must exist — RED: it does not exist yet
    if [ ! -f "$STATS_SCRIPT" ]; then
        assert_eq "review-stats.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Initialize ticket system and populate fixture events
    (cd "$repo" && bash "$REPO_ROOT/.claude/scripts/dso" ticket init 2>/dev/null) || true
    _populate_fixture_events "$repo/.tickets-tracker/.review-events"

    # Call review-stats.sh with no flags (default 30-day window)
    local output exit_code=0
    output=$(cd "$repo" && bash "$STATS_SCRIPT" 2>&1) || exit_code=$?

    assert_eq "exits zero with default window" "0" "$exit_code"

    # Output should contain a metrics table (header or summary line)
    assert_contains "output contains metrics" "review" "$output"

    # Should include 2 recent events but NOT the 90-day-old event
    assert_contains "includes recent event sess-fixture-001" "sess-fixture-001" "$output"
    assert_contains "includes recent event sess-fixture-002" "sess-fixture-002" "$output"
    # The old event (sess-fixture-003) should not appear
    local has_old="no"
    if echo "$output" | grep -q "sess-fixture-003"; then
        has_old="yes"
    fi
    assert_eq "excludes old event sess-fixture-003" "no" "$has_old"
}
test_review_stats_default_30_day_window

# ── Test 2: --since flag ──────────────────────────────────────────────────────
echo "Test 2: review-stats.sh --since flag filters events by date"
test_review_stats_since_flag() {
    # review-stats.sh must exist — RED: it does not exist yet
    if [ ! -f "$STATS_SCRIPT" ]; then
        assert_eq "review-stats.sh exists for --since test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    (cd "$repo" && bash "$REPO_ROOT/.claude/scripts/dso" ticket init 2>/dev/null) || true
    _populate_fixture_events "$repo/.tickets-tracker/.review-events"

    # Use --since with a date that includes only the most recent event (5 days ago)
    local since_date
    since_date=$(python3 -c "
import datetime
d = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)
print(d.strftime('%Y-%m-%d'))
")

    local output exit_code=0
    output=$(cd "$repo" && bash "$STATS_SCRIPT" --since="$since_date" 2>&1) || exit_code=$?

    assert_eq "exits zero with --since" "0" "$exit_code"

    # Should include only the 5-day-old event, not the 10-day-old or 90-day-old
    assert_contains "includes event within --since window" "sess-fixture-001" "$output"

    local has_older="no"
    if echo "$output" | grep -q "sess-fixture-002"; then
        has_older="yes"
    fi
    assert_eq "excludes event before --since date" "no" "$has_older"
}
test_review_stats_since_flag

# ── Test 3: --all flag ────────────────────────────────────────────────────────
echo "Test 3: review-stats.sh --all includes all events regardless of date"
test_review_stats_all_flag() {
    # review-stats.sh must exist — RED: it does not exist yet
    if [ ! -f "$STATS_SCRIPT" ]; then
        assert_eq "review-stats.sh exists for --all test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    (cd "$repo" && bash "$REPO_ROOT/.claude/scripts/dso" ticket init 2>/dev/null) || true
    _populate_fixture_events "$repo/.tickets-tracker/.review-events"

    # Call with --all flag
    local output exit_code=0
    output=$(cd "$repo" && bash "$STATS_SCRIPT" --all 2>&1) || exit_code=$?

    assert_eq "exits zero with --all" "0" "$exit_code"

    # All three events should appear
    assert_contains "includes sess-fixture-001" "sess-fixture-001" "$output"
    assert_contains "includes sess-fixture-002" "sess-fixture-002" "$output"
    assert_contains "includes sess-fixture-003" "sess-fixture-003" "$output"
}
test_review_stats_all_flag

# ── Test 4: empty/missing .review-events/ directory ───────────────────────────
echo "Test 4: review-stats.sh handles empty/missing .review-events/ gracefully"
test_review_stats_empty_events_dir() {
    # review-stats.sh must exist — RED: it does not exist yet
    if [ ! -f "$STATS_SCRIPT" ]; then
        assert_eq "review-stats.sh exists for empty-events test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    (cd "$repo" && bash "$REPO_ROOT/.claude/scripts/dso" ticket init 2>/dev/null) || true

    # Do NOT create .review-events/ — test missing directory
    local output exit_code=0
    output=$(cd "$repo" && bash "$STATS_SCRIPT" 2>&1) || exit_code=$?

    # Should exit 0 (graceful, no crash)
    assert_eq "exits zero with missing .review-events/" "0" "$exit_code"

    # Should print a "No events found" message
    assert_contains "prints no-events message" "No events found" "$output"

    # Now test with an empty .review-events/ directory
    mkdir -p "$repo/.tickets-tracker/.review-events"

    output=$(cd "$repo" && bash "$STATS_SCRIPT" 2>&1) || exit_code=$?

    assert_eq "exits zero with empty .review-events/" "0" "$exit_code"
    assert_contains "prints no-events message for empty dir" "No events found" "$output"
}
test_review_stats_empty_events_dir

print_summary
