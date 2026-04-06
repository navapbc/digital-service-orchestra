#!/usr/bin/env bash
# tests/hooks/test-record-test-status-eagain.sh
# Behavioral RED tests for EAGAIN detection in record-test-status.sh.
#
# All tests are RED before EAGAIN detection is implemented.
# EAGAIN detection: when the test runner exits 254 AND stderr contains an
# EAGAIN pattern (e.g., "Resource temporarily unavailable"), record-test-status.sh
# must write "resource_exhaustion" on line 1 of test-gate-status rather than "failed".
#
# Tests:
#   test_eagain_exit254_with_stderr_pattern
#   test_eagain_exit254_without_stderr_pattern
#   test_eagain_exit1_with_stderr_pattern
#   test_eagain_deference_to_existing_passed
#   test_resource_exhaustion_severity_below_failed
#   test_eagain_blocking_io_error_pattern
#   test_merge_path_resource_exhaustion_then_failed
#
# Usage: bash tests/hooks/test-record-test-status-eagain.sh

set -uo pipefail

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

# ── Helper: make a tmp dir tracked for cleanup ────────────────────────────────
_make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Helper: create an isolated git repo with initial commit ──────────────────
# The repo needs:
#   - A source file (src/widget.sh) committed and then modified+staged
#   - A test file (tests/test-widget.sh) committed
#   - A .test-index mapping src/widget.sh to tests/test-widget.sh
# The mock test file in tests/ is a real executable script that succeeds —
# but RECORD_TEST_STATUS_RUNNER overrides the actual runner, so the test
# file content is irrelevant for runner-override tests.
_make_rts_repo() {
    local tmpdir
    tmpdir=$(_make_tmpdir)

    git -C "$tmpdir" init --quiet 2>/dev/null
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"

    # Create initial commit
    touch "$tmpdir/.gitkeep"
    git -C "$tmpdir" add .gitkeep
    git -C "$tmpdir" commit -m "initial" --quiet 2>/dev/null

    # Create source and test files
    mkdir -p "$tmpdir/src" "$tmpdir/tests"

    cat > "$tmpdir/src/widget.sh" <<'SRCEOF'
#!/usr/bin/env bash
echo "widget"
SRCEOF

    cat > "$tmpdir/tests/test-widget.sh" <<'TESTEOF'
#!/usr/bin/env bash
echo "PASSED: 1  FAILED: 0"
exit 0
TESTEOF
    chmod +x "$tmpdir/tests/test-widget.sh"

    # Write .test-index mapping src/widget.sh → tests/test-widget.sh
    cat > "$tmpdir/.test-index" <<'IDXEOF'
src/widget.sh: tests/test-widget.sh
IDXEOF

    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -m "add widget" --quiet 2>/dev/null

    # Modify source file and stage it to create a diff
    echo "# changed" >> "$tmpdir/src/widget.sh"
    git -C "$tmpdir" add "$tmpdir/src/widget.sh"

    echo "$tmpdir"
}

# ── Helper: run the hook in a repo, returning exit code on stdout ─────────────
_run_hook() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    shift 2
    local exit_code=0
    (
        cd "$repo_dir"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$HOOK" "$@" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# ── Helper: run the hook and capture stderr ───────────────────────────────────
_run_hook_stderr() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    shift 2
    (
        cd "$repo_dir"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$HOOK" "$@" 2>&1 >/dev/null
    ) || true
}

# ── Helper: read line 1 of test-gate-status ──────────────────────────────────
_status_line1() {
    local artifacts_dir="$1"
    local status_file="$artifacts_dir/test-gate-status"
    if [[ -f "$status_file" ]]; then
        head -1 "$status_file"
    else
        echo "FILE_NOT_FOUND"
    fi
}

# ── Helper: make a mock runner script ────────────────────────────────────────
# Args: exit_code [stderr_message]
# Creates an executable script that exits with the given code and optionally
# writes a message to stderr. Prints the script path on stdout.
_make_mock_runner() {
    local exit_code="$1"
    local stderr_msg="${2:-}"
    local runner
    runner=$(mktemp "${TMPDIR:-/tmp}/mock-runner-XXXXXX")
    _TEST_TMPDIRS+=("$runner")  # tracked for cleanup (mktemp file, not dir — rm works)
    chmod +x "$runner"
    if [[ -n "$stderr_msg" ]]; then
        cat > "$runner" <<RUNEOF
#!/usr/bin/env bash
echo "${stderr_msg}" >&2
exit ${exit_code}
RUNEOF
    else
        cat > "$runner" <<RUNEOF
#!/usr/bin/env bash
exit ${exit_code}
RUNEOF
    fi
    echo "$runner"
}

