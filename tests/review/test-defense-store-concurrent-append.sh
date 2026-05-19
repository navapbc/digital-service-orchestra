#!/usr/bin/env bash
# tests/review/test-defense-store-concurrent-append.sh
# SDET audit P1-1: defense-store concurrent-append integrity test.
#
# Verifies that concurrent invocations of defense_store_write against the
# same ticket-bound store do not corrupt the persisted record set and do
# not silently drop records. The store backend is TICKET_CMD; we inject a
# fake CLI that appends comments to a shared file under flock to simulate
# the canonical concurrency boundary.
#
# Usage: bash tests/review/test-defense-store-concurrent-append.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DEFENSE_STORE="$REPO_ROOT/plugins/dso/scripts/review-defense-store.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-defense-store-concurrent-append.sh ==="

if [[ ! -f "$DEFENSE_STORE" ]]; then
    echo "SKIP: $DEFENSE_STORE not found — defense store not implemented yet"
    echo ""
    printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
    exit 0
fi

# ─── Fake ticket CLI ──────────────────────────────────────────────────────────
# Writes each `comment` invocation to a shared log under flock so concurrent
# appenders cannot interleave bytes mid-record. This models the canonical
# atomic-append contract the real ticket CLI provides.
TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/defense-concurrent-XXXXXX")
trap 'rm -rf "$TEST_TMPDIR"' EXIT

FAKE_TICKET_LOG="$TEST_TMPDIR/ticket-comments.log"
: > "$FAKE_TICKET_LOG"

FAKE_TICKET_CMD="$TEST_TMPDIR/fake-ticket.sh"
cat > "$FAKE_TICKET_CMD" <<EOF
#!/usr/bin/env bash
# fake ticket CLI: honors 'comment <ticket_id> <message>' (the actual contract
# used by defense_store_write at review-defense-store.sh:127).
set -uo pipefail
if [[ "\${1:-}" == "comment" ]]; then
    shift
    ticket_id="\${1:-unknown}"
    shift
    msg="\${1:-}"
    # Atomic append under flock — POSIX guarantees atomic short writes.
    {
        flock 9 2>/dev/null || true
        # Escape newlines so each log entry is a single line for grep/wc.
        msg_escaped=\$(printf '%s' "\$msg" | tr '\n' ' ')
        printf '%s|%s\n' "\$ticket_id" "\$msg_escaped" >> "$FAKE_TICKET_LOG"
    } 9>>"$FAKE_TICKET_LOG.lock"
    exit 0
fi
exit 0
EOF
chmod +x "$FAKE_TICKET_CMD"

# Minimal valid defense record JSON. severity_history must be non-empty.
_make_defense_json() {
    local idx="$1"
    cat <<EOF
{
  "prior_finding_id": "F${idx}",
  "cited_lines_fingerprint": "$(printf '%064d' "$idx")",
  "defense_text": "Defense record number $idx — concurrent append test",
  "defender": "test:concurrent-append",
  "cycle_number": 1,
  "timestamp": "2026-05-19T20:00:00Z",
  "severity_history": [{"cycle": 1, "severity": "important", "relation": null}],
  "ticket_id": "concurrent-test-ticket"
}
EOF
}

# ─── Test 1 — N concurrent writers, all records present, no corruption ───────
echo ""
echo "--- test_n_concurrent_writers_all_records_present ---"

test_n_concurrent_writers_all_records_present() {
    _snapshot_fail

    local n=10
    local pids=()
    local i
    for i in $(seq 1 "$n"); do
        (
            # shellcheck disable=SC2030
            DSO_SESSION_TICKET_ID="concurrent-test-ticket"; export DSO_SESSION_TICKET_ID
            # shellcheck disable=SC2030
            TICKET_CMD="$FAKE_TICKET_CMD"; export TICKET_CMD
            source "$DEFENSE_STORE" 2>/dev/null
            defense_store_write "$(_make_defense_json "$i")" >/dev/null 2>&1
        ) &
        pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done

    # Every writer should have produced exactly one comment line.
    local count
    count=$(wc -l < "$FAKE_TICKET_LOG" | tr -d ' ')
    assert_eq "n concurrent writers produced n records" "$n" "$count"

    # No record should be empty or have a corrupt prefix — every line starts
    # with the ticket_id followed by '|'.
    local malformed
    malformed=$(grep -cvE '^concurrent-test-ticket\|' "$FAKE_TICKET_LOG" || true)
    assert_eq "no malformed record lines" "0" "$malformed"

    assert_pass_if_clean "test_n_concurrent_writers_all_records_present"
}
test_n_concurrent_writers_all_records_present

# ─── Test 2 — distinct prior_finding_ids preserved across writers ────────────
echo ""
echo "--- test_distinct_finding_ids_preserved ---"

test_distinct_finding_ids_preserved() {
    _snapshot_fail
    : > "$FAKE_TICKET_LOG"

    local n=10
    local pids=()
    local i
    for i in $(seq 1 "$n"); do
        (
            # shellcheck disable=SC2030
            DSO_SESSION_TICKET_ID="concurrent-test-ticket"; export DSO_SESSION_TICKET_ID
            # shellcheck disable=SC2030
            TICKET_CMD="$FAKE_TICKET_CMD"; export TICKET_CMD
            source "$DEFENSE_STORE" 2>/dev/null
            defense_store_write "$(_make_defense_json "$i")" >/dev/null 2>&1
        ) &
        pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done

    # Each record's defense_text should reference a unique finding index.
    local unique_indexes
    unique_indexes=$(grep -oE 'Defense record number [0-9]+' "$FAKE_TICKET_LOG" | sort -u | wc -l | tr -d ' ')
    assert_eq "all $n distinct finding indexes survived" "$n" "$unique_indexes"

    assert_pass_if_clean "test_distinct_finding_ids_preserved"
}
test_distinct_finding_ids_preserved

print_summary
