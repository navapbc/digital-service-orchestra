#!/usr/bin/env bash
# tests/scratch/test-scratch-cleanup.sh
# Unit tests for _scratch_cleanup_for_ticket in plugins/dso/scripts/ticket-lib.sh.
#
# Testing Mode: RED
# RED until story c7f3-1faf-6bb4-4ed7 implementation lands (_scratch_cleanup_for_ticket
# is not yet defined in ticket-lib.sh — all tests below will fail with "command not found"
# or similar until the GREEN implementation task adds the helper).
#
# Coverage: task 92a9-bcdd-5983-438b underwrites story c7f3 dd-3, dd-4, dd-5.
#
# Test cases:
#   1. (test_cleanup_removes_existing_dir)     Removes existing per-ticket scratch dir, returns 0.
#   2. (test_cleanup_noop_when_absent)         No-op when scratch dir is absent, returns 0.
#   3. (test_cleanup_idempotent)               Two consecutive calls both return 0, no dir remains.
#   4. (test_cleanup_logs_info_on_removal)     INFO log line contains ticket_id and removed path.
#   5. (test_cleanup_warn_on_rm_failure)       On rm failure (read-only parent), WARN emitted to
#                                              stderr (contains "WARN" + ticket_id); orphan marker
#                                              written; function still returns 0.
#
# Usage: bash tests/scratch/test-scratch-cleanup.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-scratch-cleanup.sh: _scratch_cleanup_for_ticket in ticket-lib.sh ==="
echo "(RED — tests fail until story c7f3 implementation lands)"

# ── Cleanup tracking ──────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] || continue
        # Restore permissions before removing so rm -rf can always succeed
        chmod -R u+rwx "$d" 2>/dev/null || true
        rm -rf "$d"
    done
}
trap _cleanup EXIT

# ── Source ticket-lib.sh ──────────────────────────────────────────────────────
if [ ! -f "$TICKET_LIB" ]; then
    echo "FATAL: ticket-lib.sh not found at $TICKET_LIB" >&2
    exit 1
fi
# shellcheck source=plugins/dso/scripts/ticket-lib.sh
source "$TICKET_LIB"

# ── Helpers ───────────────────────────────────────────────────────────────────
_make_scratch_base() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/scratch-cleanup-test-XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ── Verify _scratch_cleanup_for_ticket is defined ────────────────────────────
# This check itself drives the RED failure: if the function is absent, all
# individual test assertions below will also fail independently (they call
# the function directly). The check here gives a clear top-level signal.
if ! declare -f _scratch_cleanup_for_ticket >/dev/null 2>&1; then
    echo "FAIL: _scratch_cleanup_for_ticket is not defined in ticket-lib.sh" >&2
    echo "  (Expected RED — implementation not yet present)" >&2
    (( ++FAIL ))
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: removes existing per-ticket scratch directory
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 1: removes existing per-ticket scratch dir ──"
test_cleanup_removes_existing_dir() {
    local base
    base=$(_make_scratch_base)
    local ticket_id="abcd-1111-efgh-2222"
    local scratch_dir="$base/$ticket_id"

    # Create a scratch dir with some content
    mkdir -p "$scratch_dir"
    echo '{"key":"value"}' > "$scratch_dir/notes.json"

    local exit_code=0
    _scratch_cleanup_for_ticket "$ticket_id" "$base" 2>/dev/null || exit_code=$?

    assert_eq "cleanup returns 0 on existing dir" "0" "$exit_code"

    local dir_exists
    dir_exists=$([ -d "$scratch_dir" ] && echo "yes" || echo "no")
    assert_eq "scratch dir no longer exists after cleanup" "no" "$dir_exists"
}
test_cleanup_removes_existing_dir

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: no-op when scratch directory is absent
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 2: no-op when scratch dir is absent ──"
test_cleanup_noop_when_absent() {
    local base
    base=$(_make_scratch_base)
    local ticket_id="abcd-3333-efgh-4444"
    local scratch_dir="$base/$ticket_id"

    # Do NOT create the dir
    local exit_code=0
    _scratch_cleanup_for_ticket "$ticket_id" "$base" 2>/dev/null || exit_code=$?

    assert_eq "cleanup returns 0 when dir absent" "0" "$exit_code"
}
test_cleanup_noop_when_absent

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: idempotent — two consecutive calls both return 0, no dir remains
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 3: idempotent cleanup ──"
test_cleanup_idempotent() {
    local base
    base=$(_make_scratch_base)
    local ticket_id="abcd-5555-efgh-6666"
    local scratch_dir="$base/$ticket_id"

    mkdir -p "$scratch_dir"
    echo '{}' > "$scratch_dir/data.json"

    # First call
    local exit_code1=0
    _scratch_cleanup_for_ticket "$ticket_id" "$base" 2>/dev/null || exit_code1=$?
    assert_eq "first cleanup returns 0" "0" "$exit_code1"

    # Second call (dir already gone)
    local exit_code2=0
    _scratch_cleanup_for_ticket "$ticket_id" "$base" 2>/dev/null || exit_code2=$?
    assert_eq "second cleanup returns 0 (idempotent)" "0" "$exit_code2"

    local dir_exists
    dir_exists=$([ -d "$scratch_dir" ] && echo "yes" || echo "no")
    assert_eq "scratch dir absent after two cleanups" "no" "$dir_exists"
}
test_cleanup_idempotent

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: INFO log on successful removal contains ticket_id and path
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 4: INFO log contains ticket_id and removed path ──"
test_cleanup_logs_info_on_removal() {
    local base
    base=$(_make_scratch_base)
    local ticket_id="abcd-7777-efgh-8888"
    local scratch_dir="$base/$ticket_id"

    mkdir -p "$scratch_dir"
    echo '{}' > "$scratch_dir/tmp.json"

    # Capture stderr (INFO log goes to stderr)
    local stderr_output exit_code=0
    stderr_output=$(_scratch_cleanup_for_ticket "$ticket_id" "$base" 2>&1 >/dev/null) || exit_code=$?

    assert_eq "cleanup returns 0 during INFO test" "0" "$exit_code"
    assert_contains "INFO log contains ticket_id" "$ticket_id" "$stderr_output"
    assert_contains "INFO log contains scratch path" "$scratch_dir" "$stderr_output"
}
test_cleanup_logs_info_on_removal