# ============================================================
# test_eagain_exit254_with_stderr_pattern
#
# Mock runner exits 254 and writes "fork: Resource temporarily unavailable"
# to stderr. The EAGAIN detection must fire (exit 254 + matching pattern)
# and write "resource_exhaustion" on line 1 of test-gate-status.
#
# RED: without EAGAIN detection, exit 254 is treated as a non-zero non-144
# exit and "failed" is written to line 1 of test-gate-status.
# ============================================================
test_eagain_exit254_with_stderr_pattern() {
    local repo artifacts runner
    repo=$(_make_rts_repo)
    artifacts=$(_make_tmpdir)
    runner=$(_make_mock_runner 254 "fork: Resource temporarily unavailable")

    (
        cd "$repo"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        RECORD_TEST_STATUS_RUNNER="$runner" \
        bash "$HOOK" 2>/dev/null
    ) || true

    local status
    status=$(_status_line1 "$artifacts")
    assert_eq "test_eagain_exit254_with_stderr_pattern: status is resource_exhaustion" \
        "resource_exhaustion" "$status"
}

# ============================================================
# test_eagain_exit254_without_stderr_pattern
#
# Mock runner exits 254 but does NOT write any EAGAIN pattern to stderr.
# Without the matching pattern, the condition is not EAGAIN — the runner
# exited 254 for some other reason. Status must be "failed", not
# "resource_exhaustion".
#
# RED: this test may PASS in RED phase (current behavior treats 254 as
# failed). But we include it as a boundary condition to confirm that
# EAGAIN detection does NOT fire without the matching pattern.
# This test asserts the correct post-implementation boundary behavior.
# ============================================================
test_eagain_exit254_without_stderr_pattern() {
    local repo artifacts runner
    repo=$(_make_rts_repo)
    artifacts=$(_make_tmpdir)
    runner=$(_make_mock_runner 254 "some other error, no resource pattern here")

    (
        cd "$repo"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        RECORD_TEST_STATUS_RUNNER="$runner" \
        bash "$HOOK" 2>/dev/null
    ) || true

    local status
    status=$(_status_line1 "$artifacts")
    assert_eq "test_eagain_exit254_without_stderr_pattern: status is failed (not resource_exhaustion)" \
        "failed" "$status"
}

# ============================================================
# test_eagain_exit1_with_stderr_pattern
#
# Mock runner exits 1 (NOT 254) but writes the EAGAIN pattern to stderr.
# EAGAIN detection requires BOTH exit code 254 AND the pattern.
# Exit code 1 must not trigger EAGAIN detection — status must be "failed".
#
# RED: this test may PASS in RED phase (exit 1 is already "failed").
# We include it as a boundary assertion that implementation does not
# over-broaden EAGAIN detection to all non-zero exits with the pattern.
# ============================================================
test_eagain_exit1_with_stderr_pattern() {
    local repo artifacts runner
    repo=$(_make_rts_repo)
    artifacts=$(_make_tmpdir)
    runner=$(_make_mock_runner 1 "fork: Resource temporarily unavailable")

    (
        cd "$repo"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        RECORD_TEST_STATUS_RUNNER="$runner" \
        bash "$HOOK" 2>/dev/null
    ) || true

    local status
    status=$(_status_line1 "$artifacts")
    assert_eq "test_eagain_exit1_with_stderr_pattern: status is failed (exit code must be 254)" \
        "failed" "$status"
}

