#!/usr/bin/env bash
# tests/scripts/test-validate-skip-ci-flag.sh
# TDD tests for --skip-ci flag in validate.sh.
#
# Bug: w21-jb9k — Local validation sub-agent redundantly checks CI status
# during post-epic validation. validate.sh --ci includes a ci(main) check
# that duplicates the dedicated ci-status.sh sub-agent.
#
# Fix: Add --skip-ci flag so local-validation sub-agent can skip CI check.
#
# Tests:
#   test_skip_ci_appears_in_help            -- --skip-ci flag documented in --help
#   test_skip_ci_suppresses_ci_check        -- validate.sh --ci --skip-ci skips CI check
#   test_skip_ci_standalone_no_ci_check     -- validate.sh --skip-ci alone produces no ci line
#   test_skip_ci_overrides_ci_flag          -- --skip-ci takes precedence over --ci
#
# Usage: bash tests/scripts/test-validate-skip-ci-flag.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

VALIDATE_SH="$DSO_PLUGIN_DIR/scripts/validate.sh"

echo "=== test-validate-skip-ci-flag.sh ==="

# Temp dirs
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Build stub commands that always pass immediately, overriding all checks.
# This lets us run validate.sh quickly without needing a real project.
STUB_BIN="$TMPDIR_TEST/stub_bin"
mkdir -p "$STUB_BIN"

# Stub for make commands: always exits 0
cat > "$STUB_BIN/make" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_BIN/make"

# Stub for bash (only for check-skill-refs.sh invocation — we allow real bash for other calls)
# We instead set VALIDATE_CMD_TEST to skip tests by stubbing the test command only.

# ── test_skip_ci_appears_in_help ─────────────────────────────────────────────
_snapshot_fail

help_output=$(bash "$VALIDATE_SH" --help 2>&1)
assert_contains "test_skip_ci_appears_in_help" "--skip-ci" "$help_output"

assert_pass_if_clean "test_skip_ci_appears_in_help"

# ── test_skip_ci_suppresses_ci_check ─────────────────────────────────────────
# When --ci --skip-ci is passed, the output must NOT contain a "ci:" or "ci(main):" line.
# We stub all check commands to exit 0 quickly so validate.sh completes fast.
_snapshot_fail

# Create a mock gh that would be called for CI check — if called, it records the call.
GH_CALL_FILE="$TMPDIR_TEST/gh-was-called"
cat > "$STUB_BIN/gh" << GHSTUB
#!/usr/bin/env bash
# Record that gh was called (should NOT happen when --skip-ci is active)
echo "gh called: \$*" > "$GH_CALL_FILE"
echo '[]'
exit 0
GHSTUB
chmod +x "$STUB_BIN/gh"

# Stub test-batched.sh to simulate passing tests immediately
STUB_TEST_BATCHED="$TMPDIR_TEST/test-batched.sh"
cat > "$STUB_TEST_BATCHED" << 'TBSTUB'
#!/usr/bin/env bash
exit 0
TBSTUB
chmod +x "$STUB_TEST_BATCHED"

# Stub check-script-writes.py (python3 call) — not relevant to CI check
# Use PATH injection to provide stubbed make, gh, and other binaries.

rc=0
output=$(PATH="$STUB_BIN:$PATH" \
    VALIDATE_CMD_TEST="true" \
    VALIDATE_SKIP_PLUGIN_CHECKS=1 \
    VALIDATE_TEST_BATCHED_SCRIPT="$STUB_TEST_BATCHED" \
    bash "$VALIDATE_SH" --ci --skip-ci 2>&1) || rc=$?

# gh should NOT have been called when --skip-ci is set
if [ -f "$GH_CALL_FILE" ]; then
    assert_eq "test_skip_ci_suppresses_ci_check gh not called" "false" "true ($(cat "$GH_CALL_FILE"))"
else
    assert_eq "test_skip_ci_suppresses_ci_check gh not called" "false" "false"
fi

# Output should NOT contain a "ci:" or "ci(main):" line
if [[ "$output" =~ ^[[:space:]]+ci(\(main\))?: ]]; then
    assert_eq "test_skip_ci_suppresses_ci_check no ci line in output" "absent" "present"
else
    assert_eq "test_skip_ci_suppresses_ci_check no ci line in output" "absent" "absent"
fi

assert_pass_if_clean "test_skip_ci_suppresses_ci_check"

# ── test_skip_ci_standalone_no_ci_check ──────────────────────────────────────
# When --skip-ci is passed WITHOUT --ci, there should also be no CI check.
_snapshot_fail

GH_CALL_FILE2="$TMPDIR_TEST/gh-was-called2"
cat > "$STUB_BIN/gh" << GHSTUB2
#!/usr/bin/env bash
echo "gh called: \$*" > "$GH_CALL_FILE2"
echo '[]'
exit 0
GHSTUB2
chmod +x "$STUB_BIN/gh"

