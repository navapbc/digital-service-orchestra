#!/usr/bin/env bash
# tests/scratch/test-scratch-lib.sh
# Unit tests for scratch helper functions in plugins/dso/scripts/ticket-lib.sh:
#   _scratch_resolve_and_validate
#   _scratch_atomic_write
#   _scratch_read_envelope
#
# Testing Mode: RED → GREEN
# Usage: bash tests/scratch/test-scratch-lib.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-scratch-lib.sh: scratch helpers in ticket-lib.sh ==="

# ── Cleanup tracking ──────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# ── Source ticket-lib.sh (required for all tests) ────────────────────────────
if [ ! -f "$TICKET_LIB" ]; then
    echo "FATAL: ticket-lib.sh not found at $TICKET_LIB" >&2
    exit 1
fi
# Source only (no subshell): functions become available in current shell.
# ticket-lib.sh uses BASH_SOURCE for self-location; sourcing is safe.
# shellcheck source=plugins/dso/scripts/ticket-lib.sh
source "$TICKET_LIB"

# ── Helper: make a temp scratch base directory ────────────────────────────────
_make_scratch_base() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/scratch-test-XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ══════════════════════════════════════════════════════════════════════════════
# _scratch_resolve_and_validate — charset validation tests
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "── _scratch_resolve_and_validate: charset validation ──"

# Test A: path traversal (..) in ticket_id is rejected
echo "Test A: path traversal '..' in ticket_id is rejected with non-zero exit + JSON error"
test_validate_rejects_dotdot_in_ticket_id() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(_scratch_resolve_and_validate "ab12..cd34" "mykey" "$base" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for dotdot in ticket_id" "0" "$exit_code"

    # Output must be JSON with status:error and code:invalid_id
    local status code
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    code=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('code',''))" 2>/dev/null || echo "")

    assert_eq "status=error for dotdot ticket_id" "error" "$status"
    assert_eq "code=invalid_id for dotdot ticket_id" "invalid_id" "$code"
}
test_validate_rejects_dotdot_in_ticket_id

# Test B: slash (/) in ticket_id is rejected
echo "Test B: slash '/' in ticket_id is rejected with non-zero exit + JSON error"
test_validate_rejects_slash_in_ticket_id() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(_scratch_resolve_and_validate "ab12/cd34" "mykey" "$base" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for slash in ticket_id" "0" "$exit_code"

    local status code
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    code=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('code',''))" 2>/dev/null || echo "")

    assert_eq "status=error for slash ticket_id" "error" "$status"
    assert_eq "code=invalid_id for slash ticket_id" "invalid_id" "$code"
}
test_validate_rejects_slash_in_ticket_id

# Test C: control char (0x01) in ticket_id is rejected
echo "Test C: control char in ticket_id is rejected with non-zero exit + JSON error"
test_validate_rejects_control_char_in_ticket_id() {
    local base
    base=$(_make_scratch_base)

    # Build a string with an embedded control char (octal 001 = 0x01)
    local bad_id
    bad_id=$(printf 'abc\x01def')

    local output exit_code=0
    output=$(_scratch_resolve_and_validate "$bad_id" "mykey" "$base" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for control char in ticket_id" "0" "$exit_code"

    local status code
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    code=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('code',''))" 2>/dev/null || echo "")

    assert_eq "status=error for control char ticket_id" "error" "$status"
    assert_eq "code=invalid_id for control char ticket_id" "invalid_id" "$code"
}
test_validate_rejects_control_char_in_ticket_id

# Test D: leading dot in ticket_id is rejected
echo "Test D: leading dot in ticket_id is rejected"
test_validate_rejects_leading_dot_in_ticket_id() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(_scratch_resolve_and_validate ".hidden-ticket" "mykey" "$base" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for leading dot in ticket_id" "0" "$exit_code"

    local status
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    assert_eq "status=error for leading dot ticket_id" "error" "$status"
}
test_validate_rejects_leading_dot_in_ticket_id

