#!/usr/bin/env bash
# tests/scripts/test-ticket-concurrency-stress.sh
# Concurrency stress test: 5 parallel sessions x 10 ops each.
#
# Each session creates 2 tickets, then performs 8 operations (transitions +
# comments) on its own tickets. Total: 50 events across 10 tickets.
#
# Verifies: all events exist, all committed in distinct git commits, no data
# loss, valid JSON with required fields, cache layer works after concurrent writes.
#
# Usage: bash tests/scripts/test-ticket-concurrency-stress.sh
# Returns: exit 0 if all assertions pass, exit 1 otherwise

# NOTE: -e is intentionally omitted — test functions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-concurrency-stress.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    (cd "$tmp/repo" && bash "$TICKET_SCRIPT" init >/dev/null 2>/dev/null) || true
    echo "$tmp/repo"
}

# ── Helper: run a single stress session ────────────────────────────────────
# Each session creates 2 tickets, then performs 4 transitions + 4 comments = 10 ops total.
# Writes session_tickets file listing created ticket IDs.
_make_stress_session() {
    local repo="$1"
    local session_idx="$2"
    local barrier_dir="$3"
    local session_log_dir="$4"
    local deadline="$5"

    mkdir -p "$session_log_dir"

    # Signal readiness
    touch "$barrier_dir/ready-$session_idx"

    # Wait for all 5 sessions to be ready (barrier with 30s timeout)
    while true; do
        local ready_count
        ready_count=$(ls "$barrier_dir"/ready-* 2>/dev/null | wc -l | tr -d ' ')
        if [ "$ready_count" -ge 5 ]; then
            break
        fi
        local now
        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
            echo "BARRIER TIMEOUT: session $session_idx — only $ready_count/5 ready after 30s" >&2
            return 1
        fi
        sleep 0.1
    done

    # Create 2 tickets
    local session_tickets=()
    local tid
    for i in 1 2; do
        tid=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "Stress-s${session_idx}-t${i}" 2>/dev/null) || true
        if [ -z "$tid" ]; then
            echo "FAIL: session $session_idx create $i returned empty ID" >&2
            return 1
        fi
        session_tickets+=("$tid")
        echo "CREATE $tid" >> "$session_log_dir/ops.log"
    done

    # Write session_tickets file for later verification
    printf '%s\n' "${session_tickets[@]}" > "$session_log_dir/session_tickets.txt"

    # 4 transitions on own tickets (2 per ticket: open→in_progress, in_progress→closed)
    for tid in "${session_tickets[@]}"; do
        (cd "$repo" && bash "$TICKET_SCRIPT" transition "$tid" open in_progress 2>/dev/null) || true
        echo "STATUS $tid" >> "$session_log_dir/ops.log"
        (cd "$repo" && bash "$TICKET_SCRIPT" transition "$tid" in_progress closed 2>/dev/null) || true
        echo "STATUS $tid" >> "$session_log_dir/ops.log"
    done

    # 4 comments on own tickets (2 per ticket)
    for tid in "${session_tickets[@]}"; do
        (cd "$repo" && bash "$TICKET_SCRIPT" comment "$tid" "Comment from session $session_idx on $tid" 2>/dev/null) || true
        echo "COMMENT $tid" >> "$session_log_dir/ops.log"
        (cd "$repo" && bash "$TICKET_SCRIPT" comment "$tid" "Second comment from session $session_idx" 2>/dev/null) || true
        echo "COMMENT $tid" >> "$session_log_dir/ops.log"
    done

    return 0
}

# ── Main stress test ───────────────────────────────────────────────────────
test_concurrent_stress_5_sessions_10_ops() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local barrier_dir
    barrier_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$barrier_dir")

    local session_log_base
    session_log_base=$(mktemp -d)
    _CLEANUP_DIRS+=("$session_log_base")

    # Compute barrier deadline: now + 30 seconds
    local deadline
    deadline=$(( $(date +%s) + 30 ))

    # Launch 5 parallel sessions
    local pid1 pid2 pid3 pid4 pid5
    _make_stress_session "$repo" 1 "$barrier_dir" "$session_log_base/s1" "$deadline" &
    pid1=$!
    _make_stress_session "$repo" 2 "$barrier_dir" "$session_log_base/s2" "$deadline" &
    pid2=$!
    _make_stress_session "$repo" 3 "$barrier_dir" "$session_log_base/s3" "$deadline" &
    pid3=$!
    _make_stress_session "$repo" 4 "$barrier_dir" "$session_log_base/s4" "$deadline" &
    pid4=$!
    _make_stress_session "$repo" 5 "$barrier_dir" "$session_log_base/s5" "$deadline" &
    pid5=$!

    # Wait for all 5 processes individually and capture exit codes
    local exit1=0 exit2=0 exit3=0 exit4=0 exit5=0
    wait "$pid1" || exit1=$?
    wait "$pid2" || exit2=$?
    wait "$pid3" || exit3=$?
    wait "$pid4" || exit4=$?
    wait "$pid5" || exit5=$?

    # Assert all 5 sessions exited 0
    assert_eq "session 1 exit code" "0" "$exit1"
    assert_eq "session 2 exit code" "0" "$exit2"
    assert_eq "session 3 exit code" "0" "$exit3"
    assert_eq "session 4 exit code" "0" "$exit4"
    assert_eq "session 5 exit code" "0" "$exit5"

    # If any session failed, skip remaining assertions
    if [ "$exit1" -ne 0 ] || [ "$exit2" -ne 0 ] || [ "$exit3" -ne 0 ] || [ "$exit4" -ne 0 ] || [ "$exit5" -ne 0 ]; then
        assert_pass_if_clean "test_concurrent_stress_5_sessions_10_ops"
        return
    fi

    local tracker_dir="$repo/.tickets-tracker"

    # Count total event files across all ticket directories
    local total_events=0
    for tkt_dir in "$tracker_dir"/*/; do
        [ -d "$tkt_dir" ] || continue
        local count
        count=$(find "$tkt_dir" -maxdepth 1 -name '*.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
        total_events=$((total_events + count))
    done

    # Assert >= 50 total events (5 sessions x 10 ops = 50 events)
    if [ "$total_events" -ge 50 ]; then
        assert_eq "total events >= 50" "true" "true"
    else
        assert_eq "total events >= 50 (got $total_events)" "true" "false"
    fi

    # Validate each event file is valid JSON with required fields
    local json_valid_count=0
    local json_invalid_count=0
    for tkt_dir in "$tracker_dir"/*/; do
        [ -d "$tkt_dir" ] || continue
        for event_file in "$tkt_dir"*.json; do
            [ -f "$event_file" ] || continue
            # Skip cache files
            case "$(basename "$event_file")" in
                .*) continue ;;
            esac
            local valid
            valid=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    # Check required fields
    for field in ['event_type', 'timestamp', 'uuid', 'env_id']:
        if field not in data:
            print('missing:' + field)
            sys.exit(0)
    print('valid')
