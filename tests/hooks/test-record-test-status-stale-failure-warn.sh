#!/usr/bin/env bash
set -uo pipefail
# tests/hooks/test-record-test-status-stale-failure-warn.sh
# Tests that --source-file merge emits a warning on stderr when inherited
# (stale) failures from a previous run are preserved for tests NOT re-run
# in the current invocation (bug 8305-2091).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/record-test-status.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Disable commit signing for test git repos
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

# ============================================================
# Helper: create an isolated temp git repo with initial commit
# ============================================================
create_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-stale-warn-XXXXXX")
    git -C "$tmpdir" init --quiet 2>/dev/null
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    touch "$tmpdir/.gitkeep"
    git -C "$tmpdir" add .gitkeep
    git -C "$tmpdir" commit -m "initial" --quiet 2>/dev/null
    echo "$tmpdir"
}

# ============================================================
# test_source_file_merge_warns_on_inherited_failures
#
# Scenario:
#   - Prior test-gate-status has tests/test_x.sh listed as FAILED
#   - Current --source-file invocation targets src/file_y.sh
#   - tests/test_x.sh is NOT associated with file_y.sh and is NOT re-run
#   - After the merge, the inherited failure must trigger a warning on stderr
#
# RED: before the fix, no warning is emitted for inherited stale failures.
# GREEN: after the fix, stderr contains the "inherited failures" warning.
# ============================================================
echo ""
echo "=== test_source_file_merge_warns_on_inherited_failures ==="
_snapshot_fail

TEST_REPO=$(create_test_repo)
ARTIFACTS=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-stale-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO" "$ARTIFACTS"' EXIT

# Create src/file_y.sh (the file being committed in the current invocation)
mkdir -p "$TEST_REPO/src" "$TEST_REPO/tests"
cat > "$TEST_REPO/src/file_y.sh" << 'EOF'
#!/usr/bin/env bash
echo "file_y"
EOF

# Create a test associated with file_y.sh that PASSES
cat > "$TEST_REPO/tests/test-file-y.sh" << 'TESTEOF'
#!/usr/bin/env bash
echo "test_file_y_passes: PASS"
exit 0
TESTEOF
chmod +x "$TEST_REPO/tests/test-file-y.sh"

# .test-index: file_y.sh maps to test-file-y.sh only (not test-x.sh)
cat > "$TEST_REPO/.test-index" << 'IDXEOF'
src/file_y.sh: tests/test-file-y.sh
IDXEOF

# Commit everything so HEAD exists and staged works
git -C "$TEST_REPO" add -A
git -C "$TEST_REPO" commit -m "add file_y and test" --quiet 2>/dev/null

# Stage a change to file_y.sh for the current invocation
echo "# changed" >> "$TEST_REPO/src/file_y.sh"
git -C "$TEST_REPO" add src/file_y.sh

# Pre-seed test-gate-status with a FAILED entry for tests/test_x.sh
# (simulating a prior --source-file run that recorded test_x.sh as failed)
cat > "$ARTIFACTS/test-gate-status" << 'STATUSEOF'
failed
diff_hash=0000000000000000000000000000000000000000000000000000000000000000
timestamp=2026-01-01T00:00:00Z
tested_files=tests/test_x.sh
failed_tests=tests/test_x.sh
STATUSEOF

# Use a mock runner that always passes for test-file-y.sh
MOCK_PASS_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-pass-runner-XXXXXX")
chmod +x "$MOCK_PASS_RUNNER"
cat > "$MOCK_PASS_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
# Mock: always passes (simulates test-file-y.sh now passing)
exit 0
MOCKEOF

# Run the hook with --source-file=src/file_y.sh; capture stderr
HOOK_STDERR=$(
    cd "$TEST_REPO" || exit 1
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_PASS_RUNNER" \
    bash "$HOOK" --source-file=src/file_y.sh 2>&1 >/dev/null || true
)

# The warning must appear on stderr when inherited failures exist for tests
# not re-run in this invocation.
assert_contains \
    "test_source_file_merge_warns_on_inherited_failures: stderr contains inherited-failure warning" \
    "inherited failures" \
    "$HOOK_STDERR"

# The warning must mention the stale test name so the user knows which test
assert_contains \
    "test_source_file_merge_warns_on_inherited_failures: warning names the inherited test" \
    "tests/test_x.sh" \
    "$HOOK_STDERR"

# The warning must suggest --restart as the remedy
assert_contains \
    "test_source_file_merge_warns_on_inherited_failures: warning suggests --restart" \
    "--restart" \
    "$HOOK_STDERR"

rm -f "$MOCK_PASS_RUNNER"
rm -rf "$TEST_REPO" "$ARTIFACTS"
trap - EXIT

assert_pass_if_clean "test_source_file_merge_warns_on_inherited_failures"

print_summary
