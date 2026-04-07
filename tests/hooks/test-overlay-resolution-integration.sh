#!/usr/bin/env bash
# tests/hooks/test-overlay-resolution-integration.sh
# RED tests for overlay findings resolution loop integration (story w22-agl5, task ad04-e56f)
#
# Tests the expected interface of plugins/dso/hooks/resolve-overlay-findings.sh, which will
# be implemented by task db57-82d7. All tests FAIL because the script does not exist yet.
#
# Interface contract under test:
#   resolve-overlay-findings.sh [--findings-json <path>] [--ticket-cmd <path>]
#                                [--write-findings-cmd <path>]
#
#   Exit codes:
#     0  = no blocking findings (minor or empty); commit may proceed
#     1  = critical or important findings present; commit is blocked
#
#   Stdout signals:
#     OVERLAY_TICKET_CREATED:<id>  — emitted once per minor finding when a tracking ticket
#                                    is created; <id> is the ticket ID returned by ticket create
#     OVERLAY_WRITE_COUNT:<n>      — emitted before exit; n is the number of times
#                                    write-reviewer-findings.sh was called (must be 1 for any
#                                    non-empty findings input, regardless of overlay count)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"

INTEGRATION_HOOK="$REPO_ROOT/plugins/dso/hooks/resolve-overlay-findings.sh"

# --- Temp dir setup ---

_TEST_TMPDIRS=()
_new_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}
trap 'rm -rf "${_TEST_TMPDIRS[@]:-}"' EXIT

# --- Helpers ---

# Run the integration hook with optional extra args.
# Usage: run_integration [extra_args...]
# Sets: INTEGRATION_OUTPUT (stdout), INTEGRATION_EXIT (exit code)
run_integration() {
    INTEGRATION_OUTPUT=""
    INTEGRATION_EXIT=0
    INTEGRATION_OUTPUT=$(bash "$INTEGRATION_HOOK" "$@" 2>/dev/null) || INTEGRATION_EXIT=$?
}

# Build a minimal overlay findings JSON file with the given severity.
# Usage: make_findings_file <dir> <severity> [<source_label>]
# Returns: path to the file via stdout
make_findings_file() {
    local dir="$1" severity="$2" source_label="${3:-security}"
    local path="$dir/findings-${source_label}.json"
    python3 - "$path" "$severity" "$source_label" <<'PYEOF'
import json, sys
path, severity, source = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {
    "scores": {"correctness": 4},
    "findings": [
        {
            "severity": severity,
            "description": f"[TOCTOU] Test finding from {source} overlay.",
            "file": "scripts/example.sh",
            "category": "correctness"
        }
    ],
    "summary": f"One {severity} finding from {source}."
}
with open(path, "w") as f:
    json.dump(payload, f)
print(path)
PYEOF
}

# Build an empty overlay findings JSON file (findings array is empty).
# Usage: make_empty_findings_file <dir>
make_empty_findings_file() {
    local dir="$1"
    local path="$dir/findings-empty.json"
    python3 -c "
import json, sys
payload = {'scores': {'correctness': 10}, 'findings': [], 'summary': 'No issues.'}
with open('$path', 'w') as f:
    json.dump(payload, f)
print('$path')
"
}

# A write-reviewer-findings.sh stub that logs each invocation to a counter file
# and exits 0.
# Usage: make_write_stub <dir>
# Returns: path to the stub via stdout
make_write_stub() {
    local dir="$1"
    local stub="$dir/write-stub.sh"
    local log="$dir/write-calls.log"
    cat > "$stub" <<STUBEOF
#!/usr/bin/env bash
# Stub: log each invocation, consume stdin, exit 0
echo "called" >> "$log"
cat > /dev/null
echo "fake-hash-000000000000000000000000000000000000000000000000000000000000"
STUBEOF
    chmod +x "$stub"
    echo "$stub"
}

# ============================================================
# test_critical_finding_blocks_commit
# Arrange: overlay findings JSON with a critical-severity finding.
# Act:     call resolve-overlay-findings.sh with the findings file.
# Assert:  exit code is non-zero (commit is blocked).
# ============================================================
tmpdir=$(_new_tmpdir)
findings_file=$(make_findings_file "$tmpdir" "critical" "security")
write_stub=$(make_write_stub "$tmpdir")

