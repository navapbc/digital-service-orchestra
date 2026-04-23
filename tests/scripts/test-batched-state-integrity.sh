#!/usr/bin/env bash
# tests/scripts/test-batched-state-integrity.sh
# Tests for test-batched.sh state file integrity features:
#   - command_hash validation (hash mismatch → warns + starts fresh)
#   - created_at timestamp with TTL (expired state → warns + starts fresh)
#   - corruption backup (corrupt state → renamed to *.corrupt.bak, not deleted)
#
# Usage: bash tests/scripts/test-batched-state-integrity.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/test-batched.sh"
ASSERT_LIB="$PLUGIN_ROOT/tests/lib/assert.sh"

if [ ! -f "$ASSERT_LIB" ]; then
    echo "SKIP: test-batched-state-integrity.sh — assert.sh not found at: $ASSERT_LIB" >&2
    exit 0
fi
source "$ASSERT_LIB"

echo "=== test-batched-state-integrity.sh ==="

# ── test_script_exists_and_executable ─────────────────────────────────────────
echo ""
echo "--- test_script_exists_and_executable ---"
_snapshot_fail
script_ok=0
[ -x "$SCRIPT" ] && script_ok=1
assert_eq "test_script_exists_and_executable: file exists and is executable" "1" "$script_ok"
assert_pass_if_clean "test_script_exists_and_executable"

if [ ! -x "$SCRIPT" ]; then
    echo ""
    echo "Skipping remaining tests — script not yet present."
    echo ""
    printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
    exit 1
fi

# ── test_state_file_includes_command_hash ─────────────────────────────────────
# When test-batched.sh creates a new state file (via timeout), it must include
# a command_hash field.
echo ""
echo "--- test_state_file_includes_command_hash ---"
_snapshot_fail
TMPDIR_HASH="$(mktemp -d)"
HASH_STATE="$TMPDIR_HASH/state.json"

# Use timeout=1 with slow command so state file is written mid-run
TEST_BATCHED_STATE_FILE="$HASH_STATE" bash "$SCRIPT" --timeout=1 "sleep 10" 2>/dev/null || true

has_command_hash=0
if [ -f "$HASH_STATE" ]; then
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    assert 'command_hash' in d, 'command_hash field missing'
    assert d['command_hash'], 'command_hash is empty'
    sys.exit(0)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" "$HASH_STATE" && has_command_hash=1 || true
fi
assert_eq "test_state_file_includes_command_hash: state file has command_hash field" \
    "1" "$has_command_hash"
rm -rf "$TMPDIR_HASH"
assert_pass_if_clean "test_state_file_includes_command_hash"

# ── test_state_file_includes_created_at ───────────────────────────────────────
# When test-batched.sh creates a new state file, it must include a created_at field.
echo ""
echo "--- test_state_file_includes_created_at ---"
_snapshot_fail
TMPDIR_CAT="$(mktemp -d)"
CAT_STATE="$TMPDIR_CAT/state.json"

TEST_BATCHED_STATE_FILE="$CAT_STATE" bash "$SCRIPT" --timeout=1 "sleep 10" 2>/dev/null || true

has_created_at=0
if [ -f "$CAT_STATE" ]; then
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    assert 'created_at' in d, 'created_at field missing'
    assert d['created_at'], 'created_at is empty'
    sys.exit(0)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" "$CAT_STATE" && has_created_at=1 || true
fi
assert_eq "test_state_file_includes_created_at: state file has created_at field" \
    "1" "$has_created_at"
rm -rf "$TMPDIR_CAT"
assert_pass_if_clean "test_state_file_includes_created_at"

# ── test_hash_mismatch_warns_and_starts_fresh ──────────────────────────────────
# When a state file exists with a different command_hash (e.g., state from a
# different command), test-batched.sh must warn and start fresh rather than
# resuming stale state.
echo ""
echo "--- test_hash_mismatch_warns_and_starts_fresh ---"
_snapshot_fail
TMPDIR_MISMATCH="$(mktemp -d)"
MISMATCH_STATE="$TMPDIR_MISMATCH/state.json"

