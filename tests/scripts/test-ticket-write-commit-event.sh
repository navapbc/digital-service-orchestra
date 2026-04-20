#!/usr/bin/env bash
# tests/scripts/test-ticket-write-commit-event.sh
# RED tests for bash-native write_commit_event (task f340-a070, story 29e5-0a74,
# epic 78fc-3858).
#
# Verifies that write_commit_event:
#   1. Spawns zero python3 processes (bash-native path).
#   2. Produces byte-identical JSON to Python's json.dumps(ensure_ascii=False,
#      separators=(',',':'), sort_keys=True) for the same inputs — including
#      unicode, backslash, and double-quote in the title field.
#   3. Handles two concurrent callers without corruption.
#   4. Does not silently corrupt output when the lock file is already held.
#   5. Returns exit code 0 on success.
#
# All 5 tests MUST FAIL (RED) against the current Python-backed implementation
# because the bash-native write_commit_event does not exist yet.
# They will pass once task f340-a070 implements the bash-native version.
#
# Usage: bash tests/scripts/test-ticket-write-commit-event.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"

source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-write-commit-event.sh ==="

# Track temp dirs / sentinel files for cleanup.
# git-fixtures.sh already sets _CLEANUP_DIRS and the EXIT trap.

# Resolve the real python3 so the PATH shim can delegate to it.
_REAL_PYTHON3="$(command -v python3 2>/dev/null || true)"
if [ -z "$_REAL_PYTHON3" ] || [ ! -x "$_REAL_PYTHON3" ]; then
    _REAL_PYTHON3="/usr/bin/python3"
fi

# ── Helper: create a PATH shim dir with a counting python3 wrapper ────────────
# The shim appends "CALLED" to <sentinel> and then execs the real python3 so
# any downstream logic still functions correctly.
_make_python3_shim() {
    local sentinel="$1"
    local shim_dir
    shim_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$shim_dir")
    cat > "$shim_dir/python3" <<EOF
#!/usr/bin/env bash
echo "CALLED" >> "$sentinel"
exec "$_REAL_PYTHON3" "\$@"
EOF
    chmod +x "$shim_dir/python3"
    echo "$shim_dir"
}

