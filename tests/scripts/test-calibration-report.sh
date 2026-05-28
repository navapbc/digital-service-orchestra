#!/usr/bin/env bash
# tests/scripts/test-calibration-report.sh
# Fixture-driven behavioral tests for plugins/dso/scripts/calibration-report.sh
#
# Testing Mode: RED → GREEN — write failing test first, then implement.
#
# Task coverage: 92fd-f373-f963-4d52
# Story coverage: calibration-program monthly aggregation
#
# Behavioral pattern: every test follows Given / When / Then. Tests invoke
# calibration-report.sh as a subprocess with --fixture and --dry-run flags.
#
# Usage: bash tests/scripts/test-calibration-report.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CALIBRATION_SCRIPT="$REPO_ROOT/plugins/dso/scripts/calibration-report.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/a34c-sprint-bugs"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-calibration-report.sh ==="

# ── Suite-level prereq guard ────────────────────────────────────────────────
# We do NOT use a _RUN_ALL_ACTIVE skip guard — this test is not a deferred RED.
# The script MUST exist for these tests to pass (GREEN phase).

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: Script exists and is executable
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 1: calibration-report.sh exists and is executable"
test_script_exists_and_executable() {
    _snapshot_fail

    if [ -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists" "exists" "exists"
    else
        assert_eq "calibration-report.sh exists" "exists" "missing"
    fi

    if [ -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh is executable" "executable" "executable"
    else
        assert_eq "calibration-report.sh is executable" "executable" "not-executable"
    fi

    assert_pass_if_clean "test_script_exists_and_executable"
}
test_script_exists_and_executable

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: CALIBRATION_TZ='UTC' declared exactly once
#
# Given: calibration-report.sh source file
# When:  we grep for the readonly CALIBRATION_TZ='UTC' declaration
# Then:  exactly 1 occurrence exists
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 2: CALIBRATION_TZ='UTC' declared exactly once"
test_calibration_tz_declared_once() {
    _snapshot_fail

    if [ ! -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_calibration_tz_declared_once"
        return
    fi

    local count
    count=$(grep -c "^readonly CALIBRATION_TZ='UTC'" "$CALIBRATION_SCRIPT" || true)
    assert_eq "CALIBRATION_TZ='UTC' declared exactly once" "1" "$count"

    assert_pass_if_clean "test_calibration_tz_declared_once"
}
test_calibration_tz_declared_once

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: Unknown subcommand exits non-zero and prints to stderr
#
# Given: calibration-report.sh is invoked with an unknown subcommand
# When:  "badsubcmd" is passed
# Then:  exit code is non-zero (stderr is allowed to receive usage text)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 3: unknown subcommand exits non-zero"
test_unknown_subcommand_exits_nonzero() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_unknown_subcommand_exits_nonzero"
        return
    fi

    local exit_code=0
    "$CALIBRATION_SCRIPT" badsubcmd 2>/dev/null || exit_code=$?
    assert_ne "badsubcmd exits non-zero" "0" "$exit_code"

    assert_pass_if_clean "test_unknown_subcommand_exits_nonzero"
}
test_unknown_subcommand_exits_nonzero

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: Fixture directory exists with at least one JSON file
#
# Given: tests/fixtures/a34c-sprint-bugs/ directory
# When:  we check its contents
# Then:  directory exists and contains at least 1 .json file
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 4: fixture directory exists with JSON files"
test_fixture_directory_exists() {
    _snapshot_fail

    if [ -d "$FIXTURE_DIR" ]; then
        assert_eq "fixture directory exists" "exists" "exists"
    else
        assert_eq "fixture directory exists" "exists" "missing"
    fi

    local json_count
    json_count=$(find "$FIXTURE_DIR" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    assert_ne "fixture directory has at least 1 JSON file" "0" "$json_count"

    assert_pass_if_clean "test_fixture_directory_exists"
}
test_fixture_directory_exists

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: monthly --dry-run output contains the rollup HTML comment marker
#
# Given: fixture with 6 bugs across 3 channels (tests:3, review-llm:2, user-report:1)
# When:  monthly --fixture --dry-run --period 2026-04
# Then:  stdout contains <!-- calibration-rollup: period=2026-04 kind=monthly -->
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 5: monthly dry-run output contains calibration-rollup HTML marker"
test_monthly_dry_run_contains_marker() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_monthly_dry_run_contains_marker"
        return
    fi

    if [ ! -d "$FIXTURE_DIR" ]; then
        assert_eq "fixture directory exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_monthly_dry_run_contains_marker"
        return
    fi

    local out exit_code=0
    out=$("$CALIBRATION_SCRIPT" monthly --fixture "$FIXTURE_DIR" --dry-run --period 2026-04 2>/dev/null) || exit_code=$?

    assert_eq "monthly --dry-run exits 0" "0" "$exit_code"
    assert_contains "stdout contains calibration-rollup marker" \
        "<!-- calibration-rollup: period=2026-04 kind=monthly -->" \
        "$out"

    assert_pass_if_clean "test_monthly_dry_run_contains_marker"
}
test_monthly_dry_run_contains_marker

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: monthly aggregation produces correct per-channel counts
#
# Given: fixture with tests:3, review-llm:2, user-report:1
# When:  monthly --fixture --dry-run --period 2026-04
# Then:  stdout shows correct counts for each channel
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 6: monthly aggregation shows correct per-channel counts"
test_monthly_channel_counts() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_monthly_channel_counts"
        return
    fi

    if [ ! -d "$FIXTURE_DIR" ]; then
        assert_eq "fixture directory exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_monthly_channel_counts"
        return
    fi

    local out exit_code=0
    out=$("$CALIBRATION_SCRIPT" monthly --fixture "$FIXTURE_DIR" --dry-run --period 2026-04 2>/dev/null) || exit_code=$?

    assert_eq "monthly --dry-run exits 0" "0" "$exit_code"

    # Check that each channel and its count appear in the output.
    # Flexible matching: "tests: 3" or "tests:3" or "tests | 3" etc.
    assert_contains "stdout contains tests channel count" "tests" "$out"
    assert_contains "stdout contains review-llm channel count" "review-llm" "$out"
    assert_contains "stdout contains user-report channel count" "user-report" "$out"

    # Assert exact count values appear near their channel names.
    # We match "3" appearing somewhere after "tests" in the output.
    if echo "$out" | grep -q "tests.*3\|3.*tests"; then
        assert_eq "tests channel count is 3" "found" "found"
    else
        assert_eq "tests channel count is 3" "found" "not-found"
    fi

    if echo "$out" | grep -q "review-llm.*2\|2.*review-llm"; then
        assert_eq "review-llm channel count is 2" "found" "found"
    else
        assert_eq "review-llm channel count is 2" "found" "not-found"
    fi

    if echo "$out" | grep -q "user-report.*1\|1.*user-report"; then
        assert_eq "user-report channel count is 1" "found" "found"
    else
        assert_eq "user-report channel count is 1" "found" "not-found"
    fi

    assert_pass_if_clean "test_monthly_channel_counts"
}
test_monthly_channel_counts

# ═══════════════════════════════════════════════════════════════════════════════
# Test 7: nonexistent fixture path exits non-zero
#
# Given: --fixture path that does not exist
# When:  monthly --fixture /nonexistent/path --dry-run --period 2026-04
# Then:  exit code is non-zero
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 7: nonexistent fixture path exits non-zero"
test_nonexistent_fixture_exits_nonzero() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_nonexistent_fixture_exits_nonzero"
        return
    fi

    local exit_code=0
    "$CALIBRATION_SCRIPT" monthly --fixture /nonexistent/path --dry-run --period 2026-04 2>/dev/null \
        || exit_code=$?
    assert_ne "nonexistent fixture exits non-zero" "0" "$exit_code"

    assert_pass_if_clean "test_nonexistent_fixture_exits_nonzero"
}
test_nonexistent_fixture_exits_nonzero