rc=0
output=$(PATH="$STUB_BIN:$PATH" \
    VALIDATE_CMD_TEST="true" \
    VALIDATE_SKIP_PLUGIN_CHECKS=1 \
    VALIDATE_TEST_BATCHED_SCRIPT="$STUB_TEST_BATCHED" \
    bash "$VALIDATE_SH" --skip-ci 2>&1) || rc=$?

# gh should NOT have been called
if [ -f "$GH_CALL_FILE2" ]; then
    assert_eq "test_skip_ci_standalone_no_ci_check gh not called" "false" "true ($(cat "$GH_CALL_FILE2"))"
else
    assert_eq "test_skip_ci_standalone_no_ci_check gh not called" "false" "false"
fi

assert_pass_if_clean "test_skip_ci_standalone_no_ci_check"

# ── test_skip_ci_overrides_ci_flag ───────────────────────────────────────────
# --skip-ci must take precedence over --ci regardless of argument order.
# Test both orders: --ci --skip-ci and --skip-ci --ci
_snapshot_fail

GH_CALL_FILE3="$TMPDIR_TEST/gh-was-called3"
cat > "$STUB_BIN/gh" << GHSTUB3
#!/usr/bin/env bash
echo "gh called: \$*" > "$GH_CALL_FILE3"
echo '[]'
exit 0
GHSTUB3
chmod +x "$STUB_BIN/gh"

# Test --skip-ci --ci order (reversed)
rc=0
PATH="$STUB_BIN:$PATH" \
    VALIDATE_CMD_TEST="true" \
    VALIDATE_SKIP_PLUGIN_CHECKS=1 \
    VALIDATE_TEST_BATCHED_SCRIPT="$STUB_TEST_BATCHED" \
    bash "$VALIDATE_SH" --skip-ci --ci > /dev/null 2>&1 || rc=$?

if [ -f "$GH_CALL_FILE3" ]; then
    assert_eq "test_skip_ci_overrides_ci_flag (--skip-ci --ci) gh not called" "false" "true ($(cat "$GH_CALL_FILE3"))"
else
    assert_eq "test_skip_ci_overrides_ci_flag (--skip-ci --ci) gh not called" "false" "false"
fi

assert_pass_if_clean "test_skip_ci_overrides_ci_flag"

# ── test_validate_phase_full_skip_ci_passthrough ─────────────────────────────
# validate-phase.sh full --skip-ci must pass --skip-ci through to validate.sh.
_snapshot_fail

VALIDATE_PHASE_SH="$DSO_PLUGIN_DIR/scripts/validate-phase.sh"

# Create a fake validate.sh that records its arguments to a file
FAKE_VALIDATE="$TMPDIR_TEST/fake-validate.sh"
ARGS_FILE="$TMPDIR_TEST/validate-args.txt"
cat > "$FAKE_VALIDATE" << FVSTUB
#!/usr/bin/env bash
echo "\$*" > "$ARGS_FILE"
exit 0
FVSTUB
chmod +x "$FAKE_VALIDATE"

# Create a minimal dso-config.conf that points commands.validate at our fake
FAKE_CONFIG_DIR="$TMPDIR_TEST/phase-test/.claude"
mkdir -p "$FAKE_CONFIG_DIR"
cat > "$FAKE_CONFIG_DIR/dso-config.conf" << CONF
commands.validate=$FAKE_VALIDATE
commands.format=true
commands.format_check=true
commands.lint=true
commands.test_unit=true
CONF

# Create a fake git repo for validate-phase.sh
FAKE_REPO="$TMPDIR_TEST/phase-test"
(cd "$FAKE_REPO" && git init -q 2>/dev/null)

# Stub tk to avoid ticket lookups
cat > "$STUB_BIN/tk" << 'TKSTUB'
#!/usr/bin/env bash
exit 0
TKSTUB
chmod +x "$STUB_BIN/tk"

phase_output=$(cd "$FAKE_REPO" && PATH="$STUB_BIN:$PATH" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$VALIDATE_PHASE_SH" full --skip-ci 2>&1) || true

# The fake validate.sh should have received --skip-ci (recorded to file)
if [ -f "$ARGS_FILE" ] && grep -q "\-\-skip-ci" "$ARGS_FILE"; then
    assert_eq "test_validate_phase_full_skip_ci_passthrough" "passed" "passed"
else
    local_args=""
    [ -f "$ARGS_FILE" ] && local_args=$(cat "$ARGS_FILE")
    assert_eq "test_validate_phase_full_skip_ci_passthrough" "passed" "failed: --skip-ci not passed. Args: '$local_args'"
fi

assert_pass_if_clean "test_validate_phase_full_skip_ci_passthrough"

echo ""
print_summary
