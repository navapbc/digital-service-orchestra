#!/usr/bin/env bash
# Tests for check-dd-lexicon.sh
# Verifies that the script correctly detects vague and compound done definitions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"

SUT="$REPO_ROOT/plugins/dso/scripts/check-dd-lexicon.sh"

# ── Tests ─────────────────────────────────────────────────────────────────────

# test_clean_dd_exits_0: clean DD with no vague or compound terms → exit 0
test_clean_dd_exits_0() {
    _snapshot_fail
    local dd="The system stores user preferences"
    local output exit_code=0
    output=$(echo "$dd" | bash "$SUT") || exit_code=$?
    assert_eq "test_clean_dd_exits_0: exit 0" "0" "$exit_code"
    assert_pass_if_clean "test_clean_dd_exits_0"
}

# test_compound_AND_uppercase_exits_1: DD with uppercase ' AND ' → exit 1 (compound)
test_compound_AND_uppercase_exits_1() {
    _snapshot_fail
    local dd="The system stores AND retrieves user preferences"
    local output exit_code=0
    output=$(echo "$dd" | bash "$SUT") || exit_code=$?
    assert_eq "test_compound_AND_uppercase_exits_1: exit 1" "1" "$exit_code"
    assert_contains "test_compound_AND_uppercase_exits_1: type=compound" '"type"' "$output"
    assert_contains "test_compound_AND_uppercase_exits_1: matched_text present" '"matched_text"' "$output"
    assert_pass_if_clean "test_compound_AND_uppercase_exits_1"
}

# test_vague_properly_exits_1: DD with 'properly' → exit 1 (vague)
test_vague_properly_exits_1() {
    _snapshot_fail
    local dd="The system properly handles errors"
    local output exit_code=0
    output=$(echo "$dd" | bash "$SUT") || exit_code=$?
    assert_eq "test_vague_properly_exits_1: exit 1" "1" "$exit_code"
    assert_contains "test_vague_properly_exits_1: type=vague" '"type"' "$output"
    assert_contains "test_vague_properly_exits_1: matched_text present" '"matched_text"' "$output"
    assert_pass_if_clean "test_vague_properly_exits_1"
}

# test_compound_and_validates_and_formats_exits_1: lowercase ' and ' between verb clauses → exit 1 (compound)
test_compound_and_validates_and_formats_exits_1() {
    _snapshot_fail
    local dd="The system validates AND formats input"
    local output exit_code=0
    output=$(echo "$dd" | bash "$SUT") || exit_code=$?
    assert_eq "test_compound_and_validates_and_formats_exits_1: exit 1" "1" "$exit_code"
    assert_contains "test_compound_and_validates_and_formats_exits_1: type=compound" '"type"' "$output"
    assert_contains "test_compound_and_validates_and_formats_exits_1: matched_text present" '"matched_text"' "$output"
    assert_pass_if_clean "test_compound_and_validates_and_formats_exits_1"
}

# test_technical_dd_exits_0: technical DD referencing script exit codes → exit 0 (clean)
test_technical_dd_exits_0() {
    _snapshot_fail
    local dd="check-story-handoff.sh exits 0 when P1=PASS"
    local output exit_code=0
    output=$(echo "$dd" | bash "$SUT") || exit_code=$?
    assert_eq "test_technical_dd_exits_0: exit 0" "0" "$exit_code"
    assert_pass_if_clean "test_technical_dd_exits_0"
}

# test_vague_should_exits_1: DD with 'should' → exit 1 (vague)
test_vague_should_exits_1() {
    _snapshot_fail
    local dd="The system should handle all edge cases"
    local output exit_code=0
    output=$(echo "$dd" | bash "$SUT") || exit_code=$?
    assert_eq "test_vague_should_exits_1: exit 1" "1" "$exit_code"
    assert_contains "test_vague_should_exits_1: type=vague" '"type"' "$output"
    assert_contains "test_vague_should_exits_1: matched_text present" '"matched_text"' "$output"
    assert_pass_if_clean "test_vague_should_exits_1"
}

# test_vague_correctly_exits_1: DD with 'correctly' → exit 1 (vague)
test_vague_correctly_exits_1() {
    _snapshot_fail
    local dd="The system correctly processes all requests"
    local output exit_code=0
    output=$(echo "$dd" | bash "$SUT") || exit_code=$?
    assert_eq "test_vague_correctly_exits_1: exit 1" "1" "$exit_code"
    assert_contains "test_vague_correctly_exits_1: type=vague" '"type"' "$output"
    assert_contains "test_vague_correctly_exits_1: matched_text present" '"matched_text"' "$output"
    assert_pass_if_clean "test_vague_correctly_exits_1"
}

# test_exit_1_outputs_json_fields: exit 1 must output JSON with type and matched_text
test_exit_1_outputs_json_fields() {
    _snapshot_fail
    local dd="The system properly stores AND retrieves data"
    local output exit_code=0
    output=$(echo "$dd" | bash "$SUT") || exit_code=$?
    assert_eq "test_exit_1_outputs_json_fields: exit 1" "1" "$exit_code"
    assert_contains "test_exit_1_outputs_json_fields: type field" '"type"' "$output"
    assert_contains "test_exit_1_outputs_json_fields: matched_text field" '"matched_text"' "$output"
    assert_pass_if_clean "test_exit_1_outputs_json_fields"
}

# ── Runner ────────────────────────────────────────────────────────────────────

test_clean_dd_exits_0
test_compound_AND_uppercase_exits_1
test_vague_properly_exits_1
test_compound_and_validates_and_formats_exits_1
test_technical_dd_exits_0
test_vague_should_exits_1
test_vague_correctly_exits_1
test_exit_1_outputs_json_fields

print_summary
