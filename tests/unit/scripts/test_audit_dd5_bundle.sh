#!/usr/bin/env bash
# tests/unit/scripts/test_audit_dd5_bundle.sh
# Behavioral unit tests for audit_dd5_bundle.sh.
#
# Tests:
#   1. test_bundle_success           — all 4 prereq files present + TICKET_CLI stub
#                                      → dd5.json has all 4 artifacts with sha256,
#                                        exit 0, stub log has exactly one comment
#                                        line containing artifact dir path
#   2. test_missing_prereq_exits_6   — dd2.json missing → exit 6, no dd5.json,
#                                      no comment recorded
#   3. test_epic_comment_posted      — bundles success then asserts stub log contains
#                                      exactly one comment line
#
# NOTE: These tests use fixture dd*.json files with locked synthetic schemas
# (independent of live audit run outputs). Each fixture has a canonical shape
# with sc8_pass=true to exercise the all-pass path.
#
# Usage: bash tests/unit/scripts/test_audit_dd5_bundle.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/dso_reconciler/audits/audit_dd5_bundle.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test_audit_dd5_bundle.sh ==="

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

# ── Helper: write locked-schema fixture dd1.json ─────────────────────────────
# dd1.json contract matches the production audit_dd1_baseline.sh writer:
# data capture only — NO boolean pass field. dd5 derives dd1_pass from the
# presence of label_only_orphan_count.
_write_dd1_fixture() {
    local dir="$1"
    local phase="${2:-bootstrap-throttle}"
    cat > "${dir}/dd1.json" <<EOF
{
  "phase": "${phase}",
  "captured_at": "2026-05-25T00:00:00Z",
  "label_only_orphan_count": 197,
  "bridge_fsck_command": "bridge-fsck --count-only",
  "git_sha": "abc123def456"
}
EOF
}

# ── Helper: write locked-schema fixture dd2.json ─────────────────────────────
_write_dd2_fixture() {
    local dir="$1"
    local phase="${2:-bootstrap-throttle}"
    cat > "${dir}/dd2.json" <<EOF
{
  "phase": "${phase}",
  "before_count": 197,
  "after_count": 0,
  "delta": 197,
  "sc8_pass": true
}
EOF
}

# ── Helper: write locked-schema fixture dd3.json ─────────────────────────────
# dd3.json contract matches the production audit_dd3_mutation_caps.py writer:
# the verdict field is `overall_pass` (NOT sc8_pass / NOT pass).
_write_dd3_fixture() {
    local dir="$1"
    local phase="${2:-bootstrap-throttle}"
    local overall_pass="${3:-true}"
    cat > "${dir}/dd3.json" <<EOF
{
  "phase": "${phase}",
  "passes": [],
  "overall_pass": ${overall_pass}
}
EOF
}

# ── Helper: write locked-schema fixture quarantine.json ──────────────────────
_write_quarantine_fixture() {
    local dir="$1"
    cat > "${dir}/quarantine.json" <<EOF
{
  "quarantined_ids": [],
  "generated_at": "2026-05-25T00:00:00Z"
}
EOF
}

# ── Helper: write all 4 fixtures into a phase artifact dir ───────────────────
_write_all_fixtures() {
    local artifact_root="$1"
    local phase="${2:-bootstrap-throttle}"
    local phase_dir="${artifact_root}/${phase}"
    mkdir -p "$phase_dir"
    _write_dd1_fixture "$phase_dir" "$phase"
    _write_dd2_fixture "$phase_dir" "$phase"
    _write_dd3_fixture "$phase_dir" "$phase"
    _write_quarantine_fixture "$phase_dir"
}

# ── Helper: create a TICKET_CLI stub that records args to a log file ──────────
_make_ticket_cli_stub() {
    local log_file="$1"
    local stub_dir
    stub_dir="$(mktemp -d)"
    local stub="${stub_dir}/dso"
    cat > "$stub" <<STUB_EOF
#!/usr/bin/env bash
# Record all arguments on one line per invocation
printf '%s\n' "\$*" >> "${log_file}"
exit 0
STUB_EOF
    chmod +x "$stub"
    printf '%s' "$stub"
}