# ═══════════════════════════════════════════════════════════════════════════════
# Test 8: monthly idempotency guard — skip posting if rollup already posted
#
# Given: a DSO stub that returns calibration-program-health with the marker
#        already present in its comments for period 2026-04
# When:  monthly is invoked for the same period (2026-04)
# Then:  script exits 0, stderr contains 'skip' or 'already',
#        and no 'ticket comment' call is made
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 8: monthly idempotency guard skips duplicate rollup posting"
test_monthly_idempotency_skip_duplicate() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_monthly_idempotency_skip_duplicate"
        return
    fi

    # Build a temp dir for the DSO stub and tracking file
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cal-idempotency.XXXXXX")
    local comment_call_log="${tmp_dir}/comment_calls.log"
    local stub="${tmp_dir}/dso"

    # The stub simulates:
    #   ticket list --type=epic          →  JSON array with calibration-program-health epic
    #   ticket show mock-health-001      →  JSON with existing rollup comment for 2026-04
    #   ticket comment ...               →  logs the call so we can assert it was NOT made
    cat > "$stub" <<STUB
#!/usr/bin/env bash
# Mock DSO stub for idempotency test
COMMENT_CALL_LOG="${comment_call_log}"

subcmd="\$1"; shift

case "\$subcmd" in
    ticket)
        ticket_subcmd="\$1"; shift
        case "\$ticket_subcmd" in
            list)
                # Return JSON array with health epic (default format — tags field, not tg)
                if [[ "\$*" == *"--type=epic"* ]]; then
                    echo '[{"ticket_id":"mock-health-001","type":"epic","title":"Health","tags":["calibration-program-health"],"status":"open"}]'
                fi
                ;;
            show)
                # Return full ticket JSON with existing rollup comment containing 2026-04 marker
                echo '{"ticket_id":"mock-health-001","comments":[{"body":"<!-- calibration-rollup: period=2026-04 kind=monthly -->\\n## Rollup","author":"bot","timestamp":1000000}]}'
                ;;
            comment)
                # Log this call — should NOT happen on duplicate
                echo "ticket comment called: \$*" >> "\$COMMENT_CALL_LOG"
                ;;
        esac
        ;;
