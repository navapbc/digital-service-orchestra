#!/usr/bin/env bash
# tests/scripts/test-flock-busybox-compat.sh
# RED test: ticket_create must succeed when the only flock in PATH is a
# BusyBox-style (non-util-linux) flock binary.
#
# Motivation: On Alpine 3.19, `command -v flock` resolves to BusyBox flock.
# _flock_stage_commit in ticket-lib.sh must detect non-util-linux flock and
# fall through to its mkdir-based lock fallback rather than attempting the
# FD-based form (flock -x -w N FD) that BusyBox flock does not reliably
# support in the subshell-redirect context.
#
# RED: before the util-linux probe, ticket_create returns empty when only
#      a non-util-linux flock is in PATH (mock flock used → FD form attempted
#      → lock times out / fails → subshell exits before `echo "$ticket_id"`).
# GREEN: after fix, the probe rejects non-util-linux flock; mkdir fallback
#        is used → ticket_create returns a valid ticket ID.
#
# Usage: bash tests/scripts/test-flock-busybox-compat.sh
# Returns: exit 0 when ticket_create succeeds despite non-util-linux flock in PATH.

# NOTE: -e intentionally omitted — test functions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
REPO_ROOT="${REPO_ROOT:-${GITHUB_WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-flock-busybox-compat.sh ==="

# ── Helper: create a fresh ticket repo ────────────────────────────────────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: create a mock "busybox-style" flock binary ───────────────────────
# This mock:
#   - Responds to --version WITHOUT "util-linux" in the output
#   - Exits non-zero when called with FD arguments (simulating busybox FD form
#     not working in the subshell-redirect context)
#   - Accepts the file-locking form (not tested here, just excluded)
_make_mock_flock_bin() {
    local bin_dir
    bin_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$bin_dir")
    cat > "$bin_dir/flock" <<'MOCK'
#!/usr/bin/env bash
# Mock flock that simulates BusyBox flock behavior:
# --version: reports "BusyBox v1.36.1" (NOT util-linux)
# FD-numeric arg form: exits non-zero (simulates unsupported FD form)
if [ "${1:-}" = "--version" ]; then
    echo "BusyBox v1.36.1"
    exit 0
fi
# For any other invocation (including FD-based locking): fail
exit 1
MOCK
    chmod +x "$bin_dir/flock"
    echo "$bin_dir"
}

echo ""
echo "=== Test: ticket_create succeeds when non-util-linux flock is in PATH ==="

test_ticket_create_with_busybox_flock() {
    local repo
    repo=$(_make_test_repo)

    local mock_bin_dir
    mock_bin_dir=$(_make_mock_flock_bin)

    # Inject mock flock at the front of PATH so it is found before real flock
    local ticket_id
    ticket_id=$(
        cd "$repo" && \
        PATH="$mock_bin_dir:$PATH" \
        _TICKET_TEST_NO_SYNC=1 \
        TICKETS_TRACKER_DIR="$repo/.tickets-tracker" \
        bash "$TICKET_SCRIPT" create task "busybox flock compat test" 2>/dev/null
    ) || true

    if [ -n "$ticket_id" ] && echo "$ticket_id" | grep -qE '^[a-f0-9]{4}-[a-f0-9]{4}$'; then
        assert_eq "ticket_create with mock busybox flock: returned valid id" "non-empty" "non-empty"
    else
        assert_eq "ticket_create with mock busybox flock: returned valid id" "non-empty" "empty_or_invalid:${ticket_id:-<empty>}"
    fi
}
test_ticket_create_with_busybox_flock

echo ""
echo "=== Test: ticket_create also succeeds when flock is completely absent ==="

test_ticket_create_without_flock() {
    local repo
    repo=$(_make_test_repo)

    # Run with a PATH that has no flock binary at all
    local no_flock_path
    no_flock_path=$(echo "$PATH" | tr ':' '\n' | grep -v 'util-linux\|flock' | tr '\n' ':' | sed 's/:$//')

    local ticket_id
    ticket_id=$(
        cd "$repo" && \
        PATH="$no_flock_path" \
        _TICKET_TEST_NO_SYNC=1 \
        TICKETS_TRACKER_DIR="$repo/.tickets-tracker" \
        bash "$TICKET_SCRIPT" create task "no flock compat test" 2>/dev/null
    ) || true

    if [ -n "$ticket_id" ] && echo "$ticket_id" | grep -qE '^[a-f0-9]{4}-[a-f0-9]{4}$'; then
        assert_eq "ticket_create without any flock: returned valid id" "non-empty" "non-empty"
    else
        assert_eq "ticket_create without any flock: returned valid id" "non-empty" "empty_or_invalid:${ticket_id:-<empty>}"
    fi
}
test_ticket_create_without_flock

print_summary