run_integration \
    --findings-json "$findings_file" \
    --write-findings-cmd "$write_stub"

assert_ne "test_critical_finding_blocks_commit: exit code must be non-zero" \
    "0" "$INTEGRATION_EXIT"

# ============================================================
# test_important_finding_blocks_commit
# Arrange: overlay findings JSON with an important-severity finding.
# Act:     call resolve-overlay-findings.sh with the findings file.
# Assert:  exit code is non-zero (commit is blocked).
# ============================================================
tmpdir=$(_new_tmpdir)
findings_file=$(make_findings_file "$tmpdir" "important" "performance")
write_stub=$(make_write_stub "$tmpdir")

run_integration \
    --findings-json "$findings_file" \
    --write-findings-cmd "$write_stub"

assert_ne "test_important_finding_blocks_commit: exit code must be non-zero" \
    "0" "$INTEGRATION_EXIT"

# ============================================================
# test_minor_finding_does_not_block_commit
# Arrange: overlay findings JSON with a minor-severity finding.
# Act:     call resolve-overlay-findings.sh with the findings file.
# Assert:  exit code is 0 (commit is not blocked).
# ============================================================
tmpdir=$(_new_tmpdir)
findings_file=$(make_findings_file "$tmpdir" "minor" "security")
write_stub=$(make_write_stub "$tmpdir")
ticket_log="$tmpdir/ticket.log"

export TICKET_LOG_FILE="$ticket_log"
run_integration \
    --findings-json "$findings_file" \
    --ticket-cmd "$REPO_ROOT/tests/lib/fake-ticket.sh" \
    --write-findings-cmd "$write_stub"
unset TICKET_LOG_FILE

assert_eq "test_minor_finding_does_not_block_commit: exit code must be 0" \
    "0" "$INTEGRATION_EXIT"

# ============================================================
# test_minor_finding_creates_tracking_ticket
# Arrange: overlay findings JSON with a minor-severity finding and a fake ticket cmd.
# Act:     call resolve-overlay-findings.sh.
# Assert:  stdout contains OVERLAY_TICKET_CREATED signal, indicating a ticket was created.
# ============================================================
tmpdir=$(_new_tmpdir)
findings_file=$(make_findings_file "$tmpdir" "minor" "performance")
write_stub=$(make_write_stub "$tmpdir")
ticket_log="$tmpdir/ticket.log"

export TICKET_LOG_FILE="$ticket_log"
run_integration \
    --findings-json "$findings_file" \
    --ticket-cmd "$REPO_ROOT/tests/lib/fake-ticket.sh" \
    --write-findings-cmd "$write_stub"
unset TICKET_LOG_FILE

assert_contains "test_minor_finding_creates_tracking_ticket: stdout must contain OVERLAY_TICKET_CREATED" \
    "OVERLAY_TICKET_CREATED:" "$INTEGRATION_OUTPUT"

# ============================================================
# test_single_writer_compliance_multiple_overlays
# Arrange: two findings files (security + performance), each with one finding.
# Act:     call resolve-overlay-findings.sh with both files.
# Assert:  write-reviewer-findings.sh is called exactly once (OVERLAY_WRITE_COUNT:1).
#          The single-writer invariant means the orchestrator aggregates and writes once,
#          not once per overlay source.
# ============================================================
tmpdir=$(_new_tmpdir)
findings_security=$(make_findings_file "$tmpdir" "critical" "security")
findings_perf=$(make_findings_file "$tmpdir" "important" "performance")
write_stub=$(make_write_stub "$tmpdir")
write_calls_log="$tmpdir/write-calls.log"

run_integration \
    --findings-json "$findings_security" \
    --findings-json "$findings_perf" \
    --write-findings-cmd "$write_stub"

# Count actual write stub invocations from the log
write_call_count=0
if [[ -f "$write_calls_log" ]]; then
    write_call_count=$(wc -l < "$write_calls_log" | tr -d ' ')
fi

assert_eq "test_single_writer_compliance_multiple_overlays: write stub called exactly once" \
    "1" "$write_call_count"

assert_contains "test_single_writer_compliance_multiple_overlays: OVERLAY_WRITE_COUNT must be 1" \
    "OVERLAY_WRITE_COUNT:1" "$INTEGRATION_OUTPUT"

