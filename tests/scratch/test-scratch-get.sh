#!/usr/bin/env bash
# tests/scratch/test-scratch-get.sh
# Unit tests for plugins/dso/scripts/ticket-scratch-get.sh
#
# Testing Mode: RED → GREEN
# Usage: bash tests/scratch/test-scratch-get.sh
#
# Covers:
#   - On hit: stdout is JSON {"status":"hit","ts":<iso8601>,"value":<value>}; exit 0
#   - On miss: stdout is JSON {"status":"miss","ticket_id":<id>,"key":<key>}; exit 0 (NOT non-zero)
#   - Invalid id/key: structured error envelope on stdout; non-zero exit

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"
SCRATCH_GET="$REPO_ROOT/plugins/dso/scripts/ticket-scratch-get.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-scratch-get.sh: ticket-scratch-get.sh hit/miss semantics ==="

# ── Cleanup tracking ──────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# ── Prerequisite checks ───────────────────────────────────────────────────────
if [ ! -f "$TICKET_LIB" ]; then
    echo "FATAL: ticket-lib.sh not found at $TICKET_LIB" >&2
    exit 1
fi

if [ ! -f "$SCRATCH_GET" ]; then
    echo "FATAL: ticket-scratch-get.sh not found at $SCRATCH_GET" >&2
    echo "  (expected: $SCRATCH_GET)" >&2
    exit 1
fi

if [ ! -x "$SCRATCH_GET" ]; then
    echo "FATAL: ticket-scratch-get.sh is not executable: $SCRATCH_GET" >&2
    exit 1
fi

# ── Source ticket-lib for _scratch_atomic_write ───────────────────────────────
# shellcheck source=plugins/dso/scripts/ticket-lib.sh
source "$TICKET_LIB"

# ── Helper: make a temp scratch base directory ────────────────────────────────
_make_scratch_base() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/scratch-get-test-XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ── Helper: extract JSON field via python3 ────────────────────────────────────
_json_field() {
    local json="$1" field="$2"
    echo "$json" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('$field',''))" 2>/dev/null || echo ""
}

# ── Helper: check iso8601 shape (basic: contains T and digits) ────────────────
_is_iso8601_like() {
    local ts="$1"
    # ISO8601 has form: YYYY-MM-DDTHH:MM:SS...
    echo "$ts" | python3 -c "
import sys, re
ts = sys.stdin.read().strip()
# Accept any string matching basic ISO8601 datetime pattern
if re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', ts):
    sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: HIT — existing key returns {status:"hit", ts:<iso8601>, value:<val>} exit 0
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 1: HIT — existing key returns status:hit with ts and value, exit 0 ──"

test_hit_returns_json_exit0() {
    local base
    base=$(_make_scratch_base)

    local ticket_id="abcd-1234-efgh-5678"
    local key="myvalue"
    local value="hello-world"

    # Write a scratch envelope using the library helper
    local abs_path="$base/$ticket_id/$key"
    local ts
    ts=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())")
    local payload
    payload=$(python3 -c "import json; print(json.dumps({'status':'stored','ts':'$ts','ticket_id':'$ticket_id','key':'$key','value':'$value'}))")

    _scratch_atomic_write "$abs_path" "$payload" >/dev/null 2>&1

    # Run the get script with the temp base
    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_GET" "$ticket_id" "$key" 2>/dev/null) \
        || exit_code=$?

    assert_eq "hit: exit code is 0" "0" "$exit_code"

    local status
    status=$(_json_field "$output" "status")
    assert_eq "hit: status field is 'hit'" "hit" "$status"

    local got_value
    got_value=$(_json_field "$output" "value")
    assert_eq "hit: value field matches stored value" "$value" "$got_value"

    local got_ts
    got_ts=$(_json_field "$output" "ts")
    assert_ne "hit: ts field is non-empty" "" "$got_ts"

    # ts must look like ISO8601
    if _is_iso8601_like "$got_ts"; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: hit: ts field is ISO8601-shaped\n  at: %s:%s\n  got: %s\n" "${BASH_SOURCE[0]}" "${LINENO}" "$got_ts" >&2
    fi
}
test_hit_returns_json_exit0

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: MISS — missing file returns {status:"miss", ticket_id, key} exit 0
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 2: MISS — missing key returns status:miss with ticket_id and key, exit 0 ──"

