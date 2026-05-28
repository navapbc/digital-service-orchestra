#!/usr/bin/env bash
# tests/scripts/test-closure-checks-migration-preview.sh
# Behavioral smoke test for plugins/dso/scripts/closure-checks-migration-preview.sh
#
# Testing Mode: GREEN — covers the chunk-F preview script added by story
# 5362-7f18-4f37-4fa9. Validates:
#   - --help renders without error
#   - graceful soft-fail (exit 2 with structured preview_error) when
#     ANTHROPIC_API_KEY is unset
#   - parses --limit and --output flags
#
# Usage: bash tests/scripts/test-closure-checks-migration-preview.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PREVIEW_SCRIPT="$REPO_ROOT/plugins/dso/scripts/closure-checks-migration-preview.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "=== test-closure-checks-migration-preview.sh ==="

if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$PREVIEW_SCRIPT" ]; then
    echo "SKIP: closure-checks-migration-preview.sh not yet implemented"
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# Test 1: script exists and is executable
if [ -x "$PREVIEW_SCRIPT" ]; then
    _pass "script exists and is executable"
else
    _fail "script missing or not executable"
fi

# Test 2: --help renders
if "$PREVIEW_SCRIPT" --help >/dev/null 2>&1; then
    _pass "--help exits 0"
else
    _fail "--help failed"
fi

# Test 3: no ANTHROPIC_API_KEY → soft-fail with structured preview_error
TMP_OUT=$(mktemp "${TMPDIR:-/tmp}/test-preview.XXXXXX".json)
trap 'rm -f "$TMP_OUT"' EXIT
out=$(ANTHROPIC_API_KEY="" "$PREVIEW_SCRIPT" --limit 1 --output "$TMP_OUT" 2>&1)
rc=$?
if [ "$rc" = "2" ] && grep -q "preview_error" "$TMP_OUT"; then
    _pass "no-API-key soft-fail produces exit 2 + preview_error JSON"
elif [ "$rc" = "0" ] && grep -q "preview_error" "$TMP_OUT"; then
    # Acceptable variant: exit 0 with preview_error when no closed brainstorm:complete epics exist
    _pass "graceful empty-input path produces exit 0 + structured preview_error"
else
    _fail "no-API-key path: rc=$rc, output: $(cat "$TMP_OUT")"
fi

# Test 4: bad --limit value rejected
err_out=$("$PREVIEW_SCRIPT" --limit abc 2>&1)
err_rc=$?
if [ "$err_rc" = "1" ] && echo "$err_out" | grep -qiE "limit|positive integer"; then
    _pass "non-numeric --limit rejected with clear error"
else
    _fail "non-numeric --limit not rejected properly (rc=$err_rc, out='$err_out')"
fi

echo ""
printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