# ============================================================
# test_eagain_deference_to_existing_passed
#
# When test-gate-status already contains "passed" (from a previous invocation),
# and a subsequent --source-file invocation encounters EAGAIN (exit 254 +
# pattern), the existing "passed" status must be preserved — the merge path
# severity hierarchy treats resource_exhaustion as lower severity than passed
# (resource_exhaustion cannot downgrade an already-passed run).
#
# Actually: the correct behavior per the task spec is that the suite-engine
# result is authoritative. When existing = "passed" and new result is
# "resource_exhaustion", the merge must keep "passed".
#
# RED: without EAGAIN detection, exit 254 produces "failed", which DOES
# downgrade an existing "passed" to "failed". After implementation,
# "resource_exhaustion" must not downgrade "passed".
#
# Uses --source-file to exercise the merge path.
# ============================================================
test_eagain_deference_to_existing_passed() {
    local repo artifacts runner
    repo=$(_make_rts_repo)
    artifacts=$(_make_tmpdir)
    runner=$(_make_mock_runner 254 "fork: Resource temporarily unavailable")

    # Pre-seed test-gate-status with "passed"
    mkdir -p "$artifacts"
    printf 'passed\ndiff_hash=abc123\ntimestamp=2026-04-05T00:00:00Z\ntested_files=tests/test-other.sh\nfailed_tests=\n' \
        > "$artifacts/test-gate-status"

    # Run with --source-file to exercise the merge path.
    # src/widget.sh is mapped in .test-index to tests/test-widget.sh,
    # which the mock runner will execute and exit 254 + EAGAIN.
    (
        cd "$repo"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        RECORD_TEST_STATUS_RUNNER="$runner" \
        bash "$HOOK" --source-file "src/widget.sh" 2>/dev/null
    ) || true

    local status
    status=$(_status_line1 "$artifacts")
    assert_eq "test_eagain_deference_to_existing_passed: existing passed is preserved over resource_exhaustion" \
        "passed" "$status"
}

# ============================================================
# test_resource_exhaustion_severity_below_failed
#
# When two tests are run in the per-file loop:
#   - first test exits 1 (normal failure) → STATUS="failed"
#   - second test exits 254 + EAGAIN pattern → would be "resource_exhaustion"
# The final status must be "failed" because "failed" > "resource_exhaustion"
# in severity. resource_exhaustion must not displace an already-failed status.
#
# RED: without EAGAIN detection, both tests produce "failed"; the test passes
# trivially. After implementation, the severity hierarchy must be confirmed:
# "failed" must win over "resource_exhaustion".
#
# Implementation note: this test creates two separate test files in .test-index
# so both are exercised in the per-file loop. We use a stateful mock runner that
# reads a call counter to vary behavior across invocations.
# ============================================================
test_resource_exhaustion_severity_below_failed() {
    local repo artifacts runner_dir
    repo=$(_make_rts_repo)
    artifacts=$(_make_tmpdir)
    runner_dir=$(_make_tmpdir)

    # Add a second test file to the repo and .test-index
    cat > "$repo/tests/test-gadget.sh" <<'TESTEOF'
#!/usr/bin/env bash
echo "PASSED: 1  FAILED: 0"
exit 0
TESTEOF
    chmod +x "$repo/tests/test-gadget.sh"

    # Add src/gadget.sh as a second source file mapped to test-gadget.sh
    cat > "$repo/src/gadget.sh" <<'SRCEOF'
#!/usr/bin/env bash
echo "gadget"
SRCEOF
    git -C "$repo" add -A
    git -C "$repo" commit -m "add gadget" --quiet 2>/dev/null

    # Append second mapping to .test-index
    printf 'src/gadget.sh: tests/test-gadget.sh\n' >> "$repo/.test-index"
    git -C "$repo" add "$repo/.test-index" "$repo/tests/test-gadget.sh"

    # Stage both source files
    echo "# changed" >> "$repo/src/gadget.sh"
    git -C "$repo" add "$repo/src/gadget.sh"
    # src/widget.sh was already staged from _make_rts_repo

    # Stateful mock runner: first call (test-widget.sh) exits 1, second call (test-gadget.sh) exits 254 + EAGAIN
    local state_file="$runner_dir/call_count"
    echo "0" > "$state_file"

    local runner="$runner_dir/stateful-runner.sh"
    cat > "$runner" <<RUNEOF
#!/usr/bin/env bash
STATE_FILE="${state_file}"
count=\$(cat "\$STATE_FILE")
count=\$(( count + 1 ))
echo "\$count" > "\$STATE_FILE"
if [ "\$count" -eq 1 ]; then
    # First test: normal failure
    exit 1
fi
# Second test: EAGAIN
echo "fork: Resource temporarily unavailable" >&2
exit 254
RUNEOF
    chmod +x "$runner"

    (
        cd "$repo"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        RECORD_TEST_STATUS_RUNNER="$runner" \
        bash "$HOOK" 2>/dev/null
    ) || true

    local status
    status=$(_status_line1 "$artifacts")
    assert_eq "test_resource_exhaustion_severity_below_failed: failed wins over resource_exhaustion" \
        "failed" "$status"
}