# ── Test 1: test_bundle_success ───────────────────────────────────────────────
# All 4 prereq files present + TICKET_CLI stub → dd5.json written with all 4
# artifacts (each having sha256), exit 0, stub log has exactly one comment line
# containing the artifact dir path.
test_bundle_success() {
    _snapshot_fail

    local phase="bootstrap-throttle"
    local epic_id="test-epic-001"

    local gate_dir artifact_root log_file stub_cli
    gate_dir="$(_make_satisfied_gate_dir "$phase")"
    artifact_root="$(mktemp -d)"
    log_file="$(mktemp "${TMPDIR:-/tmp}/ticket_stub_log.XXXXXX")"
    stub_cli="$(_make_ticket_cli_stub "$log_file")"

    trap 'rm -rf "$gate_dir" "$artifact_root" "$(dirname "$stub_cli")" "$log_file"' RETURN

    _write_all_fixtures "$artifact_root" "$phase"

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
    AUDIT_ARTIFACTS_DIR="$artifact_root" \
    TICKET_CLI="$stub_cli" \
        bash "$SCRIPT" "$phase" --epic "$epic_id" >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 0" "0" "$rc"

    local dd5_path="${artifact_root}/${phase}/dd5.json"
    local exists="no"
    [[ -f "$dd5_path" ]] && exists="yes"
    assert_eq "dd5.json exists" "yes" "$exists"

    # Verify all 4 artifact names appear in dd5.json
    if [[ -f "$dd5_path" ]]; then
        local dd5_content
        dd5_content="$(cat "$dd5_path")"

        local has_dd1="no"; [[ "$dd5_content" == *'"dd1.json"'* ]] && has_dd1="yes"
        local has_dd2="no"; [[ "$dd5_content" == *'"dd2.json"'* ]] && has_dd2="yes"
        local has_dd3="no"; [[ "$dd5_content" == *'"dd3.json"'* ]] && has_dd3="yes"
        local has_q="no";   [[ "$dd5_content" == *'"quarantine.json"'* ]] && has_q="yes"
        assert_eq "dd5.json lists dd1.json"          "yes" "$has_dd1"
        assert_eq "dd5.json lists dd2.json"          "yes" "$has_dd2"
        assert_eq "dd5.json lists dd3.json"          "yes" "$has_dd3"
        assert_eq "dd5.json lists quarantine.json"   "yes" "$has_q"

        # Each artifact entry must have a sha256 field with a non-empty value
        local sha256_count
        sha256_count="$(grep -c '"sha256"' "$dd5_path" 2>/dev/null || printf '0')"
        assert_eq "dd5.json has 4 sha256 entries" "4" "$sha256_count"

        # overall_result must be present
        local has_overall="no"
        [[ "$dd5_content" == *'"overall_result"'* ]] && has_overall="yes"
        assert_eq "dd5.json has overall_result" "yes" "$has_overall"
    fi

    # Stub log must have exactly one comment invocation containing the artifact dir
    local stub_log_content=""
    [[ -f "$log_file" ]] && stub_log_content="$(cat "$log_file")"

    local comment_lines
    comment_lines="$(printf '%s\n' "$stub_log_content" | grep -c 'ticket comment' 2>/dev/null || printf '0')"
    assert_eq "stub log has exactly one comment line" "1" "$comment_lines"

    # Comment line must contain the artifact dir path
    local artifact_dir="${artifact_root}/${phase}"
    local has_dir="no"
    [[ "$stub_log_content" == *"$artifact_dir"* ]] && has_dir="yes"
    assert_eq "comment line contains artifact dir path" "yes" "$has_dir"

    assert_pass_if_clean "test_bundle_success"
}

# ── Test 2: test_missing_prereq_exits_6 ──────────────────────────────────────
# dd2.json missing → exit 6, no dd5.json written, no comment recorded.
test_missing_prereq_exits_6() {
    _snapshot_fail

    local phase="bootstrap-throttle"
    local epic_id="test-epic-002"

    local gate_dir artifact_root log_file stub_cli
    gate_dir="$(_make_satisfied_gate_dir "$phase")"
    artifact_root="$(mktemp -d)"
    log_file="$(mktemp "${TMPDIR:-/tmp}/ticket_stub_log.XXXXXX")"
    stub_cli="$(_make_ticket_cli_stub "$log_file")"

    trap 'rm -rf "$gate_dir" "$artifact_root" "$(dirname "$stub_cli")" "$log_file"' RETURN

    # Write all fixtures EXCEPT dd2.json
    local phase_dir="${artifact_root}/${phase}"
    mkdir -p "$phase_dir"
    _write_dd1_fixture "$phase_dir" "$phase"
    # dd2.json intentionally omitted
    _write_dd3_fixture "$phase_dir" "$phase"
    _write_quarantine_fixture "$phase_dir"

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
    AUDIT_ARTIFACTS_DIR="$artifact_root" \
    TICKET_CLI="$stub_cli" \
        bash "$SCRIPT" "$phase" --epic "$epic_id" >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 6 when dd2.json missing" "6" "$rc"

    local dd5_path="${artifact_root}/${phase}/dd5.json"
    local exists="no"
    [[ -f "$dd5_path" ]] && exists="yes"
    assert_eq "no dd5.json written on missing prereq" "no" "$exists"

    # No comment must have been posted
    local comment_lines="0"
    if [[ -f "$log_file" ]]; then
        comment_lines="$(grep -c 'ticket comment' "$log_file" 2>/dev/null || printf '0')"
    fi
    assert_eq "no comment posted on exit 6" "0" "$comment_lines"

    assert_pass_if_clean "test_missing_prereq_exits_6"
}