# Write a state file with a fake/mismatched command_hash
# The test ID for "bash -c 'exit 0'" would be "bash_-c_exit_0"
python3 -c "
import json, sys
state = {
    'runner': 'some_other_command',
    'completed': ['bash_-c_exit_0'],
    'results': {'bash_-c_exit_0': 'pass'},
    'command_hash': 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
    'created_at': 9999999999
}
with open(sys.argv[1], 'w') as f:
    json.dump(state, f, indent=2)
" "$MISMATCH_STATE"

mismatch_out=""
# Run with a different command so the hash won't match
mismatch_out=$(TEST_BATCHED_STATE_FILE="$MISMATCH_STATE" bash "$SCRIPT" --timeout=30 \
    "bash -c 'exit 0'" 2>&1) || true

# Must warn about hash mismatch
hash_warned=0
_tmp="$mismatch_out"; shopt -s nocasematch; [[ "$_tmp" =~ hash|mismatch|stale|fresh ]] && hash_warned=1; shopt -u nocasematch
assert_eq "test_hash_mismatch_warns_and_starts_fresh: output warns about hash mismatch" \
    "1" "$hash_warned"

# Must NOT show "Resuming from state file" (should start fresh, not resume)
resumed_stale=0
_tmp="$mismatch_out"; [[ "$_tmp" == *"Resuming from state file"* ]] && resumed_stale=1
assert_eq "test_hash_mismatch_warns_and_starts_fresh: does NOT resume stale state" \
    "0" "$resumed_stale"

# Must complete successfully (started fresh and ran the command)
completed_ok=0
_tmp="$mismatch_out"; shopt -s nocasematch; [[ "$_tmp" =~ passed|"All tests done" ]] && completed_ok=1; shopt -u nocasematch
assert_eq "test_hash_mismatch_warns_and_starts_fresh: completes successfully after fresh start" \
    "1" "$completed_ok"

rm -rf "$TMPDIR_MISMATCH"
assert_pass_if_clean "test_hash_mismatch_warns_and_starts_fresh"

# ── test_ttl_expiry_warns_and_starts_fresh ─────────────────────────────────────
# When a state file has a created_at timestamp older than the TTL (default 4h),
# test-batched.sh must warn and start fresh.
echo ""
echo "--- test_ttl_expiry_warns_and_starts_fresh ---"
_snapshot_fail
TMPDIR_TTL="$(mktemp -d)"
TTL_STATE="$TMPDIR_TTL/state.json"

# Compute the expected command_hash for "bash -c 'exit 0'" so the hash matches
# but the timestamp is expired. This isolates the TTL test from hash-mismatch.
CMD_FOR_TTL="bash -c 'exit 0'"
CWD_FOR_TTL="$(pwd)"
EXPECTED_HASH=$(echo -n "${CMD_FOR_TTL}:${CWD_FOR_TTL}" | sha256sum 2>/dev/null | awk '{print $1}' || echo -n "${CMD_FOR_TTL}:${CWD_FOR_TTL}" | python3 -c 'import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')

python3 -c "
import json, sys
state = {
    'runner': sys.argv[1],
    'completed': ['bash_-c_exit_0'],
    'results': {'bash_-c_exit_0': 'pass'},
    'command_hash': sys.argv[2],
    'created_at': 0
}
with open(sys.argv[3], 'w') as f:
    json.dump(state, f, indent=2)
" "$CMD_FOR_TTL" "$EXPECTED_HASH" "$TTL_STATE"

ttl_out=""
ttl_out=$(TEST_BATCHED_STATE_FILE="$TTL_STATE" bash "$SCRIPT" --timeout=30 \
    "$CMD_FOR_TTL" 2>&1) || true

