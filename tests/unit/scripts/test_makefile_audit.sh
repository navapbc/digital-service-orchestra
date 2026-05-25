#!/usr/bin/env bash
# tests/unit/scripts/test_makefile_audit.sh
# Behavioral unit tests for Makefile.audit.
#
# Tests:
#   1. test_invocation_order        — stub all 5 audit scripts (exit 0);
#                                     assert log lists dd4→dd1→dd2→dd3→dd5; exit 0
#   2. test_short_circuit_on_failure — stub dd2 exits 4; assert dd3+dd5 not in log;
#                                      assert target exits non-zero
#   3. test_missing_phase_var       — `make audit-phase` with no PHASE → exit non-zero
#                                     with usage message
#
# Usage: bash tests/unit/scripts/test_makefile_audit.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
MAKEFILE="$REPO_ROOT/plugins/dso/scripts/dso_reconciler/audits/Makefile.audit"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test_makefile_audit.sh ==="

# ── Helper: create a stub directory with all 5 audit stubs ────────────────────
# Each stub appends its own filename (basename only) to the LOG_FILE env var,
# then exits with the given exit code.
# $1: associative declaration format — space-separated "name:exit_code" pairs.
#     Unspecified names default to exit 0.
_make_stub_dir() {
    local stub_dir
    stub_dir="$(mktemp -d)"

    # Default exit codes (all 0)
    local -A exits=( [dd4]=0 [dd1]=0 [dd2]=0 [dd3]=0 [dd5]=0 )

    # Apply overrides from arguments: "dd2:4" "dd3:1" etc.
    local pair
    for pair in "$@"; do
        local name="${pair%%:*}"
        local code="${pair#*:}"
        exits["$name"]="$code"
    done

    # ── bash stubs (dd4, dd1, dd2, dd5) ──────────────────────────────────────
    local script_name exit_code
    for script_name in audit_dd4_phase_gate.sh audit_dd1_baseline.sh \
                        audit_dd2_orphan_count.sh audit_dd5_bundle.sh; do
        local dd_key
        # Extract dd key: audit_dd4_phase_gate.sh → dd4
        dd_key="$(printf '%s' "$script_name" | grep -oE 'dd[0-9]+')" || dd_key=""
        exit_code="${exits[$dd_key]:-0}"
        cat > "${stub_dir}/${script_name}" <<SH
#!/usr/bin/env bash
printf '%s\n' "${script_name}" >> "\${LOG_FILE}"
exit ${exit_code}
SH
        chmod +x "${stub_dir}/${script_name}"
    done

    # ── Python stub (dd3) ─────────────────────────────────────────────────────
    exit_code="${exits[dd3]:-0}"
    cat > "${stub_dir}/audit_dd3_mutation_caps.py" <<PY
import os, sys
log_file = os.environ.get("LOG_FILE", "")
if log_file:
    with open(log_file, "a") as f:
        f.write("audit_dd3_mutation_caps.py\n")
sys.exit(${exits[dd3]})
PY

    # ── pass-log fixture (satisfies the Makefile _check-pass-log gate) ───────
    # The stubs don't actually consume this file, but the precondition target
    # checks for its presence before invoking the dd3 step.
    printf '{"phase":"test","pass_index":1,"mutation_count":0,"timestamp":"2026-05-25T00:00:00Z"}\n' \
        > "${stub_dir}/pass-log.jsonl"

    printf '%s' "$stub_dir"
}

# ── Test 1: all stubs exit 0 — assert order dd4→dd1→dd2→dd3→dd5 + exit 0 ─────
test_invocation_order() {
    _snapshot_fail

    local stub_dir log_file
    stub_dir="$(_make_stub_dir)"
    log_file="$(mktemp)"
    # Ensure trailing slash for AUDIT_DIR
    local audit_dir="${stub_dir}/"

    trap 'rm -rf "$stub_dir"; rm -f "$log_file"' RETURN

    local rc=99
    LOG_FILE="$log_file" \
        make -f "$MAKEFILE" audit-phase PHASE=test-phase AUDIT_DIR="$audit_dir" \
        >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 0" "0" "$rc"

    # Read log lines into array (strip empty lines)
    local -a log_lines=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && log_lines+=("$line")
    done < "$log_file"

    assert_eq "5 entries in log" "5" "${#log_lines[@]}"
    assert_eq "step 1 is dd4" "audit_dd4_phase_gate.sh"      "${log_lines[0]:-missing}"
    assert_eq "step 2 is dd1" "audit_dd1_baseline.sh"         "${log_lines[1]:-missing}"
    assert_eq "step 3 is dd2" "audit_dd2_orphan_count.sh"     "${log_lines[2]:-missing}"
    assert_eq "step 4 is dd3" "audit_dd3_mutation_caps.py"    "${log_lines[3]:-missing}"
    assert_eq "step 5 is dd5" "audit_dd5_bundle.sh"           "${log_lines[4]:-missing}"

    assert_pass_if_clean "test_invocation_order"
}

# ── Test 2: dd2 exits 4 → dd3 and dd5 NOT invoked; target exits non-zero ──────
test_short_circuit_on_failure() {
    _snapshot_fail

    local stub_dir log_file
    stub_dir="$(_make_stub_dir "dd2:4")"
    log_file="$(mktemp)"
    local audit_dir="${stub_dir}/"

    trap 'rm -rf "$stub_dir"; rm -f "$log_file"' RETURN

    local rc=99
    LOG_FILE="$log_file" \
        make -f "$MAKEFILE" audit-phase PHASE=test-phase AUDIT_DIR="$audit_dir" \
        >/dev/null 2>&1
    rc=$?

    assert_ne "exit code is non-zero" "0" "$rc"

    # dd3 and dd5 must not appear in the log
    local log_content
    log_content="$(cat "$log_file" 2>/dev/null || true)"

    assert_not_contains "dd3 not invoked" "audit_dd3_mutation_caps.py" "$log_content"
    assert_not_contains "dd5 not invoked" "audit_dd5_bundle.sh"        "$log_content"

    # dd4, dd1, dd2 should be present
    assert_contains "dd4 was invoked" "audit_dd4_phase_gate.sh"  "$log_content"
    assert_contains "dd1 was invoked" "audit_dd1_baseline.sh"    "$log_content"
    assert_contains "dd2 was invoked" "audit_dd2_orphan_count.sh" "$log_content"

    assert_pass_if_clean "test_short_circuit_on_failure"
}

# ── Test 3: missing PHASE variable → exit non-zero with usage message ──────────
test_missing_phase_var() {
    _snapshot_fail

    local stub_dir
    stub_dir="$(_make_stub_dir)"
    local audit_dir="${stub_dir}/"

    trap 'rm -rf "$stub_dir"' RETURN

    local rc=99
    local output
    output="$(make -f "$MAKEFILE" audit-phase AUDIT_DIR="$audit_dir" 2>&1)" || rc=$?
    rc="${rc:-0}"
    # make may return rc=0 if the assignment above swallowed it; re-run to capture
    if [[ "$rc" -eq 99 ]]; then
        make -f "$MAKEFILE" audit-phase AUDIT_DIR="$audit_dir" >/dev/null 2>&1
        rc=$?
    fi

    assert_ne "exit code is non-zero" "0" "$rc"
    assert_contains "output contains usage" "PHASE" "$output"

    assert_pass_if_clean "test_missing_phase_var"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_invocation_order
test_short_circuit_on_failure
test_missing_phase_var

print_summary
