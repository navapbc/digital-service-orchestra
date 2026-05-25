#!/usr/bin/env bash
# tests/unit/scripts/test_audit_dd2_orphan_count.sh
# Behavioral unit tests for audit_dd2_orphan_count.sh.
#
# dd1.json data contract (task-2 produces, task-3 consumes):
#   {phase, captured_at, label_only_orphan_count, bridge_fsck_command, git_sha, api_path_used}
#   This test creates fixture dd1.json with the expected schema to isolate task-3
#   from task-2 implementation timing.
#
# Tests:
#   1. test_missing_baseline_fails_closed — no dd1.json present → exit 3
#   2. test_sc8_pass_when_zero            — dd1.json before_count=197 + fsck stub returns 0
#                                           → dd2.json sc8_pass=true, exit 0
#   3. test_sc8_fail_when_nonzero         — dd1.json before_count=197 + fsck stub returns 5
#                                           → dd2.json sc8_pass=false, exit 4 (artifact still written)
#
# Usage: bash tests/unit/scripts/test_audit_dd2_orphan_count.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/dso_reconciler/audits/audit_dd2_orphan_count.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test_audit_dd2_orphan_count.sh ==="

# ── Helper: create a satisfied phase gate dir ─────────────────────────────────
_make_satisfied_gate_dir() {
    local phase="${1:-bootstrap-throttle}"
    local gate_dir
    gate_dir="$(mktemp -d)"
    printf '%s\n' "$phase" > "${gate_dir}/.reconciler-phase-gate"
    printf '{"operator":"test","timestamp":"2026-05-25T00:00:00Z","phase":"%s","comment":"test"}\n' \
        "$phase" > "${gate_dir}/.reconciler-phase-gate.ops"
    printf '%s' "$gate_dir"
}

# ── Helper: create a dd1.json fixture in an artifact dir ─────────────────────
_make_dd1_fixture() {
    local artifact_dir="$1"
    local phase="${2:-bootstrap-throttle}"
    local before_count="${3:-197}"
    mkdir -p "${artifact_dir}/${phase}"
    cat > "${artifact_dir}/${phase}/dd1.json" <<EOF
{
  "phase": "${phase}",
  "captured_at": "2026-05-25T00:00:00Z",
  "label_only_orphan_count": ${before_count},
  "bridge_fsck_command": "bridge-fsck --count-only",
  "git_sha": "abc123def456",
  "api_path_used": false
}
EOF
}

# ── Helper: create a stub fsck command in a temp bin dir ─────────────────────
_make_fsck_stub() {
    local exit_code="${1:-0}"
    local orphan_count="${2:-0}"
    local bin_dir
    bin_dir="$(mktemp -d)"
    local stub="${bin_dir}/stub-fsck"
    cat > "$stub" <<STUB_EOF
#!/usr/bin/env bash
printf 'label_only_orphans=%s\n' '${orphan_count}'
exit ${exit_code}
STUB_EOF
    chmod +x "$stub"
    printf '%s' "$stub"
}

# ── Test 1: missing dd1.json baseline → exit 3 (fail-closed) ─────────────────
test_missing_baseline_fails_closed() {
    _snapshot_fail

    local gate_dir artifact_dir stub_cmd
    gate_dir="$(_make_satisfied_gate_dir bootstrap-throttle)"
    artifact_dir="$(mktemp -d)"
    stub_cmd="$(_make_fsck_stub 0 0)"

    trap 'rm -rf "$gate_dir" "$artifact_dir" "$(dirname "$stub_cmd")"' RETURN

    # Intentionally do NOT create dd1.json in artifact_dir

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
    AUDIT_ARTIFACTS_DIR="$artifact_dir" \
    BRIDGE_FSCK_CMD="$stub_cmd" \
        bash "$SCRIPT" bootstrap-throttle >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 3 (fail-closed)" "3" "$rc"

    local artifact="${artifact_dir}/bootstrap-throttle/dd2.json"
    local exists="no"
    [[ -f "$artifact" ]] && exists="yes"
    assert_eq "no dd2.json written when baseline missing" "no" "$exists"

    assert_pass_if_clean "test_missing_baseline_fails_closed"
}

