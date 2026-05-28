#!/usr/bin/env bash
# tests/scripts/test-second-source-verification.sh
# TDD tests for plugins/dso/scripts/check-second-source-report.sh
#
# Tests cover: verifier_used=true exits 0, verifier_used=false exits 1,
# renderer_used=true exits 0, renderer_used=false exits 1,
# gate_enforced=true exits 0, all mechanisms confirmed for multiple stories exits 0.
#
# Usage: bash tests/scripts/test-second-source-verification.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# testing-mode: RED

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$PLUGIN_ROOT/plugins/dso/scripts/check-second-source-report.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-second-source-verification.sh ==="

# Helper: write JSON to a temp file and run the checker against it.
# Usage: run_checker <json-string>
# Prints exit code of the checker to stdout.
run_checker() {
    local json="$1"
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/second-source-report.XXXXXX")
    printf '%s\n' "$json" > "$tmp"
    local rc=0
    bash "$CHECKER" "$tmp" >/dev/null 2>&1 || rc=$?
    rm -f "$tmp"
    printf '%s' "$rc"
}

# ── test_verifier_used_true_exits_0 ───────────────────────────────────────────
# JSON with verifier_used=true (and renderer_used, gate_enforced also true)
# must exit 0 — all mechanisms confirmed.
test_verifier_used_true_exits_0() {
    _snapshot_fail
    local json='{"story_id":"s001","verifier_used":true,"renderer_used":true,"gate_enforced":true,"verdict":"PASS"}'
    local rc
    rc=$(run_checker "$json")
    assert_eq "test_verifier_used_true_exits_0: verifier_used=true exits 0" "0" "$rc"
    assert_pass_if_clean "test_verifier_used_true_exits_0"
}

# ── test_verifier_used_false_exits_1 ──────────────────────────────────────────
# JSON with verifier_used=false (legacy closure without P1) must exit 1 with finding.
test_verifier_used_false_exits_1() {
    _snapshot_fail
    local json='{"story_id":"s002","verifier_used":false,"renderer_used":true,"gate_enforced":true,"verdict":"FAIL"}'
    local rc
    rc=$(run_checker "$json")
    assert_eq "test_verifier_used_false_exits_1: verifier_used=false exits 1" "1" "$rc"
    assert_pass_if_clean "test_verifier_used_false_exits_1"
}

# ── test_renderer_used_true_exits_0 ───────────────────────────────────────────
# JSON with renderer_used=true (narrative sourced from render-closure-narrative.sh)
# must exit 0 — narrative provenance confirmed.
test_renderer_used_true_exits_0() {
    _snapshot_fail
    local json='{"story_id":"s003","verifier_used":true,"renderer_used":true,"gate_enforced":true,"verdict":"PASS"}'
    local rc
    rc=$(run_checker "$json")
    assert_eq "test_renderer_used_true_exits_0: renderer_used=true exits 0" "0" "$rc"
    assert_pass_if_clean "test_renderer_used_true_exits_0"
}

# ── test_renderer_used_false_exits_1 ──────────────────────────────────────────
# JSON with renderer_used=false (LLM-generated narrative) must exit 1 with finding.
test_renderer_used_false_exits_1() {
    _snapshot_fail
    local json='{"story_id":"s004","verifier_used":true,"renderer_used":false,"gate_enforced":true,"verdict":"FAIL"}'
    local rc
    rc=$(run_checker "$json")
    assert_eq "test_renderer_used_false_exits_1: renderer_used=false exits 1" "1" "$rc"
    assert_pass_if_clean "test_renderer_used_false_exits_1"
}

# ── test_gate_enforced_true_exits_0 ───────────────────────────────────────────
# JSON with gate_enforced=true (handoff gate used between stories) must exit 0.
test_gate_enforced_true_exits_0() {
    _snapshot_fail
    local json='{"story_id":"s005","verifier_used":true,"renderer_used":true,"gate_enforced":true,"verdict":"PASS"}'
    local rc
    rc=$(run_checker "$json")
    assert_eq "test_gate_enforced_true_exits_0: gate_enforced=true exits 0" "0" "$rc"
    assert_pass_if_clean "test_gate_enforced_true_exits_0"
}

# ── test_all_mechanisms_confirmed_exits_0 ─────────────────────────────────────
# Complete report with all mechanisms confirmed for multiple stories must exit 0.
# The checker is passed a JSON array (or a newline-delimited multi-story report).
test_all_mechanisms_confirmed_exits_0() {
    _snapshot_fail
    local json
    json=$(cat <<'EOF'
{
  "stories": [
    {"story_id":"s010","verifier_used":true,"renderer_used":true,"gate_enforced":true,"verdict":"PASS"},
    {"story_id":"s011","verifier_used":true,"renderer_used":true,"gate_enforced":true,"verdict":"PASS"},
    {"story_id":"s012","verifier_used":true,"renderer_used":true,"gate_enforced":true,"verdict":"PASS"}
  ],
  "summary_verdict": "PASS"
}
EOF
)
    local rc
    rc=$(run_checker "$json")
    assert_eq "test_all_mechanisms_confirmed_exits_0: all 3 stories confirmed exits 0" "0" "$rc"
    assert_pass_if_clean "test_all_mechanisms_confirmed_exits_0"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_verifier_used_true_exits_0
test_verifier_used_false_exits_1
test_renderer_used_true_exits_0
test_renderer_used_false_exits_1
test_gate_enforced_true_exits_0
test_all_mechanisms_confirmed_exits_0

print_summary