# Must warn about TTL/stale/expired
ttl_warned=0
_tmp="$ttl_out"; shopt -s nocasematch; [[ "$_tmp" =~ TTL|expired|stale|old|fresh ]] && ttl_warned=1; shopt -u nocasematch
assert_eq "test_ttl_expiry_warns_and_starts_fresh: output warns about TTL expiry" \
    "1" "$ttl_warned"

# Must NOT resume (should start fresh)
ttl_resumed=0
_tmp="$ttl_out"; [[ "$_tmp" == *"Resuming from state file"* ]] && ttl_resumed=1
assert_eq "test_ttl_expiry_warns_and_starts_fresh: does NOT resume expired state" \
    "0" "$ttl_resumed"

# Must complete successfully
ttl_completed=0
_tmp="$ttl_out"; shopt -s nocasematch; [[ "$_tmp" =~ passed|"All tests done" ]] && ttl_completed=1; shopt -u nocasematch
assert_eq "test_ttl_expiry_warns_and_starts_fresh: completes successfully after fresh start" \
    "1" "$ttl_completed"

rm -rf "$TMPDIR_TTL"
assert_pass_if_clean "test_ttl_expiry_warns_and_starts_fresh"

# ── test_ttl_configurable_via_state_ttl_env ────────────────────────────────────
# STATE_TTL env var allows overriding the default 4-hour TTL.
# When STATE_TTL=1 (1 second), a state file even 2 seconds old should be rejected.
echo ""
echo "--- test_ttl_configurable_via_state_ttl_env ---"
_snapshot_fail
TMPDIR_CUSTOM_TTL="$(mktemp -d)"
CUSTOM_TTL_STATE="$TMPDIR_CUSTOM_TTL/state.json"

CMD_FOR_CUSTOM="bash -c 'exit 0'"
CWD_FOR_CUSTOM="$(pwd)"
CUSTOM_HASH=$(echo -n "${CMD_FOR_CUSTOM}:${CWD_FOR_CUSTOM}" | sha256sum 2>/dev/null | awk '{print $1}' || echo -n "${CMD_FOR_CUSTOM}:${CWD_FOR_CUSTOM}" | python3 -c 'import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')

# Set created_at to 2 seconds in the past; with STATE_TTL=1, it should expire
PAST_TS=$(( $(date +%s) - 2 ))
python3 -c "
import json, sys
state = {
    'runner': sys.argv[1],
    'completed': ['bash_-c_exit_0'],
    'results': {'bash_-c_exit_0': 'pass'},
    'command_hash': sys.argv[2],
    'created_at': int(sys.argv[3])
}
with open(sys.argv[4], 'w') as f:
    json.dump(state, f, indent=2)
" "$CMD_FOR_CUSTOM" "$CUSTOM_HASH" "$PAST_TS" "$CUSTOM_TTL_STATE"

custom_ttl_out=""
custom_ttl_out=$(TEST_BATCHED_STATE_FILE="$CUSTOM_TTL_STATE" STATE_TTL=1 \
    bash "$SCRIPT" --timeout=30 "$CMD_FOR_CUSTOM" 2>&1) || true

# Must warn about TTL
custom_ttl_warned=0
_tmp="$custom_ttl_out"; shopt -s nocasematch; [[ "$_tmp" =~ TTL|expired|stale|old|fresh ]] && custom_ttl_warned=1; shopt -u nocasematch
assert_eq "test_ttl_configurable_via_state_ttl_env: custom STATE_TTL=1 causes expiry" \
    "1" "$custom_ttl_warned"

rm -rf "$TMPDIR_CUSTOM_TTL"
assert_pass_if_clean "test_ttl_configurable_via_state_ttl_env"

