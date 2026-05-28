#!/usr/bin/env bash
# tests/scripts/test-bootstrap-calibration-tickets.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP_SCRIPT="$REPO_ROOT/.claude/scripts/dso-bootstrap-calibration-tickets.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-bootstrap-calibration-tickets.sh ==="

# ── Stub builder ─────────────────────────────────────────────────────────────
# make_dso_stub stub_dir health_found mutation_found churn_found create_exit
# Writes a stub dso script that records all calls and simulates ticket commands.
# health_found/mutation_found/churn_found: whether the ticket exists
#   0 = ticket not found (list-epics returns empty/no-tab output)
#   1 = ticket found (list-epics returns a tab-separated epic line)
# create_exit: exit code for "ticket create" commands
# Prints the path to the call log.
make_dso_stub() {
  local stub_dir="$1"
  local health_found="${2:-0}"
  local mutation_found="${3:-0}"
  local churn_found="${4:-0}"
  local create_exit="${5:-0}"
  local call_log="$stub_dir/calls.log"

  local health_line="" mutation_line="" churn_line=""
  [ "$health_found" -eq 1 ] && health_line="abcd-1234	P1	Calibration health	0"
  [ "$mutation_found" -eq 1 ] && mutation_line="bcde-2345	P1	Mutation history	0"
  [ "$churn_found" -eq 1 ] && churn_line="cdef-3456	P1	Suite churn	0"

  cat > "$stub_dir/dso" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$call_log"
case "\$*" in
  *"list-epics"*"calibration-program-health"*) echo "${health_line}" ;;
  *"list-epics"*"mutation-history"*)           echo "${mutation_line}" ;;
  *"list-epics"*"suite-churn-history"*)        echo "${churn_line}" ;;
  "ticket create"*)
    if [ "${create_exit}" -ne 0 ]; then
      echo "create failed" >&2; exit ${create_exit}
    fi
    echo "new-stub-ticket-id"
    ;;
esac
STUB
  chmod +x "$stub_dir/dso"
  echo "$call_log"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# test_creates_all_three_when_missing
# All 3 tickets not found (list-epics returns empty for all). Assert 3 "ticket create" calls.
test_creates_all_three_when_missing() {
  local tmp_dir; tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dso-stub.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf $tmp_dir" RETURN
  local call_log; call_log="$(make_dso_stub "$tmp_dir" 0 0 0 0)"
  DSO="$tmp_dir/dso" bash "$BOOTSTRAP_SCRIPT" 2>/dev/null || return 1
  local create_count
  create_count=$(grep -c "^ticket create" "$call_log" 2>/dev/null) || create_count=0
  [ "$create_count" -eq 3 ]
}

# test_no_op_when_all_exist
# All 3 tickets found (list-epics returns tab-line for all). Assert 0 "ticket create" calls.
test_no_op_when_all_exist() {
  local tmp_dir; tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dso-stub.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf $tmp_dir" RETURN
  local call_log; call_log="$(make_dso_stub "$tmp_dir" 1 1 1 0)"
  DSO="$tmp_dir/dso" bash "$BOOTSTRAP_SCRIPT" 2>/dev/null || return 1
  local create_count
  create_count=$(grep -c "^ticket create" "$call_log" 2>/dev/null) || create_count=0
  [ "$create_count" -eq 0 ]
}

# test_partial_idempotent
# health found (list-epics tab-line), mutation/churn not found (empty list-epics).
# Assert exactly 2 "ticket create" calls, with mutation-history and suite-churn-history in log.
test_partial_idempotent() {
  local tmp_dir; tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dso-stub.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf $tmp_dir" RETURN
  local call_log; call_log="$(make_dso_stub "$tmp_dir" 1 0 0 0)"
  DSO="$tmp_dir/dso" bash "$BOOTSTRAP_SCRIPT" 2>/dev/null || return 1
  local create_count
  create_count=$(grep -c "^ticket create" "$call_log" 2>/dev/null) || create_count=0
  [ "$create_count" -eq 2 ] &&
    grep -q "mutation-history" "$call_log" &&
    grep -q "suite-churn-history" "$call_log"
}

# test_script_is_executable
# Assert bootstrap script file exists and is executable.

test_script_is_executable() {
  test -x "$BOOTSTRAP_SCRIPT"
}

# test_create_failure_aborts_remaining
# health ticket missing (list-epics empty), create fails for health ticket (create_exit=1).
# Assert bootstrap script exits non-zero WITHOUT calling ticket create for mutation-history.
# (set -euo pipefail: first create failure must abort before processing remaining aliases)
test_create_failure_aborts_remaining() {
  # Require script to exist before testing error-path behavior
  [ -f "$BOOTSTRAP_SCRIPT" ] || return 1
  local tmp_dir; tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dso-stub.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf $tmp_dir" RETURN
  local call_log; call_log="$(make_dso_stub "$tmp_dir" 0 0 0 1)"
  local exit_code=0
  DSO="$tmp_dir/dso" bash "$BOOTSTRAP_SCRIPT" 2>/dev/null || exit_code=$?
  # Must exit non-zero
  [ "$exit_code" -ne 0 ] &&
    # Must NOT have reached mutation-history or suite-churn-history creates
    ! grep -q "mutation-history" "$call_log" 2>/dev/null
}

