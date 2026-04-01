#!/usr/bin/env bash
# tests/scripts/test-validate-phase-missing-test-unit.sh
#
# RED tests for bug 5a2d-9489:
#   validate-phase.sh exits 2 when commands.test_unit is absent from
#   dso-config.conf because it calls _cfg_required instead of _cfg with a
#   default.
#
# Tests:
#   test_missing_test_unit_does_not_exit_2
#     Run validate-phase.sh post-batch with a config that omits commands.test_unit.
#     Before the fix: _cfg_required("commands.test_unit") exits 2.
#     After the fix: script continues using the fallback "make test-unit-only".
#
#   test_missing_test_unit_uses_default_command
#     Run validate-phase.sh post-batch with a config that omits commands.test_unit
#     but injects a stub "make" that records which target was invoked.
#     Before the fix: script exits 2 (stub never reached).
#     After the fix: stub receives "test-unit-only" as its first argument.
#
# Usage: bash tests/scripts/test-validate-phase-missing-test-unit.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
CANONICAL_SCRIPT="$DSO_PLUGIN_DIR/scripts/validate-phase.sh"
READ_CONFIG_SH="$DSO_PLUGIN_DIR/scripts/read-config.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-validate-phase-missing-test-unit.sh ==="

# ---------------------------------------------------------------------------
# Setup: create a temp git repo that validate-phase.sh can discover via
# "git rev-parse --show-toplevel".  The script derives CONFIG_FILE from
# $REPO_ROOT/.claude/dso-config.conf, so our stub config lives there.
# ---------------------------------------------------------------------------

_TEST_TMPDIRS=()
_tmp_cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _tmp_cleanup EXIT

TMPDIR_BASE=$(mktemp -d)
_TEST_TMPDIRS+=("$TMPDIR_BASE")

REPO_DIR="$TMPDIR_BASE/repo"
mkdir -p "$REPO_DIR/scripts" "$REPO_DIR/.claude"

# Symlink the scripts so SCRIPT_DIR inside validate-phase.sh resolves to
# $REPO_DIR/scripts and find read-config.sh as a sibling.
ln -s "$CANONICAL_SCRIPT"  "$REPO_DIR/scripts/validate-phase.sh"
ln -s "$READ_CONFIG_SH"    "$REPO_DIR/scripts/read-config.sh"

# Symlink the real project venv (if present) so read-config.sh can find a
# Python + pyyaml interpreter.  When absent (CI without app stack),
# read-config.sh falls back to system interpreters.
VENV_BIN="$PLUGIN_ROOT/app/.venv/bin"
if [ -d "$VENV_BIN" ]; then
    mkdir -p "$REPO_DIR/app/.venv"
    ln -s "$(cd "$VENV_BIN" && pwd)" "$REPO_DIR/app/.venv/bin"
fi

# Minimal git repo so "git rev-parse --show-toplevel" succeeds.
(
    cd "$REPO_DIR"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"
)

# ---------------------------------------------------------------------------
# Helper: run validate-phase.sh from within REPO_DIR.
# Sets RUN_OUTPUT (combined stdout+stderr) and RUN_EXIT.
# ---------------------------------------------------------------------------
run_phase() {
    local phase="$1"
    RUN_OUTPUT=""
    RUN_EXIT=0
    RUN_OUTPUT=$(
        cd "$REPO_DIR"
        # Inject any extra env vars passed as KEY=VALUE arguments after phase.
        env "${@:2}" bash "$CANONICAL_SCRIPT" "$phase" 2>&1
    ) || RUN_EXIT=$?
}

# ---------------------------------------------------------------------------
# Test: test_missing_test_unit_does_not_exit_2
#
# Config provides all required keys EXCEPT commands.test_unit.
# With the current (broken) code, _cfg_required exits 2 before the phase
# body runs.  The test asserts exit code != 2.
#
# RED: fails because _cfg_required("commands.test_unit") exits 2.
# GREEN: passes after _cfg with default replaces _cfg_required.
# ---------------------------------------------------------------------------
echo ""
echo "Test: test_missing_test_unit_does_not_exit_2"

