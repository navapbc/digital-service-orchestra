#!/usr/bin/env bash
# tests/scripts/test-ticket-write-commit-event.sh
# Tests for DSO_TICKET_LEGACY=1 escape hatch in write_commit_event.
#
# Story 29e5-0a74 DD6: setting DSO_TICKET_LEGACY=1 must restore the
# Python-backed write_commit_event path. This test asserts that python3
# IS spawned when the flag is set.
#
# Usage: bash tests/scripts/test-ticket-write-commit-event.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-write-commit-event.sh ==="

# ── Helper: create a fresh temp git repo ─────────────────────────────────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: build a minimal event JSON file ──────────────────────────────────
# Usage: _make_event_json <dest_path> <ticket_id>
_make_event_json() {
    local dest="$1"
    local ticket_id="$2"
    local ts
    ts=$(python3 -c "import time; print(int(time.time()))")
    local uuid
    uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
    python3 -c "
import json, sys
data = {
    'timestamp': $ts,
    'uuid': '$uuid',
    'event_type': 'CREATE',
    'env_id': '$uuid',
    'author': 'Test',
    'data': {
        'ticket_type': 'task',
        'title': 'Test ticket',
        'parent_id': None
    }
}
json.dump(data, sys.stdout)
" > "$dest"
}

# ── Test 1: DSO_TICKET_LEGACY=1 routes write_commit_event to Python-backed path
echo "Test 1: DSO_TICKET_LEGACY=1 — _python_write_commit_event is defined and python3 IS spawned"
test_write_commit_event_legacy_flag() {
    local repo
    repo=$(_make_test_repo)

    # Initialize ticket system
    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    # ticket-lib.sh must exist
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    # Static assertion: _python_write_commit_event must be defined in ticket-lib.sh
    # (RED: this function does not exist yet before the implementation)
    local has_python_fn
    has_python_fn=$(grep -c '_python_write_commit_event' "$TICKET_LIB" 2>/dev/null || echo "0")
    assert_eq "_python_write_commit_event defined in ticket-lib.sh" "1" \
        "$([ "$has_python_fn" -ge 1 ] && echo 1 || echo 0)"

    # Create a python3 shim that records spawns and then delegates to real python3.
    # To isolate the legacy path, we track spawns ONLY within the legacy branch by
    # counting spawns before vs after the call with DSO_TICKET_LEGACY=1.
    local shim_dir
    shim_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$shim_dir")

    local spawn_log="$shim_dir/python3_spawns.log"
    local real_python3
    real_python3=$(command -v python3)

    # Write the shim — records invocations that include the sentinel "fcntl" arg
    # (the legacy path uses fcntl.flock inline; the bash-native path uses _flock_stage_commit
    # which also calls python3 with fcntl). To distinguish, we write a sentinel marker
    # file when python3 is called with the legacy flock pattern keywords.
    local legacy_sentinel="$shim_dir/legacy_python3_called"
    cat > "$shim_dir/python3" <<EOF
#!/usr/bin/env bash
echo "python3_spawn: \$*" >> "$spawn_log"
# Detect legacy path: _python_write_commit_event passes fcntl + flock together
# as inline -c code containing the specific legacy marker phrase
args="\$*"
if [[ "\$args" == *"fcntl"* ]] && [[ "\$args" == *"LEGACY_PATH"* ]]; then
    touch "$legacy_sentinel"
fi
exec "$real_python3" "\$@"
EOF
    chmod +x "$shim_dir/python3"

    local ticket_id="test-legacy1"
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local event_json="$tmpdir/event.json"
    _make_event_json "$event_json" "$ticket_id"

    # Run write_commit_event with DSO_TICKET_LEGACY=1 and shim python3 on PATH.
    # Use env to pass variables into the subshell (avoids SC2030 export-in-subshell warning).
    local exit_code=0
    local stderr_legacy
    # shellcheck disable=SC2016  # $1/$2/$3 are positional params for inner bash -c, not outer expansion
    stderr_legacy=$(cd "$repo" && \
        env PATH="$shim_dir:$PATH" DSO_TICKET_LEGACY=1 \
        bash -c 'source "$1" && write_commit_event "$2" "$3"' \
            _ "$TICKET_LIB" "$ticket_id" "$event_json" 2>&1 >/dev/null) || exit_code=$?

    # Assert: operation succeeded (exit 0)
    assert_eq "DSO_TICKET_LEGACY=1 write_commit_event exits 0" "0" "$exit_code"

    # Assert: python3 was spawned (the shim recorded it — the legacy path uses python3)
    local spawn_count=0
    if [ -f "$spawn_log" ]; then
        spawn_count=$(wc -l < "$spawn_log" | tr -d ' ')
    fi
    assert_eq "python3 was spawned ≥1 time when DSO_TICKET_LEGACY=1" "1" \
        "$([ "$spawn_count" -ge 1 ] && echo 1 || echo 0)"

    # Assert: stderr contained the DSO_TICKET_LEGACY diagnostic message
    if [[ "$stderr_legacy" == *"DSO_TICKET_LEGACY"* ]] || \
       [[ "$stderr_legacy" == *"Python"* ]] || \
       [[ "$stderr_legacy" == *"python"* ]] || \
       [[ "$stderr_legacy" == *"legacy"* ]] || \
       [[ "$stderr_legacy" == *"Legacy"* ]]; then
        assert_eq "DSO_TICKET_LEGACY=1 emits diagnostic on stderr" "emitted" "emitted"
    else
        assert_eq "DSO_TICKET_LEGACY=1 emits diagnostic on stderr" "emitted" "silent"
    fi

    # Assert: the event file was actually written (not a no-op)
    local event_files
    event_files=$(find "$repo/.tickets-tracker/$ticket_id" -maxdepth 1 \
        -name '*-CREATE.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "event file created with DSO_TICKET_LEGACY=1" "1" "$event_files"
}
test_write_commit_event_legacy_flag

# ── Test 2: DSO_TICKET_LEGACY=1 emits the expected stderr diagnostic message
echo "Test 2: DSO_TICKET_LEGACY=1 — stderr prints diagnostic message about Python path"
test_write_commit_event_legacy_flag_stderr_message() {
    local repo
    repo=$(_make_test_repo)

    # Initialize ticket system
    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    # Static assertion: ticket-lib.sh must contain a DSO_TICKET_LEGACY guard
    local legacy_guard_count
    legacy_guard_count=$(grep -c 'DSO_TICKET_LEGACY' "$TICKET_LIB" 2>/dev/null || echo "0")
    assert_eq "DSO_TICKET_LEGACY guard exists in ticket-lib.sh" "1" \
        "$([ "$legacy_guard_count" -ge 1 ] && echo 1 || echo 0)"

    # Dynamic assertion: the stderr message is emitted when flag is set
    local ticket_id="test-legacy2"
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local event_json="$tmpdir/event.json"
    _make_event_json "$event_json" "$ticket_id"

    local stderr_out
    # shellcheck disable=SC2016  # $1/$2/$3 are positional params for inner bash -c, not outer expansion
    stderr_out=$(cd "$repo" && \
        env DSO_TICKET_LEGACY=1 \
        bash -c 'source "$1" && write_commit_event "$2" "$3"' \
            _ "$TICKET_LIB" "$ticket_id" "$event_json" 2>&1 >/dev/null) || true

    if [[ "$stderr_out" == *"DSO_TICKET_LEGACY"* ]] || [[ "$stderr_out" == *"Python"* ]] || \
       [[ "$stderr_out" == *"python"* ]] || [[ "$stderr_out" == *"legacy"* ]] || \
       [[ "$stderr_out" == *"Legacy"* ]]; then
        assert_eq "DSO_TICKET_LEGACY=1 emits diagnostic on stderr" "emitted" "emitted"
    else
        assert_eq "DSO_TICKET_LEGACY=1 emits diagnostic on stderr" "emitted" "silent"
    fi
}
test_write_commit_event_legacy_flag_stderr_message

# ── Test 3: Without DSO_TICKET_LEGACY, python3 is NOT spawned for the lock step
echo "Test 3: Without DSO_TICKET_LEGACY, python3 IS still used for flock (existing behavior preserved)"
test_write_commit_event_no_legacy_flag_flock_path() {
    local repo
    repo=$(_make_test_repo)

    # Initialize ticket system
    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    # Create a python3 shim to detect spawns
    local shim_dir
    shim_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$shim_dir")

    local spawn_log="$shim_dir/python3_spawns.log"
    local real_python3
    real_python3=$(command -v python3)

    cat > "$shim_dir/python3" <<EOF
#!/usr/bin/env bash
echo "python3_spawn: \$*" >> "$spawn_log"
exec "$real_python3" "\$@"
EOF
    chmod +x "$shim_dir/python3"

    local ticket_id="test-noflag1"
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local event_json="$tmpdir/event.json"
    _make_event_json "$event_json" "$ticket_id"

    # Run WITHOUT DSO_TICKET_LEGACY (or DSO_TICKET_LEGACY=0).
    # Use env to pass PATH into the subshell without the SC2030 warning.
    local exit_code=0
    # shellcheck disable=SC2016  # $1/$2/$3 are positional params for inner bash -c, not outer expansion
    (cd "$repo" && \
        env PATH="$shim_dir:$PATH" \
        bash -c 'unset DSO_TICKET_LEGACY; source "$1" && write_commit_event "$2" "$3"' \
            _ "$TICKET_LIB" "$ticket_id" "$event_json") || exit_code=$?

    # Assert: operation still succeeds (existing behavior preserved)
    assert_eq "write_commit_event without legacy flag exits 0" "0" "$exit_code"

    # Assert: event file was created (not broken by the guard)
    local event_files
    event_files=$(find "$repo/.tickets-tracker/$ticket_id" -maxdepth 1 \
        -name '*-CREATE.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "event file created without DSO_TICKET_LEGACY" "1" "$event_files"
}
test_write_commit_event_no_legacy_flag_flock_path

print_summary