# ============================================================
# test_eagain_blocking_io_error_pattern
#
# Alternate EAGAIN pattern: "BlockingIOError: [Errno 35] Resource temporarily unavailable"
# This is the Python-level EAGAIN error pattern. The detection must match it
# in the same way it matches the fork/EAGAIN pattern.
#
# Mock runner exits 254, writes "BlockingIOError: [Errno 35] Resource temporarily unavailable".
# Expected status: "resource_exhaustion".
#
# RED: without EAGAIN detection, exit 254 produces "failed".
# ============================================================
test_eagain_blocking_io_error_pattern() {
    local repo artifacts runner
    repo=$(_make_rts_repo)
    artifacts=$(_make_tmpdir)
    runner=$(_make_mock_runner 254 "BlockingIOError: [Errno 35] Resource temporarily unavailable")

    (
        cd "$repo"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        RECORD_TEST_STATUS_RUNNER="$runner" \
        bash "$HOOK" 2>/dev/null
    ) || true

    local status
    status=$(_status_line1 "$artifacts")
    assert_eq "test_eagain_blocking_io_error_pattern: BlockingIOError pattern → resource_exhaustion" \
        "resource_exhaustion" "$status"
}

# ============================================================
# test_merge_path_resource_exhaustion_then_failed
#
# Two sequential --source-file invocations against the same artifacts dir:
#   1. First invocation: runner exits 254 + EAGAIN → writes resource_exhaustion
#   2. Second invocation: runner exits 1 (normal failure) → merges to "failed"
#
# The merge severity hierarchy: failed > resource_exhaustion > passed.
# Final status in test-gate-status line 1 must be "failed".
#
# RED: without EAGAIN detection, first invocation writes "failed" (not
# resource_exhaustion). After implementation, both pre- and post-merge
# statuses follow the severity hierarchy correctly.
#
# Uses two --source-file invocations. The repo has two source files:
#   - src/widget.sh → tests/test-widget.sh (first invocation: EAGAIN)
#   - src/gadget.sh → tests/test-gadget.sh (second invocation: failed)
# ============================================================
test_merge_path_resource_exhaustion_then_failed() {
    local repo artifacts runner_eagain runner_fail
    repo=$(_make_rts_repo)
    artifacts=$(_make_tmpdir)
    runner_eagain=$(_make_mock_runner 254 "fork: Resource temporarily unavailable")
    runner_fail=$(_make_mock_runner 1 "")

    # Add second source and test files to the repo
    cat > "$repo/tests/test-gadget.sh" <<'TESTEOF'
#!/usr/bin/env bash
echo "PASSED: 1  FAILED: 0"
exit 0
TESTEOF
    chmod +x "$repo/tests/test-gadget.sh"

    cat > "$repo/src/gadget.sh" <<'SRCEOF'
#!/usr/bin/env bash
echo "gadget"
SRCEOF
    git -C "$repo" add -A
    git -C "$repo" commit -m "add gadget" --quiet 2>/dev/null

    printf 'src/gadget.sh: tests/test-gadget.sh\n' >> "$repo/.test-index"
    git -C "$repo" add "$repo/.test-index"
    git -C "$repo" commit -m "update test-index" --quiet 2>/dev/null

    # First --source-file invocation: EAGAIN runner → resource_exhaustion
    (
        cd "$repo"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        RECORD_TEST_STATUS_RUNNER="$runner_eagain" \
        bash "$HOOK" --source-file "src/widget.sh" 2>/dev/null
    ) || true

    local status_after_first
    status_after_first=$(_status_line1 "$artifacts")
    assert_eq "test_merge_path: after first invocation status is resource_exhaustion" \
        "resource_exhaustion" "$status_after_first"

    # Second --source-file invocation: normal failure runner → merges to failed
    (
        cd "$repo"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        RECORD_TEST_STATUS_RUNNER="$runner_fail" \
        bash "$HOOK" --source-file "src/gadget.sh" 2>/dev/null
    ) || true

    local status_after_second
    status_after_second=$(_status_line1 "$artifacts")
    assert_eq "test_merge_path: after second invocation merged status is failed" \
        "failed" "$status_after_second"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_eagain_exit254_with_stderr_pattern
test_eagain_exit254_without_stderr_pattern
test_eagain_exit1_with_stderr_pattern
test_eagain_deference_to_existing_passed
test_resource_exhaustion_severity_below_failed
test_eagain_blocking_io_error_pattern
test_merge_path_resource_exhaustion_then_failed

print_summary
