#!/usr/bin/env bash
# tests/scripts/test-pre-verifier-execute.sh
# Integration tests for pre-verifier-execute.sh.
#
# Covers:
#   1. Script produces valid JSON trace file with correct schema
#   2. PASS outcome for a command that exits 0
#   3. FAIL outcome for a command that exits non-zero (after retry)
#   4. DDs without verify commands appear in manifest with skip_reason
#   5. Confidence classification: pytest gets high, unknown gets normal
#   6. Summary counts are correct
#
# Usage: bash tests/scripts/test-pre-verifier-execute.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
PRE_VERIFY_SCRIPT="$REPO_ROOT/plugins/dso/scripts/pre-verifier-execute.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-pre-verifier-execute.sh ==="

_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

_create_story_with_dds() {
    local repo="$1"
    local dd_text="$2"
    local out
    out=$(cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" create story "Test story" \
            --description "### Done Definitions
$dd_text" 2>/dev/null) || true
    echo "$out" | tail -1
}

_run_pre_verify() {
    local repo="$1"
    local ticket_id="$2"
    # Create a wrapper script that the pre-verifier can call as DSO_TICKET_CMD
    local wrapper
    wrapper=$(mktemp "${TMPDIR:-/tmp}/ticket-wrapper.XXXXXX")
    cat > "$wrapper" <<WRAPPER_EOF
#!/usr/bin/env bash
_TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 exec bash "$TICKET_SCRIPT" "\$@"
WRAPPER_EOF
    chmod +x "$wrapper"
    (cd "$repo" && \
        PROJECT_ROOT="$repo" \
        DSO_TICKET_CMD="$wrapper" \
        bash "$PRE_VERIFY_SCRIPT" "$ticket_id" 2>/dev/null)
    local rc=$?
    rm -f "$wrapper"
    return $rc
}

# ── Test 1: produces valid JSON with correct schema ──────────────────────────
echo "Test 1: pre-verifier-execute.sh produces valid JSON trace"
test_produces_valid_json() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_story_with_dds "$repo" "- The command exits 0")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created" "non-empty" "empty"
        assert_pass_if_clean "test_produces_valid_json"
        return
    fi

    # Set a verify command that will pass
    (cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" set-verify-commands "$ticket_id" \
            '[{"dd_id":"dd-1","dd_text":"The command exits 0","command":"echo ok"}]' \
    ) >/dev/null 2>&1

    local trace_path
    trace_path=$(_run_pre_verify "$repo" "$ticket_id")

    if [ -z "$trace_path" ] || [ ! -f "$trace_path" ]; then
        assert_eq "trace file created" "exists" "missing"
        assert_pass_if_clean "test_produces_valid_json"
        return
    fi

    # Validate it's valid JSON
    local valid=0
    jq -e . "$trace_path" >/dev/null 2>&1 && valid=1
    assert_eq "trace is valid JSON" "1" "$valid"

    # Check schema_version
    local version
    version=$(jq -r '.schema_version' "$trace_path")
    assert_eq "schema_version is 1" "1" "$version"

    # Check story_id
    local story_id
    story_id=$(jq -r '.trace.story_id' "$trace_path")
    assert_eq "trace has correct story_id" "$ticket_id" "$story_id"

    # Check manifest exists and is array
    local manifest_type
    manifest_type=$(jq -r '.trace.manifest | type' "$trace_path")
    assert_eq "manifest is array" "array" "$manifest_type"

    # Check results exists and is array
    local results_type
    results_type=$(jq -r '.trace.results | type' "$trace_path")
    assert_eq "results is array" "array" "$results_type"

    rm -f "$trace_path"
    assert_pass_if_clean "test_produces_valid_json"
}
test_produces_valid_json