except Exception as e:
    print('error:' + str(e))
" "$event_file" 2>/dev/null) || valid="error"
            if [ "$valid" = "valid" ]; then
                json_valid_count=$((json_valid_count + 1))
            else
                json_invalid_count=$((json_invalid_count + 1))
            fi
        done
    done

    if [ "$json_valid_count" -ge 50 ] && [ "$json_invalid_count" -eq 0 ]; then
        assert_eq "all events valid JSON with required fields" "true" "true"
    else
        assert_eq "all events valid JSON (valid=$json_valid_count, invalid=$json_invalid_count)" "true" "false"
    fi

    # Assert all 50 events are committed: check git log commit count
    local commit_count
    commit_count=$(git -C "$tracker_dir" log --oneline 2>/dev/null | wc -l | tr -d ' ')
    # We expect >= 50 event commits + 2 init commits = 52
    if [ "$commit_count" -ge 52 ]; then
        assert_eq "all events in distinct git commits (>= 52 commits)" "true" "true"
    else
        assert_eq "all events in distinct git commits (got $commit_count, expected >= 52)" "true" "false"
    fi

    # Assert no bundling: verify no single commit contains event files from different sessions
    # Check recent 50 commits (the event commits)
    local bundling_violations=0
    local commit_hashes
    commit_hashes=$(git -C "$tracker_dir" log --format='%H' -50 2>/dev/null) || true
    for commit_hash in $commit_hashes; do
        local files_in_commit
        files_in_commit=$(git -C "$tracker_dir" show --name-only --format='' "$commit_hash" 2>/dev/null | grep '\.json$' | grep -v '\.cache' || true)
        local file_count
        file_count=$(echo "$files_in_commit" | grep -c . 2>/dev/null || echo "0")
        # Each event commit should have exactly 1 event file
        # (init commits have different files, so we only check commits with event files)
        if [ "$file_count" -gt 1 ]; then
            # Check if files span different ticket directories (different sessions)
            local unique_dirs
            unique_dirs=$(echo "$files_in_commit" | sed 's|/[^/]*$||' | sort -u | wc -l | tr -d ' ')
            if [ "$unique_dirs" -gt 1 ]; then
                bundling_violations=$((bundling_violations + 1))
            fi
        fi
    done

    assert_eq "no cross-session bundling in commits" "0" "$bundling_violations"

    # Cache layer test: run ticket show on sampled ticket IDs
    local show_failures=0
    local show_tested=0
    for s in 1 2 3 4 5; do
        local session_tickets_file="$session_log_base/s${s}/session_tickets.txt"
        if [ -f "$session_tickets_file" ]; then
            local first_tid
            first_tid=$(head -1 "$session_tickets_file")
            if [ -n "$first_tid" ]; then
                local show_exit=0
                local show_out
                show_out=$(cd "$repo" && bash "$TICKET_SCRIPT" show "$first_tid" 2>/dev/null) || show_exit=$?
                show_tested=$((show_tested + 1))
                if [ "$show_exit" -ne 0 ]; then
                    show_failures=$((show_failures + 1))
                else
                    # Verify output is valid JSON
                    python3 -c "import json,sys; json.loads(sys.argv[1])" "$show_out" 2>/dev/null || show_failures=$((show_failures + 1))
                fi
            fi
        fi
    done

    if [ "$show_tested" -ge 3 ] && [ "$show_failures" -eq 0 ]; then
        assert_eq "ticket show succeeds for sampled tickets after concurrent writes" "true" "true"
    else
        assert_eq "ticket show (tested=$show_tested, failures=$show_failures)" "true" "false"
    fi

    assert_pass_if_clean "test_concurrent_stress_5_sessions_10_ops"
}
test_concurrent_stress_5_sessions_10_ops

print_summary