# Test E: slash in key is rejected with code:invalid_key
echo "Test E: slash '/' in key is rejected with code:invalid_key"
test_validate_rejects_slash_in_key() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(_scratch_resolve_and_validate "valid-id-1234" "bad/key" "$base" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for slash in key" "0" "$exit_code"

    local status code
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    code=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('code',''))" 2>/dev/null || echo "")

    assert_eq "status=error for slash key" "error" "$status"
    assert_eq "code=invalid_key for slash key" "invalid_key" "$code"
}
test_validate_rejects_slash_in_key

# Test F: dotdot in key is rejected with code:invalid_key
echo "Test F: '..' in key is rejected with code:invalid_key"
test_validate_rejects_dotdot_in_key() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(_scratch_resolve_and_validate "valid-id-1234" "ab..cd" "$base" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for dotdot in key" "0" "$exit_code"

    local status code
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    code=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('code',''))" 2>/dev/null || echo "")

    assert_eq "status=error for dotdot key" "error" "$status"
    assert_eq "code=invalid_key for dotdot key" "invalid_key" "$code"
}
test_validate_rejects_dotdot_in_key

# Test G: null byte in ticket_id is rejected
echo "Test G: null byte in ticket_id is rejected"
test_validate_rejects_null_byte_in_ticket_id() {
    local base
    base=$(_make_scratch_base)

    # Bash cannot hold a null byte in a variable, but the helper must handle empty/null IDs
    # We test with an empty string (the shortest-proxy that triggers empty-ID rejection)
    local output exit_code=0
    output=$(_scratch_resolve_and_validate "" "mykey" "$base" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for empty (null-like) ticket_id" "0" "$exit_code"

    local status
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    assert_eq "status=error for empty ticket_id" "error" "$status"
}
test_validate_rejects_null_byte_in_ticket_id

# Test H: valid ticket_id + key succeeds and returns abs path
echo "Test H: valid ticket_id and key returns resolved absolute path with exit 0"
test_validate_valid_inputs_return_path() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(_scratch_resolve_and_validate "abc1-def2-ghi3-jkl4" "my-key" "$base") \
        || exit_code=$?

    assert_eq "exit 0 for valid inputs" "0" "$exit_code"
    # Output should be an absolute path containing base, ticket_id, and key
    local is_abs
    is_abs=$(echo "$output" | python3 -c "import sys,os; p=sys.stdin.read().strip(); print('yes' if os.path.isabs(p) else 'no')" 2>/dev/null || echo "no")
    assert_eq "output is absolute path" "yes" "$is_abs"
    assert_contains "path contains ticket_id" "abc1-def2-ghi3-jkl4" "$output"
    assert_contains "path contains key" "my-key" "$output"
}
test_validate_valid_inputs_return_path

# ══════════════════════════════════════════════════════════════════════════════
# _scratch_atomic_write — size enforcement and atomicity tests
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "── _scratch_atomic_write: size enforcement and atomicity ──"

# Test I: oversize write (>98304 bytes) is rejected with structured error
echo "Test I: oversize write (99000 bytes) rejected with structured error envelope"
test_atomic_write_rejects_oversize() {
    local base
    base=$(_make_scratch_base)

    # Build a 99000-byte payload (exceeds 98304 default ceiling)
    local payload
    payload=$(python3 -c "print('x' * 99000, end='')")

    local abs_path="$base/valid-ticket/scratch-key.json"
    mkdir -p "$(dirname "$abs_path")"

    local output exit_code=0
    output=$(_scratch_atomic_write "$abs_path" "$payload" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for oversize write" "0" "$exit_code"

    local status code limit actual
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    code=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('code',''))" 2>/dev/null || echo "")
    limit=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('limit',''))" 2>/dev/null || echo "")
    actual=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('actual',''))" 2>/dev/null || echo "")

    assert_eq "status=error for oversize" "error" "$status"
    assert_eq "code=oversize for oversize" "oversize" "$code"
    assert_eq "limit=98304 for oversize" "98304" "$limit"
    assert_eq "actual=99000 for oversize" "99000" "$actual"
}
test_atomic_write_rejects_oversize

