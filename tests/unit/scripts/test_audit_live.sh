#!/usr/bin/env bash
# tests/unit/scripts/test_audit_live.sh
# Behavioral unit tests for the `audit-live` Makefile target.
#
# Tests:
#   1. test_audit_live_full_pipeline — stub all 5 audit scripts to log
#      invocation; run `make -f Makefile.audit audit-live`; assert
#      dd4→dd1→dd2→dd3→dd5 ordering + exit 0.
#   2. test_audit_live_uses_bootstrap_throttle_phase — assert the PHASE
#      passed to each script equals "bootstrap-throttle".
#   3. test_audit_live_short_circuits_on_failure — stub dd2 exits 1;
#      assert dd3+dd5 not invoked; assert exit non-zero.
#
# Usage: bash tests/unit/scripts/test_audit_live.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
MAKEFILE="$REPO_ROOT/plugins/dso/scripts/dso_reconciler/audits/Makefile.audit"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test_audit_live.sh ==="

# ── Helper: create a stub directory with all 5 audit stubs ───────────────────
# Each stub appends its own filename (basename only) and the phase argument
# to LOG_FILE, then exits with the given exit code.
# $@: optional "name:exit_code" pairs (e.g. "dd2:1")
_make_stub_dir() {
    local stub_dir
    stub_dir="$(mktemp -d)"

    # Default exit codes (all 0)
    local -A exits=( [dd4]=0 [dd1]=0 [dd2]=0 [dd3]=0 [dd5]=0 )

    # Apply overrides
    local pair
    for pair in "$@"; do
        local name="${pair%%:*}"
        local code="${pair#*:}"
        exits["$name"]="$code"
    done

    # ── bash stubs (dd4, dd1, dd2, dd5) ──────────────────────────────────────
    local script_name exit_code dd_key
    for script_name in audit_dd4_phase_gate.sh audit_dd1_baseline.sh \
                        audit_dd2_orphan_count.sh audit_dd5_bundle.sh; do
        dd_key="$(printf '%s' "$script_name" | grep -oE 'dd[0-9]+')" || dd_key=""
        exit_code="${exits[$dd_key]:-0}"
        cat > "${stub_dir}/${script_name}" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "${script_name}" "\$1" >> "\${LOG_FILE}"
exit ${exit_code}
SH
        chmod +x "${stub_dir}/${script_name}"
    done

    # ── Python stub (dd3) ─────────────────────────────────────────────────────
    exit_code="${exits[dd3]:-0}"
    cat > "${stub_dir}/audit_dd3_mutation_caps.py" <<PY
import os, sys
log_file = os.environ.get("LOG_FILE", "")
phase = ""
for i, a in enumerate(sys.argv):
    if a == "--phase" and i + 1 < len(sys.argv):
        phase = sys.argv[i + 1]
if log_file:
    with open(log_file, "a") as f:
        f.write(f"audit_dd3_mutation_caps.py {phase}\n")
sys.exit(${exit_code})
PY

    # ── pass-log fixture (satisfies the Makefile _check-pass-log gate) ───────
    printf '{"phase":"bootstrap-throttle","pass_index":1,"mutation_count":0,"timestamp":"2026-05-25T00:00:00Z"}\n' \
        > "${stub_dir}/pass-log.jsonl"

    printf '%s' "$stub_dir"
}

# ── Test 1: audit-live full pipeline — dd4→dd1→dd2→dd3→dd5 order, exit 0 ─────
test_audit_live_full_pipeline() {
    _snapshot_fail

    local stub_dir log_file
    stub_dir="$(_make_stub_dir)"
    log_file="$(mktemp)"
    local audit_dir="${stub_dir}/"

    trap 'rm -rf "$stub_dir"; rm -f "$log_file"' RETURN

    local rc=99
    LOG_FILE="$log_file" \
        make -f "$MAKEFILE" audit-live AUDIT_DIR="$audit_dir" \
        >/dev/null 2>&1
    rc=$?

    assert_eq "exit code is 0" "0" "$rc"

    # Read log lines (script name only — first word)
    local -a script_names=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && script_names+=("${line%% *}")
    done < "$log_file"

    assert_eq "5 entries in log" "5" "${#script_names[@]}"
    assert_eq "step 1 is dd4" "audit_dd4_phase_gate.sh"      "${script_names[0]:-missing}"
    assert_eq "step 2 is dd1" "audit_dd1_baseline.sh"         "${script_names[1]:-missing}"
    assert_eq "step 3 is dd2" "audit_dd2_orphan_count.sh"     "${script_names[2]:-missing}"
    assert_eq "step 4 is dd3" "audit_dd3_mutation_caps.py"    "${script_names[3]:-missing}"
    assert_eq "step 5 is dd5" "audit_dd5_bundle.sh"           "${script_names[4]:-missing}"

    assert_pass_if_clean "test_audit_live_full_pipeline"
}

# ── Test 2: audit-live passes PHASE=bootstrap-throttle to each script ─────────
test_audit_live_uses_bootstrap_throttle_phase() {
    _snapshot_fail

    local stub_dir log_file
    stub_dir="$(_make_stub_dir)"
    log_file="$(mktemp)"
    local audit_dir="${stub_dir}/"
    local expected_phase="bootstrap-throttle"

    trap 'rm -rf "$stub_dir"; rm -f "$log_file"' RETURN

    LOG_FILE="$log_file" \
        make -f "$MAKEFILE" audit-live AUDIT_DIR="$audit_dir" \
        >/dev/null 2>&1

    # Each log line: "<script_name> <phase_arg>"
    local line phase_seen=0 bad_phase=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local phase_arg="${line##* }"
        if [[ "$phase_arg" == "$expected_phase" ]]; then
            (( phase_seen++ )) || true
        else
            (( bad_phase++ )) || true
        fi
    done < "$log_file"

    assert_eq "all 5 scripts received bootstrap-throttle phase" "5" "$phase_seen"
    assert_eq "no scripts received wrong phase" "0" "$bad_phase"

    assert_pass_if_clean "test_audit_live_uses_bootstrap_throttle_phase"
}

# ── Test 3: dd2 exits 1 → dd3+dd5 not invoked; target exits non-zero ──────────
test_audit_live_short_circuits_on_failure() {
    _snapshot_fail

    local stub_dir log_file
    stub_dir="$(_make_stub_dir "dd2:1")"
    log_file="$(mktemp)"
    local audit_dir="${stub_dir}/"

    trap 'rm -rf "$stub_dir"; rm -f "$log_file"' RETURN

    local rc=99
    LOG_FILE="$log_file" \
        make -f "$MAKEFILE" audit-live AUDIT_DIR="$audit_dir" \
        >/dev/null 2>&1
    rc=$?

    assert_ne "exit code is non-zero on dd2 failure" "0" "$rc"

    local log_content
    log_content="$(cat "$log_file" 2>/dev/null || true)"

    assert_not_contains "dd3 not invoked" "audit_dd3_mutation_caps.py" "$log_content"
    assert_not_contains "dd5 not invoked" "audit_dd5_bundle.sh"        "$log_content"
    assert_contains     "dd4 was invoked" "audit_dd4_phase_gate.sh"    "$log_content"
    assert_contains     "dd1 was invoked" "audit_dd1_baseline.sh"      "$log_content"
    assert_contains     "dd2 was invoked" "audit_dd2_orphan_count.sh"  "$log_content"

    assert_pass_if_clean "test_audit_live_short_circuits_on_failure"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_audit_live_full_pipeline
test_audit_live_uses_bootstrap_throttle_phase
test_audit_live_short_circuits_on_failure

print_summary