esac
STUB
    chmod +x "$stub"

    # Invoke monthly for the same period — should detect marker and skip
    local stderr_out exit_code=0
    stderr_out=$(DSO="$stub" "$CALIBRATION_SCRIPT" monthly \
        --fixture "$FIXTURE_DIR" --period 2026-04 2>&1 >/dev/null) || exit_code=$?

    # Assert: exits 0
    assert_eq "idempotency guard exits 0" "0" "$exit_code"

    # Assert: stderr contains 'skip' or 'already'
    local stderr_lower
    stderr_lower=$(echo "$stderr_out" | tr '[:upper:]' '[:lower:]')
    if echo "$stderr_lower" | grep -qE 'skip|already'; then
        assert_eq "stderr mentions skip or already" "found" "found"
    else
        assert_eq "stderr mentions skip or already" "found" "not-found"
    fi

    # Assert: no 'ticket comment' call was made
    if [ -f "$comment_call_log" ] && [ -s "$comment_call_log" ]; then
        assert_eq "no ticket comment call made (idempotent)" "no-call" "called"
    else
        assert_eq "no ticket comment call made (idempotent)" "no-call" "no-call"
    fi

    rm -rf "$tmp_dir"

    assert_pass_if_clean "test_monthly_idempotency_skip_duplicate"
}
test_monthly_idempotency_skip_duplicate

