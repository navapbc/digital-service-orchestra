#!/usr/bin/env bash
# tests/test-validate-phase-portability.sh
# Portability smoke test for validate-phase.sh with echo-command stub config.
#
# Verifies that validate-phase.sh produces correct structured output (PASS/FAIL
# lines, labels, exit codes) without any real toolchain installed.
# Proves the script is fully config-driven and portable to any stack.
#
# Manual run:
#   bash tests/test-validate-phase-portability.sh
#
# Tests covered:
#   a. post-batch / all-pass config  → exit 0, FORMAT: PASS, LINT: PASS, TESTS: PASS
#   b. post-batch / lint: "false"    → exit 1, LINT: FAIL
#   c. tier-transition / all-pass    → exit 0, FORMAT: PASS, LINT: PASS, TESTS: PASS
#   d. auto-fix / all-pass           → exit 0 (smoke: runs without error)

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_SCRIPT="$SCRIPT_DIR/../plugins/dso/scripts/validate-phase.sh"
READ_CONFIG_SH="$SCRIPT_DIR/../plugins/dso/scripts/read-config.sh"

FAILURES=0
TESTS=0

pass() { TESTS=$((TESTS + 1)); echo "  PASS: $1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); echo "  FAIL: $1"; }

echo "=== Tests for validate-phase.sh portability ==="

# ---------------------------------------------------------------------------
# Setup: create a temp git repo with stub dso-config.conf and symlinks.
#
# Temp dir structure:
#   $TMPDIR/                           ← REPO_ROOT (fake git repo)
#   $TMPDIR/dso-config.conf       ← stub config (populated per scenario)
#   $TMPDIR/scripts/
#       validate-phase.sh              ← symlink to canonical script
#       read-config.sh                 ← symlink to real read-config.sh
# ---------------------------------------------------------------------------

TMPDIR_BASE=$(mktemp -d)
trap "rm -rf '$TMPDIR_BASE'" EXIT

TMPDIR="$TMPDIR_BASE/repo"
mkdir -p "$TMPDIR/scripts" "$TMPDIR/.claude"

# Symlink canonical scripts into the fake repo so SCRIPT_DIR resolves correctly
# (validate-phase.sh resolves read-config.sh as a sibling via SCRIPT_DIR)
ln -s "$CANONICAL_SCRIPT" "$TMPDIR/scripts/validate-phase.sh"
ln -s "$READ_CONFIG_SH" "$TMPDIR/scripts/read-config.sh"

# Provide a YAML interpreter for read-config.sh:
# read-config.sh auto-probes $REPO_ROOT/app/.venv/bin/interp-name first.
# Symlink the real project venv's bin directory into the fake repo so the probe succeeds.
# This avoids any project-specific toolchain being referenced in the test file itself.
VENV_BIN="$SCRIPT_DIR/../../app/.venv/bin"
if [ -d "$VENV_BIN" ]; then
    mkdir -p "$TMPDIR/app/.venv"
    ln -s "$(cd "$VENV_BIN" && pwd)" "$TMPDIR/app/.venv/bin"
fi
# If the venv bin isn't present (e.g., in CI without the app stack), read-config.sh
# falls back to system interpreters. If none have pyyaml, tests will fail with a
# clear error message from read-config.sh rather than a cryptic failure.

# Initialize a minimal git repo (required by validate-phase.sh for git rev-parse)
(cd "$TMPDIR" && git init -q -b main && git config user.email "test@test.com" && git config user.name "Test")

# ---------------------------------------------------------------------------
# Helper: write an all-pass stub dso-config.conf at $TMPDIR/.claude/dso-config.conf
# validate-phase.sh reads from $REPO_ROOT/.claude/dso-config.conf (where
# REPO_ROOT = git rev-parse --show-toplevel of the temp repo = $TMPDIR).
# ---------------------------------------------------------------------------
write_all_pass_config() {
    cat > "$TMPDIR/.claude/dso-config.conf" << 'WCFG'
commands.format=true
commands.format_check=true
commands.lint=true
commands.lint_fix=true
commands.test_unit=echo '1 passed'
commands.validate=true
WCFG
}

# ---------------------------------------------------------------------------
# Helper: run validate-phase.sh from within the temp git repo
# Usage: run_phase <phase>
# Sets output into $RUN_OUTPUT and exit code into $RUN_EXIT
#
# We cd into $TMPDIR so that git rev-parse --show-toplevel returns $TMPDIR
# (the temp repo root), causing validate-phase.sh to read our stub config.
# ---------------------------------------------------------------------------
run_phase() {
    local phase="$1"
    RUN_OUTPUT=""
    RUN_EXIT=0
    RUN_OUTPUT=$(
        cd "$TMPDIR" && bash "$CANONICAL_SCRIPT" "$phase" 2>&1
    ) || RUN_EXIT=$?
}

# ---------------------------------------------------------------------------
# Test a: post-batch with all-pass config
#   - exit 0
#   - output has FORMAT: PASS
#   - output has LINT: PASS
#   - output has TESTS: PASS
# ---------------------------------------------------------------------------
echo ""
echo "Test a: post-batch / all-pass config"
write_all_pass_config
run_phase "post-batch"

if [ "$RUN_EXIT" -eq 0 ]; then
    pass "post-batch all-pass: exit 0"
else
    fail "post-batch all-pass: expected exit 0, got $RUN_EXIT (output: $RUN_OUTPUT)"
fi

if echo "$RUN_OUTPUT" | grep -q "FORMAT: PASS"; then
    pass "post-batch all-pass: output has FORMAT: PASS"
else
    fail "post-batch all-pass: output missing FORMAT: PASS (output: $RUN_OUTPUT)"
fi

if echo "$RUN_OUTPUT" | grep -q "LINT: PASS"; then
    pass "post-batch all-pass: output has LINT: PASS"
else
    fail "post-batch all-pass: output missing LINT: PASS (output: $RUN_OUTPUT)"
fi

if echo "$RUN_OUTPUT" | grep -q "TESTS: PASS"; then
    pass "post-batch all-pass: output has TESTS: PASS"
else
    fail "post-batch all-pass: output missing TESTS: PASS (output: $RUN_OUTPUT)"
fi

# ---------------------------------------------------------------------------
# Test b: post-batch with lint: "false" (should fail)
#   - exit 1
#   - output has LINT: FAIL
# ---------------------------------------------------------------------------
echo ""
echo "Test b: post-batch / lint: false config"
cat > "$TMPDIR/.claude/dso-config.conf" << 'WCFG'
commands.format=true
commands.format_check=true
commands.lint=false
commands.lint_fix=true
commands.test_unit=echo '1 passed'
commands.validate=true
WCFG

run_phase "post-batch"

if [ "$RUN_EXIT" -ne 0 ]; then
    pass "post-batch lint-fail: exit non-zero"
else
    fail "post-batch lint-fail: expected non-zero exit, got 0 (output: $RUN_OUTPUT)"
fi

if echo "$RUN_OUTPUT" | grep -q "LINT: FAIL"; then
    pass "post-batch lint-fail: output has LINT: FAIL"
else
    fail "post-batch lint-fail: output missing LINT: FAIL (output: $RUN_OUTPUT)"
fi

# ---------------------------------------------------------------------------
# Test c: tier-transition with all-pass config
#   - exit 0
#   - output has FORMAT: PASS
#   - output has LINT: PASS
#   - output has TESTS: PASS
# ---------------------------------------------------------------------------
echo ""
echo "Test c: tier-transition / all-pass config"
write_all_pass_config
run_phase "tier-transition"

if [ "$RUN_EXIT" -eq 0 ]; then
    pass "tier-transition all-pass: exit 0"
else
    fail "tier-transition all-pass: expected exit 0, got $RUN_EXIT (output: $RUN_OUTPUT)"
fi

if echo "$RUN_OUTPUT" | grep -q "FORMAT: PASS"; then
    pass "tier-transition all-pass: output has FORMAT: PASS"
else
    fail "tier-transition all-pass: output missing FORMAT: PASS (output: $RUN_OUTPUT)"
fi

if echo "$RUN_OUTPUT" | grep -q "LINT: PASS"; then
    pass "tier-transition all-pass: output has LINT: PASS"
else
    fail "tier-transition all-pass: output missing LINT: PASS (output: $RUN_OUTPUT)"
fi

if echo "$RUN_OUTPUT" | grep -q "TESTS: PASS"; then
    pass "tier-transition all-pass: output has TESTS: PASS"
else
    fail "tier-transition all-pass: output missing TESTS: PASS (output: $RUN_OUTPUT)"
fi

# ---------------------------------------------------------------------------
# Test d: auto-fix with all-pass config (smoke test: runs without error)
#   - exit 0
# (collect_modified uses find with source_dirs; empty list falls back to
#  default dirs which may not exist — the script handles this with || true)
# ---------------------------------------------------------------------------
echo ""
echo "Test d: auto-fix / all-pass config (smoke test)"
write_all_pass_config
run_phase "auto-fix"

if [ "$RUN_EXIT" -eq 0 ]; then
    pass "auto-fix all-pass: exit 0 (smoke test)"
else
    fail "auto-fix all-pass: expected exit 0, got $RUN_EXIT (output: $RUN_OUTPUT)"
fi

# ---------------------------------------------------------------------------
# Test e: post-batch with no commands.lint_fix in config (bug dso-0gqr)
#   - exit 0 (not 2) — lint_fix is optional; absence must not abort the script
# ---------------------------------------------------------------------------
echo ""
echo "Test e: post-batch / config WITHOUT commands.lint_fix"
cat > "$TMPDIR/.claude/dso-config.conf" << 'WCFG'
commands.format=true
commands.format_check=true
commands.lint=true
commands.test_unit=echo '1 passed'
commands.validate=true
WCFG

run_phase "post-batch"

if [ "$RUN_EXIT" -eq 0 ]; then
    pass "post-batch no-lint_fix: exit 0 (lint_fix is optional)"
else
    fail "post-batch no-lint_fix: expected exit 0, got $RUN_EXIT (output: $RUN_OUTPUT)"
fi

# ---------------------------------------------------------------------------
# Test f: post-batch uses test-batched.sh when VALIDATE_TEST_BATCHED_SCRIPT is set
#   Verifies dso-qlgq fix: validate-phase.sh must delegate test execution to
#   test-batched.sh rather than running CMD_TEST_UNIT via raw eval.
#   A stub test-batched.sh is injected via VALIDATE_TEST_BATCHED_SCRIPT env var.
#   The stub writes a sentinel file to confirm it was called, then echoes
#   "1/1 tests completed." to simulate a passing run.
# ---------------------------------------------------------------------------
echo ""
echo "Test f: post-batch / test-batched.sh delegation (dso-qlgq)"
write_all_pass_config

# Create a stub test-batched.sh that records it was called
STUB_BATCHED="$TMPDIR/stub-test-batched.sh"
STUB_SENTINEL="$TMPDIR/test-batched-called"
cat > "$STUB_BATCHED" << 'STUB'
#!/usr/bin/env bash
# Stub: record that test-batched.sh was called and emit a passing summary
touch "$STUB_SENTINEL_PATH"
echo "1/1 tests completed."
echo "All tests done. 1/1 tests completed. 1 passed, 0 failed."
exit 0
STUB
chmod +x "$STUB_BATCHED"

RUN_OUTPUT=""
RUN_EXIT=0
RUN_OUTPUT=$(
    cd "$TMPDIR" && \
    STUB_SENTINEL_PATH="$STUB_SENTINEL" \
    VALIDATE_TEST_BATCHED_SCRIPT="$STUB_BATCHED" \
    bash "$CANONICAL_SCRIPT" "post-batch" 2>&1
) || RUN_EXIT=$?

if [ "$RUN_EXIT" -eq 0 ]; then
    pass "post-batch test-batched delegation: exit 0"
else
    fail "post-batch test-batched delegation: expected exit 0, got $RUN_EXIT (output: $RUN_OUTPUT)"
fi

if [ -f "$STUB_SENTINEL" ]; then
    pass "post-batch test-batched delegation: test-batched.sh was called"
else
    fail "post-batch test-batched delegation: test-batched.sh was NOT called (raw eval used instead)"
fi

if echo "$RUN_OUTPUT" | grep -q "TESTS: PASS"; then
    pass "post-batch test-batched delegation: output has TESTS: PASS"
else
    fail "post-batch test-batched delegation: output missing TESTS: PASS (output: $RUN_OUTPUT)"
fi

# ---------------------------------------------------------------------------
# Test g: tier-transition uses test-batched.sh when VALIDATE_TEST_BATCHED_SCRIPT is set
# ---------------------------------------------------------------------------
echo ""
echo "Test g: tier-transition / test-batched.sh delegation (dso-qlgq)"
write_all_pass_config

STUB_SENTINEL_G="$TMPDIR/test-batched-called-g"
RUN_OUTPUT=""
RUN_EXIT=0
RUN_OUTPUT=$(
    cd "$TMPDIR" && \
    STUB_SENTINEL_PATH="$STUB_SENTINEL_G" \
    VALIDATE_TEST_BATCHED_SCRIPT="$STUB_BATCHED" \
    bash "$CANONICAL_SCRIPT" "tier-transition" 2>&1
) || RUN_EXIT=$?

if [ "$RUN_EXIT" -eq 0 ]; then
    pass "tier-transition test-batched delegation: exit 0"
else
    fail "tier-transition test-batched delegation: expected exit 0, got $RUN_EXIT (output: $RUN_OUTPUT)"
fi

if [ -f "$STUB_SENTINEL_G" ]; then
    pass "tier-transition test-batched delegation: test-batched.sh was called"
else
    fail "tier-transition test-batched delegation: test-batched.sh was NOT called (raw eval used instead)"
fi

# ---------------------------------------------------------------------------
# Test h: auto-fix uses test-batched.sh when VALIDATE_TEST_BATCHED_SCRIPT is set
# ---------------------------------------------------------------------------
echo ""
echo "Test h: auto-fix / test-batched.sh delegation (dso-qlgq)"
write_all_pass_config

STUB_SENTINEL_H="$TMPDIR/test-batched-called-h"
RUN_OUTPUT=""
RUN_EXIT=0
RUN_OUTPUT=$(
    cd "$TMPDIR" && \
    STUB_SENTINEL_PATH="$STUB_SENTINEL_H" \
    VALIDATE_TEST_BATCHED_SCRIPT="$STUB_BATCHED" \
    bash "$CANONICAL_SCRIPT" "auto-fix" 2>&1
) || RUN_EXIT=$?

if [ "$RUN_EXIT" -eq 0 ]; then
    pass "auto-fix test-batched delegation: exit 0"
else
    fail "auto-fix test-batched delegation: expected exit 0, got $RUN_EXIT (output: $RUN_OUTPUT)"
fi

if [ -f "$STUB_SENTINEL_H" ]; then
    pass "auto-fix test-batched delegation: test-batched.sh was called"
else
    fail "auto-fix test-batched delegation: test-batched.sh was NOT called (raw eval used instead)"
fi

# ---------------------------------------------------------------------------
# Test i: post-batch with RUN: output from test-batched.sh exits 2 (pending)
# ---------------------------------------------------------------------------
echo ""
echo "Test i: post-batch / RUN: output from test-batched.sh → exit 2 (dso-qlgq, 2731-c62d)"
write_all_pass_config

STUB_NEXT="$TMPDIR/stub-test-batched-next.sh"
STUB_SENTINEL_I="$TMPDIR/test-batched-called-i"
cat > "$STUB_NEXT" << 'STUB'
#!/usr/bin/env bash
# Stub: simulate a partial (time-bounded) run — emit RUN: and exit 0
touch "$STUB_SENTINEL_PATH"
echo "0/1 tests completed."
echo "RUN: TEST_BATCHED_STATE_FILE=/tmp/state.json bash /path/to/test-batched.sh 'bash tests/run-all.sh'"
exit 0
STUB
chmod +x "$STUB_NEXT"

RUN_OUTPUT=""
RUN_EXIT=0
RUN_OUTPUT=$(
    cd "$TMPDIR" && \
    STUB_SENTINEL_PATH="$STUB_SENTINEL_I" \
    VALIDATE_TEST_BATCHED_SCRIPT="$STUB_NEXT" \
    bash "$CANONICAL_SCRIPT" "post-batch" 2>&1
) || RUN_EXIT=$?

if [ "$RUN_EXIT" -eq 2 ]; then
    pass "post-batch RUN: pending: exit 2"
else
    fail "post-batch RUN: pending: expected exit 2 (pending), got $RUN_EXIT (output: $RUN_OUTPUT)"
fi

if echo "$RUN_OUTPUT" | grep -q "TESTS: PENDING"; then
    pass "post-batch RUN: pending: output has TESTS: PENDING"
else
    fail "post-batch RUN: pending: output missing TESTS: PENDING (output: $RUN_OUTPUT)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $((TESTS - FAILURES))/$TESTS passed ==="
if (( FAILURES > 0 )); then
    echo "FAILED: $FAILURES test(s) failed"
    exit 1
else
    echo "All tests passed."
    exit 0
fi
