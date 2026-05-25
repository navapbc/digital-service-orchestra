#!/usr/bin/env bash
# tests/unit/scripts/test_audit_dd1_baseline.sh
# Behavioral unit tests for audit_dd1_baseline.sh.
#
# Tests:
#   1. test_capture_writes_json        — stub fsck prints 'label_only_orphans=197';
#                                        phase gate satisfied; dd1.json written with count=197; exit 0
#   2. test_gate_refusal_short_circuits — phase gate fails → exit non-zero, no artifact
#   3. test_fails_closed_on_fsck_error  — stub fsck exits 1 → audit exits 3, no artifact
#
# Usage: bash tests/unit/scripts/test_audit_dd1_baseline.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/dso_reconciler/audits/audit_dd1_baseline.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test_audit_dd1_baseline.sh ==="

# ── Helper: create a satisfied phase gate dir ─────────────────────────────────
_make_satisfied_gate_dir() {
    local phase="${1:-1}"
    local gate_dir
    gate_dir="$(mktemp -d)"
    printf '%s\n' "$phase" > "${gate_dir}/.reconciler-phase-gate"
    # Also create the ops file to suppress WARNING (not strictly required)
    printf '{"operator":"test","timestamp":"2026-05-25T00:00:00Z","phase":"%s","comment":"test"}\n' \
        "$phase" > "${gate_dir}/.reconciler-phase-gate.ops"
    printf '%s' "$gate_dir"
}

# ── Helper: create a stub fsck command in a temp bin dir ─────────────────────
_make_fsck_stub() {
    local exit_code="${1:-0}"
    local output="${2:-label_only_orphans=0}"
    local bin_dir
    bin_dir="$(mktemp -d)"
    local stub="${bin_dir}/stub-fsck"
    cat > "$stub" <<STUB_EOF
#!/usr/bin/env bash
printf '%s\n' '${output}'
exit ${exit_code}
STUB_EOF
    chmod +x "$stub"
    printf '%s' "$stub"
}

# ── Test 1: successful capture writes dd1.json with expected count ─────────────
test_capture_writes_json() {
    _snapshot_fail

    local gate_dir artifact_dir stub_cmd
    gate_dir="$(_make_satisfied_gate_dir 1)"
    artifact_dir="$(mktemp -d)"
    stub_cmd="$(_make_fsck_stub 0 'label_only_orphans=197')"

    trap 'rm -rf "$gate_dir" "$artifact_dir" "$(dirname "$stub_cmd")"' RETURN

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
    AUDIT_ARTIFACTS_DIR="$artifact_dir" \
    BRIDGE_FSCK_CMD="$stub_cmd" \
        bash "$SCRIPT" 1 >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 0"          "0"  "$rc"

    local artifact="${artifact_dir}/1/dd1.json"
    local exists="no"
    [[ -f "$artifact" ]] && exists="yes"
    assert_eq "dd1.json exists"         "yes" "$exists"

    # Verify count field in JSON
    local count_val="none"
    if [[ -f "$artifact" ]]; then
        count_val="$(grep -oE '"label_only_orphan_count"[[:space:]]*:[[:space:]]*[0-9]+' "$artifact" \
            | grep -oE '[0-9]+$')" || count_val="parse-failed"
    fi
    assert_eq "label_only_orphan_count is 197" "197" "$count_val"

    assert_pass_if_clean "test_capture_writes_json"
}

# ── Test 2: phase gate refusal short-circuits, no artifact written ─────────────
test_gate_refusal_short_circuits() {
    _snapshot_fail

    local gate_dir artifact_dir stub_cmd
    # gate_dir with NO gate file → check_phase_gate returns 2
    gate_dir="$(mktemp -d)"
    artifact_dir="$(mktemp -d)"
    stub_cmd="$(_make_fsck_stub 0 'label_only_orphans=42')"

    trap 'rm -rf "$gate_dir" "$artifact_dir" "$(dirname "$stub_cmd")"' RETURN

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
    AUDIT_ARTIFACTS_DIR="$artifact_dir" \
    BRIDGE_FSCK_CMD="$stub_cmd" \
        bash "$SCRIPT" 1 >/dev/null 2>&1
    rc=$?

    assert_ne "exit code is non-zero" "0" "$rc"

    local artifact="${artifact_dir}/1/dd1.json"
    local exists="no"
    [[ -f "$artifact" ]] && exists="yes"
    assert_eq "no artifact written" "no" "$exists"

    assert_pass_if_clean "test_gate_refusal_short_circuits"
}

# ── Test 3: fsck exits non-zero → audit exits 3, no artifact ─────────────────
test_fails_closed_on_fsck_error() {
    _snapshot_fail

    local gate_dir artifact_dir stub_cmd
    gate_dir="$(_make_satisfied_gate_dir 1)"
    artifact_dir="$(mktemp -d)"
    stub_cmd="$(_make_fsck_stub 1 'error: bridge-fsck failed')"

    trap 'rm -rf "$gate_dir" "$artifact_dir" "$(dirname "$stub_cmd")"' RETURN

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
    AUDIT_ARTIFACTS_DIR="$artifact_dir" \
    BRIDGE_FSCK_CMD="$stub_cmd" \
        bash "$SCRIPT" 1 >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 3" "3" "$rc"

    local artifact="${artifact_dir}/1/dd1.json"
    local exists="no"
    [[ -f "$artifact" ]] && exists="yes"
    assert_eq "no artifact written on fsck error" "no" "$exists"

    assert_pass_if_clean "test_fails_closed_on_fsck_error"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_capture_writes_json
test_gate_refusal_short_circuits
test_fails_closed_on_fsck_error

print_summary
