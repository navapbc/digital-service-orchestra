#!/usr/bin/env bash
set -uo pipefail
# tests/hooks/test-record-test-status-staged-test-no-source.sh
# Behavioral test for bug 64f4-aa92:
#   When a RED test targets a source file that does not exist yet (TDD RED phase),
#   only the test file is staged. record-test-status.sh must find the RED marker
#   from .test-index via the global fallback and tolerate the failure.
#
# Root cause under investigation: the direct marker lookup for a staged test file
# (lines ~551-561 in record-test-status.sh) strips the source prefix with ##*:
# which leaves a leading space, causing the path comparison to fail. The global
# scan (find_global_red_marker_for_test) should catch it via its whitespace-trimming
# parser.
#
# This test is RED if the global scan does NOT find the marker (bug still present).
# This test is GREEN if the global scan finds the marker (bug fixed).
#
# Usage: bash tests/hooks/test-record-test-status-staged-test-no-source.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/record-test-status.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# Disable commit signing for test git repos
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_all() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap '_cleanup_all' EXIT

_make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Helper: run the hook capturing exit code ──────────────────────────────────
_run_hook_exit() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local runner="$3"
    local exit_code=0
    (
        cd "$repo_dir"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        RECORD_TEST_STATUS_RUNNER="$runner" \
        bash "$HOOK" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# ============================================================
# test_staged_test_red_marker_found_when_source_not_exist (64f4-aa92)
#
# Scenario:
#   .test-index: src/future-feature.sh: tests/hooks/test-future.sh [test_future_behavior]
#   src/future-feature.sh — does NOT exist (TDD RED phase, implementation not written)
#   tests/hooks/test-future.sh — STAGED (the new test we just wrote)
#   test runner exits 1 (RED — test fails because implementation missing)
#
# Expected: test-gate-status line 1 = "passed"
#   (RED marker found → failure tolerated)
#
# RED (bug present): marker not found → "failed" written → harvest rejects
# GREEN (bug fixed): marker found via global scan → "passed" written
# ============================================================
echo ""
echo "=== test_staged_test_red_marker_found_when_source_not_exist (64f4-aa92) ==="
_snapshot_fail

REPO=$(_make_tmpdir)
ARTIFACTS=$(_make_tmpdir)

# Initialize git repo with a real initial commit
git -C "$REPO" init --quiet 2>/dev/null
git -C "$REPO" config user.email "test@test.com"
git -C "$REPO" config user.name "Test"
touch "$REPO/.gitkeep"
git -C "$REPO" add .gitkeep
git -C "$REPO" commit -m "init" --quiet 2>/dev/null

# Create the test directory (hooks, to match test-dir discovery pattern)
mkdir -p "$REPO/tests/hooks"

# Create the test file (simulates the RED test the developer just wrote)
# The test fails because the implementation doesn't exist yet.
cat > "$REPO/tests/hooks/test-future.sh" << 'TESTEOF'
#!/usr/bin/env bash
echo "test_future_behavior: FAIL (implementation not written yet)"
exit 1
TESTEOF
chmod +x "$REPO/tests/hooks/test-future.sh"

# .test-index maps the NON-EXISTENT source to the test file WITH a RED marker.
# src/future-feature.sh does NOT exist (TDD RED phase).
cat > "$REPO/.test-index" << 'IDXEOF'
src/future-feature.sh: tests/hooks/test-future.sh [test_future_behavior]
IDXEOF

# Commit the test file and .test-index (source does NOT exist — not committed)
git -C "$REPO" add tests/hooks/test-future.sh .test-index
git -C "$REPO" commit -m "add red test for future feature" --quiet 2>/dev/null

# Stage ONLY the test file (simulate developer re-staging after edit)
# src/future-feature.sh still does not exist — not staged
echo "# updated test" >> "$REPO/tests/hooks/test-future.sh"
git -C "$REPO" add tests/hooks/test-future.sh

# Mock runner: simulates the RED test failing (implementation missing)
MOCK_RUNNER=$(_make_tmpdir)/mock-runner.sh
cat > "$MOCK_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
echo "test_future_behavior: FAIL (implementation not written yet)"
exit 1
MOCKEOF
chmod +x "$MOCK_RUNNER"

# Run record-test-status.sh
EXIT_CODE=$(_run_hook_exit "$REPO" "$ARTIFACTS" "$MOCK_RUNNER")

# Assert: exit 0 means marker was found and failure was tolerated
assert_eq "staged_test_no_source: hook exits 0 (RED zone tolerated)" "0" "$EXIT_CODE"

# Assert: test-gate-status line 1 = "passed"
if [[ -f "$ARTIFACTS/test-gate-status" ]]; then
    STATUS_LINE=$(head -1 "$ARTIFACTS/test-gate-status")
    assert_eq "staged_test_no_source: test-gate-status is 'passed'" "passed" "$STATUS_LINE"
else
    assert_eq "staged_test_no_source: test-gate-status file created" "exists" "missing"
fi

assert_pass_if_clean "test_staged_test_red_marker_found_when_source_not_exist"

# ============================================================
# test_doc_only_staged_writes_passed_status (a2e0-3ae8)
#
# Scenario: only a doc file is staged; .test-index has no entry for it.
#   ASSOCIATED_TESTS is empty → record-test-status.sh previously exited 0
#   without writing test-gate-status, causing harvest-worktree.sh to block
#   with "ERROR: test-gate-status not found".
#
# Expected: record-test-status.sh writes test-gate-status=passed with
#   tested_files=doc-only-exempt so harvest-worktree.sh can proceed.
#
# RED (bug present): test-gate-status not written → file missing
# GREEN (bug fixed):  test-gate-status written as "passed"
# ============================================================
echo ""
echo "=== test_doc_only_staged_writes_passed_status (a2e0-3ae8) ==="
_snapshot_fail

REPO=$(_make_tmpdir)
ARTIFACTS=$(_make_tmpdir)

git -C "$REPO" init --quiet 2>/dev/null
git -C "$REPO" config user.email "test@test.com"
git -C "$REPO" config user.name "Test"
touch "$REPO/.gitkeep"
git -C "$REPO" add .gitkeep
git -C "$REPO" commit -m "init" --quiet 2>/dev/null

# .test-index has NO entry for the doc file
cat > "$REPO/.test-index" <<'IDXEOF'
src/module.py: tests/test_module.sh
IDXEOF

# Stage only a doc file — no .test-index entry for it
mkdir -p "$REPO/docs"
echo "# Doc content" > "$REPO/docs/guide.md"
git -C "$REPO" add docs/guide.md .test-index
git -C "$REPO" commit -m "add doc file" --quiet 2>/dev/null
echo "updated" >> "$REPO/docs/guide.md"
git -C "$REPO" add docs/guide.md

EXIT_CODE=0
(
    cd "$REPO"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$HOOK" 2>/dev/null
) || EXIT_CODE=$?

assert_eq "doc-only staged: hook exits 0" "0" "$EXIT_CODE"

if [[ -f "$ARTIFACTS/test-gate-status" ]]; then
    STATUS_LINE=$(head -1 "$ARTIFACTS/test-gate-status")
    assert_eq "doc-only staged: test-gate-status is 'passed'" "passed" "$STATUS_LINE"
else
    assert_eq "doc-only staged: test-gate-status file must exist" "exists" "missing"
fi

assert_pass_if_clean "test_doc_only_staged_writes_passed_status"

print_summary