# ═══════════════════════════════════════════════════════════════════════════════
# Test 9: quarterly subcommand exists in dispatcher
#
# Given: calibration-report.sh source file
# When:  we grep for the quarterly) case in the dispatcher
# Then:  it matches (proving the subcommand is registered)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 9: quarterly subcommand registered in dispatcher"
test_quarterly_subcommand_registered() {
    _snapshot_fail

    if [ ! -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_quarterly_subcommand_registered"
        return
    fi

    if grep -qE '^[[:space:]]*quarterly\)' "$CALIBRATION_SCRIPT"; then
        assert_eq "quarterly) case registered" "found" "found"
    else
        assert_eq "quarterly) case registered" "found" "not-found"
    fi

    assert_pass_if_clean "test_quarterly_subcommand_registered"
}
test_quarterly_subcommand_registered

# ═══════════════════════════════════════════════════════════════════════════════
# Test 10: quarterly --dry-run output contains kind=quarterly HTML marker
#
# Given: fixture with 6 bugs across 3 channels
# When:  quarterly --fixture --dry-run --period 2026-Q2
# Then:  stdout contains <!-- calibration-rollup: period=2026-Q2 kind=quarterly -->
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 10: quarterly dry-run output contains kind=quarterly HTML marker"
test_quarterly_dry_run_contains_marker() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_quarterly_dry_run_contains_marker"
        return
    fi

    if [ ! -d "$FIXTURE_DIR" ]; then
        assert_eq "fixture directory exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_quarterly_dry_run_contains_marker"
        return
    fi

    local out exit_code=0
    out=$("$CALIBRATION_SCRIPT" quarterly --fixture "$FIXTURE_DIR" --dry-run --period 2026-Q2 2>/dev/null) \
        || exit_code=$?

    assert_eq "quarterly --dry-run exits 0" "0" "$exit_code"
    assert_contains "stdout contains kind=quarterly marker" \
        "<!-- calibration-rollup: period=2026-Q2 kind=quarterly -->" \
        "$out"

    assert_pass_if_clean "test_quarterly_dry_run_contains_marker"
}
test_quarterly_dry_run_contains_marker

# ═══════════════════════════════════════════════════════════════════════════════
# Test 11: quarterly aggregation shows correct per-channel counts
#
# Given: fixture with tests:3, review-llm:2, user-report:1
# When:  quarterly --fixture --dry-run --period 2026-Q2
# Then:  stdout shows channel names and counts matching fixture distribution
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 11: quarterly aggregation shows correct per-channel counts"
test_quarterly_channel_counts() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_quarterly_channel_counts"
        return
    fi

    if [ ! -d "$FIXTURE_DIR" ]; then
        assert_eq "fixture directory exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_quarterly_channel_counts"
        return
    fi

    local out exit_code=0
    out=$("$CALIBRATION_SCRIPT" quarterly --fixture "$FIXTURE_DIR" --dry-run --period 2026-Q2 2>/dev/null) \
        || exit_code=$?

    assert_eq "quarterly --dry-run exits 0" "0" "$exit_code"

    assert_contains "stdout contains tests channel" "tests" "$out"
    assert_contains "stdout contains review-llm channel" "review-llm" "$out"
    assert_contains "stdout contains user-report channel" "user-report" "$out"

    if echo "$out" | grep -q "tests.*3\|3.*tests"; then
        assert_eq "tests channel count is 3" "found" "found"
    else
        assert_eq "tests channel count is 3" "found" "not-found"
    fi

    if echo "$out" | grep -q "review-llm.*2\|2.*review-llm"; then
        assert_eq "review-llm channel count is 2" "found" "found"
    else
        assert_eq "review-llm channel count is 2" "found" "not-found"
    fi

    if echo "$out" | grep -q "user-report.*1\|1.*user-report"; then
        assert_eq "user-report channel count is 1" "found" "found"
    else
        assert_eq "user-report channel count is 1" "found" "not-found"
    fi

    assert_pass_if_clean "test_quarterly_channel_counts"
}
test_quarterly_channel_counts

