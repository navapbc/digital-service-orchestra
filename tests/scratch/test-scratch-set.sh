#!/usr/bin/env bash
# tests/scratch/test-scratch-set.sh
# Behavioral tests for plugins/dso/scripts/ticket-scratch-set.sh
#
# Testing Mode: RED → GREEN
# Usage: bash tests/scratch/test-scratch-set.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SCRATCH_SET="$REPO_ROOT/plugins/dso/scripts/ticket-scratch-set.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-scratch-set.sh: ticket-scratch-set.sh behavioral tests ==="

# ── Preflight ────────────────────────────────────────────────────────────────
if [ ! -f "$SCRATCH_SET" ]; then
    echo "FATAL: ticket-scratch-set.sh not found at $SCRATCH_SET" >&2
    exit 1
fi

if [ ! -x "$SCRATCH_SET" ]; then
    echo "FATAL: ticket-scratch-set.sh is not executable: $SCRATCH_SET" >&2
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

_make_scratch_base() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/scratch-set-test-XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: Valid write — exit 0, stdout is ok JSON, file has ts+value envelope
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 1: valid write emits ok response and writes ts+value envelope ──"
test_valid_write() {
    local base
    base=$(_make_scratch_base)

    local ticket_id="test-id-1234-abcd"
    local key="foo"
    local value="hello"

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SET" "$ticket_id" "$key" "$value" 2>/dev/null) \
        || exit_code=$?

    assert_eq "exit 0 for valid write" "0" "$exit_code"

    # stdout must be JSON with status:ok, ticket_id, and key
    local status tid k
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    tid=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('ticket_id',''))" 2>/dev/null || echo "")
    k=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('key',''))" 2>/dev/null || echo "")

    assert_eq "stdout status=ok" "ok" "$status"
    assert_eq "stdout ticket_id matches" "$ticket_id" "$tid"
    assert_eq "stdout key matches" "$key" "$k"

    # The written file must exist and be a valid JSON envelope with ts and value
    local abs_path="$base/$ticket_id/$key"
    assert_eq "file exists at expected path" "0" "$([ -f "$abs_path" ] && echo 0 || echo 1)"

    local file_ts file_value
    file_ts=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('ts',''))" "$abs_path" 2>/dev/null || echo "")
    file_value=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('value',''))" "$abs_path" 2>/dev/null || echo "")

    assert_ne "envelope has non-empty ts" "" "$file_ts"
    assert_eq "envelope value matches input" "$value" "$file_value"
}
test_valid_write

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: ts field is ISO 8601 format
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 2: ts field in envelope is ISO 8601 format ──"
test_ts_is_iso8601() {
    local base
    base=$(_make_scratch_base)

    local ticket_id="ts-iso-ticket-abcd"
    local key="mykey"
    local value="checkts"

    SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SET" "$ticket_id" "$key" "$value" >/dev/null 2>&1

    local abs_path="$base/$ticket_id/$key"
    local ts
    ts=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('ts',''))" "$abs_path" 2>/dev/null || echo "")

    # ISO 8601 check: contains T and looks like a date-time string
    local is_iso
    is_iso=$(python3 -c "
import sys, re
ts = sys.argv[1]
# Basic ISO 8601: YYYY-MM-DDTHH:MM:SS (with optional fractional seconds and timezone)
pattern = r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
print('yes' if re.match(pattern, ts) else 'no')
" "$ts" 2>/dev/null || echo "no")

    assert_eq "ts field is ISO 8601" "yes" "$is_iso"
}
test_ts_is_iso8601

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: Atomic semantics — no *.tmp.* leftover after successful write
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 3: no *.tmp.* siblings remain after successful write ──"
test_no_tmp_siblings() {
    local base
    base=$(_make_scratch_base)

    local ticket_id="atomic-ticket-efgh"
    local key="bar"
    local value="atomicval"

    SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SET" "$ticket_id" "$key" "$value" >/dev/null 2>&1

    local target_dir="$base/$ticket_id"
    local tmp_count
    tmp_count=$(find "$target_dir" -maxdepth 1 -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "no *.tmp.* siblings after write" "0" "$tmp_count"
}
test_no_tmp_siblings

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: Charset validation — invalid ticket_id propagates error, exits non-zero
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 4: invalid ticket_id (with '..') is rejected with structured error ──"
test_invalid_ticket_id_dotdot() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SET" "bad..id" "key" "value" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for invalid ticket_id" "0" "$exit_code"

    local status code
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    code=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('code',''))" 2>/dev/null || echo "")

    assert_eq "error status for invalid ticket_id" "error" "$status"
    assert_eq "code=invalid_id for dotdot ticket_id" "invalid_id" "$code"
}
test_invalid_ticket_id_dotdot

