#!/usr/bin/env bash
# lockpick-workflow/tests/test-validate-phase-portability.sh
# Portability smoke test for validate-phase.sh with echo-command stub config.
#
# Verifies that validate-phase.sh produces correct structured output (PASS/FAIL
# lines, labels, exit codes) without any real toolchain installed.
# Proves the script is fully config-driven and portable to any stack.
#
# Manual run:
#   bash lockpick-workflow/tests/test-validate-phase-portability.sh
#
# Tests covered:
#   a. post-batch / all-pass config  → exit 0, FORMAT: PASS, LINT: PASS, TESTS: PASS
#   b. post-batch / lint: "false"    → exit 1, LINT: FAIL
#   c. tier-transition / all-pass    → exit 0, FORMAT: PASS, LINT: PASS, TESTS: PASS
#   d. auto-fix / all-pass           → exit 0 (smoke: runs without error)

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_SCRIPT="$SCRIPT_DIR/../scripts/validate-phase.sh"
READ_CONFIG_SH="$SCRIPT_DIR/../scripts/read-config.sh"

FAILURES=0
TESTS=0

pass() { TESTS=$((TESTS + 1)); echo "  PASS: $1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); echo "  FAIL: $1"; }

echo "=== Tests for validate-phase.sh portability ==="

# ---------------------------------------------------------------------------
# Setup: create a temp git repo with stub workflow-config.conf and symlinks.
#
# Temp dir structure:
#   $TMPDIR/                           ← REPO_ROOT (fake git repo)
#   $TMPDIR/workflow-config.conf       ← stub config (populated per scenario)
#   $TMPDIR/lockpick-workflow/scripts/
#       validate-phase.sh              ← symlink to canonical script
#       read-config.sh                 ← symlink to real read-config.sh
# ---------------------------------------------------------------------------

TMPDIR_BASE=$(mktemp -d)
trap "rm -rf '$TMPDIR_BASE'" EXIT

TMPDIR="$TMPDIR_BASE/repo"
mkdir -p "$TMPDIR/lockpick-workflow/scripts"

# Symlink canonical scripts into the fake repo so SCRIPT_DIR resolves correctly
# (validate-phase.sh resolves read-config.sh as a sibling via SCRIPT_DIR)
ln -s "$CANONICAL_SCRIPT" "$TMPDIR/lockpick-workflow/scripts/validate-phase.sh"
ln -s "$READ_CONFIG_SH" "$TMPDIR/lockpick-workflow/scripts/read-config.sh"

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
(cd "$TMPDIR" && git init -q && git config user.email "test@test.com" && git config user.name "Test")

# ---------------------------------------------------------------------------
# Helper: write an all-pass stub workflow-config.conf
# ---------------------------------------------------------------------------
write_all_pass_config() {
    cat > "$TMPDIR/workflow-config.conf" << 'WCFG'
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
cat > "$TMPDIR/workflow-config.conf" << 'WCFG'
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