# ═══════════════════════════════════════════════════════════════════════════════
# Test 12: invalid quarter Q5 exits non-zero
#
# Given: --period 2026-Q5 (invalid; only Q1-Q4 are valid)
# When:  quarterly is invoked with --period 2026-Q5 --dry-run
# Then:  exit code is non-zero
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 12: invalid quarter Q5 exits non-zero"
test_quarterly_invalid_q5_exits_nonzero() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_quarterly_invalid_q5_exits_nonzero"
        return
    fi

    local exit_code=0
    "$CALIBRATION_SCRIPT" quarterly --fixture "$FIXTURE_DIR" --dry-run --period 2026-Q5 2>/dev/null \
        || exit_code=$?
    assert_ne "Q5 exits non-zero" "0" "$exit_code"

    assert_pass_if_clean "test_quarterly_invalid_q5_exits_nonzero"
}
test_quarterly_invalid_q5_exits_nonzero

# ═══════════════════════════════════════════════════════════════════════════════
# Test 13: monthly and quarterly markers are DISTINCT strings
#
# Given: same fixture, monthly period=2026-04, quarterly period=2026-Q2
# When:  both subcommands run with --dry-run
# Then:  the extracted HTML comment markers differ (no collision)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 13: monthly and quarterly HTML markers are distinct"
test_monthly_quarterly_markers_distinct() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_monthly_quarterly_markers_distinct"
        return
    fi

    if [ ! -d "$FIXTURE_DIR" ]; then
        assert_eq "fixture directory exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_monthly_quarterly_markers_distinct"
        return
    fi

    local m_marker q_marker
    m_marker=$("$CALIBRATION_SCRIPT" monthly \
        --fixture "$FIXTURE_DIR" --dry-run --period 2026-04 2>/dev/null \
        | grep -oE '<!--[^>]*-->' | head -1)
    q_marker=$("$CALIBRATION_SCRIPT" quarterly \
        --fixture "$FIXTURE_DIR" --dry-run --period 2026-Q2 2>/dev/null \
        | grep -oE '<!--[^>]*-->' | head -1)

    assert_ne "monthly and quarterly markers are distinct" "$m_marker" "$q_marker"

    # Also verify kind=quarterly appears in quarterly marker
    if echo "$q_marker" | grep -q "kind=quarterly"; then
        assert_eq "quarterly marker contains kind=quarterly" "found" "found"
    else
        assert_eq "quarterly marker contains kind=quarterly" "found" "not-found"
    fi

    # And kind=monthly appears in monthly marker
    if echo "$m_marker" | grep -q "kind=monthly"; then
        assert_eq "monthly marker contains kind=monthly" "found" "found"
    else
        assert_eq "monthly marker contains kind=monthly" "found" "not-found"
    fi

    assert_pass_if_clean "test_monthly_quarterly_markers_distinct"
}
test_monthly_quarterly_markers_distinct

# ═══════════════════════════════════════════════════════════════════════════════
# Test 14: aggregate_bugs_by_channel shared function used in both monthly + quarterly
#
# Given: calibration-report.sh source file
# When:  we count occurrences of aggregate_bugs_by_channel (or aggregate_by_channel)
# Then:  at least 2 references exist (definition + invocation from each subcommand)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 14: shared aggregation function referenced at least twice"
test_shared_aggregation_function_referenced() {
    _snapshot_fail

    if [ ! -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_shared_aggregation_function_referenced"
        return
    fi

    local count
    count=$(grep -cE '(aggregate_bugs_by_channel|aggregate_by_channel)' "$CALIBRATION_SCRIPT" || true)

    if [ "$count" -ge 2 ]; then
        assert_eq "shared aggregation function referenced >= 2 times" "found" "found"
    else
        assert_eq "shared aggregation function referenced >= 2 times" "found" "not-found (count=$count)"
    fi

    assert_pass_if_clean "test_shared_aggregation_function_referenced"
}
test_shared_aggregation_function_referenced

# ═══════════════════════════════════════════════════════════════════════════════
# Test 15: idempotency guard must use ticket show, NOT ticket list-comments
#
# Given: a DSO stub that handles ticket show (with marker) but NOT list-comments
# When:  monthly is invoked for the same period (2026-04)
# Then:  guard finds marker via ticket show → skips → no comment posted
# RED on current impl: calls ticket list-comments (not stubbed) → empty → posts
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 15: idempotency guard uses ticket show, not ticket list-comments"
test_idempotency_guard_uses_ticket_show() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_idempotency_guard_uses_ticket_show"
        return
    fi

    local tmp_dir comment_log stub
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cal-red-idempotency.XXXXXX")
    comment_log="${tmp_dir}/comment_calls.log"
    stub="${tmp_dir}/dso"

    # Cooperating stub for health-ticket lookup (both current and fixed impl can find it).
    # ticket show returns JSON with monthly marker. ticket list-comments NOT handled.
    # ticket comment logs (must NOT be called if guard works).
    cat > "$stub" <<STUB
#!/usr/bin/env bash
log="${comment_log}"
case "\$*" in
  *"ticket list"*"--type=epic"*)
    printf '[{"id":"mock-h-001","ticket_id":"mock-h-001","type":"epic","title":"Health","tags":["calibration-program-health"],"tg":["calibration-program-health"],"status":"open"}]\n'
    ;;
  *"ticket show"*"mock-h-001"*)
    printf '{"ticket_id":"mock-h-001","tags":["calibration-program-health"],"comments":[{"body":"<!-- calibration-rollup: period=2026-04 kind=monthly -->","author":"bot","timestamp":1000000}]}\n'
    ;;
  *"ticket comment"*)
    echo "comment posted" >> "\$log"
    ;;
