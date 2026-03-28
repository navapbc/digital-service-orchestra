#!/usr/bin/env bash
# plugins/dso/scripts/ticket-benchmark.sh
# Benchmark the ticket list or close command against a seeded ticket system.
#
# Usage: ticket-benchmark.sh [-n <count>] [--threshold <seconds>] [--mode=list|close]
#   -n <count>         Number of tickets to seed (default: 300; 0 = use existing repo tickets)
#   --threshold <secs> Max acceptable wall-clock time in seconds
#                      list defaults: 3s for n<=300, 10s for n<=1000, 30s for n>1000
#                      close default: 10s
#   --mode=list|close  Benchmark mode (default: list for backward compatibility)
#                      list: measures ticket list wall-clock time
#                      close: seeds a mixed population, measures ticket transition open->closed
#
# When run without -n (or with -n 0) inside a repo that already has a ticket
# system initialized, benchmarks the existing tickets.  Otherwise creates a
# temporary git repo, seeds N tickets, and benchmarks that.
#
# Output: "Elapsed: X.XXs for N tickets" to stdout (list mode)
#         "Elapsed: X.XXs for closing ticket with N non-archived tickets in tracker" (close mode)
# Exit 0 if elapsed < threshold, exit 1 if elapsed >= threshold.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST_SCRIPT="$SCRIPT_DIR/ticket-list.sh"
TICKET_SCRIPT="$SCRIPT_DIR/ticket"
REDUCER="$SCRIPT_DIR/ticket-reducer.py"

# ── Parse arguments ──────────────────────────────────────────────────────────
seed_count=0
threshold=""
mode="list"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n)
            seed_count="${2:?'-n requires a count argument'}"
            shift 2
            ;;
        --threshold)
            threshold="${2:?'--threshold requires a seconds argument'}"
            shift 2
            ;;
        --mode=*)
            mode="${1#--mode=}"
            shift
            ;;
        --mode)
            mode="${2:?'--mode requires list or close'}"
            shift 2
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            echo "Usage: ticket-benchmark.sh [-n <count>] [--threshold <seconds>] [--mode=list|close]" >&2
            exit 2
            ;;
    esac
done

# Validate mode
if [[ "$mode" != "list" && "$mode" != "close" ]]; then
    echo "Error: --mode must be 'list' or 'close', got '$mode'" >&2
    exit 2
fi

# ── Determine working mode ──────────────────────────────────────────────────
_tmp_dir=""
_close_repo=""
_cleanup() {
    if [[ -n "$_tmp_dir" ]] && [[ -d "$_tmp_dir" ]]; then
        rm -rf "$_tmp_dir"
    fi
}
trap _cleanup EXIT

tracker_dir=""

