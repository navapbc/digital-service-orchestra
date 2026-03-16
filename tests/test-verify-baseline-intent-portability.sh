#!/usr/bin/env bash
# lockpick-workflow/tests/test-verify-baseline-intent-portability.sh
# Portability smoke test for verify-baseline-intent.sh.
#
# Verifies that verify-baseline-intent.sh is a no-op (exit 0, no stderr) when:
#   a. workflow-config.conf has no visual section (graceful skip)
#   b. visual.baseline_directory is set but no baseline .png files changed on branch
#
# These tests prove the script is safe to ship in the plugin for consumers that
# have no visual testing setup.
#
# Manual run:
#   bash lockpick-workflow/tests/test-verify-baseline-intent-portability.sh
#
# Tests covered:
#   a. no visual config (no visual section in workflow-config.conf) → exit 0, no stderr
#   b. visual config present, no baseline changes on branch         → exit 0

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_SCRIPT="$SCRIPT_DIR/../scripts/verify-baseline-intent.sh"
READ_CONFIG_SH="$SCRIPT_DIR/../scripts/read-config.sh"

FAILURES=0
TESTS=0

pass() { TESTS=$((TESTS + 1)); echo "  PASS: $1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); echo "  FAIL: $1"; }

echo "=== Tests for verify-baseline-intent.sh portability (no-visual config) ==="

# ---------------------------------------------------------------------------
# Pre-flight: canonical script must exist
# ---------------------------------------------------------------------------
if [ ! -f "$CANONICAL_SCRIPT" ]; then
    echo "ERROR: Canonical script not found: $CANONICAL_SCRIPT"
    echo "FAILED: Cannot run tests without the canonical script."
    exit 1
fi

# ---------------------------------------------------------------------------
# Setup: create a temp git repo with a real commit so merge-base logic works.
#
# Temp dir structure:
#   $TMPDIR/                             ← REPO_ROOT (fake git repo)
#   $TMPDIR/workflow-config.conf         ← stub config (populated per scenario)
#   $TMPDIR/lockpick-workflow/scripts/
#       verify-baseline-intent.sh        ← symlink to canonical script
#       read-config.sh                   ← symlink to real read-config.sh
#
# We symlink the canonical scripts into the fake repo so that SCRIPT_DIR
# inside verify-baseline-intent.sh resolves to $TMPDIR/lockpick-workflow/scripts/
# and sibling script calls (read-config.sh) resolve correctly.
# ---------------------------------------------------------------------------

TMPDIR_BASE=$(mktemp -d)
trap "rm -rf '$TMPDIR_BASE'" EXIT

TMPDIR="$TMPDIR_BASE/repo"
mkdir -p "$TMPDIR/lockpick-workflow/scripts"

# Symlink canonical scripts into the fake repo
ln -s "$CANONICAL_SCRIPT" "$TMPDIR/lockpick-workflow/scripts/verify-baseline-intent.sh"
ln -s "$READ_CONFIG_SH" "$TMPDIR/lockpick-workflow/scripts/read-config.sh"

# Provide a YAML interpreter for read-config.sh:
# read-config.sh probes $REPO_ROOT/app/.venv/bin/python3 first.
# Symlink the real project venv's bin directory into the fake repo so the probe
# succeeds without requiring any project-specific config in this test file.
VENV_BIN="$SCRIPT_DIR/../../app/.venv/bin"
if [ -d "$VENV_BIN" ]; then
    mkdir -p "$TMPDIR/app/.venv"
    ln -s "$(cd "$VENV_BIN" && pwd)" "$TMPDIR/app/.venv/bin"
fi
# If the venv bin isn't present (e.g., CI without the app stack), read-config.sh
# falls back to system python3. If none have pyyaml, tests fail with a clear error.

# Initialize a minimal git repo with one commit so merge-base logic works.
# verify-baseline-intent.sh calls: git merge-base HEAD origin/main || git merge-base HEAD main || git rev-parse HEAD
# With a single initial commit and no remote, the fallback `git rev-parse HEAD` is used,
# which means MERGE_BASE == HEAD and `git diff HEAD HEAD -- $BASELINE_DIR` returns empty.
(
    cd "$TMPDIR"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"
    # Need at least one commit for git rev-parse HEAD to succeed
    touch .gitkeep
    git add .gitkeep
    git commit -q -m "initial commit"
)

# ---------------------------------------------------------------------------
# Helper: run verify-baseline-intent.sh from within the temp git repo.
# Captures stdout+stderr separately.
# Sets: RUN_STDOUT, RUN_STDERR, RUN_EXIT
# ---------------------------------------------------------------------------
run_verify() {
    RUN_STDOUT=""
    RUN_STDERR=""
    RUN_EXIT=0

    local stderr_file
    stderr_file=$(mktemp)

    RUN_STDOUT=$(
        cd "$TMPDIR" && bash "$CANONICAL_SCRIPT" 2>"$stderr_file"
    ) || RUN_EXIT=$?

    RUN_STDERR=$(cat "$stderr_file")
    rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# Test a: no visual config (no visual section in workflow-config.conf)
#
# Expects:
#   - exit 0
#   - no stderr output
#
# This is the primary portability guarantee: any project that adopts the plugin
# without configuring visual baselines gets a silent no-op.
# ---------------------------------------------------------------------------
echo ""
echo "Test a: no visual config (workflow-config.conf has no visual section)"

cat > "$TMPDIR/workflow-config.conf" << 'WCFG'
commands.format=true
commands.lint=true
commands.test_unit=echo '1 passed'
WCFG

run_verify

if [ "$RUN_EXIT" -eq 0 ]; then
    pass "no-visual config: exit 0"
else
    fail "no-visual config: expected exit 0, got $RUN_EXIT (stdout: $RUN_STDOUT) (stderr: $RUN_STDERR)"
fi

if [ -z "$RUN_STDERR" ]; then
    pass "no-visual config: no stderr output"
else
    fail "no-visual config: expected no stderr, got: $RUN_STDERR"
fi

# ---------------------------------------------------------------------------
# Test b: visual config absent entirely (no workflow-config.conf at all)
#
# Expects:
#   - exit 0
#   - no stderr output
#
# read-config.sh exits 0 with empty output when no config file is found.
# verify-baseline-intent.sh treats empty BASELINE_DIR as no-op.
# ---------------------------------------------------------------------------
echo ""
echo "Test b: no workflow-config.conf file at all"

rm -f "$TMPDIR/workflow-config.conf"

run_verify

if [ "$RUN_EXIT" -eq 0 ]; then
    pass "no-config-file: exit 0"
else
    fail "no-config-file: expected exit 0, got $RUN_EXIT (stdout: $RUN_STDOUT) (stderr: $RUN_STDERR)"
fi

if [ -z "$RUN_STDERR" ]; then
    pass "no-config-file: no stderr output"
else
    fail "no-config-file: expected no stderr, got: $RUN_STDERR"
fi

# ---------------------------------------------------------------------------
# Test c: visual.baseline_directory is set but no baseline .png changes on branch
#
# Setup: create a baseline directory and add a committed .png file (so the
# directory exists) but make NO additional changes on the branch beyond the
# initial commit. git diff HEAD..HEAD -- baselines/ will be empty.
#
# Expects:
#   - exit 0
# ---------------------------------------------------------------------------
echo ""
echo "Test c: visual.baseline_directory set, no baseline changes on branch"

# Restore workflow-config.conf with visual section
cat > "$TMPDIR/workflow-config.conf" << 'WCFG'
commands.format=true
commands.lint=true
commands.test_unit=echo '1 passed'
visual.baseline_directory=tests/visual/baselines
WCFG

# Create the baseline directory with a committed .png so it's tracked by git
mkdir -p "$TMPDIR/tests/visual/baselines"
# Create a minimal 1-byte fake .png (git only cares about filename)
printf '\x89PNG\r\n' > "$TMPDIR/tests/visual/baselines/example.png"

(
    cd "$TMPDIR"
    git add workflow-config.conf tests/
    git commit -q -m "add visual baselines config and example baseline"
)

# At this point HEAD == the commit we just made, merge-base fallback is HEAD,
# so git diff HEAD..HEAD -- tests/visual/baselines is empty → exit 0

run_verify

if [ "$RUN_EXIT" -eq 0 ]; then
    pass "no-baseline-changes: exit 0"
else
    fail "no-baseline-changes: expected exit 0, got $RUN_EXIT (stdout: $RUN_STDOUT) (stderr: $RUN_STDERR)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $((TESTS - FAILURES))/$TESTS passed ==="
if [ "$FAILURES" -gt 0 ]; then
    echo "FAILED: $FAILURES test(s) failed"
    exit 1
else
    echo "All tests passed."
    exit 0
fi