esac
STUB
    chmod +x "$stub"

    local exit_code=0
    DSO="$stub" "$CALIBRATION_SCRIPT" monthly \
        --fixture "$FIXTURE_DIR" --period 2026-04 2>/dev/null || exit_code=$?

    assert_eq "exits 0 (idempotent)" "0" "$exit_code"

    if [ -f "$comment_log" ] && [ -s "$comment_log" ]; then
        assert_eq "no duplicate comment posted (idempotent via ticket show)" "no-post" "posted"
    else
        assert_eq "no duplicate comment posted (idempotent via ticket show)" "no-post" "no-post"
    fi

    rm -rf "$tmp_dir"
    assert_pass_if_clean "test_idempotency_guard_uses_ticket_show"
}
test_idempotency_guard_uses_ticket_show

# ═══════════════════════════════════════════════════════════════════════════════
# Test 16: health-ticket lookup must NOT use --format=llm
#
# Given: stub where --format=llm returns empty; default format returns health ticket
# When:  monthly is invoked (non-dry-run, fixture)
# Then:  health ticket is found → rollup comment IS posted
# RED on current impl: uses --format=llm → empty → WARNING → no post
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 16: health-ticket lookup uses default JSON format, not --format=llm"
test_health_ticket_lookup_uses_default_format() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_health_ticket_lookup_uses_default_format"
        return
    fi

    local tmp_dir comment_log stub
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cal-red-lookup.XXXXXX")
    comment_log="${tmp_dir}/comment_calls.log"
    stub="${tmp_dir}/dso"

    cat > "$stub" <<STUB
#!/usr/bin/env bash
log="${comment_log}"
case "\$*" in
  *"ticket list"*"--format=llm"*)
    # llm format returns empty (real behavior: tags→tg, missing fields)
    ;;
  *"ticket list"*"--type=epic"*)
    # Default format: JSON array with health ticket and tags field
    printf '[{"ticket_id":"mock-h-001","type":"epic","title":"Health","tags":["calibration-program-health"],"status":"open"}]\n'
    ;;
  *"ticket show"*"mock-h-001"*)
    printf '{"ticket_id":"mock-h-001","comments":[]}\n'
    ;;
  *"ticket comment"*)
    echo "posted" >> "\$log"
    ;;
esac
STUB
    chmod +x "$stub"

    local exit_code=0
    DSO="$stub" "$CALIBRATION_SCRIPT" monthly \
        --fixture "$FIXTURE_DIR" --period 2026-05 2>/dev/null || exit_code=$?

    assert_eq "exits 0" "0" "$exit_code"

    if [ -f "$comment_log" ] && [ -s "$comment_log" ]; then
        assert_eq "rollup comment posted (health ticket found via default format)" "posted" "posted"
    else
        assert_eq "rollup comment posted (health ticket found via default format)" "posted" "not-posted"
    fi

    rm -rf "$tmp_dir"
    assert_pass_if_clean "test_health_ticket_lookup_uses_default_format"
}
test_health_ticket_lookup_uses_default_format

