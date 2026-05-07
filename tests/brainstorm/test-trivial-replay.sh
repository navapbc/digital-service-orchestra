#!/usr/bin/env bash
# test-trivial-replay.sh: Trivial end-to-end harness smoke test.
# Verifies fixture loading and assertion helper functionality.
# Set SKIP_LLM_REPLAY=1 to skip LLM-dependent assertions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HARNESS_DIR="$REPO_ROOT/tests/brainstorm"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== test_fixture_exists ==="
FIXTURE="$HARNESS_DIR/fixtures/example-ticket.json"
if [ -f "$FIXTURE" ]; then
  pass "Fixture file exists: $FIXTURE"
else
  fail "Fixture file missing: $FIXTURE"
fi

echo ""
echo "=== test_fixture_valid_json ==="
if python3 -c "import json; json.load(open('$FIXTURE'))" 2>/dev/null; then
  pass "Fixture is valid JSON"
else
  fail "Fixture is not valid JSON"
fi

echo ""
echo "=== test_assertion_helper_works ==="
source "$HARNESS_DIR/helpers/assert-golden.sh"
if assert_contains "hello world" "world" "assert_contains basic functionality" 2>/dev/null; then
  pass "assert-golden.sh assertion helper works"
else
  fail "assert-golden.sh assertion helper failed"
fi

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL VALIDATIONS PASSED" && exit 0
echo "VALIDATION FAILED"
exit 1