# ── Test 3: test_epic_comment_posted ─────────────────────────────────────────
# Bundles success then asserts stub log contains exactly one comment line with
# the artifact dir path (re-verification of the comment contract in isolation).
test_epic_comment_posted() {
    _snapshot_fail

    local phase="bootstrap-throttle"
    local epic_id="test-epic-003"

    local gate_dir artifact_root log_file stub_cli
    gate_dir="$(_make_satisfied_gate_dir "$phase")"
    artifact_root="$(mktemp -d)"
    log_file="$(mktemp "${TMPDIR:-/tmp}/ticket_stub_log.XXXXXX")"
    stub_cli="$(_make_ticket_cli_stub "$log_file")"

    trap 'rm -rf "$gate_dir" "$artifact_root" "$(dirname "$stub_cli")" "$log_file"' RETURN

    _write_all_fixtures "$artifact_root" "$phase"

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
    AUDIT_ARTIFACTS_DIR="$artifact_root" \
    TICKET_CLI="$stub_cli" \
        bash "$SCRIPT" "$phase" --epic "$epic_id" >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 0 (epic comment test)" "0" "$rc"

    local stub_log_content=""
    [[ -f "$log_file" ]] && stub_log_content="$(cat "$log_file")"

    # Exactly one comment line
    local comment_lines
    comment_lines="$(printf '%s\n' "$stub_log_content" | grep -c 'ticket comment' 2>/dev/null || printf '0')"
    assert_eq "exactly one comment line posted" "1" "$comment_lines"

    # Comment line contains artifact dir path
    local artifact_dir="${artifact_root}/${phase}"
    local has_dir="no"
    [[ "$stub_log_content" == *"$artifact_dir"* ]] && has_dir="yes"
    assert_eq "comment contains artifact dir path" "yes" "$has_dir"

    # Comment references the epic id
    local has_epic="no"
    [[ "$stub_log_content" == *"$epic_id"* ]] && has_epic="yes"
    assert_eq "comment invocation references epic id" "yes" "$has_epic"

    assert_pass_if_clean "test_epic_comment_posted"
}

# ── Test 4: test_dd3_overall_pass_false_propagates ────────────────────────────
# When dd3.json reports overall_pass=false, dd5 MUST:
#   - emit dd3_pass=false in dd5.json
#   - emit overall_result=false
#   - exit non-zero (this is a real audit failure, not silent certification)
# This is the regression test for the silent-certification fall-through bug
# where a missing/unrecognised pass-field caused the script to default to true.
test_dd3_overall_pass_false_propagates() {
    _snapshot_fail

    local phase="bootstrap-throttle"
    local epic_id="test-epic-004"

    local gate_dir artifact_root log_file stub_cli
    gate_dir="$(_make_satisfied_gate_dir "$phase")"
    artifact_root="$(mktemp -d)"
    log_file="$(mktemp "${TMPDIR:-/tmp}/ticket_stub_log.XXXXXX")"
    stub_cli="$(_make_ticket_cli_stub "$log_file")"

    trap 'rm -rf "$gate_dir" "$artifact_root" "$(dirname "$stub_cli")" "$log_file"' RETURN

    # Write fixtures: dd1, dd2 healthy; dd3 reports a real failure.
    local phase_dir="${artifact_root}/${phase}"
    mkdir -p "$phase_dir"
    _write_dd1_fixture "$phase_dir" "$phase"
    _write_dd2_fixture "$phase_dir" "$phase"
    _write_dd3_fixture "$phase_dir" "$phase" "false"   # overall_pass = false
    _write_quarantine_fixture "$phase_dir"

    local rc=99
    RECONCILER_PHASE_GATE_DIR="$gate_dir" \
    AUDIT_ARTIFACTS_DIR="$artifact_root" \
    TICKET_CLI="$stub_cli" \
        bash "$SCRIPT" "$phase" --epic "$epic_id" >/dev/null 2>&1
    rc=$?

    # Script writes dd5.json (the audit DID run); but does it record the
    # failure correctly? Inspect the artifact before checking rc.
    local dd5_path="${artifact_root}/${phase}/dd5.json"
    local dd5_exists="no"
    [[ -f "$dd5_path" ]] && dd5_exists="yes"
    assert_eq "dd5.json written for failed audit" "yes" "$dd5_exists"

    if [[ -f "$dd5_path" ]]; then
        local content
        content="$(cat "$dd5_path")"

        # dd3_pass MUST be false (not silently true)
        local has_dd3_false="no"
        [[ "$content" == *'"dd3_pass": false'* ]] && has_dd3_false="yes"
        assert_eq "dd3_pass is false in dd5.json"     "yes" "$has_dd3_false"

        # overall_result MUST be false (AND of all four)
        local has_overall_false="no"
        [[ "$content" == *'"overall_result": false'* ]] && has_overall_false="yes"
        assert_eq "overall_result is false"           "yes" "$has_overall_false"
    fi

    # Exit code MUST be 6 (real failure surfaced to callers)
    assert_eq "exit code is 6 on dd3 overall_pass=false" "6" "$rc"

    assert_pass_if_clean "test_dd3_overall_pass_false_propagates"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_bundle_success
test_missing_prereq_exits_6
test_epic_comment_posted
test_dd3_overall_pass_false_propagates

print_summary