# ── Close mode: seed a mixed population and benchmark ticket transition ───────
if [[ "$mode" == "close" ]]; then
    if [[ "$seed_count" -gt 0 ]]; then
        # Create a temporary git repo with full ticket system for close benchmark
        _tmp_dir=$(mktemp -d)
        _close_repo="$_tmp_dir/repo"

        git init -q -b main "$_close_repo"
        git -C "$_close_repo" config user.email "benchmark@test.com"
        git -C "$_close_repo" config user.name "Benchmark"
        echo "init" > "$_close_repo/README.md"
        git -C "$_close_repo" add -A
        git -C "$_close_repo" commit -q -m "init"

        # Initialize ticket system in temp repo
        (cd "$_close_repo" && bash "$TICKET_SCRIPT" init >/dev/null 2>&1) || {
            echo "Error: failed to initialize ticket system in temp repo" >&2
            exit 1
        }

        tracker_dir="$_close_repo/.tickets-tracker"

        # Seed a realistic mixed population:
        # - 3 epics (open)
        # - 10 stories (in_progress) as children of first epic
        # - remaining tasks as open standalone
        # - 50 archived (closed) tasks
        # - 15+ dependency links between task pairs

        local_epic_count=3
        local_story_count=10
        # Non-archived count: epics + stories + tasks = seed_count
        local_archived_count=50
        local_task_count=$(( seed_count - local_epic_count - local_story_count - local_archived_count ))
        if [[ "$local_task_count" -lt 1 ]]; then
            local_task_count=1
        fi
        local_link_count=15

        first_epic_id=""

        # Create epics
        for (( i = 1; i <= local_epic_count; i++ )); do
            eid=$(cd "$_close_repo" && bash "$TICKET_SCRIPT" create epic "Benchmark epic $i" 2>/dev/null) || true
            if [[ $i -eq 1 ]]; then first_epic_id="$eid"; fi
        done

        # Create stories as children of first epic (transition to in_progress)
        if [[ -n "$first_epic_id" ]]; then
            for (( i = 1; i <= local_story_count; i++ )); do
                sid=$(cd "$_close_repo" && bash "$TICKET_SCRIPT" create story "Benchmark story $i" "$first_epic_id" 2>/dev/null) || true
                if [[ -n "$sid" ]]; then
                    (cd "$_close_repo" && bash "$TICKET_SCRIPT" transition "$sid" open in_progress >/dev/null 2>/dev/null) || true
                fi
            done
        fi

        # Create standalone open tasks and collect IDs for linking
        task_ids=()
        for (( i = 1; i <= local_task_count; i++ )); do
            tid=$(cd "$_close_repo" && bash "$TICKET_SCRIPT" create task "Benchmark task $i" 2>/dev/null) || true
            if [[ -n "$tid" ]]; then task_ids+=("$tid"); fi
        done

        # Create archived (closed) tasks
        for (( i = 1; i <= local_archived_count; i++ )); do
            aid=$(cd "$_close_repo" && bash "$TICKET_SCRIPT" create task "Archived task $i" 2>/dev/null) || true
            if [[ -n "$aid" ]]; then
                (cd "$_close_repo" && bash "$TICKET_SCRIPT" transition "$aid" open closed --reason="Fixed: benchmark seed" >/dev/null 2>/dev/null) || true
            fi
        done

        # Add dependency links between task pairs
        links_added=0
        pair_count="${#task_ids[@]}"
        for (( i = 0; i < pair_count - 1 && links_added < local_link_count; i += 2 )); do
            src="${task_ids[$i]}"
            tgt="${task_ids[$((i+1))]}"
            if [[ -n "$src" ]] && [[ -n "$tgt" ]]; then
                (cd "$_close_repo" && bash "$TICKET_SCRIPT" link "$src" "$tgt" depends_on >/dev/null 2>/dev/null) || true
                (( links_added++ )) || true
            fi
        done

        # Count non-archived tickets via reducer (authoritative source for archived state)
        non_archived_count=$(python3 "$REDUCER" --batch --exclude-archived "$tracker_dir" 2>/dev/null | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())))' 2>/dev/null) || non_archived_count="?"
    else
        # Use existing repo
        if [[ -n "${TICKETS_TRACKER_DIR:-}" ]]; then
            tracker_dir="$TICKETS_TRACKER_DIR"
            _close_repo="$(dirname "$tracker_dir")"
        else
            repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
                echo "Error: not inside a git repository and -n not specified" >&2
                exit 1
            }
            tracker_dir="$repo_root/.tickets-tracker"
            _close_repo="$repo_root"
        fi

        if [[ ! -d "$tracker_dir" ]]; then
            echo "Error: ticket system not initialized at $tracker_dir" >&2
            exit 1
        fi

        # Count non-archived tickets via reducer (consistent with seeded mode)
        non_archived_count=$(python3 "$REDUCER" --batch --exclude-archived "$tracker_dir" 2>/dev/null | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())))' 2>/dev/null) || non_archived_count="?"
    fi

    # Apply default threshold for close mode
    if [[ -z "$threshold" ]]; then
        threshold="10"
    fi

    # Create the target ticket: a simple task in open status with no children
    target_id=$(cd "$_close_repo" && bash "$TICKET_SCRIPT" create task "Target close benchmark task" 2>/dev/null) || {
        echo "Error: failed to create target ticket for close benchmark" >&2
        exit 1
    }

    if [[ -z "$target_id" ]]; then
        echo "Error: ticket create returned empty ID" >&2
        exit 1
    fi

    # Measure wall-clock time of full ticket transition open->closed
    start_time=$(python3 -c "import time; print(f'{time.time():.6f}')")

    (cd "$_close_repo" && bash "$TICKET_SCRIPT" transition "$target_id" open closed --reason="Fixed: benchmark" >/dev/null 2>/dev/null)

    end_time=$(python3 -c "import time; print(f'{time.time():.6f}')")

    elapsed=$(python3 -c "print(f'{float(\"$end_time\") - float(\"$start_time\"):.2f}')")

    echo "Elapsed: ${elapsed}s for closing ticket with $non_archived_count non-archived tickets in tracker"

    # Threshold check
    over=$(python3 -c "print('1' if float('$elapsed') >= float('$threshold') else '0')")

    if [[ "$over" == "1" ]]; then
        echo "FAIL: ${elapsed}s >= threshold ${threshold}s" >&2
        exit 1
    fi

    exit 0
