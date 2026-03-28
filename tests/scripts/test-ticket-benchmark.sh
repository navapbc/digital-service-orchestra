#!/usr/bin/env bash
# tests/scripts/test-ticket-benchmark.sh
# RED tests for plugins/dso/scripts/ticket-benchmark.sh — ticket benchmark subcommand.
#
# All test functions MUST FAIL until ticket-benchmark.sh is implemented.
# Covers: exit code under/over threshold, timing output format.
#
# Usage: bash tests/scripts/test-ticket-benchmark.sh
# Returns: exit non-zero (RED) until ticket-benchmark.sh is implemented.

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
BENCHMARK_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-benchmark.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-benchmark.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    (cd "$tmp/repo" && bash "$TICKET_SCRIPT" init >/dev/null 2>/dev/null) || true
    echo "$tmp/repo"
}

# ── Helper: create a ticket and return its ID ─────────────────────────────────
_create_ticket() {
    local repo="$1"
    local ticket_type="${2:-task}"
    local title="${3:-Test ticket}"
    local out
    out=$(cd "$repo" && bash "$TICKET_SCRIPT" create "$ticket_type" "$title" 2>/dev/null) || true
    echo "$out"
}

# ── Helper: seed N tickets into a test repo ───────────────────────────────────
_seed_tickets() {
    local repo="$1"
    local count="${2:-5}"
    local i
    for (( i = 1; i <= count; i++ )); do
        _create_ticket "$repo" task "Benchmark test ticket $i" >/dev/null
    done
}

# ── Test 1: benchmark exits zero when operations are under threshold ──────────
echo "Test 1: benchmark exits 0 when operations complete under generous threshold"
test_benchmark_exits_zero_under_threshold() {
    _snapshot_fail

    # RED: ticket-benchmark.sh must not exist yet
    if [ ! -f "$BENCHMARK_SCRIPT" ]; then
        assert_eq "ticket-benchmark.sh exists" "exists" "missing"
        assert_pass_if_clean "test_benchmark_exits_zero_under_threshold"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Seed 5 tickets so the benchmark has something to measure
    _seed_tickets "$repo" 5

    local exit_code=0
    (cd "$repo" && bash "$BENCHMARK_SCRIPT" --threshold 30 >/dev/null 2>/dev/null) || exit_code=$?

    # Assert: exits 0 with a generous 30s threshold
    assert_eq "benchmark exits 0 under threshold" "0" "$exit_code"

    assert_pass_if_clean "test_benchmark_exits_zero_under_threshold"
}
test_benchmark_exits_zero_under_threshold

# ── Test 2: benchmark exits non-zero when operations exceed threshold ─────────
echo "Test 2: benchmark exits non-zero when threshold is impossibly low"
test_benchmark_exits_nonzero_over_threshold() {
    _snapshot_fail

    # RED: ticket-benchmark.sh must not exist yet
    if [ ! -f "$BENCHMARK_SCRIPT" ]; then
        assert_eq "ticket-benchmark.sh exists" "exists" "missing"
        assert_pass_if_clean "test_benchmark_exits_nonzero_over_threshold"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Seed a few tickets
    _seed_tickets "$repo" 5

    local exit_code=0
    (cd "$repo" && bash "$BENCHMARK_SCRIPT" --threshold 0.001 >/dev/null 2>/dev/null) || exit_code=$?

    # Assert: exits non-zero with an impossibly low 0.001s threshold
    assert_ne "benchmark exits non-zero over threshold" "0" "$exit_code"

    assert_pass_if_clean "test_benchmark_exits_nonzero_over_threshold"
}
test_benchmark_exits_nonzero_over_threshold

# ── Test 3: benchmark outputs numeric timing information ──────────────────────
echo "Test 3: benchmark stdout contains numeric timing value"
test_benchmark_outputs_timing_info() {
    _snapshot_fail

    # RED: ticket-benchmark.sh must not exist yet
    if [ ! -f "$BENCHMARK_SCRIPT" ]; then
        assert_eq "ticket-benchmark.sh exists" "exists" "missing"
        assert_pass_if_clean "test_benchmark_outputs_timing_info"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Seed 5 tickets
    _seed_tickets "$repo" 5

    local output
    local exit_code=0
    output=$(cd "$repo" && bash "$BENCHMARK_SCRIPT" --threshold 30 2>/dev/null) || exit_code=$?

    # Assert: stdout contains at least one numeric value (timing in seconds, e.g., "0.123" or "1.45")
    local has_numeric
    has_numeric=$(echo "$output" | grep -cE '[0-9]+\.[0-9]+' || true)

    assert_ne "benchmark output contains numeric timing" "0" "$has_numeric"

    assert_pass_if_clean "test_benchmark_outputs_timing_info"
}
test_benchmark_outputs_timing_info