# ═══════════════════════════════════════════════════════════════════════════════
# Test 17: monthly CLI path must filter bugs by period (not all-time)
#
# Given: DSO stub returning bugs from 2026-01 (detected_by:tests) and
#        2026-05 (detected_by:user-report); period requested is 2026-01
# When:  monthly --period 2026-01 (no --fixture; uses CLI path)
# Then:  rollup only counts January bug; user-report channel absent
# RED on current impl: _load_from_cli loads ALL bugs → both channels counted
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 17: monthly CLI path filters bugs to the specified period"
test_monthly_cli_filters_by_period() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_monthly_cli_filters_by_period"
        return
    fi

    local tmp_dir comment_log stub
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cal-red-period.XXXXXX")
    comment_log="${tmp_dir}/comment_calls.log"
    stub="${tmp_dir}/dso"

    # 2026-01-15 UTC ≈ 1768435200s → ns; 2026-05-15 UTC ≈ 1778803200s → ns
    local jan_ns may_ns
    jan_ns="1768435200000000000"
    may_ns="1778803200000000000"

    cat > "$stub" <<STUB
#!/usr/bin/env bash
log="${comment_log}"
jan_ns="${jan_ns}"
may_ns="${may_ns}"
case "\$*" in
  *"ticket list"*"--format=llm"*)
    ;;
  *"ticket list"*"--type=epic"*)
    printf '[{"ticket_id":"mock-h-001","type":"epic","title":"Health","tags":["calibration-program-health"],"status":"open"}]\n'
    ;;
  *"ticket list"*"--type=bug"*)
    printf '[{"ticket_id":"b-jan","type":"bug","title":"Jan bug","status":"open","created_at":%s,"tags":["detected_by:tests"]},{"ticket_id":"b-may","type":"bug","title":"May bug","status":"open","created_at":%s,"tags":["detected_by:user-report"]}]\n' "\$jan_ns" "\$may_ns"
    ;;
  *"ticket show"*"mock-h-001"*)
    printf '{"ticket_id":"mock-h-001","comments":[]}\n'
    ;;
  *"ticket comment"*)
    printf '%s\n' "\$*" >> "\$log"
    ;;
esac
STUB
    chmod +x "$stub"

    local exit_code=0
    DSO="$stub" "$CALIBRATION_SCRIPT" monthly --period 2026-01 2>/dev/null || exit_code=$?

    assert_eq "exits 0" "0" "$exit_code"

    if [ ! -f "$comment_log" ] || [ ! -s "$comment_log" ]; then
        assert_eq "rollup comment posted" "posted" "not-posted"
        rm -rf "$tmp_dir"
        assert_pass_if_clean "test_monthly_cli_filters_by_period"
        return
    fi

    local comment_content
    comment_content=$(cat "$comment_log")

    if echo "$comment_content" | grep -q "tests"; then
        assert_eq "Jan channel (tests) in rollup" "present" "present"
    else
        assert_eq "Jan channel (tests) in rollup" "present" "absent"
    fi

    if echo "$comment_content" | grep -q "user-report"; then
        assert_eq "May channel (user-report) absent in 2026-01 rollup" "absent" "present"
    else
        assert_eq "May channel (user-report) absent in 2026-01 rollup" "absent" "absent"
    fi

    rm -rf "$tmp_dir"
    assert_pass_if_clean "test_monthly_cli_filters_by_period"
}
test_monthly_cli_filters_by_period

# ─── mutation-append exits 1 when health ticket is absent ─────────────────────
test_mutation_append_exits_1_on_missing_health_ticket() {
    _snapshot_fail
    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_mutation_append_exits_1_on_missing_health_ticket"
        return
    fi

    local tmp_dir stub
    local exit_code=0
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cal-test.XXXXXX")
    stub="$tmp_dir/dso"

    # Stub returns empty list — no calibration-program-health ticket
    cat >"$stub" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ticket list"*"--type=epic"*)
    printf '[]\n'
    ;;
  *)
    printf '[]\n'
    ;;
