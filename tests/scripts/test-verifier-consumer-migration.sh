#!/usr/bin/env bash
# tests/scripts/test-verifier-consumer-migration.sh
# Integration tests verifying consumer migration to schema_version=2 P1 typed-enum field.
#
# Tests use check-verifier-verdict.sh and render-closure-narrative.sh as executable
# consumer proxies (sprint/end-session SKILL.md are LLM instructions, not runnable bash).
#
# Tests cover:
#   1. schema_version=2 + P1=PASS → consumer reads PASS correctly (exit 0)
#   2. schema_version=2 + P1=FAIL → consumer halts (exit 1)
#   3. schema_version=1 + overall_verdict=PASS (no P1) → backward-compat reads overall_verdict (exit 0, warning)
#   4. schema_version=2 + P1=INCONCLUSIVE → consumer reads INCONCLUSIVE correctly (exit 1)
#   5. check-verifier-verdict.sh: P1=PASS→0, P1=FAIL/BLOCKED/INCONCLUSIVE→1
#   6. render-closure-narrative.sh: schema_version=2 JSON → "P1=PASS criteria_met=N/N" format
#
# Usage: bash tests/scripts/test-verifier-consumer-migration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# testing-mode: GREEN
# Consumer migrated to schema_version=2 (S1b)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_VERDICT="$REPO_ROOT/plugins/dso/scripts/check-verifier-verdict.sh"
RENDER_NARRATIVE="$REPO_ROOT/plugins/dso/scripts/render-closure-narrative.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-verifier-consumer-migration.sh ==="

# ── Prerequisite checks ───────────────────────────────────────────────────────

if [[ ! -x "$CHECK_VERDICT" ]]; then
    echo "FATAL: $CHECK_VERDICT not found or not executable" >&2
    exit 2
fi

if [[ ! -x "$RENDER_NARRATIVE" ]]; then
    echo "FATAL: $RENDER_NARRATIVE not found or not executable" >&2
    exit 2
fi

# ── test_schema_v2_p1_pass_consumer_reads_pass ────────────────────────────────
# Given schema_version=2 JSON with P1=PASS → consumer correctly reads PASS (exit 0).
# This validates that the sprint/end-session consumers (proxied via check-verifier-verdict.sh)
# correctly parse the P1 field from schema_version=2 payloads.
test_schema_v2_p1_pass_consumer_reads_pass() {
    _snapshot_fail
    local rc=0
    cat <<'EOF' | bash "$CHECK_VERDICT" 2>/dev/null || rc=$?
{
  "schema_version": 2,
  "P1": "PASS",
  "overall_verdict": "PASS",
  "narrative": "P1=PASS criteria_met=3/3 blocked_by=0",
  "criteria_results": [
    {"criterion": "DD1: All callers audited", "verdict": "PASS"},
    {"criterion": "DD2: Integration tests written", "verdict": "PASS"},
    {"criterion": "DD3: Backward-compat shim documented", "verdict": "PASS"}
  ]
}
EOF
    assert_eq "test_schema_v2_p1_pass_consumer_reads_pass: schema_version=2 P1=PASS → exit 0" "0" "$rc"
    assert_pass_if_clean "test_schema_v2_p1_pass_consumer_reads_pass"
}

# ── test_schema_v2_p1_fail_consumer_halts ─────────────────────────────────────
# Given schema_version=2 JSON with P1=FAIL → consumer halts (exit 1).
# This validates that the sprint Phase F/G gating logic correctly blocks closure on FAIL.
test_schema_v2_p1_fail_consumer_halts() {
    _snapshot_fail
    local rc=0
    cat <<'EOF' | bash "$CHECK_VERDICT" 2>/dev/null || rc=$?
{
  "schema_version": 2,
  "P1": "FAIL",
  "overall_verdict": "FAIL",
  "narrative": "P1=FAIL criteria_met=1/3 blocked_by=2",
  "criteria_results": [
    {"criterion": "DD1: All callers audited", "verdict": "PASS"},
    {"criterion": "DD2: Integration tests written", "verdict": "FAIL"},
    {"criterion": "DD3: Backward-compat shim documented", "verdict": "FAIL"}
  ]
}
EOF
    assert_eq "test_schema_v2_p1_fail_consumer_halts: schema_version=2 P1=FAIL → exit 1" "1" "$rc"
    assert_pass_if_clean "test_schema_v2_p1_fail_consumer_halts"
}

