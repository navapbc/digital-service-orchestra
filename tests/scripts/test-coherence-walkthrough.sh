#!/usr/bin/env bash
# tests/scripts/test-coherence-walkthrough.sh
# Behavioral smoke test for plugins/dso/scripts/coherence-walkthrough.sh
#
# Testing Mode: GREEN — covers the Phase 3.5 walkthrough orchestrator added
# by story 5362-7f18-4f37-4fa9. Validates:
#   - --help renders the usage block
#   - missing required --epic-id yields a clear error
#   - --manifest produces a structured JSON manifest with 6 chunks under all
#     branches (including the no-API-key preview path which still emits a
#     manifest with chunk F getting a preview_error inline)
#
# Usage: bash tests/scripts/test-coherence-walkthrough.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
ORCH_SCRIPT="$REPO_ROOT/plugins/dso/scripts/coherence-walkthrough.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "=== test-coherence-walkthrough.sh ==="

if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$ORCH_SCRIPT" ]; then
    echo "SKIP: coherence-walkthrough.sh not yet implemented"
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# Test 1: script exists and is executable
if [ -x "$ORCH_SCRIPT" ]; then
    _pass "script exists and is executable"
else
    _fail "script missing or not executable"
fi

# Test 2: --help renders without error
help_out=$("$ORCH_SCRIPT" --help 2>&1)
if [ "$?" = "0" ] && echo "$help_out" | grep -q "coherence-walkthrough.sh"; then
    _pass "--help exits 0 and prints usage block"
else
    _fail "--help failed"
fi

# Test 3: missing --epic-id yields a clear error
err_out=$("$ORCH_SCRIPT" 2>&1)
err_rc=$?
if [ "$err_rc" = "1" ] && echo "$err_out" | grep -qiE "epic-id|required"; then
    _pass "missing --epic-id exits 1 with descriptive error"
else
    _fail "missing --epic-id did not exit 1 (rc=$err_rc, out='$err_out')"
fi

# Test 4: --manifest produces a structured manifest with 6 chunks (ANTHROPIC_API_KEY may be unset;
# the preview script will return preview_error, but the orchestrator still emits the manifest)
TMP_MANIFEST=$(mktemp /tmp/test-cw-manifest.XXXXXX.json)
trap 'rm -f "$TMP_MANIFEST"' EXIT
ANTHROPIC_API_KEY="" "$ORCH_SCRIPT" \
    --epic-id a03c-d55e-1393-4f27 \
    --limit 1 \
    --manifest "$TMP_MANIFEST" > /dev/null 2>&1
# Exit code may be 0 or 2 (soft preview failure); both are acceptable
if [ -s "$TMP_MANIFEST" ]; then
    CHUNK_COUNT=$(python3 -c "import json; m=json.load(open('$TMP_MANIFEST')); print(len(m.get('chunks', [])))" 2>/dev/null)
    if [ "$CHUNK_COUNT" = "6" ]; then
        _pass "--manifest emits 6 chunks"
    else
        _fail "--manifest produced $CHUNK_COUNT chunks (expected 6)"
    fi

    # Verify schema fields
    if python3 -c "
import json
m = json.load(open('$TMP_MANIFEST'))
required = ['schema_version', 'contract_doc', 'epic_id', 'dispatch_model', 'parallel_dispatch', 'retry_policy', 'chunks', 'aggregation_instructions']
for k in required:
    assert k in m, f'missing key: {k}'
assert m['dispatch_model'] == 'opus'
assert m['parallel_dispatch'] is True
assert m['retry_policy']['retries_per_chunk'] == 1
" 2>/dev/null; then
        _pass "manifest schema includes required fields with expected values"
    else
        _fail "manifest schema missing required fields"
    fi
else
    _fail "--manifest did not produce a non-empty file"
fi

echo ""
printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