test_miss_returns_json_exit0() {
    local base
    base=$(_make_scratch_base)

    local ticket_id="miss-ticket-id-0001"
    local key="nonexistent-key"

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_GET" "$ticket_id" "$key" 2>/dev/null) \
        || exit_code=$?

    # CRITICAL: miss MUST exit 0 — orchestrators distinguish via status field, not exit code
    assert_eq "miss: exit code is 0 (NOT non-zero)" "0" "$exit_code"

    local status
    status=$(_json_field "$output" "status")
    assert_eq "miss: status field is 'miss'" "miss" "$status"

    local got_ticket_id
    got_ticket_id=$(_json_field "$output" "ticket_id")
    assert_eq "miss: ticket_id field matches input" "$ticket_id" "$got_ticket_id"

    local got_key
    got_key=$(_json_field "$output" "key")
    assert_eq "miss: key field matches input" "$key" "$got_key"
}
test_miss_returns_json_exit0

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: MISS on empty file — empty file treated as miss, exit 0
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 3: MISS on empty file — empty file returns status:miss, exit 0 ──"

test_miss_on_empty_file_exit0() {
    local base
    base=$(_make_scratch_base)

    local ticket_id="empty-file-ticket-1234"
    local key="empty-key"

    # Create the file but leave it empty
    local abs_path="$base/$ticket_id/$key"
    mkdir -p "$(dirname "$abs_path")"
    touch "$abs_path"

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_GET" "$ticket_id" "$key" 2>/dev/null) \
        || exit_code=$?

    assert_eq "miss-empty: exit code is 0 (NOT non-zero)" "0" "$exit_code"

    local status
    status=$(_json_field "$output" "status")
    assert_eq "miss-empty: status field is 'miss'" "miss" "$status"
}
test_miss_on_empty_file_exit0

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: INVALID ticket_id — structured error envelope, non-zero exit
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 4: INVALID ticket_id (path traversal) — error envelope, non-zero exit ──"

test_invalid_ticket_id_exits_nonzero() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_GET" "ab..cd" "mykey" 2>/dev/null) \
        || exit_code=$?

    assert_ne "invalid_id: exit code is non-zero" "0" "$exit_code"

    local status
    status=$(_json_field "$output" "status")
    assert_eq "invalid_id: status field is 'error'" "error" "$status"

    local code
    code=$(_json_field "$output" "code")
    assert_eq "invalid_id: code field is 'invalid_id'" "invalid_id" "$code"
}
test_invalid_ticket_id_exits_nonzero

# ══════════════════════════════════════════════════════════════════════════════
# Test 5: INVALID key — structured error envelope, non-zero exit
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 5: INVALID key (slash) — error envelope, non-zero exit ──"

test_invalid_key_exits_nonzero() {
    local base
    base=$(_make_scratch_base)

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_GET" "valid-ticket-1234" "bad/key" 2>/dev/null) \
        || exit_code=$?

    assert_ne "invalid_key: exit code is non-zero" "0" "$exit_code"

    local status
    status=$(_json_field "$output" "status")
    assert_eq "invalid_key: status field is 'error'" "error" "$status"

    local code
    code=$(_json_field "$output" "code")
    assert_eq "invalid_key: code field is 'invalid_key'" "invalid_key" "$code"
}
test_invalid_key_exits_nonzero

# ══════════════════════════════════════════════════════════════════════════════
# Test 6: Wrong argument count — exits non-zero with usage error
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 6: Missing arguments — exits non-zero ──"

test_missing_args_exits_nonzero() {
    local exit_code=0
    bash "$SCRATCH_GET" >/dev/null 2>&1 || exit_code=$?

    assert_ne "missing-args: exit code is non-zero" "0" "$exit_code"
}
test_missing_args_exits_nonzero

# ══════════════════════════════════════════════════════════════════════════════
# Test 7: HIT — output contains only the hit envelope (no extra lines)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 7: HIT output is valid JSON parseable by python3 ──"

test_hit_output_is_valid_json() {
    local base
    base=$(_make_scratch_base)

    local ticket_id="json-valid-1234-abcd"
    local key="jsontest"
    local value="check-json"

    local abs_path="$base/$ticket_id/$key"
    local ts
    ts=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())")
    local payload
    payload=$(python3 -c "import json; print(json.dumps({'status':'stored','ts':'$ts','ticket_id':'$ticket_id','key':'$key','value':'$value'}))")
    _scratch_atomic_write "$abs_path" "$payload" >/dev/null 2>&1

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_GET" "$ticket_id" "$key" 2>/dev/null) \
        || exit_code=$?

    assert_eq "hit-json: exit 0" "0" "$exit_code"

    # Must be parseable as JSON
    local parse_ok
    parse_ok=$(echo "$output" | python3 -c "import json,sys; json.loads(sys.stdin.read()); print('ok')" 2>/dev/null || echo "fail")
    assert_eq "hit-json: output is valid JSON" "ok" "$parse_ok"
}
test_hit_output_is_valid_json

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
print_summary
