#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-merge-ticket-index.sh
# Tests for lockpick-workflow/scripts/merge-ticket-index.py
#
# Usage: bash lockpick-workflow/tests/scripts/test-merge-ticket-index.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/merge-ticket-index.py"

echo "=== test-merge-ticket-index.sh ==="

# ── Helper: create temp dir ────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
cleanup() {
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# ── Test 1: Script exists and is executable ────────────────────────────────
echo ""
echo "Test 1: Script exists and is executable"
if [[ -f "$SCRIPT" ]]; then
    (( ++PASS ))
    echo "  PASS: script exists"
else
    (( ++FAIL ))
    echo "  FAIL: $SCRIPT does not exist" >&2
fi

if [[ -x "$SCRIPT" ]]; then
    (( ++PASS ))
    echo "  PASS: script is executable"
else
    (( ++FAIL ))
    echo "  FAIL: script is not executable" >&2
fi

# ── Test 2: --help flag exits 0 with usage text ────────────────────────────
echo ""
echo "Test 2: --help flag"
help_out=$(python3 "$SCRIPT" --help 2>&1) || help_exit=$?
if echo "$help_out" | grep -qi "usage\|merge\|ancestor\|ours\|theirs"; then
    (( ++PASS ))
    echo "  PASS: --help shows usage text"
else
    (( ++FAIL ))
    echo "  FAIL: --help output missing expected content" >&2
    echo "  Output: $help_out" >&2
fi

# ── Test 3: Basic union merge — non-overlapping keys ───────────────────────
echo ""
echo "Test 3: Basic union merge (non-overlapping keys)"
cat > "$TMPDIR_TEST/base.json" <<'EOF'
{"ticket-aaa": {"status": "open", "title": "Ticket A"}}
EOF
cat > "$TMPDIR_TEST/ours.json" <<'EOF'
{"ticket-aaa": {"status": "open", "title": "Ticket A"}, "ticket-bbb": {"status": "open", "title": "Ticket B"}}
EOF
cat > "$TMPDIR_TEST/theirs.json" <<'EOF'
{"ticket-aaa": {"status": "open", "title": "Ticket A"}, "ticket-ccc": {"status": "closed", "title": "Ticket C"}}
EOF

cp "$TMPDIR_TEST/ours.json" "$TMPDIR_TEST/ours_work.json"
exit_code=0
python3 "$SCRIPT" "$TMPDIR_TEST/base.json" "$TMPDIR_TEST/ours_work.json" "$TMPDIR_TEST/theirs.json" >/dev/null 2>/dev/null || exit_code=$?
if [[ "$exit_code" -eq 0 ]]; then
    result=$(python3 -c "import json; d=json.load(open('$TMPDIR_TEST/ours_work.json')); print(sorted(d.keys()))")
    if echo "$result" | grep -q "ticket-bbb" && echo "$result" | grep -q "ticket-ccc"; then
        (( ++PASS ))
        echo "  PASS: union merge preserves both new keys"
    else
        (( ++FAIL ))
        echo "  FAIL: union merge missing expected keys; result keys: $result" >&2
    fi
else
    (( ++FAIL ))
    echo "  FAIL: script exited $exit_code" >&2
fi

# ── Test 4: Conflict resolution — theirs wins on same-key different values ─
echo ""
echo "Test 4: Conflict resolution — theirs wins on same-key different values"
cat > "$TMPDIR_TEST/base2.json" <<'EOF'
{"ticket-aaa": {"status": "open", "title": "Ticket A"}}
EOF
cat > "$TMPDIR_TEST/ours2.json" <<'EOF'
{"ticket-aaa": {"status": "in_progress", "title": "Ticket A Updated by ours"}}
EOF
cat > "$TMPDIR_TEST/theirs2.json" <<'EOF'
{"ticket-aaa": {"status": "closed", "title": "Ticket A Closed by theirs"}}
EOF

cp "$TMPDIR_TEST/ours2.json" "$TMPDIR_TEST/ours2_work.json"
exit_code=0
python3 "$SCRIPT" "$TMPDIR_TEST/base2.json" "$TMPDIR_TEST/ours2_work.json" "$TMPDIR_TEST/theirs2.json" >/dev/null 2>/dev/null || exit_code=$?
if [[ "$exit_code" -eq 0 ]]; then
    result_status=$(python3 -c "import json; d=json.load(open('$TMPDIR_TEST/ours2_work.json')); print(d['ticket-aaa']['status'])")
    if [[ "$result_status" == "closed" ]]; then
        (( ++PASS ))
        echo "  PASS: theirs wins on conflicting key values"
    else
        (( ++FAIL ))
        echo "  FAIL: expected 'closed' (theirs), got '$result_status'" >&2
    fi
else
    (( ++FAIL ))
    echo "  FAIL: script exited $exit_code" >&2
fi

# ── Test 5: Ours-only change is preserved ─────────────────────────────────
echo ""
echo "Test 5: Ours-only changes are preserved"
cat > "$TMPDIR_TEST/base3.json" <<'EOF'
{"ticket-aaa": {"status": "open", "title": "Ticket A"}}
EOF
cat > "$TMPDIR_TEST/ours3.json" <<'EOF'
{"ticket-aaa": {"status": "in_progress", "title": "Ticket A"}}
EOF
cat > "$TMPDIR_TEST/theirs3.json" <<'EOF'
{"ticket-aaa": {"status": "open", "title": "Ticket A"}}
EOF

cp "$TMPDIR_TEST/ours3.json" "$TMPDIR_TEST/ours3_work.json"
exit_code=0
python3 "$SCRIPT" "$TMPDIR_TEST/base3.json" "$TMPDIR_TEST/ours3_work.json" "$TMPDIR_TEST/theirs3.json" >/dev/null 2>/dev/null || exit_code=$?
if [[ "$exit_code" -eq 0 ]]; then
    result_status=$(python3 -c "import json; d=json.load(open('$TMPDIR_TEST/ours3_work.json')); print(d['ticket-aaa']['status'])")
    if [[ "$result_status" == "in_progress" ]]; then
        (( ++PASS ))
        echo "  PASS: ours-only change preserved"
    else
        (( ++FAIL ))
        echo "  FAIL: expected 'in_progress' (ours), got '$result_status'" >&2
    fi
else
    (( ++FAIL ))
    echo "  FAIL: script exited $exit_code" >&2
fi

# ── Test 6: Malformed JSON input exits non-zero with error message ─────────
echo ""
echo "Test 6: Malformed JSON input produces error and non-zero exit"
echo "not valid json" > "$TMPDIR_TEST/bad.json"
cat > "$TMPDIR_TEST/good.json" <<'EOF'
{"ticket-aaa": {"status": "open"}}
EOF

exit_code=0
err_out=$(python3 "$SCRIPT" "$TMPDIR_TEST/bad.json" "$TMPDIR_TEST/good.json" "$TMPDIR_TEST/good.json" 2>&1) || exit_code=$?
if [[ "$exit_code" -ne 0 ]]; then
    (( ++PASS ))
    echo "  PASS: malformed JSON causes non-zero exit (exit $exit_code)"
else
    (( ++FAIL ))
    echo "  FAIL: expected non-zero exit for malformed JSON, got 0" >&2
fi
if echo "$err_out" | grep -qi "error\|invalid\|json\|malformed\|parse"; then
    (( ++PASS ))
    echo "  PASS: error message mentions JSON issue"
else
    (( ++FAIL ))
    echo "  FAIL: error message missing JSON context; got: $err_out" >&2
fi

# ── Test 7: Structured log line emitted to stderr ─────────────────────────
echo ""
echo "Test 7: Structured log line emitted to stderr"
cat > "$TMPDIR_TEST/log_base.json" <<'EOF'
{}
EOF
cat > "$TMPDIR_TEST/log_ours.json" <<'EOF'
{"ticket-aaa": {"status": "open"}}
EOF
cat > "$TMPDIR_TEST/log_theirs.json" <<'EOF'
{"ticket-bbb": {"status": "closed"}}
EOF

cp "$TMPDIR_TEST/log_ours.json" "$TMPDIR_TEST/log_ours_work.json"
stderr_out=$(python3 "$SCRIPT" "$TMPDIR_TEST/log_base.json" "$TMPDIR_TEST/log_ours_work.json" "$TMPDIR_TEST/log_theirs.json" 2>&1 >/dev/null)
if echo "$stderr_out" | grep -q "MERGE_AUTO_RESOLVE"; then
    (( ++PASS ))
    echo "  PASS: MERGE_AUTO_RESOLVE found in stderr"
else
    (( ++FAIL ))
    echo "  FAIL: MERGE_AUTO_RESOLVE not found in stderr; got: $stderr_out" >&2
fi
if echo "$stderr_out" | grep -q "layer=driver"; then
    (( ++PASS ))
    echo "  PASS: layer=driver found in stderr"
else
    (( ++FAIL ))
    echo "  FAIL: layer=driver not found in stderr; got: $stderr_out" >&2
fi

# ── Test 8: Output is valid JSON with sorted keys ─────────────────────────
echo ""
echo "Test 8: Output is valid JSON with sorted keys"
cat > "$TMPDIR_TEST/sort_base.json" <<'EOF'
{}
EOF
cat > "$TMPDIR_TEST/sort_ours.json" <<'EOF'
{"ticket-zzz": {"status": "open"}, "ticket-aaa": {"status": "closed"}}
EOF
cat > "$TMPDIR_TEST/sort_theirs.json" <<'EOF'
{"ticket-mmm": {"status": "open"}}
EOF

cp "$TMPDIR_TEST/sort_ours.json" "$TMPDIR_TEST/sort_ours_work.json"
exit_code=0
python3 "$SCRIPT" "$TMPDIR_TEST/sort_base.json" "$TMPDIR_TEST/sort_ours_work.json" "$TMPDIR_TEST/sort_theirs.json" 2>/dev/null || exit_code=$?
if [[ "$exit_code" -eq 0 ]]; then
    # Verify keys are sorted alphabetically
    keys=$(python3 -c "import json; d=json.load(open('$TMPDIR_TEST/sort_ours_work.json')); print(list(d.keys()))")
    sorted_keys=$(python3 -c "import json; d=json.load(open('$TMPDIR_TEST/sort_ours_work.json')); print(sorted(d.keys()))")
    if [[ "$keys" == "$sorted_keys" ]]; then
        (( ++PASS ))
        echo "  PASS: output keys are sorted"
    else
        (( ++FAIL ))
        echo "  FAIL: output keys not sorted; got $keys, expected $sorted_keys" >&2
    fi
else
    (( ++FAIL ))
    echo "  FAIL: script exited $exit_code" >&2
fi

# ── Test 9: Performance — exits under 1 second with 1000-entry inputs ─────
echo ""
echo "Test 9: Performance — 1000-entry inputs complete in under 1 second"

# Generate 1000-entry JSON
python3 -c "
import json
d = {f'ticket-{i:04d}': {'status': 'open', 'title': f'Ticket {i}'} for i in range(1000)}
print(json.dumps(d))
" > "$TMPDIR_TEST/perf_base.json"

python3 -c "
import json
d = {f'ticket-{i:04d}': {'status': 'open', 'title': f'Ticket {i}'} for i in range(1000)}
# Modify some to simulate ours changes
for i in range(0, 100):
    d[f'ticket-{i:04d}']['status'] = 'closed'
# Add new tickets from ours
for i in range(1000, 1100):
    d[f'ticket-{i:04d}'] = {'status': 'open', 'title': f'New Ticket {i}'}
print(json.dumps(d))
" > "$TMPDIR_TEST/perf_ours.json"

python3 -c "
import json
d = {f'ticket-{i:04d}': {'status': 'open', 'title': f'Ticket {i}'} for i in range(1000)}
# Add new tickets from theirs
for i in range(2000, 2100):
    d[f'ticket-{i:04d}'] = {'status': 'in_progress', 'title': f'Other Ticket {i}'}
print(json.dumps(d))
" > "$TMPDIR_TEST/perf_theirs.json"

cp "$TMPDIR_TEST/perf_ours.json" "$TMPDIR_TEST/perf_ours_work.json"

start_time=$(date +%s%N 2>/dev/null || date +%s)
exit_code=0
python3 "$SCRIPT" "$TMPDIR_TEST/perf_base.json" "$TMPDIR_TEST/perf_ours_work.json" "$TMPDIR_TEST/perf_theirs.json" 2>/dev/null || exit_code=$?
end_time=$(date +%s%N 2>/dev/null || date +%s)

if [[ "$exit_code" -eq 0 ]]; then
    # Calculate elapsed time in milliseconds
    if [[ "$start_time" =~ [0-9]{13,} ]]; then
        # nanoseconds available
        elapsed_ms=$(( (end_time - start_time) / 1000000 ))
    else
        # seconds only
        elapsed_ms=$(( (end_time - start_time) * 1000 ))
    fi
    if [[ "$elapsed_ms" -lt 1000 ]]; then
        (( ++PASS ))
        echo "  PASS: completed in ${elapsed_ms}ms (< 1000ms)"
    else
        (( ++FAIL ))
        echo "  FAIL: took ${elapsed_ms}ms (>= 1000ms)" >&2
    fi
else
    (( ++FAIL ))
    echo "  FAIL: script exited $exit_code" >&2
fi

# ── Test 10: Empty files (empty objects) merge cleanly ─────────────────────
echo ""
echo "Test 10: Empty JSON objects merge cleanly"
echo '{}' > "$TMPDIR_TEST/empty1.json"
echo '{}' > "$TMPDIR_TEST/empty2.json"
echo '{}' > "$TMPDIR_TEST/empty3.json"

cp "$TMPDIR_TEST/empty2.json" "$TMPDIR_TEST/empty2_work.json"
exit_code=0
python3 "$SCRIPT" "$TMPDIR_TEST/empty1.json" "$TMPDIR_TEST/empty2_work.json" "$TMPDIR_TEST/empty3.json" 2>/dev/null || exit_code=$?
if [[ "$exit_code" -eq 0 ]]; then
    result=$(python3 -c "import json; d=json.load(open('$TMPDIR_TEST/empty2_work.json')); print(d)")
    if [[ "$result" == "{}" ]]; then
        (( ++PASS ))
        echo "  PASS: empty inputs produce empty output"
    else
        (( ++FAIL ))
        echo "  FAIL: expected {}, got: $result" >&2
    fi
else
    (( ++FAIL ))
    echo "  FAIL: script exited $exit_code" >&2
fi

# ── Summary ────────────────────────────────────────────────────────────────
print_summary