esac
STUB
    chmod +x "$stub"

    DSO="$stub" "$CALIBRATION_SCRIPT" mutation-append --pr test-pr-001 --findings 5 2>/dev/null || exit_code=$?

    assert_eq "mutation-append exits 1 when health ticket absent" "1" "$exit_code"

    rm -rf "$tmp_dir"
    assert_pass_if_clean "test_mutation_append_exits_1_on_missing_health_ticket"
}
test_mutation_append_exits_1_on_missing_health_ticket

# ─── monthly exits 1 when health ticket is absent ────────────────────────────
test_monthly_exits_1_on_missing_health_ticket() {
    _snapshot_fail
    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_monthly_exits_1_on_missing_health_ticket"
        return
    fi

    local tmp_dir stub
    local exit_code=0
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cal-test.XXXXXX")
    stub="$tmp_dir/dso"

    # Stub returns empty list — no calibration-program-health ticket
    cat >"$stub" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ticket list"*"--type=epic"*)
    printf '[]\n'
    ;;
  *)
    printf '[]\n'
    ;;
esac
STUB
    chmod +x "$stub"

    DSO="$stub" "$CALIBRATION_SCRIPT" monthly --fixture "$FIXTURE_DIR" --period 2026-04 2>/dev/null || exit_code=$?

    assert_eq "monthly exits 1 when health ticket absent" "1" "$exit_code"

    rm -rf "$tmp_dir"
    assert_pass_if_clean "test_monthly_exits_1_on_missing_health_ticket"
}
test_monthly_exits_1_on_missing_health_ticket

# ─── quarterly exits 1 when health ticket is absent ───────────────────────────
test_quarterly_exits_1_on_missing_health_ticket() {
    _snapshot_fail
    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_quarterly_exits_1_on_missing_health_ticket"
        return
    fi

    local tmp_dir stub
    local exit_code=0
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cal-test.XXXXXX")
    stub="$tmp_dir/dso"

    # Stub returns empty list — no calibration-program-health ticket
    cat >"$stub" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ticket list"*"--type=epic"*)
    printf '[]\n'
    ;;
  *)
    printf '[]\n'
    ;;
esac
STUB
    chmod +x "$stub"

    DSO="$stub" "$CALIBRATION_SCRIPT" quarterly --fixture "$FIXTURE_DIR" --period 2026-Q2 2>/dev/null || exit_code=$?

    assert_eq "quarterly exits 1 when health ticket absent" "1" "$exit_code"

    rm -rf "$tmp_dir"
    assert_pass_if_clean "test_quarterly_exits_1_on_missing_health_ticket"
}
test_quarterly_exits_1_on_missing_health_ticket

# ─── churn-append exits 1 when health ticket is absent ────────────────────────
test_churn_append_exits_1_on_missing_health_ticket() {
    _snapshot_fail
    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_churn_append_exits_1_on_missing_health_ticket"
        return
    fi

    local tmp_dir stub
    local exit_code=0
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cal-test.XXXXXX")
    stub="$tmp_dir/dso"

    cat >"$stub" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ticket list"*"--type=epic"*)
    printf '[]\n'
    ;;
  *)
    printf '[]\n'
    ;;
esac
STUB
    chmod +x "$stub"

    DSO="$stub" "$CALIBRATION_SCRIPT" churn-append --pr test-pr-001 --churn 3 2>/dev/null || exit_code=$?

    assert_eq "churn-append exits 1 when health ticket absent" "1" "$exit_code"

    rm -rf "$tmp_dir"
    assert_pass_if_clean "test_churn_append_exits_1_on_missing_health_ticket"
}
test_churn_append_exits_1_on_missing_health_ticket

# ═══════════════════════════════════════════════════════════════════════════════
print_summary
