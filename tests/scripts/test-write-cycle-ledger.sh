#!/usr/bin/env bash
# tests/scripts/test-write-cycle-ledger.sh
# RED-phase tests for plugins/dso/scripts/write-cycle-ledger.sh
#
# The script under test does NOT exist yet — all tests must fail (RED).
#
# Behaviors under test:
#   1. test_write_cycle_ledger_creates_file         — happy-path write: file created with correct JSON schema
#   2. test_write_cycle_ledger_concurrent_safe      — 3 parallel writes produce a valid (non-corrupt) JSON file
#   3. test_write_cycle_ledger_missing_artifacts_dir_fails — exits non-zero when artifacts dir cannot be used
#   4. test_write_cycle_ledger_invalid_json_fails   — exits non-zero when --payload is not valid JSON
#
# Usage: bash tests/scripts/test-write-cycle-ledger.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/write-cycle-ledger.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Global cleanup registry — each test appends its temp dir here.
declare -a CLEANUP_DIRS=()
trap 'rm -rf "${CLEANUP_DIRS[@]:-}"' EXIT

# ---------------------------------------------------------------------------
# TEST 1: Happy-path write — file created with correct JSON schema fields
# ---------------------------------------------------------------------------

test_write_cycle_ledger_creates_file() {
    local ARTIFACTS_DIR
    ARTIFACTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-write-cycle-ledger-XXXXXX")"
    CLEANUP_DIRS+=("$ARTIFACTS_DIR")

    local PAYLOAD='{"cycle":1,"findings_summary":{"critical":0,"important":1}}'

    local output exit_code=0
    output=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR" \
        bash "$SCRIPT" \
        --artifacts-dir "$ARTIFACTS_DIR" \
        --payload "$PAYLOAD" 2>&1) || exit_code=$?

    assert_eq "test_write_cycle_ledger_creates_file: exits 0" "0" "$exit_code"

    local ledger_file="$ARTIFACTS_DIR/cycle-ledger.json"

    if [[ -f "$ledger_file" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_write_cycle_ledger_creates_file: cycle-ledger.json not created\n  output: %s\n" "$output" >&2
    fi

    # Validate required top-level schema fields: schema_version, epic_id, cycles
    if [[ -f "$ledger_file" ]]; then
        local schema_ok
        schema_ok=$(python3 - "$ledger_file" <<'PYEOF'
import sys, json
data = json.load(open(sys.argv[1]))
required = {"schema_version", "epic_id", "cycles"}
missing = required - set(data.keys())
if missing:
    print("missing_fields:" + ",".join(sorted(missing)))
else:
    print("ok")
PYEOF
)
        assert_eq "test_write_cycle_ledger_creates_file: schema fields present" "ok" "$schema_ok"

        # Validate cycles is a list
        local cycles_type
        cycles_type=$(python3 - "$ledger_file" <<'PYEOF'
import sys, json
data = json.load(open(sys.argv[1]))
print("list" if isinstance(data.get("cycles"), list) else "not-list")
PYEOF
)
        assert_eq "test_write_cycle_ledger_creates_file: cycles is array" "list" "$cycles_type"
    fi
}

test_write_cycle_ledger_creates_file

# ---------------------------------------------------------------------------
# TEST 2: Concurrent writes do not corrupt the ledger file
# ---------------------------------------------------------------------------

test_write_cycle_ledger_concurrent_safe() {
    local ARTIFACTS_DIR
    ARTIFACTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-write-cycle-ledger-concurrent-XXXXXX")"
    CLEANUP_DIRS+=("$ARTIFACTS_DIR")

    # Spawn 3 parallel writes; each carries a distinct cycle number
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR" \
        bash "$SCRIPT" --artifacts-dir "$ARTIFACTS_DIR" \
        --payload '{"cycle":1,"findings_summary":{"critical":0}}' 2>/dev/null &
    local pid1=$!

    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR" \
        bash "$SCRIPT" --artifacts-dir "$ARTIFACTS_DIR" \
        --payload '{"cycle":2,"findings_summary":{"critical":1}}' 2>/dev/null &
    local pid2=$!

    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR" \
        bash "$SCRIPT" --artifacts-dir "$ARTIFACTS_DIR" \
        --payload '{"cycle":3,"findings_summary":{"critical":0}}' 2>/dev/null &
    local pid3=$!

    # Wait for all background processes before asserting
    wait $pid1 $pid2 $pid3 2>/dev/null || true

    local ledger_file="$ARTIFACTS_DIR/cycle-ledger.json"

    if [[ ! -f "$ledger_file" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_write_cycle_ledger_concurrent_safe: ledger file not created\n" >&2
        return
    fi

    # File must be valid JSON (no corruption)
    local json_valid
    json_valid=$(python3 -c "
import sys, json
try:
    data = json.load(open('$ledger_file'))
    print('valid')
except Exception as e:
    print('invalid:' + str(e))
" 2>&1)

    assert_eq "test_write_cycle_ledger_concurrent_safe: file is valid JSON after concurrent writes" "valid" "$json_valid"
}

test_write_cycle_ledger_concurrent_safe

# ---------------------------------------------------------------------------
# TEST 3: Missing / non-writable artifacts dir exits non-zero
# ---------------------------------------------------------------------------

test_write_cycle_ledger_missing_artifacts_dir_fails() {
    # Use a path that cannot be created (subdirectory of a non-existent read-only path)
    local BAD_DIR
    BAD_DIR="/nonexistent-root-$$-$(date +%s)/artifacts"

    local output exit_code=0
    output=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$BAD_DIR" \
        bash "$SCRIPT" \
        --artifacts-dir "$BAD_DIR" \
        --payload '{"cycle":1,"findings_summary":{}}' 2>&1) || exit_code=$?

    assert_ne "test_write_cycle_ledger_missing_artifacts_dir_fails: exits non-zero" "0" "$exit_code"
    assert_contains "test_write_cycle_ledger_missing_artifacts_dir_fails: stderr mentions error" \
        "error" "$(echo "$output" | tr '[:upper:]' '[:lower:]')"
}

test_write_cycle_ledger_missing_artifacts_dir_fails

# ---------------------------------------------------------------------------
# TEST 4: Invalid JSON payload exits non-zero
# ---------------------------------------------------------------------------

test_write_cycle_ledger_invalid_json_fails() {
    local ARTIFACTS_DIR
    ARTIFACTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-write-cycle-ledger-invalid-XXXXXX")"
    CLEANUP_DIRS+=("$ARTIFACTS_DIR")

    local output exit_code=0
    output=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR" \
        bash "$SCRIPT" \
        --artifacts-dir "$ARTIFACTS_DIR" \
        --payload 'not-valid-json' 2>&1) || exit_code=$?

    assert_ne "test_write_cycle_ledger_invalid_json_fails: exits non-zero" "0" "$exit_code"
}

test_write_cycle_ledger_invalid_json_fails

# ---------------------------------------------------------------------------

print_summary