# ── test_schema_v1_backward_compat_reads_overall_verdict ──────────────────────
# Given schema_version=1 JSON (no P1 field, overall_verdict=PASS) →
# backward-compat shim reads overall_verdict, emits a deprecation warning, exits 0.
# This validates the S1b backward-compat requirement for legacy v1 payloads.
test_schema_v1_backward_compat_reads_overall_verdict() {
    _snapshot_fail
    local rc=0
    local stderr_out
    stderr_out=$(cat <<'EOF' | bash "$CHECK_VERDICT" 2>&1 >/dev/null || true
{
  "schema_version": 1,
  "overall_verdict": "PASS"
}
EOF
)
    cat <<'EOF' | bash "$CHECK_VERDICT" 2>/dev/null || rc=$?
{
  "schema_version": 1,
  "overall_verdict": "PASS"
}
EOF
    assert_eq "test_schema_v1_backward_compat_reads_overall_verdict: schema_version=1 overall_verdict=PASS → exit 0" "0" "$rc"
    assert_contains "test_schema_v1_backward_compat_reads_overall_verdict: stderr contains deprecation warning" "WARNING" "$stderr_out"
    assert_pass_if_clean "test_schema_v1_backward_compat_reads_overall_verdict"
}

# ── test_schema_v2_p1_inconclusive_consumer_reads_inconclusive ────────────────
# Given schema_version=2 JSON with P1=INCONCLUSIVE → consumer reads INCONCLUSIVE (exit 1).
# This validates that INCONCLUSIVE correctly blocks closure (sprint Phase C re-entry).
test_schema_v2_p1_inconclusive_consumer_reads_inconclusive() {
    _snapshot_fail
    local rc=0
    cat <<'EOF' | bash "$CHECK_VERDICT" 2>/dev/null || rc=$?
{
  "schema_version": 2,
  "P1": "INCONCLUSIVE",
  "overall_verdict": "SKIPPED",
  "narrative": "P1=INCONCLUSIVE criteria_met=0/3 blocked_by=0",
  "criteria_results": [
    {"criterion": "DD1: All callers audited", "verdict": "PENDING"},
    {"criterion": "DD2: Integration tests written", "verdict": "PENDING"},
    {"criterion": "DD3: Backward-compat shim documented", "verdict": "PENDING"}
  ]
}
EOF
    assert_eq "test_schema_v2_p1_inconclusive_consumer_reads_inconclusive: schema_version=2 P1=INCONCLUSIVE → exit 1" "1" "$rc"
    assert_pass_if_clean "test_schema_v2_p1_inconclusive_consumer_reads_inconclusive"
}

# ── test_check_verifier_verdict_exit_codes ────────────────────────────────────
# Validate the full exit-code contract: P1=PASS→0, P1=FAIL→1, P1=BLOCKED→1, P1=INCONCLUSIVE→1.
test_check_verifier_verdict_p1_pass_exits_0() {
    _snapshot_fail
    local rc=0
    echo '{"schema_version": 2, "P1": "PASS"}' | bash "$CHECK_VERDICT" 2>/dev/null || rc=$?
    assert_eq "test_check_verifier_verdict_p1_pass_exits_0: P1=PASS → exit 0" "0" "$rc"
    assert_pass_if_clean "test_check_verifier_verdict_p1_pass_exits_0"
}

test_check_verifier_verdict_p1_fail_exits_1() {
    _snapshot_fail
    local rc=0
    echo '{"schema_version": 2, "P1": "FAIL"}' | bash "$CHECK_VERDICT" 2>/dev/null || rc=$?
    assert_eq "test_check_verifier_verdict_p1_fail_exits_1: P1=FAIL → exit 1" "1" "$rc"
    assert_pass_if_clean "test_check_verifier_verdict_p1_fail_exits_1"
}

