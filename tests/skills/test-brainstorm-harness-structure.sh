#!/usr/bin/env bash
# Structural tests for brainstorm replay harness: directory existence and runner registration.
# NOTE: These tests are intentionally RED — tests/brainstorm/ does not exist yet and
# commands.test_dirs does not include it. They will turn GREEN when the harness is created.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
# fail() prints a machine-readable "FAIL: section_name" line (required by parse_failing_tests_from_output
# in red-zone.sh, which uses pattern '^FAIL: [a-zA-Z_][a-zA-Z0-9_-]*') followed by the human-readable
# message. The section name is set by each "=== section_name ===" block below.
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ============================================================
echo ""
echo "=== test_harness_directory_exists ==="
SECTION="test_harness_directory_exists"

HARNESS_DIR="$REPO_ROOT/tests/brainstorm"

if [ -d "$HARNESS_DIR" ]; then
  pass "tests/brainstorm/ directory exists"
else
  fail "tests/brainstorm/ directory does not exist (harness not yet created)"
fi

# Check for at least one test runner file in the harness directory
if find "$HARNESS_DIR" -maxdepth 1 -name "test-*.sh" 2>/dev/null | head -1 | grep -q test-; then
  pass "tests/brainstorm/ contains at least one test runner file (test-*.sh)"
else
  fail "tests/brainstorm/ missing test runner files (no test-*.sh found)"
fi

# ============================================================
echo ""
echo "=== test_runner_registration ==="
SECTION="test_runner_registration"

DSO_CONFIG="$REPO_ROOT/.claude/dso-config.conf"

if [ -f "$DSO_CONFIG" ]; then
  pass ".claude/dso-config.conf exists"
else
  fail ".claude/dso-config.conf not found"
fi

# Check that tests/brainstorm is in commands.test_dirs
if grep -q 'commands\.test_dirs.*tests/brainstorm\|tests/brainstorm.*commands\.test_dirs' "$DSO_CONFIG" 2>/dev/null; then
  pass "commands.test_dirs in dso-config.conf includes tests/brainstorm"
else
  # Also check as a plain grep (the value may be on the same line as the key)
  _test_dirs_line=$(grep '^commands\.test_dirs=' "$DSO_CONFIG" 2>/dev/null || true)
  if echo "$_test_dirs_line" | grep -q 'tests/brainstorm'; then
    pass "commands.test_dirs in dso-config.conf includes tests/brainstorm"
  else
    fail "commands.test_dirs in dso-config.conf missing tests/brainstorm (current: ${_test_dirs_line:-not found})"
  fi
fi

# ============================================================
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo "VALIDATION FAILED"
  exit 1
fi

echo "ALL VALIDATIONS PASSED"