# Test J: oversize write leaves no file at target path
echo "Test J: oversize write leaves no file created at target path"
test_atomic_write_oversize_leaves_no_file() {
    local base
    base=$(_make_scratch_base)

    local payload
    payload=$(python3 -c "print('y' * 99000, end='')")

    local abs_path="$base/valid-ticket/no-file-created.json"
    mkdir -p "$(dirname "$abs_path")"

    _scratch_atomic_write "$abs_path" "$payload" >/dev/null 2>&1 || true

    # The file must NOT exist
    if [ -f "$abs_path" ]; then
        assert_eq "no file created on oversize" "absent" "present"
    else
        assert_eq "no file created on oversize" "absent" "absent"
    fi
}
test_atomic_write_oversize_leaves_no_file

# Test K: valid write leaves no *.tmp.* siblings
echo "Test K: valid write leaves no *.tmp.* sibling files in target directory"
test_atomic_write_no_tmp_siblings() {
    local base
    base=$(_make_scratch_base)

    local payload='{"status":"ok","data":"hello"}'
    local target_dir="$base/ticket-abc1/scratch"
    mkdir -p "$target_dir"
    local abs_path="$target_dir/key.json"

    local exit_code=0
    _scratch_atomic_write "$abs_path" "$payload" >/dev/null 2>&1 || exit_code=$?

    assert_eq "exit 0 for valid write" "0" "$exit_code"

    # No *.tmp.* files should remain
    local tmp_count
    tmp_count=$(find "$target_dir" -maxdepth 1 -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "no tmp siblings after write" "0" "$tmp_count"
}
test_atomic_write_no_tmp_siblings

# Test L: valid write creates correct file with expected content
echo "Test L: valid write creates file with expected content"
test_atomic_write_correct_content() {
    local base
    base=$(_make_scratch_base)

    local payload='{"hello":"world","n":42}'
    local target_dir="$base/ticket-round/scratch"
    mkdir -p "$target_dir"
    local abs_path="$target_dir/roundtrip.json"

    local exit_code=0
    _scratch_atomic_write "$abs_path" "$payload" >/dev/null 2>&1 || exit_code=$?

    assert_eq "exit 0 for valid write" "0" "$exit_code"
    assert_eq "file exists after write" "0" "$([ -f "$abs_path" ] && echo 0 || echo 1)"

    local content
    content=$(cat "$abs_path" 2>/dev/null || echo "")
    assert_eq "file content matches payload" "$payload" "$content"
}
test_atomic_write_correct_content

# ══════════════════════════════════════════════════════════════════════════════
# _scratch_read_envelope — read tests
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "── _scratch_read_envelope: read tests ──"

# Test M: read missing file returns non-zero
echo "Test M: reading missing file returns non-zero exit"
test_read_envelope_missing_file() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(_scratch_read_envelope "$base/nonexistent/path.json" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for missing file" "0" "$exit_code"
}
test_read_envelope_missing_file

# Test N: read empty file returns non-zero
echo "Test N: reading empty file returns non-zero exit"
test_read_envelope_empty_file() {
    local base
    base=$(_make_scratch_base)

    local abs_path="$base/empty-ticket/empty.json"
    mkdir -p "$(dirname "$abs_path")"
    touch "$abs_path"  # create empty file

    local exit_code=0
    _scratch_read_envelope "$abs_path" >/dev/null 2>&1 || exit_code=$?

    assert_ne "non-zero exit for empty file" "0" "$exit_code"
}
test_read_envelope_empty_file

# Test O: valid round-trip — write then read returns expected JSON
echo "Test O: valid round-trip write+read returns expected payload"
test_read_envelope_roundtrip() {
    local base
    base=$(_make_scratch_base)

    local payload='{"status":"ok","ticket":"abc","key":"notes","value":"hello world"}'
    local abs_path="$base/rt-ticket/key.json"
    mkdir -p "$(dirname "$abs_path")"

    # Write using the atomic writer
    local write_exit=0
    _scratch_atomic_write "$abs_path" "$payload" >/dev/null 2>&1 || write_exit=$?
    assert_eq "write succeeded for round-trip" "0" "$write_exit"

    # Now read back
    local read_output read_exit=0
    read_output=$(_scratch_read_envelope "$abs_path" 2>/dev/null) \
        || read_exit=$?

    assert_eq "read exit 0 for round-trip" "0" "$read_exit"
    assert_eq "read content matches written payload" "$payload" "$read_output"
}
test_read_envelope_roundtrip

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
print_summary