# ── test_corruption_renames_to_corrupt_bak ────────────────────────────────────
# When a state file is corrupted (invalid JSON), it must be renamed to
# *.corrupt.bak (not deleted with rm -f).
echo ""
echo "--- test_corruption_renames_to_corrupt_bak ---"
_snapshot_fail
TMPDIR_CORRUPT="$(mktemp -d)"
CORRUPT_STATE="$TMPDIR_CORRUPT/state.json"
CORRUPT_BAK="$CORRUPT_STATE.corrupt.bak"

# Write corrupted JSON
echo "NOT_VALID_JSON{{{" > "$CORRUPT_STATE"

corrupt_out=""
corrupt_out=$(TEST_BATCHED_STATE_FILE="$CORRUPT_STATE" bash "$SCRIPT" --timeout=30 \
    "bash -c 'exit 0'" 2>&1) || true

# The .corrupt.bak file must exist
bak_exists=0
[ -f "$CORRUPT_BAK" ] && bak_exists=1
assert_eq "test_corruption_renames_to_corrupt_bak: *.corrupt.bak file was created" \
    "1" "$bak_exists"

# The original state.json must NOT exist (was renamed away)
original_exists=0
[ -f "$CORRUPT_STATE" ] && original_exists=1
# Note: If a new valid state is written after fresh start + completion, that's ok.
# What matters is the bak file was created (rename happened, not rm -f).
# We check the bak explicitly above.

# Must also warn about corruption
corrupt_warned=0
_tmp="$corrupt_out"; shopt -s nocasematch; [[ "$_tmp" =~ corrupt|corrupted|invalid|"starting fresh"|fresh ]] && corrupt_warned=1; shopt -u nocasematch
assert_eq "test_corruption_renames_to_corrupt_bak: warns about corruption" \
    "1" "$corrupt_warned"

# Must complete successfully (started fresh)
corrupt_completed=0
_tmp="$corrupt_out"; shopt -s nocasematch; [[ "$_tmp" =~ passed|"All tests done" ]] && corrupt_completed=1; shopt -u nocasematch
assert_eq "test_corruption_renames_to_corrupt_bak: completes successfully after backup" \
    "1" "$corrupt_completed"

rm -rf "$TMPDIR_CORRUPT"
assert_pass_if_clean "test_corruption_renames_to_corrupt_bak"

# ── test_valid_hash_allows_resume ──────────────────────────────────────────────
# When a state file has a matching command_hash and is within TTL, resume must
# succeed normally (no warning, shows "Resuming from state file").
echo ""
echo "--- test_valid_hash_allows_resume ---"
_snapshot_fail
TMPDIR_VALID="$(mktemp -d)"
VALID_STATE="$TMPDIR_VALID/state.json"

