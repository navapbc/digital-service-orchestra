#!/usr/bin/env bash
# tests/scripts/test-calibration-query.sh
# Fixture-driven behavioral tests for calibration-report.sh query subcommand.
#
# Testing Mode: GREEN — implements tests for the query subcommand added in tasks
#   3ef4-8499-9f15-44f8 and ae0e-b914-c322-4e72 (story 602a-3661-0462-4f29).
#
# Behavioral pattern: every test follows Given / When / Then.
# Tests invoke calibration-report.sh as a subprocess with --fixture flag.
#
# Usage: bash tests/scripts/test-calibration-query.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CALIBRATION_SCRIPT="$REPO_ROOT/plugins/dso/scripts/calibration-report.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/a34c-sprint-bugs"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-calibration-query.sh ==="

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: query --help exits 0 and prints sub-handler list
#
# Given: calibration-report.sh with query subcommand registered
# When:  we run 'calibration-report.sh query --help'
# Then:  exit code is 0 and output contains sub-handler names
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 1: query --help exits 0 and prints sub-handler names"
test_query_help() {
    _snapshot_fail

    local output exit_code=0
    output=$("$CALIBRATION_SCRIPT" query --help 2>&1) || exit_code=$?

    assert_eq "query --help exits 0" "0" "$exit_code"
    assert_contains "query --help mentions intents-with-low-kill-rate" \
        "intents-with-low-kill-rate" "$output"
    assert_contains "query --help mentions intents-without-coverage" \
        "intents-without-coverage" "$output"
    assert_contains "query --help mentions bugs-by-channel-and-type" \
        "bugs-by-channel-and-type" "$output"
    assert_contains "query --help mentions rule-effectiveness" \
        "rule-effectiveness" "$output"

    assert_pass_if_clean "test_query_help"
}
test_query_help

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: query intents-with-low-kill-rate --fixture returns valid JSON array
#
# Given: fixture dir with bugs.json containing 6 bugs grouped by title prefix
# When:  we run 'calibration-report.sh query intents-with-low-kill-rate --fixture <dir>'
# Then:  output is a JSON array with objects containing intent_id, kill_rate, bug_count
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 2: query intents-with-low-kill-rate --fixture returns valid JSON array"
test_query_intents_with_low_kill_rate() {
    _snapshot_fail

    local output exit_code=0
    output=$("$CALIBRATION_SCRIPT" query intents-with-low-kill-rate \
        --fixture "$FIXTURE_DIR" 2>&1) || exit_code=$?

    assert_eq "intents-with-low-kill-rate exits 0" "0" "$exit_code"

    # Output must be a JSON array
    assert_contains "output starts with [" "[" "${output:0:1}"

    # Validate it parses as JSON and has expected fields
    local parsed_ok
    parsed_ok=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    assert isinstance(data, list), 'not a list'
    for item in data:
        assert 'intent_id' in item, f'missing intent_id in {item}'
        assert 'kill_rate' in item, f'missing kill_rate in {item}'
        assert 'bug_count' in item, f'missing bug_count in {item}'
    print('ok')
except Exception as e:
    print(f'error: {e}')
" "$output" 2>&1)
    assert_eq "intents-with-low-kill-rate output is valid JSON array with required fields" \
        "ok" "$parsed_ok"

    # Fixture has 6 bugs all with kill_rate=0 (below default 50% threshold)
    # so all unique titles should appear; verify at least 1 entry
    local entry_count
    entry_count=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print(len(data))
except Exception:
    print(0)
" "$output" 2>&1)
    assert_ne "intents-with-low-kill-rate returns at least 1 intent" "0" "$entry_count"

    assert_pass_if_clean "test_query_intents_with_low_kill_rate"
}
test_query_intents_with_low_kill_rate

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: query intents-without-coverage --fixture returns valid JSON array
#
# Given: fixture dir with bugs.json (no test_run_id tags in fixture)
# When:  we run 'calibration-report.sh query intents-without-coverage --fixture <dir>'
# Then:  output is a JSON array where all intents appear (none have test_run_id tags)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 3: query intents-without-coverage --fixture returns valid JSON array"
test_query_intents_without_coverage() {
    _snapshot_fail

    local output exit_code=0
    output=$("$CALIBRATION_SCRIPT" query intents-without-coverage \
        --fixture "$FIXTURE_DIR" 2>&1) || exit_code=$?

    assert_eq "intents-without-coverage exits 0" "0" "$exit_code"

    # Output must be a JSON array
    assert_contains "output starts with [" "[" "${output:0:1}"

    # Validate it parses as JSON and has expected fields
    local parsed_ok
    parsed_ok=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    assert isinstance(data, list), 'not a list'
    for item in data:
        assert 'intent_id' in item, f'missing intent_id in {item}'
        assert 'bug_count' in item, f'missing bug_count in {item}'
    print('ok')
except Exception as e:
    print(f'error: {e}')
" "$output" 2>&1)
    assert_eq "intents-without-coverage output is valid JSON array with required fields" \
        "ok" "$parsed_ok"

    # Fixture bugs have no test_run_id tags, so all intents should appear
    local entry_count
    entry_count=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print(len(data))
except Exception:
    print(0)
" "$output" 2>&1)
    assert_ne "intents-without-coverage returns at least 1 intent" "0" "$entry_count"

    assert_pass_if_clean "test_query_intents_without_coverage"
}
test_query_intents_without_coverage

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: query bugs-by-channel-and-type --fixture returns valid JSON array
#
# Given: fixture bugs.json with detected_by:tests (3 bugs) and detected_by:review-llm (2)
#        and detected_by:user-report (1)
# When:  we run 'calibration-report.sh query bugs-by-channel-and-type --fixture <dir>'
# Then:  output is JSON array with channel/type/count objects matching fixture counts
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 4: query bugs-by-channel-and-type --fixture returns valid JSON array"
test_query_bugs_by_channel_and_type() {
    _snapshot_fail

    local output exit_code=0
    output=$("$CALIBRATION_SCRIPT" query bugs-by-channel-and-type \
        --fixture "$FIXTURE_DIR" 2>&1) || exit_code=$?

    assert_eq "bugs-by-channel-and-type exits 0" "0" "$exit_code"

    # Output must be a JSON array
    assert_contains "output starts with [" "[" "${output:0:1}"

    # Validate structure and known channel counts from fixture
    local check_result
    check_result=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    assert isinstance(data, list), 'not a list'
    for item in data:
        assert 'channel' in item, f'missing channel in {item}'
        assert 'type' in item, f'missing type in {item}'
        assert 'count' in item, f'missing count in {item}'

    # Build channel→count from result
    by_channel = {item['channel']: item['count'] for item in data}

    # Fixture: 3 bugs with detected_by:tests
    assert by_channel.get('tests') == 3, f'expected tests=3, got {by_channel.get(\"tests\")}'
    # Fixture: 2 bugs with detected_by:review-llm
    assert by_channel.get('review-llm') == 2, f'expected review-llm=2, got {by_channel.get(\"review-llm\")}'
    # Fixture: 1 bug with detected_by:user-report
    assert by_channel.get('user-report') == 1, f'expected user-report=1, got {by_channel.get(\"user-report\")}'
    print('ok')
except Exception as e:
    print(f'error: {e}')
" "$output" 2>&1)
    assert_eq "bugs-by-channel-and-type output matches fixture channel counts" \
        "ok" "$check_result"

    assert_pass_if_clean "test_query_bugs_by_channel_and_type"
}
test_query_bugs_by_channel_and_type

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: query rule-effectiveness --fixture returns valid JSON object
#
# Given: fixture bugs.json (no bugs tagged with rule:*)
# When:  we run 'calibration-report.sh query rule-effectiveness no-raw-commit --fixture <dir>'
# Then:  output is JSON object with rule_id, bug_count, kill_rate, effectiveness_score
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 5: query rule-effectiveness --fixture returns valid JSON object"
test_query_rule_effectiveness() {
    _snapshot_fail

    local output exit_code=0
    output=$("$CALIBRATION_SCRIPT" query rule-effectiveness no-raw-commit \
        --fixture "$FIXTURE_DIR" 2>&1) || exit_code=$?

    assert_eq "rule-effectiveness exits 0" "0" "$exit_code"

    # Output must be a JSON object (starts with {)
    assert_contains "output starts with {" "{" "${output:0:1}"

    # Validate structure
    local check_result
    check_result=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    assert isinstance(data, dict), 'not a dict'
    assert 'rule_id' in data, 'missing rule_id'
    assert 'bug_count' in data, 'missing bug_count'
    assert 'kill_rate' in data, 'missing kill_rate'
    assert 'effectiveness_score' in data, 'missing effectiveness_score'
    assert data['rule_id'] == 'no-raw-commit', f'expected rule_id=no-raw-commit, got {data[\"rule_id\"]}'
    assert data['kill_rate'] == 0, f'expected kill_rate=0, got {data[\"kill_rate\"]}'
    assert data['effectiveness_score'] == 0, f'expected effectiveness_score=0, got {data[\"effectiveness_score\"]}'
    # bug_count=0 because fixture bugs have no rule:no-raw-commit tag
    assert data['bug_count'] == 0, f'expected bug_count=0 (no rule tags in fixture), got {data[\"bug_count\"]}'
    print('ok')
except Exception as e:
    print(f'error: {e}')
" "$output" 2>&1)
    assert_eq "rule-effectiveness output is valid JSON object with required fields" \
        "ok" "$check_result"

    assert_pass_if_clean "test_query_rule_effectiveness"
}
test_query_rule_effectiveness

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: query unknown sub exits non-zero
#
# Given: calibration-report.sh query subcommand
# When:  we run 'calibration-report.sh query nonexistent-sub'
# Then:  exit code is non-zero and stderr contains error message
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 6: query unknown sub exits non-zero"
test_query_unknown_sub() {
    _snapshot_fail

    local output exit_code=0
    output=$("$CALIBRATION_SCRIPT" query nonexistent-sub 2>&1) || exit_code=$?

    assert_ne "query unknown sub exits non-zero" "0" "$exit_code"
    assert_contains "error message mentions unknown sub-handler" \
        "unknown sub-handler" "$output"

    assert_pass_if_clean "test_query_unknown_sub"
}
test_query_unknown_sub

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
print_summary