# test_create_failure_aborts
# health ticket not found (list-epics empty) but create exits 1.
# Assert bootstrap script exits non-zero with some output on stderr.
test_create_failure_aborts() {
  # Require script to exist before testing error-path behavior
  [ -f "$BOOTSTRAP_SCRIPT" ] || return 1
  local tmp_dir; tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dso-stub.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf $tmp_dir" RETURN
  local call_log; call_log="$(make_dso_stub "$tmp_dir" 0 0 0 1)"
  local exit_code=0
  local stderr_output
  stderr_output="$(DSO="$tmp_dir/dso" bash "$BOOTSTRAP_SCRIPT" 2>&1 >/dev/null)" || exit_code=$?
  # Must exit non-zero
  [ "$exit_code" -ne 0 ] &&
    # stderr must contain some indication of the failure
    [ -n "$stderr_output" ]
}

# test_uses_list_epics_for_idempotency
# Stub: ticket list-epics --has-tag=<alias> returns a tab-separated line (all 3 exist).
#   ticket exists always returns 1 (real behavior for text aliases).
# Assert: 0 "ticket create" calls — bootstrap must skip all 3.

test_uses_list_epics_for_idempotency() {
  local tmp_dir; tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dso-stub.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf $tmp_dir" RETURN
  local call_log="$tmp_dir/calls.log"
  touch "$call_log"

  cat > "$tmp_dir/dso" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$call_log"
case "\$*" in
  *"list-epics"*) echo "abcd-1234	P1	Calibration ticket	0" ;;
  "ticket exists"*) exit 1 ;;
  "ticket create"*) echo "new-ticket-id" ;;
esac
STUB
  chmod +x "$tmp_dir/dso"

  DSO="$tmp_dir/dso" bash "$BOOTSTRAP_SCRIPT" 2>/dev/null || return 1
  local create_count
  create_count=$(grep -c "^ticket create" "$call_log" 2>/dev/null) || create_count=0
  [ "$create_count" -eq 0 ]
}

# test_creates_epic_type_without_alias_flag
# Stub: list-epics returns empty (no tab), ticket create epic succeeds.
# Assert: 3 "ticket create epic" calls AND no "--alias=" in any call.

test_creates_epic_type_without_alias_flag() {
  local tmp_dir; tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dso-stub.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf $tmp_dir" RETURN
  local call_log="$tmp_dir/calls.log"
  touch "$call_log"

  cat > "$tmp_dir/dso" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$call_log"
case "\$*" in
  *"list-epics"*) echo "No open epics found." ;;
  "ticket exists"*) exit 1 ;;
  "ticket create"*) echo "new-ticket-id" ;;
esac
STUB
  chmod +x "$tmp_dir/dso"

  DSO="$tmp_dir/dso" bash "$BOOTSTRAP_SCRIPT" 2>/dev/null || return 1
  local create_count
  create_count=$(grep -c "^ticket create epic" "$call_log" 2>/dev/null) || create_count=0
  local alias_count
  alias_count=$(grep -c -- "--alias=" "$call_log" 2>/dev/null) || alias_count=0
  [ "$create_count" -eq 3 ] && [ "$alias_count" -eq 0 ]
}

# ── Runner ───────────────────────────────────────────────────────────────────

_snapshot_fail
if test_creates_all_three_when_missing; then (( ++PASS )); else (( ++FAIL )); fi
assert_pass_if_clean "test_creates_all_three_when_missing"

_snapshot_fail
if test_no_op_when_all_exist; then (( ++PASS )); else (( ++FAIL )); fi
assert_pass_if_clean "test_no_op_when_all_exist"

_snapshot_fail
if test_partial_idempotent; then (( ++PASS )); else (( ++FAIL )); fi
assert_pass_if_clean "test_partial_idempotent"

_snapshot_fail
if test_script_is_executable; then (( ++PASS )); else (( ++FAIL )); fi
assert_pass_if_clean "test_script_is_executable"

_snapshot_fail
if test_create_failure_aborts_remaining; then (( ++PASS )); else (( ++FAIL )); fi
assert_pass_if_clean "test_create_failure_aborts_remaining"

_snapshot_fail
if test_create_failure_aborts; then (( ++PASS )); else (( ++FAIL )); fi
assert_pass_if_clean "test_create_failure_aborts"

_snapshot_fail
if test_uses_list_epics_for_idempotency; then (( ++PASS )); else (( ++FAIL )); fi
assert_pass_if_clean "test_uses_list_epics_for_idempotency"

_snapshot_fail
if test_creates_epic_type_without_alias_flag; then (( ++PASS )); else (( ++FAIL )); fi
assert_pass_if_clean "test_creates_epic_type_without_alias_flag"

print_summary