# ══════════════════════════════════════════════════════════════════════════════
# Test 5: Charset validation — invalid key (with '/') is rejected
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 5: invalid key (with '/') is rejected with structured error ──"
test_invalid_key_slash() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SET" "valid-ticket-id" "bad/key" "value" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for invalid key" "0" "$exit_code"

    local status code
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    code=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('code',''))" 2>/dev/null || echo "")

    assert_eq "error status for invalid key" "error" "$status"
    assert_eq "code=invalid_key for slash key" "invalid_key" "$code"
}
test_invalid_key_slash

# ══════════════════════════════════════════════════════════════════════════════
# Test 6: Oversize value — rejected with structured error
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 6: oversize value (> 4096 bytes envelope total) is rejected ──"
test_oversize_value() {
    local base
    base=$(_make_scratch_base)

    # Build a value that will exceed 4096 bytes when wrapped in the envelope
    local big_value
    big_value=$(python3 -c "print('x' * 5000, end='')")

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SET" "valid-ticket-id" "bigkey" "$big_value" 2>/dev/null) \
        || exit_code=$?

    assert_ne "non-zero exit for oversize value" "0" "$exit_code"

    local status code
    status=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || echo "")
    code=$(echo "$output" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('code',''))" 2>/dev/null || echo "")

    assert_eq "error status for oversize" "error" "$status"
    assert_eq "code=oversize for oversize value" "oversize" "$code"
}
test_oversize_value

# ══════════════════════════════════════════════════════════════════════════════
# Test 7: Missing args — exits non-zero with usage error
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 7: missing args exits non-zero ──"
test_missing_args() {
    local exit_code=0
    bash "$SCRATCH_SET" >/dev/null 2>&1 || exit_code=$?
    assert_ne "non-zero exit for missing args" "0" "$exit_code"
}
test_missing_args

# ══════════════════════════════════════════════════════════════════════════════
# Test 8: Crash-safety — abort between write and rename leaves no corrupt state
# Simulate via DSO_TEST_CRASH=1 env variable; after abort, prior envelope
# (if any) must still be intact, and no *.tmp.* files remain.
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 8: crash between write and rename leaves no corrupt envelope ──"
test_crash_safety() {
    local base
    base=$(_make_scratch_base)

    local ticket_id="crash-test-ticket-ijkl"
    local key="crashkey"

    # Step A: write a known good prior envelope
    SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SET" "$ticket_id" "$key" "prior-value" >/dev/null 2>&1

    local abs_path="$base/$ticket_id/$key"
    local prior_content
    prior_content=$(cat "$abs_path" 2>/dev/null || echo "")

    # Verify prior envelope was written correctly
    local prior_value
    prior_value=$(echo "$prior_content" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('value',''))" 2>/dev/null || echo "")
    assert_eq "prior envelope written correctly" "prior-value" "$prior_value"

    # Step B: simulate crash during a second write via DSO_TEST_CRASH=1
    # The script exits before rename if DSO_TEST_CRASH=1 is set
    local crash_exit=0
    SCRATCH_BASE_DIR="$base" DSO_TEST_CRASH=1 bash "$SCRATCH_SET" "$ticket_id" "$key" "new-value" >/dev/null 2>&1 \
        || crash_exit=$?

    # The crash write should exit non-zero
    assert_ne "crash write exits non-zero" "0" "$crash_exit"

    # Step C: the target file must either not exist OR contain the valid prior envelope
    # (never a partial/new value)
    if [ -f "$abs_path" ]; then
        local post_crash_content post_crash_value
        post_crash_content=$(cat "$abs_path" 2>/dev/null || echo "")
        # It must be valid JSON
        local is_valid_json
        is_valid_json=$(echo "$post_crash_content" | python3 -c "import json,sys; json.loads(sys.stdin.read()); print('yes')" 2>/dev/null || echo "no")
        assert_eq "post-crash file is valid JSON" "yes" "$is_valid_json"

        # Value must still be the prior value (not partial/new)
        post_crash_value=$(echo "$post_crash_content" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('value',''))" 2>/dev/null || echo "")
        assert_eq "post-crash envelope is prior (intact) value" "prior-value" "$post_crash_value"
    fi

    # Step D: no *.tmp.* siblings remain after the crashed process exits
    local target_dir="$base/$ticket_id"
    local tmp_count
    tmp_count=$(find "$target_dir" -maxdepth 1 -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "no *.tmp.* files remain after crash" "0" "$tmp_count"
}
test_crash_safety

# ══════════════════════════════════════════════════════════════════════════════
# Test 9: Overwrite existing — second write updates envelope without error
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 9: overwrite existing envelope updates value correctly ──"
test_overwrite_existing() {
    local base
    base=$(_make_scratch_base)

    local ticket_id="overwrite-ticket-mnop"
    local key="ow-key"

    SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SET" "$ticket_id" "$key" "first-value" >/dev/null 2>&1
    SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SET" "$ticket_id" "$key" "second-value" >/dev/null 2>&1

    local abs_path="$base/$ticket_id/$key"
    local final_value
    final_value=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('value',''))" "$abs_path" 2>/dev/null || echo "")
    assert_eq "overwrite updates value to second-value" "second-value" "$final_value"
}
test_overwrite_existing

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
print_summary