cat > "$REPO_DIR/.claude/dso-config.conf" << 'CFG'
commands.format=true
commands.format_check=true
commands.lint=true
commands.validate=true
CFG
# NOTE: commands.test_unit intentionally absent.

_snapshot_fail

run_phase "post-batch"

assert_ne \
    "validate-phase exits with config-error code 2 when commands.test_unit absent" \
    "2" \
    "$RUN_EXIT"

assert_pass_if_clean "test_missing_test_unit_does_not_exit_2"

# ---------------------------------------------------------------------------
# Test: test_missing_test_unit_uses_default_command
#
# Config omits commands.test_unit.  A fake "make" binary (on PATH before
# the real one) writes its first argument to a sentinel file so we can
# observe which make target the script attempted.
#
# After the fix, _cfg("commands.test_unit", "make test-unit-only") returns
# the default.  validate-phase.sh then invokes "make test-unit-only" (via
# test-batched.sh or direct eval).  The stub intercepts the call.
#
# We verify: the sentinel file contains "test-unit-only" (the default target).
#
# RED: fails because the script never reaches the make invocation (exits 2).
# GREEN: passes after the fix — make is called with "test-unit-only".
# ---------------------------------------------------------------------------
echo ""
echo "Test: test_missing_test_unit_uses_default_command"

MAKE_SENTINEL="$TMPDIR_BASE/make-called-with"
FAKE_BIN_DIR="$TMPDIR_BASE/fakebin"
mkdir -p "$FAKE_BIN_DIR"

# Stub "make": record the first argument, then exit 0.
cat > "$FAKE_BIN_DIR/make" << MAKESTUB
#!/usr/bin/env bash
echo "\$1" > "$MAKE_SENTINEL"
exit 0
MAKESTUB
chmod +x "$FAKE_BIN_DIR/make"

# Stub test-batched.sh so the test delegation path also works:
# It records what CMD it received, then calls make with the right target.
STUB_BATCHED="$TMPDIR_BASE/stub-test-batched.sh"
cat > "$STUB_BATCHED" << 'STUB'
#!/usr/bin/env bash
# Stub test-batched.sh: forward the command so our fake make is invoked.
# Accept the same flag interface as the real test-batched.sh.
# The command under test is passed as a positional arg or via --runner/--test-dir.
# For this stub we just eval the last positional argument (the command string).
cmd="${@: -1}"
eval "$cmd" 2>/dev/null || true
echo "1/1 tests completed."
echo "All tests done. 1/1 tests completed. 1 passed, 0 failed."
exit 0
STUB
chmod +x "$STUB_BATCHED"

cat > "$REPO_DIR/.claude/dso-config.conf" << 'CFG'
commands.format=true
commands.format_check=true
commands.lint=true
commands.validate=true
CFG
# NOTE: commands.test_unit intentionally absent.

_snapshot_fail

RUN_OUTPUT=""
RUN_EXIT=0
RUN_OUTPUT=$(
    cd "$REPO_DIR"
    PATH="$FAKE_BIN_DIR:$PATH" \
    VALIDATE_TEST_BATCHED_SCRIPT="$STUB_BATCHED" \
    bash "$CANONICAL_SCRIPT" "post-batch" 2>&1
) || RUN_EXIT=$?

# The script must not have exited 2 (config-error).
assert_ne \
    "validate-phase does not exit 2 (config missing test_unit — default must apply)" \
    "2" \
    "$RUN_EXIT"

# The stub must have been reached and invoked make with "test-unit-only".
if [ -f "$MAKE_SENTINEL" ]; then
    MAKE_ARG=$(cat "$MAKE_SENTINEL")
    assert_eq \
        "validate-phase falls back to default make target test-unit-only" \
        "test-unit-only" \
        "$MAKE_ARG"
else
    # Sentinel missing means make was never called — still flag it clearly.
    assert_eq \
        "validate-phase falls back to default make target test-unit-only (make not called)" \
        "test-unit-only" \
        "(make not invoked)"
fi

assert_pass_if_clean "test_missing_test_unit_uses_default_command"

print_summary