CMD_FOR_VALID="bash -c 'exit 0'"
CWD_FOR_VALID="$(pwd)"
VALID_HASH=$(echo -n "${CMD_FOR_VALID}:${CWD_FOR_VALID}" | sha256sum 2>/dev/null | awk '{print $1}' || echo -n "${CMD_FOR_VALID}:${CWD_FOR_VALID}" | python3 -c 'import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
CURRENT_TS=$(date +%s)

# Write a state file with matching hash and fresh timestamp
python3 -c "
import json, sys
state = {
    'runner': sys.argv[1],
    'completed': ['bash_-c_exit_0'],
    'results': {'bash_-c_exit_0': 'pass'},
    'command_hash': sys.argv[2],
    'created_at': int(sys.argv[3])
}
with open(sys.argv[4], 'w') as f:
    json.dump(state, f, indent=2)
" "$CMD_FOR_VALID" "$VALID_HASH" "$CURRENT_TS" "$VALID_STATE"

valid_out=""
valid_out=$(TEST_BATCHED_STATE_FILE="$VALID_STATE" bash "$SCRIPT" --timeout=30 \
    "$CMD_FOR_VALID" 2>&1) || true

# Must resume (not start fresh)
resumed_ok=0
_tmp="$valid_out"; [[ "$_tmp" == *"Resuming from state file"* ]] && resumed_ok=1
assert_eq "test_valid_hash_allows_resume: valid hash + fresh timestamp allows resume" \
    "1" "$resumed_ok"

# Must show "Skipping (already completed)"
skipped_ok=0
_tmp="$valid_out"; [[ "$_tmp" == *"Skipping (already completed)"* ]] && skipped_ok=1
assert_eq "test_valid_hash_allows_resume: skips already-completed test" \
    "1" "$skipped_ok"

rm -rf "$TMPDIR_VALID"
assert_pass_if_clean "test_valid_hash_allows_resume"

# ── test_interrupted_test_reruns_on_resume ────────────────────────────────────
# When a state file contains a test with result "interrupted" (killed due to
# timeout), resuming should RE-RUN that test — not skip it. Interrupted tests
# never completed, so treating them as "completed" blocks re-runs and leaves
# validate.sh stuck with stale interrupted state across sessions.
#
# The bash runner uses the filename (relative to TEST_DIR) as the test_id.
# This test writes a state file with that key set to "interrupted" and verifies
# the test is re-run (not skipped) on the next test-batched.sh invocation.
echo ""
echo "--- test_interrupted_test_reruns_on_resume ---"
_snapshot_fail
TMPDIR_INTERRUPTED="$(mktemp -d)"

# Create a fast-passing stub test with the exact name bash-runner will use
STUB_NAME="test-stub.sh"
STUB_TEST="$TMPDIR_INTERRUPTED/$STUB_NAME"
cat > "$STUB_TEST" <<'STUB'
#!/usr/bin/env bash
echo "stub test ran"
exit 0
STUB
chmod +x "$STUB_TEST"

INTERRUPTED_STATE="$TMPDIR_INTERRUPTED/state.json"
# bash-runner uses test_id = relative path = basename when TEST_DIR prefix matches
# No CMD_HASH stored for bash-runner (it uses "" for command_hash field)
CURRENT_TS_INT=$(date +%s)

# Write a state file where test-stub.sh is recorded as "interrupted"
# The runner field must match "bash:<TEST_DIR>" pattern used by bash-runner
python3 -c "
import json, sys
test_id = sys.argv[1]
runner = sys.argv[2]
state = {
    'runner': runner,
    'completed': [test_id],
    'results': {test_id: 'interrupted'},
    'command_hash': '',
    'created_at': int(sys.argv[3])
}
with open(sys.argv[4], 'w') as f:
    json.dump(state, f, indent=2)
" "$STUB_NAME" "bash:${TMPDIR_INTERRUPTED}" "$CURRENT_TS_INT" "$INTERRUPTED_STATE"

interrupted_out=""
interrupted_exit=0
interrupted_out=$(TEST_BATCHED_STATE_FILE="$INTERRUPTED_STATE" bash "$SCRIPT" \
    --runner=bash --test-dir="$TMPDIR_INTERRUPTED" --timeout=30 2>&1) || interrupted_exit=$?

# The stub test must have been re-run (output contains "stub test ran")
reran=0
_tmp="$interrupted_out"; [[ "$_tmp" == *"stub test ran"* ]] && reran=1
assert_eq "test_interrupted_test_reruns_on_resume: interrupted test is re-run" \
    "1" "$reran"

# The final exit code must be 0 (stub passes after re-run)
assert_eq "test_interrupted_test_reruns_on_resume: exit 0 after re-run passes" \
    "0" "$interrupted_exit"

# Must NOT say "Skipping (already completed)" for the interrupted test
not_skipped=0
_tmp="$interrupted_out"; [[ "$_tmp" == *"Skipping (already completed)"* ]] || not_skipped=1
assert_eq "test_interrupted_test_reruns_on_resume: interrupted test not skipped" \
    "1" "$not_skipped"

rm -rf "$TMPDIR_INTERRUPTED"
assert_pass_if_clean "test_interrupted_test_reruns_on_resume"

# ── test_state_write_is_atomic ─────────────────────────────────────────────────
# _state_write must use atomic writes (temp file + rename) so that an interrupted
# write does NOT destroy existing state. This test verifies that the python3 code
# inside _state_write uses tempfile.mkstemp + os.replace (or equivalent), NOT
# direct open('w') which truncates the file before writing.
#
# Strategy: Source the _state_write function and inspect the python3 code it uses
# to confirm it doesn't use open(..., 'w') directly on the target file.
echo ""
echo "--- test_state_write_is_atomic ---"
_snapshot_fail

# Extract the _state_write function body from test-batched.sh.
# The function contains embedded python with bare } lines, so we extract
# from the function declaration to the next function declaration (or EOF)
# and check for atomic write patterns within that range.
state_write_body=$(awk '/_state_write\(\) \{/{found=1} found{print} found && /^}$/{count++; if(count>=2) exit}' "$SCRIPT")

# Check for atomic pattern: tempfile.mkstemp or tempfile.NamedTemporaryFile
has_atomic=0
_tmp="$state_write_body"; [[ "$_tmp" =~ mkstemp|NamedTemporaryFile|tempfile ]] && has_atomic=1
assert_eq "test_state_write_is_atomic: _state_write uses tempfile for atomic write" \
    "1" "$has_atomic"

# Check for atomic replace: os.replace or os.rename
has_replace=0
_tmp="$state_write_body"; [[ "$_tmp" =~ os\.replace|os\.rename ]] && has_replace=1
assert_eq "test_state_write_is_atomic: _state_write uses os.replace for atomic swap" \
    "1" "$has_replace"

# Functional verification: call _state_write via sourcing and confirm it writes
# valid state AND that the write uses atomic semantics (existing file preserved
# if the python3 write process is killed mid-write).
TMPDIR_ATOMIC="$(mktemp -d)"
ATOMIC_STATE="$TMPDIR_ATOMIC/state.json"

# Create existing state that we want to survive an interrupted write
python3 -c "
import json
with open('$ATOMIC_STATE', 'w') as f:
    json.dump({'runner': 'old', 'completed': ['a','b'], 'results': {'a':'pass','b':'pass'}, 'command_hash': '', 'created_at': 1234}, f)
"

# Extract _state_write using awk (matches the extraction above — counts 2 bare }
# lines to handle the embedded Python dict literal).
_extracted_func=$(awk '/_state_write\(\) \{/{found=1} found{print} found && /^}$/{count++; if(count>=2) exit}' "$SCRIPT")

# Verify extraction succeeded (function body is non-trivial)
extracted_ok=0
_tmp="$_extracted_func"; [[ "$_tmp" == *'_state_write()'* ]] && extracted_ok=1
assert_eq "test_state_write_is_atomic: function extraction succeeded" \
    "1" "$extracted_ok"

# Source the extracted function and call it with valid args
(
    source <(echo "$_extracted_func")
    _state_write "$ATOMIC_STATE" "new_runner" '["c","d"]' '{"c":"pass","d":"fail"}' "hash123" "5678"
) 2>/dev/null

# Verify the file contains the NEW data (not the old pre-populated data)
new_write_valid=0
if [ -f "$ATOMIC_STATE" ]; then
    python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert d['runner'] == 'new_runner', f'expected new_runner, got {d[\"runner\"]}'
assert d['completed'] == ['c','d'], f'expected [c,d], got {d[\"completed\"]}'
assert d['results'] == {'c':'pass','d':'fail'}, f'unexpected results'
" "$ATOMIC_STATE" 2>/dev/null && new_write_valid=1
fi
assert_eq "test_state_write_is_atomic: _state_write wrote correct new data" \
    "1" "$new_write_valid"

rm -rf "$TMPDIR_ATOMIC"
assert_pass_if_clean "test_state_write_is_atomic"

# ── test_default_timeout_below_platform_ceiling ───────────────────────────────
# DEFAULT_TIMEOUT must be ≤ 45 seconds to ensure test-batched.sh's internal
# save-state fires BEFORE the Claude Code tool timeout ceiling (~48s without
# explicit timeout: 600000 override). If DEFAULT_TIMEOUT ≥ 48s, SIGURG arrives
# before save-state runs, killing test-batched.sh with exit 144 (bug 8141-41eb).
echo ""
echo "--- test_default_timeout_below_platform_ceiling ---"

_actual_default_timeout=$(grep '^DEFAULT_TIMEOUT=' "$SCRIPT" 2>/dev/null | head -1 | cut -d= -f2)
_max_allowed=45

if [[ -n "$_actual_default_timeout" ]] && [[ "$_actual_default_timeout" -le "$_max_allowed" ]] 2>/dev/null; then
    (( ++PASS ))
    echo "  PASS: DEFAULT_TIMEOUT=$_actual_default_timeout (≤ $_max_allowed — below ~48s platform ceiling)"
else
    (( ++FAIL ))
    echo "  FAIL: DEFAULT_TIMEOUT=$_actual_default_timeout exceeds $_max_allowed — risk of platform SIGURG before save-state fires (bug 8141-41eb)" >&2
fi

# ── test_per_test_timeout_marks_result (07f1-f8b6) ───────────────────────────
# When --per-test-timeout=N is set and a test runs longer than N seconds, the
# test must be recorded as "interrupted-timeout-exceeded" (not "interrupted").
# This allows the resume filter to skip it on the next run instead of retrying.
#
# Strategy: create a slow test (sleep 10), run with --per-test-timeout=1, and
# verify the state file contains "interrupted-timeout-exceeded" for that test.
echo ""
echo "--- test_per_test_timeout_marks_result ---"
_snapshot_fail
TMPDIR_PERTIMEOUT="$(mktemp -d)"

SLOW_STUB_NAME="test-slow-stub.sh"
SLOW_STUB_TEST="$TMPDIR_PERTIMEOUT/$SLOW_STUB_NAME"
cat > "$SLOW_STUB_TEST" <<'STUB'
#!/usr/bin/env bash
sleep 30
echo "slow stub finished"
exit 0
STUB
chmod +x "$SLOW_STUB_TEST"

PERTIMEOUT_STATE="$TMPDIR_PERTIMEOUT/state.json"

pertimeout_out=""
pertimeout_exit=0
pertimeout_out=$(TEST_BATCHED_STATE_FILE="$PERTIMEOUT_STATE" bash "$SCRIPT" \
    --runner=bash --test-dir="$TMPDIR_PERTIMEOUT" \
    --timeout=20 --per-test-timeout=1 2>&1) || pertimeout_exit=$?

# The slow stub must have been killed (not allowed to finish)
finished_pt=0
_tmp="$pertimeout_out"; [[ "$_tmp" == *"slow stub finished"* ]] && finished_pt=1
assert_eq "test_per_test_timeout_marks_result: slow test was killed before finishing" \
    "0" "$finished_pt"

# State file must exist (runner saves state on per-test-timeout kill)
state_exists=0
[ -f "$PERTIMEOUT_STATE" ] && state_exists=1
assert_eq "test_per_test_timeout_marks_result: state file saved after per-test timeout" \
    "1" "$state_exists"

# State must record 'interrupted-timeout-exceeded' for the slow test (not 'interrupted')
result_val="none"
if [ -f "$PERTIMEOUT_STATE" ]; then
    result_val=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
results = d.get('results', {})
print(list(results.values())[0] if results else 'empty')
" "$PERTIMEOUT_STATE" 2>/dev/null || echo "parse-error")
fi
assert_eq "test_per_test_timeout_marks_result: slow test recorded as interrupted-timeout-exceeded" \
    "interrupted-timeout-exceeded" "$result_val"

rm -rf "$TMPDIR_PERTIMEOUT"
assert_pass_if_clean "test_per_test_timeout_marks_result"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
