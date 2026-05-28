#!/usr/bin/env bash
# tests/scratch/test-scratch-dispatcher.sh
# Behavioral tests for the `dso ticket scratch <verb>` dispatcher routing.
#
# Testing Mode: RED → GREEN
# Asserts that `dso ticket scratch set/get/clear` routes to the correct
# per-verb scripts (ticket-scratch-set.sh, ticket-scratch-get.sh,
# ticket-scratch-clear.sh) and that an unknown verb returns a structured
# error envelope with non-zero exit.
#
# Usage: bash tests/scratch/test-scratch-dispatcher.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

# Locate the dso shim
DSO_SHIM="$REPO_ROOT/.claude/scripts/dso"
# For direct dispatch we also point at the ticket dispatcher
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"

echo "=== test-scratch-dispatcher.sh: dso ticket scratch dispatcher routing tests ==="

# ── Preflight ────────────────────────────────────────────────────────────────
if [ ! -f "$TICKET_SCRIPT" ]; then
    echo "FATAL: ticket dispatcher not found at $TICKET_SCRIPT" >&2
    exit 1
fi

if [ ! -x "$TICKET_SCRIPT" ]; then
    echo "FATAL: ticket dispatcher is not executable: $TICKET_SCRIPT" >&2
    exit 1
fi

# Per-verb scripts must already exist (sibling agent shipped them)
for verb in set get clear; do
    script="$REPO_ROOT/plugins/dso/scripts/ticket-scratch-${verb}.sh"
    if [ ! -f "$script" ]; then
        echo "FATAL: ticket-scratch-${verb}.sh not found at $script" >&2
        exit 1
    fi
done

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
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/scratch-dispatcher-test-XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: `ticket scratch set` routes to ticket-scratch-set.sh — exits 0
# and emits ok JSON
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 1: 'ticket scratch set' routes to ticket-scratch-set.sh ──"
test_scratch_set_routing() {
    local base
    base=$(_make_scratch_base)

    local ticket_id="disp-set-test-abcd"
    local key="dispkey"
    local value="dispvalue"

    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" _TICKET_TEST_NO_SYNC=1 \
        bash "$TICKET_SCRIPT" scratch set "$ticket_id" "$key" "$value" 2>/dev/null) \
        || exit_code=$?

    assert_eq "scratch set exits 0" "0" "$exit_code"

    local status
    status=$(printf '%s' "$output" | python3 -c \
        "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" \
        2>/dev/null || echo "")
    assert_eq "scratch set returns status=ok" "ok" "$status"

    # The file must exist — confirming the real set script was invoked
    local abs_path="$base/$ticket_id/$key"
    assert_eq "scratch set wrote the file" "0" "$([ -f "$abs_path" ] && echo 0 || echo 1)"
}
test_scratch_set_routing

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: `ticket scratch get` routes to ticket-scratch-get.sh — exits 0
# and emits hit/miss JSON
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 2: 'ticket scratch get' routes to ticket-scratch-get.sh ──"
test_scratch_get_routing() {
    local base
    base=$(_make_scratch_base)

    local ticket_id="disp-get-test-efgh"
    local key="getkey"
    local value="getvalue"

    # First write via set
    SCRATCH_BASE_DIR="$base" _TICKET_TEST_NO_SYNC=1 \
        bash "$TICKET_SCRIPT" scratch set "$ticket_id" "$key" "$value" >/dev/null 2>&1

    # Now get
    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" _TICKET_TEST_NO_SYNC=1 \
        bash "$TICKET_SCRIPT" scratch get "$ticket_id" "$key" 2>/dev/null) \
        || exit_code=$?

    assert_eq "scratch get exits 0" "0" "$exit_code"

    local status
    status=$(printf '%s' "$output" | python3 -c \
        "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" \
        2>/dev/null || echo "")
    assert_eq "scratch get returns status=hit" "hit" "$status"

    # Confirm value is correct — proving the real get script ran
    local got_value
    got_value=$(printf '%s' "$output" | python3 -c \
        "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('value',''))" \
        2>/dev/null || echo "")
    assert_eq "scratch get returns correct value" "$value" "$got_value"
}
test_scratch_get_routing

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: `ticket scratch clear` routes to ticket-scratch-clear.sh — exits 0
# and emits ok JSON; file is removed
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 3: 'ticket scratch clear' routes to ticket-scratch-clear.sh ──"
test_scratch_clear_routing() {
    local base
    base=$(_make_scratch_base)

    local ticket_id="disp-clear-test-ijkl"
    local key="clearkey"
    local value="clearvalue"

    # Write a value first
    SCRATCH_BASE_DIR="$base" _TICKET_TEST_NO_SYNC=1 \
        bash "$TICKET_SCRIPT" scratch set "$ticket_id" "$key" "$value" >/dev/null 2>&1

    local abs_path="$base/$ticket_id/$key"
    assert_eq "file exists before clear" "0" "$([ -f "$abs_path" ] && echo 0 || echo 1)"

    # Now clear
    local output exit_code=0
    output=$(SCRATCH_BASE_DIR="$base" _TICKET_TEST_NO_SYNC=1 \
        bash "$TICKET_SCRIPT" scratch clear "$ticket_id" 2>/dev/null) \
        || exit_code=$?

    assert_eq "scratch clear exits 0" "0" "$exit_code"

    local status
    status=$(printf '%s' "$output" | python3 -c \
        "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" \
        2>/dev/null || echo "")
    assert_eq "scratch clear returns status=ok" "ok" "$status"

    # The file must be gone — proving the real clear script ran
    assert_eq "scratch clear removed the file" "1" "$([ -f "$abs_path" ] && echo 0 || echo 1)"
}
test_scratch_clear_routing

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: Unknown verb returns structured error envelope with non-zero exit
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 4: unknown verb returns structured error envelope, non-zero exit ──"
test_unknown_verb_error() {
    local output exit_code=0
    output=$(_TICKET_TEST_NO_SYNC=1 \
        bash "$TICKET_SCRIPT" scratch frobnicate test-001 2>/dev/null) \
        || exit_code=$?

    assert_ne "unknown verb exits non-zero" "0" "$exit_code"

    local status code verb_field
    status=$(printf '%s' "$output" | python3 -c \
        "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" \
        2>/dev/null || echo "")
    code=$(printf '%s' "$output" | python3 -c \
        "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('code',''))" \
        2>/dev/null || echo "")
    verb_field=$(printf '%s' "$output" | python3 -c \
        "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('verb',''))" \
        2>/dev/null || echo "")

    assert_eq "unknown verb returns status=error" "error" "$status"
    assert_eq "unknown verb returns code=unknown_verb" "unknown_verb" "$code"
    assert_eq "unknown verb echoes verb in envelope" "frobnicate" "$verb_field"
}
test_unknown_verb_error

# ══════════════════════════════════════════════════════════════════════════════
# Test 5: `ticket scratch` with no sub-verb also returns error (missing verb)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 5: 'ticket scratch' with no sub-verb exits non-zero ──"
test_missing_verb_error() {
    local exit_code=0
    _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" scratch 2>/dev/null \
        || exit_code=$?

    assert_ne "missing verb exits non-zero" "0" "$exit_code"
}
test_missing_verb_error

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
print_summary