# ── Helper: seed a mixed population of tickets into a test repo ───────────────
# Creates:
#   - <epic_count> epics (open)
#   - <story_count> stories (in_progress) as children of first epic
#   - <task_count> tasks (open) as standalone
#   - <archived_count> archived tasks (closed) as standalone
#   - <link_count> dependency links between task pairs
# Returns: first epic ID on stdout (for reference)
_seed_mixed_population() {
    local repo="$1"
    local epic_count="${2:-5}"
    local story_count="${3:-10}"
    local task_count="${4:-185}"
    local archived_count="${5:-50}"
    local link_count="${6:-10}"

    local first_epic_id=""

    # Create epics (open status by default)
    local i epic_id
    for (( i = 1; i <= epic_count; i++ )); do
        epic_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create epic "Benchmark epic $i" 2>/dev/null) || true
        if [ $i -eq 1 ]; then first_epic_id="$epic_id"; fi
    done

    # Create stories (in_progress) as children of first epic
    if [ -n "$first_epic_id" ]; then
        for (( i = 1; i <= story_count; i++ )); do
            local sid
            sid=$(cd "$repo" && bash "$TICKET_SCRIPT" create story "Benchmark story $i" "$first_epic_id" 2>/dev/null) || true
            # Transition to in_progress
            if [ -n "$sid" ]; then
                (cd "$repo" && bash "$TICKET_SCRIPT" transition "$sid" open in_progress >/dev/null 2>/dev/null) || true
            fi
        done
    fi

    # Create standalone tasks (open)
    local task_ids=()
    for (( i = 1; i <= task_count; i++ )); do
        local tid
        tid=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "Benchmark task $i" 2>/dev/null) || true
        if [ -n "$tid" ]; then task_ids+=("$tid"); fi
    done

    # Create archived (closed) tasks
    for (( i = 1; i <= archived_count; i++ )); do
        local aid
        aid=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "Archived task $i" 2>/dev/null) || true
        if [ -n "$aid" ]; then
            (cd "$repo" && bash "$TICKET_SCRIPT" transition "$aid" open closed --reason="Fixed: benchmark seed" >/dev/null 2>/dev/null) || true
        fi
    done

    # Add dependency links between task pairs
    local pair_count="${#task_ids[@]}"
    local links_added=0
    for (( i = 0; i < pair_count - 1 && links_added < link_count; i += 2 )); do
        local src="${task_ids[$i]}"
        local tgt="${task_ids[$((i+1))]}"
        if [ -n "$src" ] && [ -n "$tgt" ]; then
            (cd "$repo" && bash "$TICKET_SCRIPT" link "$src" "$tgt" depends_on >/dev/null 2>/dev/null) || true
            (( links_added++ )) || true
        fi
    done

    echo "$first_epic_id"
}

# ── Test 4: close benchmark under 10s with 200 non-archived + 50 archived tickets
echo "Test 4: ticket transition open->closed wall-clock < 10s with 250-ticket population"
test_close_benchmark_under_threshold() {
    _snapshot_fail

    # RED: ticket-benchmark.sh must support --mode=close
    # This test will fail until ticket-benchmark.sh implements --mode=close.
    # We call the benchmark script with --mode=close so the test is RED until
    # that option is implemented.
    local exit_code=0
    bash "$BENCHMARK_SCRIPT" --mode=close --threshold 10 >/dev/null 2>/dev/null || exit_code=$?

    # Assert: --mode=close is recognised (exits 0 or 1, not 2 for unknown arg)
    # Until --mode=close is implemented, ticket-benchmark.sh exits 2 → RED.
    assert_ne "benchmark --mode=close is not an unknown-argument error" "2" "$exit_code"

    local repo
    repo=$(_make_test_repo)

    # Seed 200 non-archived + 50 archived tickets with mixed types and links
    _seed_mixed_population "$repo" 5 10 185 50 15 >/dev/null

    # Create target: a task in open status with no children (simplest closeable state)
    local target_id
    target_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "Target close benchmark task" 2>/dev/null) || true

    if [ -z "$target_id" ]; then
        assert_eq "target ticket created" "non-empty" "empty"
        assert_pass_if_clean "test_close_benchmark_under_threshold"
        return
    fi

    # Time the full ticket transition CLI command (includes open-children guard + flock +
    # STATUS event write + ticket-unblock.py subprocess)
    local t_start t_end elapsed exit_code_transition
    t_start=$(date +%s.%N)
    exit_code_transition=0
    (cd "$repo" && bash "$TICKET_SCRIPT" transition "$target_id" open closed --reason="Fixed: benchmark" >/dev/null 2>/dev/null) \
        || exit_code_transition=$?
    t_end=$(date +%s.%N)

    elapsed=$(python3 -c "print(float('$t_end') - float('$t_start'))")

    # Assert: transition succeeded
    assert_eq "ticket transition open->closed exits 0" "0" "$exit_code_transition"

    # Assert: wall-clock time < 10s
    local over_threshold
    over_threshold=$(python3 -c "print('1' if float('$elapsed') >= 10.0 else '0')")
    assert_eq "close wall-clock < 10s (elapsed=${elapsed}s)" "0" "$over_threshold"

    assert_pass_if_clean "test_close_benchmark_under_threshold"
}
test_close_benchmark_under_threshold