# ══════════════════════════════════════════════════════════════════════════════
# Test 5: WARN on rm failure; orphan marker written; still returns 0
#
# Simulates permission-denied by chmod 000 on a sub-directory so rm -rf
# cannot descend into it. Then verifies:
#   (a) WARN appears in stderr with ticket_id
#   (b) orphan marker written to .tickets-tracker/.scratch-orphans/<id>
#   (c) function still returns 0
#
# NOTE: This test requires running as a non-root user (root can always rm).
# If running as root, the test is skipped with a note.
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 5: WARN on rm failure, orphan marker, returns 0 ──"
test_cleanup_warn_on_rm_failure() {
    # Skip if running as root (root ignores permission bits)
    if [ "$(id -u)" -eq 0 ]; then
        echo "  (skipped — running as root, permission simulation not possible)"
        return
    fi

    local base
    base=$(_make_scratch_base)
    local ticket_id="abcd-9999-efgh-0000"
    local scratch_dir="$base/$ticket_id"

    # Create a sub-directory that is not removable (read-only)
    mkdir -p "$scratch_dir/locked-sub"
    echo '{}' > "$scratch_dir/locked-sub/data.json"
    chmod 000 "$scratch_dir/locked-sub"

    # Also need a fake .tickets-tracker for the orphan marker
    local tracker_dir="$base/.tickets-tracker"
    mkdir -p "$tracker_dir"

    # Capture stderr; function should still return 0
    local stderr_output exit_code=0
    stderr_output=$(SCRATCH_ORPHANS_DIR="$tracker_dir/.scratch-orphans" \
        _scratch_cleanup_for_ticket "$ticket_id" "$base" 2>&1 >/dev/null) || exit_code=$?

    # Restore permissions so _cleanup() trap can remove the dir
    chmod -R u+rwx "$scratch_dir" 2>/dev/null || true

    assert_eq "cleanup returns 0 despite rm failure" "0" "$exit_code"

    # (a) WARN in stderr
    assert_contains "stderr contains WARN" "WARN" "$stderr_output"
    assert_contains "stderr contains ticket_id in WARN" "$ticket_id" "$stderr_output"

    # (b) orphan marker file written
    local orphan_dir="$tracker_dir/.scratch-orphans"
    local orphan_file="$orphan_dir/$ticket_id"
    local orphan_exists
    orphan_exists=$([ -f "$orphan_file" ] && echo "yes" || echo "no")
    assert_eq "orphan marker file was written" "yes" "$orphan_exists"

    if [ -f "$orphan_file" ]; then
        # Marker must be valid JSON with required fields
        local has_ticket_id has_path has_error has_timestamp
        has_ticket_id=$(python3 -c "
import json, sys
try:
    d = json.load(open('$orphan_file'))
    print('yes' if d.get('ticket_id') == '$ticket_id' else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")
        has_path=$(python3 -c "
import json, sys
try:
    d = json.load(open('$orphan_file'))
    print('yes' if 'path' in d else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")
        has_error=$(python3 -c "
import json, sys
try:
    d = json.load(open('$orphan_file'))
    print('yes' if 'error' in d else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")
        has_timestamp=$(python3 -c "
import json, sys
try:
    d = json.load(open('$orphan_file'))
    print('yes' if 'timestamp' in d else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")
        assert_eq "orphan marker has ticket_id field" "yes" "$has_ticket_id"
        assert_eq "orphan marker has path field" "yes" "$has_path"
        assert_eq "orphan marker has error field" "yes" "$has_error"
        assert_eq "orphan marker has timestamp field" "yes" "$has_timestamp"
    fi
}
test_cleanup_warn_on_rm_failure

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
print_summary
