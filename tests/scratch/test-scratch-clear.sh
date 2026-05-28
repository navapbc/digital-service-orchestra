#!/usr/bin/env bash
# tests/scratch/test-scratch-clear.sh
# Unit tests for ticket-scratch-clear.sh
#
# Testing Mode: RED → GREEN
# Usage: bash tests/scratch/test-scratch-clear.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CLEAR_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-scratch-clear.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-scratch-clear.sh: ticket-scratch-clear.sh ==="

# ── Guard: script must exist ──────────────────────────────────────────────────
if [ ! -f "$CLEAR_SCRIPT" ]; then
    echo "FATAL: ticket-scratch-clear.sh not found at $CLEAR_SCRIPT" >&2
    exit 1
fi

# ── Cleanup tracking ──────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# ── Helper: make a temp scratch base directory ────────────────────────────────
_make_scratch_base() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/scratch-clear-test-XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ── Helper: create a scratch file at <base>/<ticket_id>/<key> ────────────────
_create_scratch_file() {
    local base="$1" ticket_id="$2" key="$3" content="${4:-test-content}"
    local dir="$base/$ticket_id"
    mkdir -p "$dir"
    printf '%s' "$content" > "$dir/$key"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test A: clear with key removes only that key file
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test A: clear <id> <key> removes only the specified key ──"
test_clear_single_key_removes_only_that_key() {
    local base
    base=$(_make_scratch_base)

    _create_scratch_file "$base" "abc1-def2-ghi3-jkl4" "key1" "value1"
    _create_scratch_file "$base" "abc1-def2-ghi3-jkl4" "key2" "value2"

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$CLEAR_SCRIPT" "abc1-def2-ghi3-jkl4" "key1" 2>/dev/null) \
        || exit_code=$?

    assert_eq "exit 0 for clear single key" "0" "$exit_code"

    # key1 must be gone
    assert_eq "key1 removed" "0" "$([ ! -f "$base/abc1-def2-ghi3-jkl4/key1" ] && echo 0 || echo 1)"
    # key2 must still exist
    assert_eq "key2 still present" "0" "$([ -f "$base/abc1-def2-ghi3-jkl4/key2" ] && echo 0 || echo 1)"

    # stdout must report removed:1
    local removed
    removed=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('removed',''))" 2>/dev/null || echo "")
    assert_eq "removed=1 for single key clear" "1" "$removed"

    local status
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    assert_eq "status=ok for single key clear" "ok" "$status"
}
test_clear_single_key_removes_only_that_key

# ══════════════════════════════════════════════════════════════════════════════
# Test B: clear without key removes entire per-ticket scratch directory
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test B: clear <id> (no key) removes the whole ticket scratch dir ──"
test_clear_no_key_removes_entire_dir() {
    local base
    base=$(_make_scratch_base)

    _create_scratch_file "$base" "aaaa-bbbb-cccc-dddd" "key1" "v1"
    _create_scratch_file "$base" "aaaa-bbbb-cccc-dddd" "key2" "v2"

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$CLEAR_SCRIPT" "aaaa-bbbb-cccc-dddd" 2>/dev/null) \
        || exit_code=$?

    assert_eq "exit 0 for clear all" "0" "$exit_code"

    # entire dir must be gone
    assert_eq "ticket scratch dir removed" "0" "$([ ! -d "$base/aaaa-bbbb-cccc-dddd" ] && echo 0 || echo 1)"

    # stdout must report removed:2
    local removed
    removed=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('removed',''))" 2>/dev/null || echo "")
    assert_eq "removed=2 for full clear" "2" "$removed"

    local status
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    assert_eq "status=ok for full clear" "ok" "$status"
}
test_clear_no_key_removes_entire_dir

