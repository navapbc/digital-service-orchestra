#!/usr/bin/env bash
# lockpick-workflow/tests/test-portability.sh
# Portability test: validates the plugin works from any installation location.
#
# Copies lockpick-workflow/ to /tmp/lw-portability-test/, sets CLAUDE_PLUGIN_ROOT
# to the copied location, runs run-all.sh from there (with stub runners for speed),
# and asserts the test infrastructure executes correctly.
#
# The stub runners verify that run-all.sh can orchestrate suites from an arbitrary
# path — individual sub-test correctness is validated by those tests themselves.
#
# Usage:
#   bash lockpick-workflow/tests/test-portability.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
source "$SCRIPT_DIR/lib/assert.sh"

# --- Temp directory with cleanup trap ---
PORTABILITY_DIR="/tmp/lw-portability-test"

cleanup() {
    rm -rf "$PORTABILITY_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Clean any leftover from a prior run
cleanup

echo "=== Plugin Portability Test ==="
echo ""

# ============================================================
# Step 1: Copy plugin to isolated temp location
# ============================================================

echo "--- test_copy_plugin_to_temp ---"

mkdir -p "$PORTABILITY_DIR"

# Copy the plugin directory (-L dereferences symlinks so the copy is standalone)
cp -RL "$REPO_ROOT/lockpick-workflow" "$PORTABILITY_DIR/lockpick-workflow"

# The copied plugin needs a minimal git repo context for scripts that call
# git rev-parse. Initialize one at the portability root.
(cd "$PORTABILITY_DIR" && git init -q && git config user.email "test@test.com" && git config user.name "Test")

# Copy workflow-config.yaml if it exists (some scripts need it)
if [[ -f "$REPO_ROOT/workflow-config.yaml" ]]; then
    cp "$REPO_ROOT/workflow-config.yaml" "$PORTABILITY_DIR/"
fi

# Symlink the app venv for scripts that probe for Python/pyyaml
if [[ -d "$REPO_ROOT/app/.venv/bin" ]]; then
    mkdir -p "$PORTABILITY_DIR/app/.venv"
    ln -s "$(cd "$REPO_ROOT/app/.venv/bin" && pwd)" "$PORTABILITY_DIR/app/.venv/bin"
fi

assert_eq "plugin directory copied" "true" \
    "$(test -d "$PORTABILITY_DIR/lockpick-workflow" && echo true || echo false)"

assert_eq "tests directory exists in copy" "true" \
    "$(test -d "$PORTABILITY_DIR/lockpick-workflow/tests" && echo true || echo false)"

assert_eq "run-all.sh exists in copy" "true" \
    "$(test -f "$PORTABILITY_DIR/lockpick-workflow/tests/run-all.sh" && echo true || echo false)"

assert_eq "assert.sh lib exists in copy" "true" \
    "$(test -f "$PORTABILITY_DIR/lockpick-workflow/tests/lib/assert.sh" && echo true || echo false)"

assert_eq "scripts directory exists in copy" "true" \
    "$(test -d "$PORTABILITY_DIR/lockpick-workflow/scripts" && echo true || echo false)"

assert_eq "hooks directory exists in copy" "true" \
    "$(test -d "$PORTABILITY_DIR/lockpick-workflow/hooks" && echo true || echo false)"

# ============================================================
# Step 2: Verify no references back to source repo
# ============================================================

echo ""
echo "--- test_no_source_repo_references ---"

# The copied plugin must not contain hardcoded references to the original repo path.
# Exclude compiled artifacts (__pycache__, .pyc) which may embed absolute paths.
HARDCODED_REFS=$(grep -rl --exclude-dir='__pycache__' --exclude='*.pyc' \
    "$REPO_ROOT" "$PORTABILITY_DIR/lockpick-workflow/scripts/" \
    "$PORTABILITY_DIR/lockpick-workflow/hooks/" 2>/dev/null | wc -l | tr -d ' ')

assert_eq "no hardcoded source-repo paths in copied scripts/hooks" "0" "$HARDCODED_REFS"

# ============================================================
# Step 3: Run run-all.sh from the copied location with stub runners
#
# We use --hooks-runner, --scripts-runner, --evals-runner overrides
# (supported by run-all.sh) to inject fast-exit stubs. This proves
# run-all.sh can orchestrate from a non-source location without
# running the full 3+ minute test suite.
# ============================================================

echo ""
echo "--- test_run_all_from_copied_location ---"

export CLAUDE_PLUGIN_ROOT="$PORTABILITY_DIR/lockpick-workflow"

# Create stub runners that exit 0 (simulating all-pass suites)
STUB_DIR="$PORTABILITY_DIR/_stubs"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/stub-pass.sh" << 'STUB'
#!/usr/bin/env bash
echo "stub suite: PASS"
exit 0
STUB
chmod +x "$STUB_DIR/stub-pass.sh"

RUN_OUTPUT=""
RUN_EXIT=0
RUN_OUTPUT=$(
    cd "$PORTABILITY_DIR" && bash "$PORTABILITY_DIR/lockpick-workflow/tests/run-all.sh" \
        --hooks-runner "$STUB_DIR/stub-pass.sh" \
        --scripts-runner "$STUB_DIR/stub-pass.sh" \
        --evals-runner "$STUB_DIR/stub-pass.sh" 2>&1
) || RUN_EXIT=$?

assert_eq "run-all.sh exits 0 from copied location" "0" "$RUN_EXIT"

# Verify the output contains the expected structural markers
assert_contains "output has combined summary banner" "Run-All Combined Summary" "$RUN_OUTPUT"
assert_contains "output has hook tests suite header" "Suite: Hook Tests" "$RUN_OUTPUT"
assert_contains "output has script tests suite header" "Suite: Script Tests" "$RUN_OUTPUT"
assert_contains "output has evals suite header" "Suite: Evals" "$RUN_OUTPUT"
assert_contains "output reports overall pass" "Overall: PASS" "$RUN_OUTPUT"

# ============================================================
# Step 4: Verify a real test can source assert.sh from the copy
# ============================================================

echo ""
echo "--- test_assert_sh_works_from_copy ---"

ASSERT_OUTPUT=""
ASSERT_EXIT=0
ASSERT_OUTPUT=$(
    cd "$PORTABILITY_DIR" && bash -c '
        source "$1/lockpick-workflow/tests/lib/assert.sh"
        assert_eq "portable assert" "hello" "hello"
        print_summary
    ' -- "$PORTABILITY_DIR" 2>&1
) || ASSERT_EXIT=$?

assert_eq "assert.sh works from copied location" "0" "$ASSERT_EXIT"
assert_contains "assert.sh reports pass" "PASSED: 1" "$ASSERT_OUTPUT"

# ============================================================
# Summary
# ============================================================

print_summary