test_check_verifier_verdict_p1_blocked_exits_1() {
    _snapshot_fail
    local rc=0
    echo '{"schema_version": 2, "P1": "BLOCKED"}' | bash "$CHECK_VERDICT" 2>/dev/null || rc=$?
    assert_eq "test_check_verifier_verdict_p1_blocked_exits_1: P1=BLOCKED → exit 1" "1" "$rc"
    assert_pass_if_clean "test_check_verifier_verdict_p1_blocked_exits_1"
}

test_check_verifier_verdict_p1_inconclusive_exits_1() {
    _snapshot_fail
    local rc=0
    echo '{"schema_version": 2, "P1": "INCONCLUSIVE"}' | bash "$CHECK_VERDICT" 2>/dev/null || rc=$?
    assert_eq "test_check_verifier_verdict_p1_inconclusive_exits_1: P1=INCONCLUSIVE → exit 1" "1" "$rc"
    assert_pass_if_clean "test_check_verifier_verdict_p1_inconclusive_exits_1"
}

# ── test_render_closure_narrative_schema_v2_format ────────────────────────────
# render-closure-narrative.sh with schema_version=2 JSON → produces "P1=PASS criteria_met=N/N" format.
# This validates that the narrative consumer (used at sprint Phase G Step 2) correctly
# formats the closure narrative from typed fields.
test_render_closure_narrative_schema_v2_format() {
    _snapshot_fail
    local output
    output=$(cat <<'EOF' | bash "$RENDER_NARRATIVE" 2>/dev/null
{
  "schema_version": 2,
  "P1": "PASS",
  "overall_verdict": "PASS",
  "criteria_results": [
    {"criterion": "DD1", "verdict": "PASS"},
    {"criterion": "DD2", "verdict": "PASS"},
    {"criterion": "DD3", "verdict": "PASS"}
  ]
}
EOF
)
    assert_eq "test_render_closure_narrative_schema_v2_format: narrative has P1=PASS prefix" \
        "P1=PASS criteria_met=3/3 blocked_by=0" "$output"
    assert_pass_if_clean "test_render_closure_narrative_schema_v2_format"
}

# ── test_render_closure_narrative_schema_v2_partial_pass ──────────────────────
# render-closure-narrative.sh with mixed criteria_results → counts correctly.
test_render_closure_narrative_schema_v2_partial_pass() {
    _snapshot_fail
    local output
    output=$(cat <<'EOF' | bash "$RENDER_NARRATIVE" 2>/dev/null
{
  "schema_version": 2,
  "P1": "FAIL",
  "overall_verdict": "FAIL",
  "criteria_results": [
    {"criterion": "DD1", "verdict": "PASS"},
    {"criterion": "DD2", "verdict": "FAIL"},
    {"criterion": "DD3", "verdict": "BLOCKED"}
  ]
}
EOF
)
    assert_eq "test_render_closure_narrative_schema_v2_partial_pass: narrative counts FAIL+BLOCKED as blocked_by" \
        "P1=FAIL criteria_met=1/3 blocked_by=2" "$output"
    assert_pass_if_clean "test_render_closure_narrative_schema_v2_partial_pass"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_schema_v2_p1_pass_consumer_reads_pass
test_schema_v2_p1_fail_consumer_halts
test_schema_v1_backward_compat_reads_overall_verdict
test_schema_v2_p1_inconclusive_consumer_reads_inconclusive
test_check_verifier_verdict_p1_pass_exits_0
test_check_verifier_verdict_p1_fail_exits_1
test_check_verifier_verdict_p1_blocked_exits_1
test_check_verifier_verdict_p1_inconclusive_exits_1
test_render_closure_narrative_schema_v2_format
test_render_closure_narrative_schema_v2_partial_pass

print_summary
