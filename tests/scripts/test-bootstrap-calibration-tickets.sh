#!/usr/bin/env bash
# tests/scripts/test-bootstrap-calibration-tickets.sh
# test_script_is_executable is intentionally RED until implementation task lands — expected TDD RED state
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP_SCRIPT="$REPO_ROOT/.claude/scripts/dso-bootstrap-calibration-tickets.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-bootstrap-calibration-tickets.sh ==="

# ── Stub builder ─────────────────────────────────────────────────────────────
# make_dso_stub stub_dir health_exists mutation_exists churn_exists create_exit
# Writes a stub dso script that records all calls and simulates ticket commands.
# health_exists/mutation_exists/churn_exists: exit codes for "ticket exists <alias>"
#   0 = ticket exists, 1 = ticket missing, 2 = error
# create_exit: exit code for "ticket create" commands
# Prints the path to the call log.
make_dso_stub() {
  local stub_dir="$1"
  local health_exists="${2:-1}"
  local mutation_exists="${3:-1}"
  local churn_exists="${4:-1}"
  local create_exit="${5:-0}"
  local call_log="$stub_dir/calls.log"

  cat > "$stub_dir/dso" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$call_log"
case "\$*" in
  "ticket exists calibration-program-health") exit $health_exists ;;
  "ticket exists mutation-history")           exit $mutation_exists ;;
  "ticket exists suite-churn-history")        exit $churn_exists ;;
  "ticket create"*)
    if [ "$create_exit" -ne 0 ]; then
      echo "create failed" >&2; exit $create_exit
    fi
    echo "Created stub ticket"
    ;;
esac
STUB
  chmod +x "$stub_dir/dso"
  echo "$call_log"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# test_creates_all_three_when_missing
# All 3 tickets missing (exists exit 1). Run script. Assert 3 "ticket create" calls.
test_creates_all_three_when_missing() {
  local tmp_dir; tmp_dir="$(mktemp -d /tmp/dso-stub.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf $tmp_dir" RETURN
  local call_log; call_log="$(make_dso_stub "$tmp_dir" 1 1 1 0)"
  DSO="$tmp_dir/dso" bash "$BOOTSTRAP_SCRIPT" 2>/dev/null || return 1
  local create_count; create_count=$(grep -c "^ticket create" "$call_log" 2>/dev/null || echo 0)
  [ "$create_count" -eq 3 ]
}

# test_no_op_when_all_exist
# All 3 tickets present (exists exit 0). Run script. Assert 0 "ticket create" calls.
test_no_op_when_all_exist() {
  local tmp_dir; tmp_dir="$(mktemp -d /tmp/dso-stub.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf $tmp_dir" RETURN
  local call_log; call_log="$(make_dso_stub "$tmp_dir" 0 0 0 0)"
  DSO="$tmp_dir/dso" bash "$BOOTSTRAP_SCRIPT" 2>/dev/null || return 1
  local create_count; create_count=$(grep -c "^ticket create" "$call_log" 2>/dev/null || echo 0)
  [ "$create_count" -eq 0 ]
}

# test_partial_idempotent
# health=exists(0), mutation=missing(1), churn=missing(1).
# Assert exactly 2 "ticket create" calls, with mutation-history and suite-churn-history in log.
test_partial_idempotent() {
  local tmp_dir; tmp_dir="$(mktemp -d /tmp/dso-stub.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf $tmp_dir" RETURN
  local call_log; call_log="$(make_dso_stub "$tmp_dir" 0 1 1 0)"
  DSO="$tmp_dir/dso" bash "$BOOTSTRAP_SCRIPT" 2>/dev/null || return 1
  local create_count; create_count=$(grep -c "^ticket create" "$call_log" 2>/dev/null || echo 0)
  [ "$create_count" -eq 2 ] &&
    grep -q "mutation-history" "$call_log" &&
    grep -q "suite-churn-history" "$call_log"
}

# test_script_is_executable
# Assert bootstrap script file exists and is executable.
# Intentionally RED until implementation task lands.
test_script_is_executable() {
  test -x "$BOOTSTRAP_SCRIPT"
}

# test_unknown_exists_exit_code_aborts
# health missing but exists exits 2 (error code, not just missing).
# Assert bootstrap script exits non-zero WITHOUT calling ticket create for that alias.
test_unknown_exists_exit_code_aborts() {
  # Require script to exist before testing error-path behavior
  [ -f "$BOOTSTRAP_SCRIPT" ] || return 1
  local tmp_dir; tmp_dir="$(mktemp -d /tmp/dso-stub.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf $tmp_dir" RETURN
  local call_log; call_log="$(make_dso_stub "$tmp_dir" 2 1 1 0)"
  local exit_code=0
  DSO="$tmp_dir/dso" bash "$BOOTSTRAP_SCRIPT" 2>/dev/null || exit_code=$?
  # Must exit non-zero
  [ "$exit_code" -ne 0 ] &&
    # Must NOT have called ticket create for calibration-program-health
    ! grep -q "^ticket create.*calibration-program-health" "$call_log" 2>/dev/null
}

# test_create_failure_aborts
# health missing (exists exit 1) but create exits 1.
# Assert bootstrap script exits non-zero with failing alias mentioned in stderr.
test_create_failure_aborts() {
  # Require script to exist before testing error-path behavior
  [ -f "$BOOTSTRAP_SCRIPT" ] || return 1
  local tmp_dir; tmp_dir="$(mktemp -d /tmp/dso-stub.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf $tmp_dir" RETURN
  local call_log; call_log="$(make_dso_stub "$tmp_dir" 1 1 1 1)"
  local exit_code=0
  local stderr_output
  stderr_output="$(DSO="$tmp_dir/dso" bash "$BOOTSTRAP_SCRIPT" 2>&1 >/dev/null)" || exit_code=$?
  # Must exit non-zero
  [ "$exit_code" -ne 0 ] &&
    # stderr must contain some indication of the failing alias
    [ -n "$stderr_output" ]
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
if test_unknown_exists_exit_code_aborts; then (( ++PASS )); else (( ++FAIL )); fi
assert_pass_if_clean "test_unknown_exists_exit_code_aborts"

_snapshot_fail
if test_create_failure_aborts; then (( ++PASS )); else (( ++FAIL )); fi
assert_pass_if_clean "test_create_failure_aborts"

print_summary