# ══════════════════════════════════════════════════════════════════════════════
# Test C: clear with key is idempotent — missing key is success (removed:0)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test C: clear <id> <key> where key does not exist is idempotent ──"
test_clear_missing_key_is_idempotent() {
    local base
    base=$(_make_scratch_base)

    # No files at all in this ticket dir
    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$CLEAR_SCRIPT" "no-ticket-here-1234" "missing-key" 2>/dev/null) \
        || exit_code=$?

    assert_eq "exit 0 when key missing (idempotent)" "0" "$exit_code"

    local removed
    removed=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('removed',''))" 2>/dev/null || echo "")
    assert_eq "removed=0 when key missing" "0" "$removed"
}
test_clear_missing_key_is_idempotent

# ══════════════════════════════════════════════════════════════════════════════
# Test D: clear without key is idempotent — missing ticket dir is success
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test D: clear <id> (no key) where ticket dir does not exist is idempotent ──"
test_clear_missing_dir_is_idempotent() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$CLEAR_SCRIPT" "ghost-ticket-5678" 2>/dev/null) \
        || exit_code=$?

    assert_eq "exit 0 when dir missing (idempotent)" "0" "$exit_code"

    local removed
    removed=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('removed',''))" 2>/dev/null || echo "")
    assert_eq "removed=0 when dir missing" "0" "$removed"
}
test_clear_missing_dir_is_idempotent

# ══════════════════════════════════════════════════════════════════════════════
# Test E: invalid ticket_id (path traversal) rejected with error envelope
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test E: invalid ticket_id rejected with structured error ──"
test_clear_invalid_id_rejected() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$CLEAR_SCRIPT" "../../etc" "key" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for invalid ticket_id" "0" "$exit_code"

    local status code
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    code=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('code',''))" 2>/dev/null || echo "")

    assert_eq "status=error for invalid id" "error" "$status"
    assert_eq "code=invalid_id for path traversal" "invalid_id" "$code"
}
test_clear_invalid_id_rejected

# ══════════════════════════════════════════════════════════════════════════════
# Test F: invalid key (slash) rejected with error envelope
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test F: invalid key rejected with structured error ──"
test_clear_invalid_key_rejected() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$CLEAR_SCRIPT" "valid-ticket-1234" "bad/key" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for invalid key" "0" "$exit_code"

    local status code
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    code=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('code',''))" 2>/dev/null || echo "")

    assert_eq "status=error for invalid key" "error" "$status"
    assert_eq "code=invalid_key for slash key" "invalid_key" "$code"
}
test_clear_invalid_key_rejected

# ══════════════════════════════════════════════════════════════════════════════
# Test G: output includes ticket_id field
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test G: output JSON includes ticket_id ──"
test_clear_output_includes_ticket_id() {
    local base
    base=$(_make_scratch_base)

    _create_scratch_file "$base" "tid1-tid2-tid3-tid4" "mykey" "stuff"

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$CLEAR_SCRIPT" "tid1-tid2-tid3-tid4" "mykey" 2>/dev/null) \
        || exit_code=$?

    assert_eq "exit 0" "0" "$exit_code"

    local tid
    tid=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('ticket_id',''))" 2>/dev/null || echo "")
    assert_eq "ticket_id in output" "tid1-tid2-tid3-tid4" "$tid"
}
test_clear_output_includes_ticket_id

# ══════════════════════════════════════════════════════════════════════════════
# Test H: clear with key output includes key field
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test H: single-key clear output includes key field ──"
test_clear_single_key_output_includes_key_field() {
    local base
    base=$(_make_scratch_base)

    _create_scratch_file "$base" "eid1-eid2-eid3-eid4" "thekey" "data"

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$CLEAR_SCRIPT" "eid1-eid2-eid3-eid4" "thekey" 2>/dev/null) \
        || exit_code=$?

    assert_eq "exit 0" "0" "$exit_code"

    local key_field
    key_field=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('key',''))" 2>/dev/null || echo "")
    assert_eq "key field in output" "thekey" "$key_field"
}
test_clear_single_key_output_includes_key_field

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
print_summary