# ── Test 2: PASS outcome for exit-0 command ──────────────────────────────────
echo "Test 2: PASS outcome for a command that exits 0"
test_pass_outcome() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_story_with_dds "$repo" "- Feature works correctly")

    (cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" set-verify-commands "$ticket_id" \
            '[{"dd_id":"dd-1","dd_text":"Feature works correctly","command":"echo pass"}]' \
    ) >/dev/null 2>&1

    local trace_path
    trace_path=$(_run_pre_verify "$repo" "$ticket_id")

    local outcome
    outcome=$(jq -r '.trace.results[0].outcome' "$trace_path" 2>/dev/null)
    assert_eq "outcome is PASS" "PASS" "$outcome"

    local exit_code
    exit_code=$(jq -r '.trace.results[0].exit_code' "$trace_path" 2>/dev/null)
    assert_eq "exit_code is 0" "0" "$exit_code"

    local confidence
    confidence=$(jq -r '.trace.results[0].confidence' "$trace_path" 2>/dev/null)
    assert_eq "echo command gets normal confidence" "normal" "$confidence"

    rm -f "$trace_path"
    assert_pass_if_clean "test_pass_outcome"
}
test_pass_outcome

# ── Test 3: FAIL outcome for exit-nonzero command ────────────────────────────
echo "Test 3: FAIL outcome for a command that exits non-zero"
test_fail_outcome() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_story_with_dds "$repo" "- Feature fails")

    (cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" set-verify-commands "$ticket_id" \
            '[{"dd_id":"dd-1","dd_text":"Feature fails","command":"exit 1"}]' \
    ) >/dev/null 2>&1

    local trace_path
    trace_path=$(_run_pre_verify "$repo" "$ticket_id")

    local outcome
    outcome=$(jq -r '.trace.results[0].outcome' "$trace_path" 2>/dev/null)
    assert_eq "outcome is FAIL" "FAIL" "$outcome"

    local attempt
    attempt=$(jq -r '.trace.results[0].attempt' "$trace_path" 2>/dev/null)
    assert_eq "attempt is 2 (retried)" "2" "$attempt"

    rm -f "$trace_path"
    assert_pass_if_clean "test_fail_outcome"
}
test_fail_outcome

# ── Test 4: DDs without verify commands in manifest ──────────────────────────
echo "Test 4: DDs without verify commands appear in manifest with skip_reason"
test_no_command_manifest() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_story_with_dds "$repo" "- DD with command
- DD without command")

    # Only set command for dd-1, not dd-2
    (cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" set-verify-commands "$ticket_id" \
            '[{"dd_id":"dd-1","dd_text":"DD with command","command":"echo ok"}]' \
    ) >/dev/null 2>&1

    local trace_path
    trace_path=$(_run_pre_verify "$repo" "$ticket_id")

    local manifest_len
    manifest_len=$(jq '.trace.manifest | length' "$trace_path" 2>/dev/null)
    assert_eq "manifest has 2 entries" "2" "$manifest_len"

    local no_cmd_count
    no_cmd_count=$(jq '.trace.summary.no_command' "$trace_path" 2>/dev/null)
    assert_eq "no_command count is 1" "1" "$no_cmd_count"

    rm -f "$trace_path"
    assert_pass_if_clean "test_no_command_manifest"
}
test_no_command_manifest

# ── Test 5: confidence classification ────────────────────────────────────────
echo "Test 5: pytest gets high confidence, unknown gets normal"
test_confidence_classification() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_story_with_dds "$repo" "- Pytest test
- Custom check")

    (cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" set-verify-commands "$ticket_id" \
            '[{"dd_id":"dd-1","dd_text":"Pytest test","command":"pytest --version"},{"dd_id":"dd-2","dd_text":"Custom check","command":"echo custom"}]' \
    ) >/dev/null 2>&1

    local trace_path
    trace_path=$(_run_pre_verify "$repo" "$ticket_id")

    local conf1
    conf1=$(jq -r '.trace.results[] | select(.dd_id == "dd-1") | .confidence' "$trace_path" 2>/dev/null)
    assert_eq "pytest gets high confidence" "high" "$conf1"

    local conf2
    conf2=$(jq -r '.trace.results[] | select(.dd_id == "dd-2") | .confidence' "$trace_path" 2>/dev/null)
    assert_eq "echo gets normal confidence" "normal" "$conf2"

    rm -f "$trace_path"
    assert_pass_if_clean "test_confidence_classification"
}
test_confidence_classification

