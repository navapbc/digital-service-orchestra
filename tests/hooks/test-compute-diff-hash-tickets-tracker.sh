#!/usr/bin/env bash
# tests/hooks/test-compute-diff-hash-tickets-tracker.sh
# TDD RED tests for .tickets-tracker/ path migration.
#
# These tests assert the POST-MIGRATION state:
#   - review-gate-allowlist.conf should contain .tickets-tracker/** (not .tickets/**)
#   - compute-diff-hash.sh fallback pathspecs should use :!.tickets-tracker/** (not :!.tickets/**)
#
# These tests are expected to FAIL (RED) against the current pre-migration code.
# They will become GREEN after dso-1cje updates the infrastructure path references.
#
# Tests:
#   test_allowlist_uses_tickets_tracker_path
#   test_compute_diff_hash_fallback_uses_tickets_tracker_path

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

ALLOWLIST="$DSO_PLUGIN_DIR/hooks/lib/review-gate-allowlist.conf"
COMPUTE_DIFF_HASH="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"

# ============================================================
# test_allowlist_uses_tickets_tracker_path
# review-gate-allowlist.conf must contain .tickets-tracker/**
# (post-migration: old .tickets/** entry replaced with .tickets-tracker/**)
# ============================================================
test_allowlist_uses_tickets_tracker_path() {
    local match
    match=$(grep -c '\.tickets-tracker/\*\*' "$ALLOWLIST" 2>/dev/null || true)
    match="${match:-0}"
    assert_eq "test_allowlist_uses_tickets_tracker_path" "true" \
        "$( [[ "${match}" -ge 1 ]] && echo true || echo false )"
}

# ============================================================
# test_compute_diff_hash_fallback_uses_tickets_tracker_path
# The fallback pathspecs in compute-diff-hash.sh must contain
# ':!.tickets-tracker/**' (not the old ':!.tickets/**')
# ============================================================
test_compute_diff_hash_fallback_uses_tickets_tracker_path() {
    local match
    match=$(grep -c "':!\.tickets-tracker/\*\*'" "$COMPUTE_DIFF_HASH" 2>/dev/null || true)
    match="${match:-0}"
    assert_eq "test_compute_diff_hash_fallback_uses_tickets_tracker_path" "true" \
        "$( [[ "${match}" -ge 1 ]] && echo true || echo false )"
}

# Run all tests
test_allowlist_uses_tickets_tracker_path
test_compute_diff_hash_fallback_uses_tickets_tracker_path

print_summary