# ── Test 2: before_count=197 + fsck returns 0 → sc8_pass=true, exit 0 ────────
test_sc8_pass_when_zero() {
    _snapshot_fail

    local gate_dir artifact_dir stub_cmd
    gate_dir="$(_make_satisfied_gate_dir bootstrap-throttle)"
    artifact_dir="$(mktemp -d)"
    stub_cmd="$(_make_fsck_stub 0 0)"

    trap 'rm -rf "$gate_dir" "$artifact_dir" "$(dirname "$stub_cmd")"' RETURN

    _make_dd1_fixture "$artifact_dir" bootstrap-throttle 197

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
    AUDIT_ARTIFACTS_DIR="$artifact_dir" \
    BRIDGE_FSCK_CMD="$stub_cmd" \
        bash "$SCRIPT" bootstrap-throttle >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 0 when after_count==0" "0" "$rc"

    local artifact="${artifact_dir}/bootstrap-throttle/dd2.json"
    local exists="no"
    [[ -f "$artifact" ]] && exists="yes"
    assert_eq "dd2.json written" "yes" "$exists"

    if [[ -f "$artifact" ]]; then
        local before_val after_val sc8_val
        before_val="$(grep -oE '"before_count"[[:space:]]*:[[:space:]]*[0-9]+' "$artifact" \
            | grep -oE '[0-9]+$')" || before_val="parse-failed"
        after_val="$(grep -oE '"after_count"[[:space:]]*:[[:space:]]*[0-9]+' "$artifact" \
            | grep -oE '[0-9]+$')" || after_val="parse-failed"
        sc8_val="$(grep -oE '"sc8_pass"[[:space:]]*:[[:space:]]*(true|false)' "$artifact" \
            | grep -oE '(true|false)$')" || sc8_val="parse-failed"

        assert_eq "before_count is 197"  "197"  "$before_val"
        assert_eq "after_count is 0"     "0"    "$after_val"
        assert_eq "sc8_pass is true"     "true" "$sc8_val"
    fi

    assert_pass_if_clean "test_sc8_pass_when_zero"
}

# ── Test 3: before_count=197 + fsck returns 5 → sc8_pass=false, exit 4 ───────
test_sc8_fail_when_nonzero() {
    _snapshot_fail

    local gate_dir artifact_dir stub_cmd
    gate_dir="$(_make_satisfied_gate_dir bootstrap-throttle)"
    artifact_dir="$(mktemp -d)"
    stub_cmd="$(_make_fsck_stub 0 5)"

    trap 'rm -rf "$gate_dir" "$artifact_dir" "$(dirname "$stub_cmd")"' RETURN

    _make_dd1_fixture "$artifact_dir" bootstrap-throttle 197

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
    AUDIT_ARTIFACTS_DIR="$artifact_dir" \
    BRIDGE_FSCK_CMD="$stub_cmd" \
        bash "$SCRIPT" bootstrap-throttle >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 4 when after_count>0" "4" "$rc"

    # dd2.json must still be written even on SC-8 fail
    local artifact="${artifact_dir}/bootstrap-throttle/dd2.json"
    local exists="no"
    [[ -f "$artifact" ]] && exists="yes"
    assert_eq "dd2.json still written on sc8 fail" "yes" "$exists"

    if [[ -f "$artifact" ]]; then
        local before_val after_val sc8_val
        before_val="$(grep -oE '"before_count"[[:space:]]*:[[:space:]]*[0-9]+' "$artifact" \
            | grep -oE '[0-9]+$')" || before_val="parse-failed"
        after_val="$(grep -oE '"after_count"[[:space:]]*:[[:space:]]*[0-9]+' "$artifact" \
            | grep -oE '[0-9]+$')" || after_val="parse-failed"
        sc8_val="$(grep -oE '"sc8_pass"[[:space:]]*:[[:space:]]*(true|false)' "$artifact" \
            | grep -oE '(true|false)$')" || sc8_val="parse-failed"

        assert_eq "before_count is 197"   "197"   "$before_val"
        assert_eq "after_count is 5"      "5"     "$after_val"
        assert_eq "sc8_pass is false"     "false" "$sc8_val"
    fi

    assert_pass_if_clean "test_sc8_fail_when_nonzero"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_missing_baseline_fails_closed
test_sc8_pass_when_zero
test_sc8_fail_when_nonzero

print_summary