# ── Test 5: seeded population has realistic mix of types, statuses, and links ──
echo "Test 5: seeded population has >= 3 ticket types, >= 2 statuses, >= 10 dependency links"
test_close_benchmark_realistic_population() {
    _snapshot_fail

    # RED: requires --mode=close seeding support in ticket-benchmark.sh
    local exit_code=0
    bash "$BENCHMARK_SCRIPT" --mode=close --threshold 10 >/dev/null 2>/dev/null || exit_code=$?
    assert_ne "benchmark --mode=close is not an unknown-argument error" "2" "$exit_code"

    local repo
    repo=$(_make_test_repo)

    # Seed a mixed population: 5 epics, 10 stories (in_progress), 185 tasks (open),
    # 50 archived tasks (closed), 15 dependency links
    _seed_mixed_population "$repo" 5 10 185 50 15 >/dev/null

    local tracker_dir="$repo/.tickets-tracker"

    # Count distinct ticket types in the tracker
    local type_count
    type_count=$(python3 -c "
import os, json, glob

tracker = '$tracker_dir'
types = set()
for d in os.listdir(tracker):
    ticket_dir = os.path.join(tracker, d)
    if not os.path.isdir(ticket_dir):
        continue
    for f in sorted(os.listdir(ticket_dir)):
        if not f.endswith('-CREATE.json'):
            continue
        try:
            with open(os.path.join(ticket_dir, f)) as fh:
                ev = json.load(fh)
            t = ev.get('data', {}).get('ticket_type', '')
            if t:
                types.add(t)
        except Exception:
            pass
print(len(types))
" 2>/dev/null) || type_count=0

    assert_ne "at least 3 distinct ticket types (got $type_count)" "true" \
        "$(python3 -c "print('true' if int('${type_count:-0}') < 3 else 'false')" 2>/dev/null || echo 'true')"

    # Count distinct statuses by reading STATUS events
    local status_count
    status_count=$(python3 -c "
import os, json

tracker = '$tracker_dir'
statuses = set()
# Default status (no STATUS event) is 'open'
statuses.add('open')
for d in os.listdir(tracker):
    ticket_dir = os.path.join(tracker, d)
    if not os.path.isdir(ticket_dir):
        continue
    for f in sorted(os.listdir(ticket_dir)):
        if not f.endswith('-STATUS.json'):
            continue
        try:
            with open(os.path.join(ticket_dir, f)) as fh:
                ev = json.load(fh)
            s = ev.get('data', {}).get('status', '')
            if s:
                statuses.add(s)
        except Exception:
            pass
print(len(statuses))
" 2>/dev/null) || status_count=0

    assert_ne "at least 2 distinct statuses (got $status_count)" "true" \
        "$(python3 -c "print('true' if int('${status_count:-0}') < 2 else 'false')" 2>/dev/null || echo 'true')"

    # Count dependency links (LINK events across all ticket dirs)
    local link_count
    link_count=$(python3 -c "
import os, json

tracker = '$tracker_dir'
count = 0
for d in os.listdir(tracker):
    ticket_dir = os.path.join(tracker, d)
    if not os.path.isdir(ticket_dir):
        continue
    for f in os.listdir(ticket_dir):
        if f.endswith('-LINK.json'):
            count += 1
print(count)
" 2>/dev/null) || link_count=0

    assert_ne "at least 10 dependency links (got $link_count)" "true" \
        "$(python3 -c "print('true' if int('${link_count:-0}') < 10 else 'false')" 2>/dev/null || echo 'true')"

    assert_pass_if_clean "test_close_benchmark_realistic_population"
}
test_close_benchmark_realistic_population

print_summary