# ── Test 6: summary counts ──────────────────────────────────────────────────
echo "Test 6: summary counts are correct"
test_summary_counts() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_story_with_dds "$repo" "- Pass DD
- Fail DD
- No cmd DD")

    (cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" set-verify-commands "$ticket_id" \
            '[{"dd_id":"dd-1","dd_text":"Pass DD","command":"echo pass"},{"dd_id":"dd-2","dd_text":"Fail DD","command":"exit 1"}]' \
    ) >/dev/null 2>&1

    local trace_path
    trace_path=$(_run_pre_verify "$repo" "$ticket_id")

    local total
    total=$(jq '.trace.summary.total_dds' "$trace_path" 2>/dev/null)
    assert_eq "total_dds is 3" "3" "$total"

    local executed
    executed=$(jq '.trace.summary.executed' "$trace_path" 2>/dev/null)
    assert_eq "executed is 2" "2" "$executed"

    local passed
    passed=$(jq '.trace.summary.passed' "$trace_path" 2>/dev/null)
    assert_eq "passed is 1" "1" "$passed"

    local failed
    failed=$(jq '.trace.summary.failed' "$trace_path" 2>/dev/null)
    assert_eq "failed is 1" "1" "$failed"

    local no_cmd
    no_cmd=$(jq '.trace.summary.no_command' "$trace_path" 2>/dev/null)
    assert_eq "no_command is 1" "1" "$no_cmd"

    rm -f "$trace_path"
    assert_pass_if_clean "test_summary_counts"
}
test_summary_counts

# ── Test 7: TIMEOUT outcome for a slow command ──────────────────────────────
echo "Test 7: TIMEOUT outcome for a command that exceeds timeout"
test_timeout_outcome() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_story_with_dds "$repo" "- Slow feature")

    (cd "$repo" && \
        _TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 \
        bash "$TICKET_SCRIPT" set-verify-commands "$ticket_id" \
            '[{"dd_id":"dd-1","dd_text":"Slow feature","command":"sleep 10"}]' \
    ) >/dev/null 2>&1

    # Create wrapper with 2s timeout override
    local wrapper
    wrapper=$(mktemp "${TMPDIR:-/tmp}/ticket-wrapper.XXXXXX")
    cat > "$wrapper" <<WRAPPER_EOF
#!/usr/bin/env bash
_TICKET_TEST_NO_SYNC=1 DSO_TICKET_LEGACY=0 exec bash "$TICKET_SCRIPT" "\$@"
WRAPPER_EOF
    chmod +x "$wrapper"

    local trace_path
    trace_path=$(cd "$repo" && \
        PROJECT_ROOT="$repo" \
        DSO_TICKET_CMD="$wrapper" \
        DSO_VERIFY_TIMEOUT=2 \
        bash "$PRE_VERIFY_SCRIPT" "$ticket_id" 2>/dev/null)
    rm -f "$wrapper"

    local outcome
    outcome=$(jq -r '.trace.results[0].outcome' "$trace_path" 2>/dev/null)
    assert_eq "outcome is TIMEOUT" "TIMEOUT" "$outcome"

    local timeout_count
    timeout_count=$(jq '.trace.summary.timeout' "$trace_path" 2>/dev/null)
    assert_eq "timeout count is 1" "1" "$timeout_count"

    rm -f "$trace_path"
    assert_pass_if_clean "test_timeout_outcome"
}
test_timeout_outcome

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== test-pre-verifier-execute.sh complete ==="
print_summary