# ============================================================
# test_empty_findings_returns_success_no_side_effects
# Arrange: findings file with an empty findings array.
# Act:     call resolve-overlay-findings.sh.
# Assert:  exit code is 0; no OVERLAY_TICKET_CREATED signal emitted;
#          write-reviewer-findings.sh is NOT called (nothing to write).
# ============================================================
tmpdir=$(_new_tmpdir)
findings_file=$(make_empty_findings_file "$tmpdir")
write_stub=$(make_write_stub "$tmpdir")
write_calls_log="$tmpdir/write-calls.log"
ticket_log="$tmpdir/ticket.log"

export TICKET_LOG_FILE="$ticket_log"
run_integration \
    --findings-json "$findings_file" \
    --ticket-cmd "$REPO_ROOT/tests/lib/fake-ticket.sh" \
    --write-findings-cmd "$write_stub"
unset TICKET_LOG_FILE

assert_eq "test_empty_findings_returns_success: exit code must be 0" \
    "0" "$INTEGRATION_EXIT"

write_call_count=0
if [[ -f "$write_calls_log" ]]; then
    write_call_count=$(wc -l < "$write_calls_log" | tr -d ' ')
fi

assert_eq "test_empty_findings_no_write_side_effect: write stub must not be called" \
    "0" "$write_call_count"

# No OVERLAY_TICKET_CREATED signal should appear for empty findings
ticket_signal_present=0
if [[ "$INTEGRATION_OUTPUT" == *"OVERLAY_TICKET_CREATED:"* ]]; then
    ticket_signal_present=1
fi
assert_eq "test_empty_findings_no_ticket_signal: no OVERLAY_TICKET_CREATED for empty findings" \
    "0" "$ticket_signal_present"

# ============================================================
# test_fragile_finding_blocks_commit
# Given:  overlay findings JSON with a fragile-severity finding.
# When:   resolve-overlay-findings.sh is called with that findings file.
# Then:   exit code is non-zero (fragile is treated as blocking).
#
# RED: The script's has_blocking check only matches "critical" and "important";
#      "fragile" is not included, so the script exits 0 instead of 1.
# ============================================================
tmpdir=$(_new_tmpdir)
findings_file=$(make_findings_file "$tmpdir" "fragile" "correctness")
write_stub=$(make_write_stub "$tmpdir")

run_integration \
    --findings-json "$findings_file" \
    --write-findings-cmd "$write_stub"

assert_ne "test_fragile_finding_blocks_commit: exit code must be non-zero (fragile is blocking)" \
    "0" "$INTEGRATION_EXIT"

# ============================================================
# test_fragile_finding_score_is_3
# Given:  overlay findings JSON with a fragile-severity finding mapped to category
#         "correctness".
# When:   resolve-overlay-findings.sh is called and invokes write-reviewer-findings.sh.
# Then:   the JSON piped to the write stub contains a correctness score of 3
#         (fragile maps to score 3, same as important — not the default fallback of 4).
#
# RED: severity_to_score does not include "fragile", so .get("fragile", 4) returns 4,
#      and the correctness dimension score will be 4 instead of the expected 3.
# ============================================================
tmpdir=$(_new_tmpdir)
findings_file=$(make_findings_file "$tmpdir" "fragile" "correctness")

# Capture-stdin write stub: logs the JSON payload it receives via stdin.
capture_stub="$tmpdir/capture-write-stub.sh"
captured_json="$tmpdir/captured-findings.json"
cat > "$capture_stub" <<STUBEOF
#!/usr/bin/env bash
# Capture-stdin stub: saves stdin to a file, returns a fake hash.
cat > "$captured_json"
echo "fake-hash-000000000000000000000000000000000000000000000000000000000000"
STUBEOF
chmod +x "$capture_stub"

run_integration \
    --findings-json "$findings_file" \
    --write-findings-cmd "$capture_stub"

# Extract the correctness score from the captured JSON payload.
correctness_score=$(python3 -c "
import json, sys
try:
    with open('$captured_json') as fh:
        data = json.load(fh)
    print(data.get('scores', {}).get('correctness', 'missing'))
except Exception as e:
    print('missing')
")

assert_eq "test_fragile_finding_score_is_3: correctness score for fragile must be 3" \
    "3" "$correctness_score"

print_summary
