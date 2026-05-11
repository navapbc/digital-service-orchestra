#!/usr/bin/env bash
# tests/scripts/test-check-unacked-degradations.sh
# Behavioral tests for check-unacked-degradations.sh — script that detects
# degradation decisions recorded in *-PRECONDITIONS.json that have not been
# acknowledged by a corresponding *-ACK.json file.
#
# Tests:
#  1. test_no_events                — empty story dir → exit 0
#  2. test_no_degradation_entries   — PRECONDITIONS file with no degradation field → exit 0
#  3. test_all_acked                — degradation:true, all decision_ids ACKed → exit 0
#  4. test_one_unacked              — degradation:true, one unacked id → exit 1, id in stdout
#  5. test_partial_ack              — two ids, one ACKed: exit 1, unacked in stdout, acked not in stdout
#  6. test_fail_open                — malformed JSON PRECONDITIONS → exit 0 (fail-open)
#  7. test_multiple_unacked         — two unacked ids → exit 1, both ids in stdout
#  8. test_no_preconditions_file    — dir has only STATUS.json, no PRECONDITIONS → exit 0
#
# Usage: bash tests/scripts/test-check-unacked-degradations.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-unacked-degradations.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-unacked-degradations.sh ==="

FIXTURES_DIR="$PLUGIN_ROOT/tests/fixtures/degradations"

# ── test_no_events ────────────────────────────────────────────────────────────
# An empty story directory (no files at all) should exit 0 — pre-manifest
# exemption: nothing to check.
test_no_events() {
    _snapshot_fail
    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$FIXTURES_DIR" bash "$SCRIPT" "no-events" 2>/dev/null || _exit=$?
    assert_eq "test_no_events: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_no_events"
}

# ── test_no_degradation_entries ───────────────────────────────────────────────
# A PRECONDITIONS file whose data object has no degradation field should exit 0.
test_no_degradation_entries() {
    _snapshot_fail
    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$FIXTURES_DIR" bash "$SCRIPT" "no-degradation" 2>/dev/null || _exit=$?
    assert_eq "test_no_degradation_entries: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_no_degradation_entries"
}

# ── test_all_acked ────────────────────────────────────────────────────────────
# When all decision_ids from a degradation PRECONDITIONS are covered by an ACK
# file, the script should exit 0.
test_all_acked() {
    _snapshot_fail
    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$FIXTURES_DIR" bash "$SCRIPT" "all-acked" 2>/dev/null || _exit=$?
    assert_eq "test_all_acked: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_all_acked"
}

# ── test_one_unacked ──────────────────────────────────────────────────────────
# When a degradation decision_id has no ACK, the script must exit 1 and print
# the unacked id to stdout.
test_one_unacked() {
    _snapshot_fail
    local _out _exit=0
    _out=$(DSO_TICKETS_TRACKER_DIR="$FIXTURES_DIR" bash "$SCRIPT" "one-unacked" 2>/dev/null) || _exit=$?
    assert_eq "test_one_unacked: exit 1" "1" "$_exit"
    assert_contains "test_one_unacked: unacked id in stdout" "sess:def456" "$_out"
    assert_pass_if_clean "test_one_unacked"
}

# ── test_partial_ack ──────────────────────────────────────────────────────────
# When only some decision_ids are ACKed, the script must exit 1, print the
# unacked id, and NOT print the acked id.
test_partial_ack() {
    _snapshot_fail
    local _out _exit=0
    _out=$(DSO_TICKETS_TRACKER_DIR="$FIXTURES_DIR" bash "$SCRIPT" "partial-ack" 2>/dev/null) || _exit=$?
    assert_eq "test_partial_ack: exit 1" "1" "$_exit"
    assert_contains "test_partial_ack: unacked id in stdout" "sess:jkl" "$_out"
    assert_not_contains "test_partial_ack: acked id not in stdout" "sess:ghi" "$_out"
    assert_pass_if_clean "test_partial_ack"
}

# ── test_fail_open ────────────────────────────────────────────────────────────
# A malformed JSON PRECONDITIONS file must not cause the script to fail — it
# should exit 0 (fail-open on parse error).
test_fail_open() {
    _snapshot_fail
    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$FIXTURES_DIR" bash "$SCRIPT" "fail-open" 2>/dev/null || _exit=$?
    assert_eq "test_fail_open: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_fail_open"
}

# ── test_multiple_unacked ─────────────────────────────────────────────────────
# When multiple decision_ids are unacked, the script must exit 1 and print each
# unacked id to stdout.
test_multiple_unacked() {
    _snapshot_fail
    local _out _exit=0
    _out=$(DSO_TICKETS_TRACKER_DIR="$FIXTURES_DIR" bash "$SCRIPT" "multiple-unacked" 2>/dev/null) || _exit=$?
    assert_eq "test_multiple_unacked: exit 1" "1" "$_exit"
    assert_contains "test_multiple_unacked: first unacked id in stdout" "sess:pqr" "$_out"
    assert_contains "test_multiple_unacked: second unacked id in stdout" "sess:stu" "$_out"
    assert_pass_if_clean "test_multiple_unacked"
}

# ── test_no_preconditions_file ────────────────────────────────────────────────
# A story directory that contains other event files (e.g. STATUS.json) but no
# *-PRECONDITIONS.json files must exit 0 (pre-manifest exemption).
test_no_preconditions_file() {
    _snapshot_fail
    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$FIXTURES_DIR" bash "$SCRIPT" "no-preconditions-file" 2>/dev/null || _exit=$?
    assert_eq "test_no_preconditions_file: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_no_preconditions_file"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_no_events
test_no_degradation_entries
test_all_acked
test_one_unacked
test_partial_ack
test_fail_open
test_multiple_unacked
test_no_preconditions_file

print_summary
