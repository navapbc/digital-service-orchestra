#!/usr/bin/env bash
# tests/scripts/test-validate-issues-timestamp.sh
# Regression test for: validate-issues.sh crashes on int created_at timestamp
#
# Root cause: check_orphaned_tasks() did ts = created[:19].replace('T', ' ')
# which assumes created_at is a string. The event-sourced ticket system stores
# created_at as an integer (Unix epoch seconds).
#
# When created_at is an integer, the cluster detection code path silently
# discards all integer-timestamped tickets (TypeError caught by bare except),
# so 3+ orphaned tasks with the same-hour integer timestamps never trigger the
# MAJOR cluster warning. This is a data-loss bug, not just a crash.
#
# The fix: convert int to datetime string before processing.
#   if isinstance(created, int): ts = str(datetime.fromtimestamp(created))
#   else: ts = created[:19].replace('T', ' ')
#
# Usage: bash tests/scripts/test-validate-issues-timestamp.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/validate-issues.sh"

source "$SCRIPT_DIR/../lib/run_test.sh"

# ── Cleanup ───────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]:-}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-validate-issues-timestamp.sh ==="

# ── Fixture helpers ───────────────────────────────────────────────────────────

# make_ticket_cmd TICKETS_JSON
# Creates a mock `ticket` script that returns the given JSON from `ticket list`.
make_ticket_cmd() {
    local tickets_json="${1:-[]}"
    local mock_dir
    mock_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$mock_dir")
    local mock_script="$mock_dir/ticket"
    cat > "$mock_script" << MOCK_TICKET
#!/usr/bin/env bash
SUBCMD="\${1:-}"
case "\$SUBCMD" in
    list) echo '${tickets_json//\'/\'\\\'\'}' ; exit 0 ;;
    *) exit 0 ;;
esac
MOCK_TICKET
    chmod +x "$mock_script"
    echo "$mock_script"
}

# ── Test 1: Single orphaned task with integer created_at — no crash ───────────
# Validates that the script exits with a valid health-score exit code (0–4)
# and does not emit a Python traceback when processing a single task with an
# integer epoch timestamp.
echo "Test 1: Single orphaned task with integer created_at exits with valid exit code"

TICKETS_JSON='[{"ticket_id":"task-int-ts","status":"open","ticket_type":"task","title":"Task with int timestamp","parent_id":null,"description":"","notes":"","deps":[],"created_at":1774661690}]'
MOCK_TICKET_CMD=$(make_ticket_cmd "$TICKETS_JSON")

exit_code=0
output=""
output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --quick --terse 2>&1) || exit_code=$?

if echo "$output" | grep -qiE "traceback|TypeError|subscriptable"; then
    echo "  FAIL: Python exception in output — int created_at caused unhandled error" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
elif [[ $exit_code -ge 5 ]]; then
    echo "  FAIL: unexpected exit code $exit_code (expected 0–4, health-score range)" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
else
    echo "  PASS: single int-timestamp task handled without exception (exit $exit_code)"
    (( PASS++ ))
fi

# ── Test 2: Cluster detection fires for 3+ orphaned tasks with int created_at ─
# This is the primary regression: when created_at is an integer, the cluster
# detection code silently discards tickets (TypeError swallowed), so 3+ tasks
# in the same hour NEVER produce a MAJOR cluster warning.
# After the fix, the MAJOR warning must appear.
echo "Test 2: Three orphaned tasks with integer created_at trigger MAJOR cluster warning"

# Three tasks, all within the same hour (epoch values ~1 second apart).
# Without fix: TypeError swallowed → no cluster → no MAJOR output.
# With fix:    epoch converted to datetime → all in same hour → MAJOR emitted.
TICKETS_JSON='[
  {"ticket_id":"task-int-1","status":"open","ticket_type":"task","title":"Int TS Task 1","parent_id":null,"description":"","notes":"","deps":[],"created_at":1774661690},
  {"ticket_id":"task-int-2","status":"open","ticket_type":"task","title":"Int TS Task 2","parent_id":null,"description":"","notes":"","deps":[],"created_at":1774661691},
  {"ticket_id":"task-int-3","status":"open","ticket_type":"task","title":"Int TS Task 3","parent_id":null,"description":"","notes":"","deps":[],"created_at":1774661692}
]'
MOCK_TICKET_CMD=$(make_ticket_cmd "$TICKETS_JSON")

exit_code=0
output=""
output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --quick --terse 2>&1) || exit_code=$?

if echo "$output" | grep -qiE "traceback|TypeError|subscriptable"; then
    echo "  FAIL: Python exception — int created_at not handled in cluster detection" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
elif ! echo "$output" | grep -qiE "\[MAJOR\].*orphaned tasks created around"; then
    echo "  FAIL: 3+ same-hour orphaned tasks with int timestamps did not produce MAJOR cluster warning" >&2
    echo "  (cluster detection is silently discarding int timestamps instead of converting them)" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
else
    echo "  PASS: 3 int-timestamp orphaned tasks produced MAJOR cluster warning"
    (( PASS++ ))
fi

# ── Test 3: Mixed integer and ISO-string created_at — backward compatibility ──
# String ISO timestamps must continue to work after the fix.
echo "Test 3: Mixed integer and ISO-string created_at values both handled correctly"

# Three ISO-string tasks + one int task, all orphaned, all in same "hour" bucket.
# The ISO tasks already produce the MAJOR warning with the current code.
# After fix, the int task should also be counted (4 total, still MAJOR).
TICKETS_JSON='[
  {"ticket_id":"task-str-1","status":"open","ticket_type":"task","title":"Str TS Task 1","parent_id":null,"description":"","notes":"","deps":[],"created_at":"2026-01-01T12:00:01Z"},
  {"ticket_id":"task-str-2","status":"open","ticket_type":"task","title":"Str TS Task 2","parent_id":null,"description":"","notes":"","deps":[],"created_at":"2026-01-01T12:00:02Z"},
  {"ticket_id":"task-str-3","status":"open","ticket_type":"task","title":"Str TS Task 3","parent_id":null,"description":"","notes":"","deps":[],"created_at":"2026-01-01T12:00:03Z"},
  {"ticket_id":"task-int-4","status":"open","ticket_type":"task","title":"Int TS Task 4","parent_id":null,"description":"","notes":"","deps":[],"created_at":1774699200}
]'
MOCK_TICKET_CMD=$(make_ticket_cmd "$TICKETS_JSON")

exit_code=0
output=""
output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --quick --terse 2>&1) || exit_code=$?

if echo "$output" | grep -qiE "traceback|TypeError|subscriptable"; then
    echo "  FAIL: Python exception on mixed created_at types" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
elif ! echo "$output" | grep -qiE "\[MAJOR\].*orphaned tasks created around"; then
    echo "  FAIL: mixed-type tasks did not produce expected MAJOR cluster warning" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
else
    echo "  PASS: mixed int/string created_at types handled correctly"
    (( PASS++ ))
fi

print_results