fi

# ── List mode: seed and benchmark ticket list ─────────────────────────────────
if [[ "$seed_count" -gt 0 ]]; then
    # Create a temporary git repo and seed tickets
    _tmp_dir=$(mktemp -d)
    local_repo="$_tmp_dir/repo"

    git init -q -b main "$local_repo"
    git -C "$local_repo" config user.email "benchmark@test.com"
    git -C "$local_repo" config user.name "Benchmark"
    echo "init" > "$local_repo/README.md"
    git -C "$local_repo" add -A
    git -C "$local_repo" commit -q -m "init"

    # Create tracker directory (mimics ticket init without the worktree machinery)
    tracker_dir="$local_repo/.tickets-tracker"
    mkdir -p "$tracker_dir"

    # Seed N tickets with CREATE events
    for (( i = 1; i <= seed_count; i++ )); do
        ticket_id=$(python3 -c "import uuid; u=str(uuid.uuid4()); print(u[:4]+'-'+u[4:8])")
        ts=$(python3 -c "import time; print(int(time.time() * 1_000_000_000))")
        event_uuid=$(python3 -c "import uuid; print(str(uuid.uuid4()))")

        ticket_dir="$tracker_dir/$ticket_id"
        mkdir -p "$ticket_dir"

        python3 -c "
import json, sys
event = {
    'timestamp': int(sys.argv[1]),
    'uuid': sys.argv[2],
    'event_type': 'CREATE',
    'env_id': 'benchmark',
    'author': 'benchmark',
    'data': {
        'ticket_type': 'task',
        'title': 'Benchmark ticket ' + sys.argv[3]
    }
}
with open(sys.argv[4], 'w') as f:
    json.dump(event, f)
" "$ts" "$event_uuid" "$i" "$ticket_dir/${ts}-${event_uuid}-CREATE.json"
    done
else
    # Use the current repo's ticket system
    if [[ -n "${TICKETS_TRACKER_DIR:-}" ]]; then
        tracker_dir="$TICKETS_TRACKER_DIR"
    else
        repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
            echo "Error: not inside a git repository and -n not specified" >&2
            exit 1
        }
        tracker_dir="$repo_root/.tickets-tracker"
    fi

    if [[ ! -d "$tracker_dir" ]]; then
        echo "Error: ticket system not initialized at $tracker_dir" >&2
        exit 1
    fi

    # Count existing tickets
    seed_count=$(find "$tracker_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
fi

# ── Apply default threshold ──────────────────────────────────────────────────
if [[ -z "$threshold" ]]; then
    if [[ "$seed_count" -le 300 ]]; then
        threshold="3"
    elif [[ "$seed_count" -le 1000 ]]; then
        threshold="10"
    else
        threshold="30"
    fi
fi

# ── Measure ticket list wall-clock time ──────────────────────────────────────
start_time=$(python3 -c "import time; print(f'{time.time():.6f}')")

TICKETS_TRACKER_DIR="$tracker_dir" bash "$LIST_SCRIPT" >/dev/null 2>/dev/null

end_time=$(python3 -c "import time; print(f'{time.time():.6f}')")

# ── Compute elapsed and report ───────────────────────────────────────────────
elapsed=$(python3 -c "print(f'{float(\"$end_time\") - float(\"$start_time\"):.2f}')")

echo "Elapsed: ${elapsed}s for $seed_count tickets"

# ── Threshold check ──────────────────────────────────────────────────────────
over=$(python3 -c "print('1' if float('$elapsed') >= float('$threshold') else '0')")

if [[ "$over" == "1" ]]; then
    echo "FAIL: ${elapsed}s >= threshold ${threshold}s" >&2
    exit 1
fi

exit 0