# ── Helper: create a fresh temp git repo with ticket system initialized ────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: build a minimal valid event JSON temp file ────────────────────────
# Usage: _make_event_json <repo> <ticket_id> <title>
# Writes a CREATE event JSON to a temp file and prints its path.
_make_event_json() {
    local repo="$1"
    local ticket_id="$2"
    local title="$3"
    local tmp_event
    tmp_event=$(mktemp)
    _CLEANUP_FILES+=("$tmp_event") 2>/dev/null || true
    # Build a minimal CREATE event JSON with the supplied title.
    python3 - "$tmp_event" "$ticket_id" "$title" <<'PYEOF'
import json, sys, uuid, datetime

out_path = sys.argv[1]
ticket_id = sys.argv[2]
title = sys.argv[3]

event = {
    "event_type": "CREATE",
    "timestamp": datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%S%f") + "Z",
    "uuid": str(uuid.uuid4()).replace("-", "")[:12],
    "data": {
        "ticket_id": ticket_id,
        "title": title,
        "type": "task",
        "priority": 4,
        "status": "open",
        "tags": [],
    },
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(event, f, ensure_ascii=False)
PYEOF
    echo "$tmp_event"
}

# ── Helper: create a ticket directory and return the ticket_id ────────────────
_init_ticket_dir() {
    local repo="$1"
    local ticket_id="ti00-test"
    mkdir -p "$repo/.tickets-tracker/$ticket_id"
    echo "$ticket_id"
}

# ── Test 1: write_commit_event spawns zero python3 processes ──────────────────
test_write_commit_event_no_python3() {
    local repo ticket_id event_json sentinel shim_dir
    repo=$(_make_test_repo)
    ticket_id=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "No-python3 test" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$ticket_id" ]; then
        echo "  setup failed: ticket create returned empty ID"
        return 1
    fi

    event_json=$(_make_event_json "$repo" "$ticket_id" "No-python3 test")

    sentinel=$(mktemp)
    rm -f "$sentinel"  # sentinel is absent until python3 is called
    _CLEANUP_FILES+=("$sentinel") 2>/dev/null || true

    shim_dir=$(_make_python3_shim "$sentinel")

    # Source ticket-lib and call write_commit_event with shimmed PATH.
    local exit_code=0
    (
        cd "$repo"
        PATH="$shim_dir:$PATH" _TICKET_TEST_NO_SYNC=1 \
            bash -c "
                source '$TICKET_LIB'
                write_commit_event '$ticket_id' '$event_json'
            " 2>/dev/null
    ) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        echo "  write_commit_event exited $exit_code (expected 0)"
        return 1
    fi

    if [ -f "$sentinel" ]; then
        local call_count
        call_count=$(wc -l < "$sentinel" | tr -d ' ')
        echo "  sentinel exists: python3 was spawned $call_count time(s) (expected 0)"
        return 1
    fi
    return 0
}

# ── Test 2: write_commit_event output is byte-identical to Python's json.dumps ──
# Uses ensure_ascii=False, separators=(',',':'), sort_keys=True for comparison.
# Inputs include unicode (título), backslash, and double-quote characters.
#
# RED rationale: the current Python-backed implementation writes JSON via
# json.dump(data) with default spacing/key-ordering (e.g., ": " separators, no
# sort_keys), so the raw file bytes will NOT match the compact sorted canonical
# form.  The bash-native implementation MUST produce that canonical form.
test_write_commit_event_json_byte_exact() {
    local repo ticket_id sentinel shim_dir
    repo=$(_make_test_repo)
    ticket_id=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "Byte-exact test" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$ticket_id" ]; then
        echo "  setup failed: ticket create returned empty ID"
        return 1
    fi

    # Craft a title with unicode, backslash, and double-quote.
    local test_title='título \"back\\slash\"'

    # Build the event JSON via Python (helper uses python3 — fine here because
    # we are testing the *output* of write_commit_event, not its internals).
    local event_json
    event_json=$(_make_event_json "$repo" "$ticket_id" "$test_title")

    # Derive the expected canonical raw bytes once from the input data.
    local expected_raw
    expected_raw=$(python3 - "$event_json" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
# Canonical form: compact separators, sorted keys, no trailing newline.
import sys
sys.stdout.buffer.write(
    json.dumps(data, ensure_ascii=False, separators=(',', ':'), sort_keys=True).encode('utf-8')
)
PYEOF
    ) || {
        echo "  setup failed: python3 could not produce expected JSON"
        return 1
    }

    # Now call write_commit_event with a python3 sentinel so we can assert
    # whether python3 was invoked (the RED condition for the bash-native story).
    sentinel=$(mktemp)
    rm -f "$sentinel"
    _CLEANUP_FILES+=("$sentinel") 2>/dev/null || true
    shim_dir=$(_make_python3_shim "$sentinel")

    local exit_code=0
    (
        cd "$repo"
        PATH="$shim_dir:$PATH" _TICKET_TEST_NO_SYNC=1 bash -c "
            source '$TICKET_LIB'
            write_commit_event '$ticket_id' '$event_json'
        " 2>/dev/null
    ) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        echo "  write_commit_event exited $exit_code (expected 0)"
        return 1
    fi

    # Find the written event file.
    local tracker_dir="$repo/.tickets-tracker"
    local event_file
    event_file=$(find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-CREATE.json' ! -name '.*' 2>/dev/null | sort | tail -1)
    if [ -z "$event_file" ] || [ ! -f "$event_file" ]; then
        echo "  no CREATE event file found under $tracker_dir/$ticket_id"
        return 1
    fi

    # Read the raw bytes written by write_commit_event (no re-serialisation).
    local actual_raw
    actual_raw=$(python3 - "$event_file" <<'PYEOF'
import sys
sys.stdout.buffer.write(open(sys.argv[1], 'rb').read().rstrip(b'\n'))
PYEOF
    )

    # RED assertion 1: python3 must NOT have been spawned.
    if [ -f "$sentinel" ]; then
        local call_count
        call_count=$(wc -l < "$sentinel" | tr -d ' ')
        echo "  python3 was spawned $call_count time(s) — bash-native implementation required"
        return 1
    fi

    # RED assertion 2: raw bytes must match the canonical form exactly.
    if [ "$expected_raw" != "$actual_raw" ]; then
        echo "  JSON byte mismatch (current impl uses non-canonical separators/ordering)"
        echo "    expected (compact+sorted): $expected_raw"
        echo "    actual (current impl):     $actual_raw"
        return 1
    fi
    return 0
}

# ── Test 3: two concurrent write_commit_event calls produce valid, non-corrupt files
# RED rationale: the bash-native implementation must use flock without python3.
# The current Python-backed path spawns python3 processes per call; this test
# asserts zero python3 spawns during the concurrent writes AND that both event
# files are valid JSON (no corruption/interleaving).
test_write_commit_event_concurrent_no_corruption() {
    local repo ticket_id_a ticket_id_b event_json_a event_json_b
    repo=$(_make_test_repo)

    # Create two separate tickets so each gets its own event file.
    ticket_id_a=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "Concurrent A" 2>/dev/null | tr -d '[:space:]')
    ticket_id_b=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "Concurrent B" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$ticket_id_a" ] || [ -z "$ticket_id_b" ]; then
        echo "  setup failed: ticket create returned empty IDs"
        return 1
    fi

    event_json_a=$(_make_event_json "$repo" "$ticket_id_a" "Concurrent A")
    event_json_b=$(_make_event_json "$repo" "$ticket_id_b" "Concurrent B")

    # Sentinel for python3 spawn counting.
    local sentinel
    sentinel=$(mktemp)
    rm -f "$sentinel"
    _CLEANUP_FILES+=("$sentinel") 2>/dev/null || true
    local shim_dir
    shim_dir=$(_make_python3_shim "$sentinel")

    local exit_a=0 exit_b=0

    # Launch both write_commit_event calls as background subshells with the shim.
    (
        cd "$repo" || exit 1
        PATH="$shim_dir:$PATH" _TICKET_TEST_NO_SYNC=1 bash -c "
            source '$TICKET_LIB'
            write_commit_event '$ticket_id_a' '$event_json_a'
        " 2>/dev/null
    ) &
    local pid_a=$!

    (
        cd "$repo" || exit 1
        PATH="$shim_dir:$PATH" _TICKET_TEST_NO_SYNC=1 bash -c "
            source '$TICKET_LIB'
            write_commit_event '$ticket_id_b' '$event_json_b'
        " 2>/dev/null
    ) &
    local pid_b=$!

    wait "$pid_a" || exit_a=$?
    wait "$pid_b" || exit_b=$?

    # Both calls must have succeeded (exit 0).
    if [ "$exit_a" -ne 0 ] || [ "$exit_b" -ne 0 ]; then
        echo "  concurrent write_commit_event failed: exit_a=$exit_a exit_b=$exit_b"
        return 1
    fi

    # RED assertion: python3 must NOT have been spawned by either call.
    if [ -f "$sentinel" ]; then
        local call_count
        call_count=$(wc -l < "$sentinel" | tr -d ' ')
        echo "  python3 was spawned $call_count time(s) during concurrent writes (expected 0)"
        return 1
    fi

    # Both event files must exist and be valid JSON (no corruption/interleaving).
    local tracker_dir="$repo/.tickets-tracker"
    local event_file_a event_file_b
    event_file_a=$(find "$tracker_dir/$ticket_id_a" -maxdepth 1 -name '*.json' ! -name '.*' 2>/dev/null | sort | tail -1)
    event_file_b=$(find "$tracker_dir/$ticket_id_b" -maxdepth 1 -name '*.json' ! -name '.*' 2>/dev/null | sort | tail -1)

    for f in "$event_file_a" "$event_file_b"; do
        if [ -z "$f" ] || [ ! -f "$f" ]; then
            echo "  event file missing for one of the concurrent writers"
            return 1
        fi
        if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
            echo "  event file is invalid JSON: $f"
            return 1
        fi
    done
    return 0
}

# ── Test 4: write_commit_event with lock held does not silently corrupt output ──
# Holds the flock lock in a background process, then calls write_commit_event
# with FLOCK_STAGE_COMMIT_TIMEOUT=2.  Verifies the function either waits and
# succeeds (with a valid event file) OR fails with a clear non-zero exit code
# and a diagnostic message — never silently corrupts or loses the event.
#
# RED rationale: the bash-native implementation is required to use shell-level
# flock (not python3 fcntl).  The current Python-backed path spawns python3
# for every flock acquire; this test asserts zero python3 spawns in addition
# to the behavioral no-corruption invariant.
test_write_commit_event_retry_on_locked_file() {
    local repo ticket_id event_json
    repo=$(_make_test_repo)
    ticket_id=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "Lock-retry test" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$ticket_id" ]; then
        echo "  setup failed: ticket create returned empty ID"
        return 1
    fi

    event_json=$(_make_event_json "$repo" "$ticket_id" "Lock-retry test")

    local tracker_dir
    tracker_dir=$(cd "$repo/.tickets-tracker" && pwd -P)
    local lock_file="$tracker_dir/.ticket-write.lock"

    # Hold the lock for 30 s using python3 fcntl (setup only — not under test).
    local lock_holder_pid
    (
        python3 -c "
import fcntl, os, time
fd = os.open('$lock_file', os.O_CREAT | os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(30)
os.close(fd)
" 2>/dev/null
    ) &
    lock_holder_pid=$!

    # Give the lock holder a moment to acquire the lock.
    sleep 0.3

    # Sentinel for python3 spawn counting by write_commit_event itself.
    local sentinel
    sentinel=$(mktemp)
    rm -f "$sentinel"
    _CLEANUP_FILES+=("$sentinel") 2>/dev/null || true
    local shim_dir
    shim_dir=$(_make_python3_shim "$sentinel")

    local exit_code=0
    local out_file
    out_file=$(mktemp)
    _CLEANUP_FILES+=("$out_file") 2>/dev/null || true

    # Use a short flock timeout so the test does not block for 30 s.
    (
        cd "$repo"
        PATH="$shim_dir:$PATH" FLOCK_STAGE_COMMIT_TIMEOUT=2 _TICKET_TEST_NO_SYNC=1 bash -c "
            source '$TICKET_LIB'
            write_commit_event '$ticket_id' '$event_json'
        " >"$out_file" 2>&1
    ) || exit_code=$?

    # Kill the lock holder.
    kill "$lock_holder_pid" 2>/dev/null || true
    wait "$lock_holder_pid" 2>/dev/null || true

    # The bash-native implementation must NOT silently succeed when it could not
    # acquire the lock — it must either return non-zero OR have written a valid
    # event file.  What is NOT acceptable is exit 0 with no event file.
    local event_file
    event_file=$(find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*.json' ! -name '.*' 2>/dev/null | sort | tail -1)

    if [ "$exit_code" -eq 0 ]; then
        # Claimed success — event file must exist and be valid JSON.
        if [ -z "$event_file" ] || [ ! -f "$event_file" ]; then
            echo "  write_commit_event returned 0 but no event file was written (silent loss)"
            return 1
        fi
        if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$event_file" 2>/dev/null; then
            echo "  write_commit_event returned 0 but event file is corrupt JSON: $event_file"
            return 1
        fi
    else
        # Non-zero exit — acceptable.  Verify it emitted a diagnostic message.
        if [ ! -s "$out_file" ]; then
            echo "  write_commit_event returned $exit_code with no stderr/stdout (silent fail)"
            return 1
        fi
    fi

    # RED assertion: python3 must NOT have been spawned by write_commit_event.
    # The shim wraps the real python3 so the lock-holder setup above still works,
    # but every write_commit_event-internal python3 call will be recorded.
    if [ -f "$sentinel" ]; then
        local call_count
        call_count=$(wc -l < "$sentinel" | tr -d ' ')
        echo "  python3 was spawned $call_count time(s) by write_commit_event (expected 0)"
        return 1
    fi

    return 0
}

# ── Test 5: write_commit_event returns 0 on success ───────────────────────────
test_write_commit_event_exit_codes() {
    local repo ticket_id event_json sentinel shim_dir
    repo=$(_make_test_repo)
    ticket_id=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "Exit-code test" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$ticket_id" ]; then
        echo "  setup failed: ticket create returned empty ID"
        return 1
    fi

    event_json=$(_make_event_json "$repo" "$ticket_id" "Exit-code test")

    sentinel=$(mktemp)
    rm -f "$sentinel"
    _CLEANUP_FILES+=("$sentinel") 2>/dev/null || true
    shim_dir=$(_make_python3_shim "$sentinel")

    local exit_code=0
    (
        cd "$repo"
        PATH="$shim_dir:$PATH" _TICKET_TEST_NO_SYNC=1 bash -c "
            source '$TICKET_LIB'
            write_commit_event '$ticket_id' '$event_json'
        " 2>/dev/null
    ) || exit_code=$?

    # RED: the current implementation spawns python3; the bash-native version
    # must return 0 AND have spawned zero python3 processes.
    if [ "$exit_code" -ne 0 ]; then
        echo "  write_commit_event exited $exit_code (expected 0)"
        return 1
    fi

    # The test is RED because the no-python3 requirement is violated.
    if [ -f "$sentinel" ]; then
        local call_count
        call_count=$(wc -l < "$sentinel" | tr -d ' ')
        echo "  python3 was spawned $call_count time(s) — bash-native implementation required"
        return 1
    fi

    return 0
}

# ── Runner ─────────────────────────────────────────────────────────────────────
pass=0
fail=0
for fn in \
    test_write_commit_event_no_python3 \
    test_write_commit_event_json_byte_exact \
    test_write_commit_event_concurrent_no_corruption \
    test_write_commit_event_retry_on_locked_file \
    test_write_commit_event_exit_codes
do
    if $fn; then
        echo "PASS: $fn"
        pass=$((pass + 1))
    else
        echo "FAIL: $fn"
        fail=$((fail + 1))
    fi
done

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
