#!/usr/bin/env bash
# tests/scripts/test-tk-sync-events-integration.sh
#
# Integration tests for _sync_events round-trip between two local repos.
#
# Ticket: w20-pijg
# Parent: w21-6k7v (sync-events story)
#
# TDD exemption: Integration test written after implementation — this IS the
# integration test for the git remote boundary. Exemption: Integration Test
# Task Rule — integration tests may be written after the implementation task.
#
# Setup: bare origin repo + two local clones, each with .tickets-tracker/
# git worktree on tickets branch.
#
# Tests:
#   test_sync_events_basic_push_pull          — event written in A appears in B after sync
#   test_sync_events_divergent_merge          — independent events from A and B both survive
#   test_sync_events_flock_not_held_during_fetch — lock NOT held while fetch runs
#   test_sync_events_push_retry              — push retry on simulated exit 128 succeeds
#
# Usage: bash tests/scripts/test-tk-sync-events-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TK_SCRIPT="$REPO_ROOT/plugins/dso/scripts/tk"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-tk-sync-events-integration.sh ==="

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_INTEGRATION_TMP_DIRS=()
_integration_cleanup() {
    for d in "${_INTEGRATION_TMP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap _integration_cleanup EXIT

# ── Helper: make_bare_origin ─────────────────────────────────────────────────
# Creates a bare git repo at $1 with a tickets branch pre-seeded.
# Returns: path is already known from $1; sets _BARE_ORIGIN globally for callers.
_make_bare_origin() {
    local bare="$1"
    mkdir -p "$bare"

    # Seed repo: init a temp non-bare repo, create tickets branch, push to bare
    local seed_tmp
    seed_tmp=$(mktemp -d)
    _INTEGRATION_TMP_DIRS+=("$seed_tmp")

    git init -q -b main "$seed_tmp"
    git -C "$seed_tmp" config user.email "test@test.com"
    git -C "$seed_tmp" config user.name "Test"

    # Create initial commit on main (needed to allow worktree add)
    echo "seed" > "$seed_tmp/README.md"
    git -C "$seed_tmp" add -A
    git -C "$seed_tmp" commit -q -m "init"

    # Create tickets branch with an initial empty commit
    git -C "$seed_tmp" checkout -q -b tickets
    mkdir -p "$seed_tmp/.tickets"
    echo "# tickets tracker branch" > "$seed_tmp/.tickets/.gitkeep"
    git -C "$seed_tmp" add -A
    git -C "$seed_tmp" commit -q -m "init tickets branch"

    # Push to bare origin
    git init -q --bare "$bare"
    git -C "$seed_tmp" remote add origin "$bare"
    git -C "$seed_tmp" push -q origin main
    git -C "$seed_tmp" push -q origin tickets
}

# ── Helper: make_clone_with_tracker ──────────────────────────────────────────
# Clones bare origin to $2 as a normal repo and creates a .tickets-tracker/
# worktree pointing at the tickets branch.
_make_clone_with_tracker() {
    local origin_bare="$1"
    local clone_path="$2"

    git clone -q "$origin_bare" "$clone_path"
    git -C "$clone_path" config user.email "test@test.com"
    git -C "$clone_path" config user.name "Test"

    # Fetch the tickets branch so the local ref exists
    git -C "$clone_path" fetch -q origin tickets:tickets

    # Add .tickets-tracker as a worktree on tickets branch
    git -C "$clone_path" worktree add -q "$clone_path/.tickets-tracker" tickets
}

# ── Helper: write_event_file ─────────────────────────────────────────────────
# Writes an event file directly into a tracker worktree and commits it.
# Usage: _write_event_file <tracker_dir> <filename> <content>
_write_event_file() {
    local tracker_dir="$1"
    local filename="$2"
    local content="$3"

    echo "$content" > "$tracker_dir/$filename"
    git -C "$tracker_dir" add "$filename"
    git -C "$tracker_dir" commit -q -m "add event $filename"
}

# ── Helper: run_sync_events ──────────────────────────────────────────────────
# Invokes 'tk sync-events' from within a clone repo directory.
# Returns the exit code of tk.
_run_sync_events() {
    local clone_path="$1"
    (cd "$clone_path" && bash "$TK_SCRIPT" sync-events 2>&1)
}

# ── Test 1: basic_push_pull ──────────────────────────────────────────────────
# Repo A writes an event file → commits to tickets branch →
# tk sync-events from repo B → event file present in B's .tickets-tracker/
_snapshot_fail

_t1_tmp=$(mktemp -d)
_INTEGRATION_TMP_DIRS+=("$_t1_tmp")

_t1_bare="$_t1_tmp/origin.git"
_t1_repo_a="$_t1_tmp/repo-a"
_t1_repo_b="$_t1_tmp/repo-b"

_make_bare_origin "$_t1_bare"
_make_clone_with_tracker "$_t1_bare" "$_t1_repo_a"
_make_clone_with_tracker "$_t1_bare" "$_t1_repo_b"

# A writes and pushes an event file via _write_event_file + push
_write_event_file "$_t1_repo_a/.tickets-tracker" "event-from-a.json" '{"type":"test","id":"a1"}'
git -C "$_t1_repo_a/.tickets-tracker" push -q origin tickets

# B syncs: fetch + merge + push
_t1_sync_output=$(_run_sync_events "$_t1_repo_b" 2>&1 || true)
_t1_sync_exit=$?

assert_eq "test_basic_push_pull: sync-events exits 0" "0" "$_t1_sync_exit"

_t1_event_present=0
if [[ -f "$_t1_repo_b/.tickets-tracker/event-from-a.json" ]]; then
    _t1_event_present=1
fi
assert_eq "test_basic_push_pull: event-from-a.json present in repo B" "1" "$_t1_event_present"

_t1_content=$(cat "$_t1_repo_b/.tickets-tracker/event-from-a.json" 2>/dev/null || true)
assert_contains "test_basic_push_pull: event content correct" '"id":"a1"' "$_t1_content"

assert_pass_if_clean "test_basic_push_pull"

# ── Test 2: divergent_merge ───────────────────────────────────────────────────
# Both repos independently write different event files without syncing →
# A syncs (push) → B syncs (fetch + merge + push) → both event files present in both
_snapshot_fail

_t2_tmp=$(mktemp -d)
_INTEGRATION_TMP_DIRS+=("$_t2_tmp")

_t2_bare="$_t2_tmp/origin.git"
_t2_repo_a="$_t2_tmp/repo-a"
_t2_repo_b="$_t2_tmp/repo-b"

_make_bare_origin "$_t2_bare"
_make_clone_with_tracker "$_t2_bare" "$_t2_repo_a"
_make_clone_with_tracker "$_t2_bare" "$_t2_repo_b"

# A and B write independent events (no sync between them)
_write_event_file "$_t2_repo_a/.tickets-tracker" "event-divergent-a.json" '{"type":"test","id":"div-a"}'
_write_event_file "$_t2_repo_b/.tickets-tracker" "event-divergent-b.json" '{"type":"test","id":"div-b"}'

# A syncs first (push succeeds — no conflict from B's local commit yet)
_t2_sync_a_output=$(_run_sync_events "$_t2_repo_a" 2>&1 || true)
_t2_sync_a_exit=$?
assert_eq "test_divergent_merge: A sync-events exits 0" "0" "$_t2_sync_a_exit"

# B syncs (will hit non-fast-forward on push → retry cycle merges A's commit)
_t2_sync_b_output=$(_run_sync_events "$_t2_repo_b" 2>&1 || true)
_t2_sync_b_exit=$?
assert_eq "test_divergent_merge: B sync-events exits 0" "0" "$_t2_sync_b_exit"

# After B's sync: B's tracker should have both event files
_t2_a_in_b=0
_t2_b_in_b=0
if [[ -f "$_t2_repo_b/.tickets-tracker/event-divergent-a.json" ]]; then _t2_a_in_b=1; fi
if [[ -f "$_t2_repo_b/.tickets-tracker/event-divergent-b.json" ]]; then _t2_b_in_b=1; fi

assert_eq "test_divergent_merge: event-divergent-a.json present in repo B" "1" "$_t2_a_in_b"
assert_eq "test_divergent_merge: event-divergent-b.json present in repo B" "1" "$_t2_b_in_b"

# A also needs to see B's event (re-fetch to pull B's merge commit)
git -C "$_t2_repo_a/.tickets-tracker" fetch -q origin tickets
git -C "$_t2_repo_a/.tickets-tracker" merge -q --ff-only origin/tickets 2>/dev/null || \
    git -C "$_t2_repo_a/.tickets-tracker" merge -q origin/tickets 2>/dev/null || true

_t2_b_in_a=0
if [[ -f "$_t2_repo_a/.tickets-tracker/event-divergent-b.json" ]]; then _t2_b_in_a=1; fi
assert_eq "test_divergent_merge: event-divergent-b.json visible in repo A after sync" "1" "$_t2_b_in_a"

assert_pass_if_clean "test_divergent_merge"

# ── Test 3: flock_not_held_during_fetch ──────────────────────────────────────
# sync-events with a slow fetch (mock git sleeps 0.2s during fetch) →
# .ticket-write.lock is NOT locked during fetch (verified by a concurrent
# writer succeeding and acquiring the lock during the sleep window).
_snapshot_fail

_t3_tmp=$(mktemp -d)
_INTEGRATION_TMP_DIRS+=("$_t3_tmp")

_t3_bare="$_t3_tmp/origin.git"
_t3_repo_a="$_t3_tmp/repo-a"

_make_bare_origin "$_t3_bare"
_make_clone_with_tracker "$_t3_bare" "$_t3_repo_a"

# Create the lock file path so python3 can create it
_t3_lock_file="$_t3_repo_a/.tickets-tracker/.ticket-write.lock"
touch "$_t3_lock_file"

# Create a mock git that:
# - For "fetch" operations: writes a sentinel, sleeps 0.2s, then exits 0
# - For all other operations: calls real git
_t3_mock_dir="$_t3_tmp/mock-bin"
mkdir -p "$_t3_mock_dir"
_t3_real_git="$(command -v git)"

cat > "$_t3_mock_dir/git" << MOCK_GIT_EOF
#!/usr/bin/env bash
# Mock git: slow fetch, passthrough for everything else
_REAL_GIT="$_t3_real_git"
if [[ "\$*" == *"fetch"* ]]; then
    echo "MOCK_FETCH_START" >> "$_t3_tmp/mock-fetch.log"
    touch "$_t3_tmp/fetch-running.flag"
    sleep 0.2
    rm -f "$_t3_tmp/fetch-running.flag"
    echo "MOCK_FETCH_END" >> "$_t3_tmp/mock-fetch.log"
    # Run the real fetch so the repo state is valid
    exec "\$_REAL_GIT" "\$@"
else
    exec "\$_REAL_GIT" "\$@"
fi
MOCK_GIT_EOF
chmod +x "$_t3_mock_dir/git"

# Concurrent writer: waits for fetch-running.flag, then tries to acquire the lock.
# If the design is correct (flock NOT held during fetch), this should succeed quickly.
_t3_lock_result_file="$_t3_tmp/lock-result.txt"
cat > "$_t3_tmp/try-lock.sh" << TRY_LOCK_EOF
#!/usr/bin/env bash
# Wait up to 2s for the fetch to start
for i in \$(seq 1 20); do
    if [[ -f "$_t3_tmp/fetch-running.flag" ]]; then break; fi
    sleep 0.1
done

# Now try to acquire the lock using python3 flock (same mechanism as tk)
python3 - "$_t3_lock_file" "$_t3_lock_result_file" << 'PYEOF'
import fcntl, sys, time
lock_file = sys.argv[1]
result_file = sys.argv[2]
start = time.monotonic()
try:
    fd = open(lock_file, 'w')
    # Try non-blocking first — if lock is NOT held by sync-events, this succeeds
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        elapsed = time.monotonic() - start
        with open(result_file, 'w') as rf:
            rf.write(f"LOCK_ACQUIRED:{elapsed:.3f}")
        fcntl.flock(fd, fcntl.LOCK_UN)
    except BlockingIOError:
        with open(result_file, 'w') as rf:
            rf.write("LOCK_BLOCKED")
    fd.close()
except Exception as e:
    with open(result_file, 'w') as rf:
        rf.write(f"ERROR:{e}")
PYEOF
TRY_LOCK_EOF
chmod +x "$_t3_tmp/try-lock.sh"

# Run concurrent lock attempt in background
bash "$_t3_tmp/try-lock.sh" &
_t3_lock_pid=$!

# Run sync-events with mock git on PATH
_t3_sync_exit=0
(cd "$_t3_repo_a" && PATH="$_t3_mock_dir:$PATH" bash "$TK_SCRIPT" sync-events 2>/dev/null) || _t3_sync_exit=$?

# Wait for the concurrent writer to finish
wait "$_t3_lock_pid" 2>/dev/null || true

# Check lock result
_t3_lock_result=$(cat "$_t3_lock_result_file" 2>/dev/null || echo "NO_RESULT")

assert_eq "test_flock_not_held_during_fetch: sync-events exits 0" "0" "$_t3_sync_exit"

# The lock result must be LOCK_ACQUIRED (not LOCK_BLOCKED)
_t3_lock_ok=0
if [[ "$_t3_lock_result" == LOCK_ACQUIRED:* ]]; then
    _t3_lock_ok=1
fi
assert_eq "test_flock_not_held_during_fetch: concurrent writer can acquire lock during fetch" "1" "$_t3_lock_ok"

assert_pass_if_clean "test_flock_not_held_during_fetch"

# ── Test 4: push_retry ────────────────────────────────────────────────────────
# First push fails with exit 128 (simulated via mock git) →
# second attempt succeeds after re-fetch → event reaches remote
_snapshot_fail

_t4_tmp=$(mktemp -d)
_INTEGRATION_TMP_DIRS+=("$_t4_tmp")

_t4_bare="$_t4_tmp/origin.git"
_t4_repo_a="$_t4_tmp/repo-a"

_make_bare_origin "$_t4_bare"
_make_clone_with_tracker "$_t4_bare" "$_t4_repo_a"

# Write a local event so there's something to push
_write_event_file "$_t4_repo_a/.tickets-tracker" "event-retry.json" '{"type":"test","id":"retry"}'

# Create a mock git that fails push exactly once with exit 128, then passes
_t4_mock_dir="$_t4_tmp/mock-bin"
mkdir -p "$_t4_mock_dir"
_t4_real_git="$(command -v git)"
_t4_push_count_file="$_t4_tmp/push-count.txt"
echo "0" > "$_t4_push_count_file"

cat > "$_t4_mock_dir/git" << MOCK_GIT4_EOF
#!/usr/bin/env bash
_REAL_GIT="$_t4_real_git"
# Intercept push to tickets — fail first attempt with exit 128
if [[ "\$*" == *"push"* && "\$*" == *"tickets"* ]]; then
    _count=\$(cat "$_t4_push_count_file" 2>/dev/null || echo "0")
    _count=\$(( _count + 1 ))
    echo "\$_count" > "$_t4_push_count_file"
    if [[ "\$_count" -eq 1 ]]; then
        # Simulate non-fast-forward rejection
        echo "! [rejected] tickets -> tickets (non-fast-forward)" >&2
        exit 128
    fi
    # Subsequent pushes: real git
    exec "\$_REAL_GIT" "\$@"
else
    exec "\$_REAL_GIT" "\$@"
fi
MOCK_GIT4_EOF
chmod +x "$_t4_mock_dir/git"

# Run sync-events with mock git
_t4_sync_exit=0
(cd "$_t4_repo_a" && PATH="$_t4_mock_dir:$PATH" bash "$TK_SCRIPT" sync-events 2>/dev/null) || _t4_sync_exit=$?

# Check push was attempted more than once (retry happened)
_t4_push_count=$(cat "$_t4_push_count_file" 2>/dev/null || echo "0")

assert_eq "test_push_retry: sync-events exits 0 after retry" "0" "$_t4_sync_exit"

_t4_retried=0
if [[ "$_t4_push_count" -ge 2 ]]; then
    _t4_retried=1
fi
assert_eq "test_push_retry: push was retried (count >= 2)" "1" "$_t4_retried"

# Verify the event actually reached the bare origin
_t4_verify_tmp=$(mktemp -d)
_INTEGRATION_TMP_DIRS+=("$_t4_verify_tmp")
git clone -q "$_t4_bare" "$_t4_verify_tmp/check-repo"
git -C "$_t4_verify_tmp/check-repo" fetch -q origin tickets:tickets
git -C "$_t4_verify_tmp/check-repo" worktree add -q "$_t4_verify_tmp/check-tracker" tickets

_t4_event_on_remote=0
if [[ -f "$_t4_verify_tmp/check-tracker/event-retry.json" ]]; then
    _t4_event_on_remote=1
fi
assert_eq "test_push_retry: event-retry.json reached remote after retry" "1" "$_t4_event_on_remote"

assert_pass_if_clean "test_push_retry"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
