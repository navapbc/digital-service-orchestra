#!/usr/bin/env bash
# tests/scripts/test-review-defense-store-pr-keyed.sh
# Behavioral tests for plugins/dso/scripts/review-defense-store.sh —
# --pr-number key support and sentinel readback (v1.2.0 grammar).
#
# RED until review-defense-store.sh supports --pr-number on write and
# defense_store_list_by_pr for keyed readback.
#
# Usage: bash tests/scripts/test-review-defense-store-pr-keyed.sh
# Returns: exit 1 (RED) until implementation is present.

# NOTE: -e intentionally omitted — test functions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DEFENSE_STORE="$REPO_ROOT/plugins/dso/scripts/review-defense-store.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-review-defense-store-pr-keyed.sh ==="

# =============================================================================
# Test 1 — defense_store_write accepts --pr-number and embeds pr_number in
#           the written DEFENSE_RECORD output
#
# Given: a defense record JSON and --pr-number 42 flag
# When: defense_store_write --pr-number 42 is called with TICKET_CMD=echo
# Then: stdout contains a JSON record with pr_number=42
# =============================================================================
echo ""
echo "--- test_defense_store_write_accepts_pr_number ---"

test_defense_store_write_accepts_pr_number() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_write_accepts_pr_number\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local captured_output exit_code=0
    captured_output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID=TEST-PR-1
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="echo"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        record=$(python3 -c "
import json
print(json.dumps({
    'ticket_id': 'TEST-PR-1',
    'prior_finding_id': 'f-pr-abc',
    'defense_text': 'defense for pr 42',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}]
}))
")
        defense_store_write --pr-number 42 "$record" 2>/dev/null
    ) || exit_code=$?

    assert_eq "test_defense_store_write_accepts_pr_number: exits 0" "0" "$exit_code"

    # Output JSON must contain pr_number=42
    local has_pr_number=0
    if python3 -c "
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(1)
# Output may be prefixed with TICKET_CMD args; find the JSON part
for line in raw.split('\n'):
    try:
        data = json.loads(line)
        if data.get('pr_number') == 42:
            sys.exit(0)
    except (json.JSONDecodeError, ValueError):
        continue
# Try finding JSON in the last token (TICKET_CMD=echo emits: <ticket_id> DEFENSE_RECORD: {...})
for line in raw.split('\n'):
    parts = line.split('DEFENSE_RECORD: ', 1)
    if len(parts) == 2:
        try:
            data = json.loads(parts[1])
            if data.get('pr_number') == 42:
                sys.exit(0)
        except (json.JSONDecodeError, ValueError):
            pass
# Try parsing the output directly as JSON (when TICKET_CMD=echo, stdout has the enriched JSON)
try:
    data = json.loads(raw)
    if data.get('pr_number') == 42:
        sys.exit(0)
except (json.JSONDecodeError, ValueError):
    pass
sys.exit(1)
" <<< "$captured_output" 2>/dev/null; then
        has_pr_number=1
    fi
    assert_eq "test_defense_store_write_accepts_pr_number: output JSON has pr_number=42" \
        "1" "$has_pr_number"

    assert_pass_if_clean "test_defense_store_write_accepts_pr_number"
}

test_defense_store_write_accepts_pr_number

# =============================================================================
# Test 2 — defense_store_list_by_pr returns records keyed by the given
#           pr_number, including sentinel (pr_number=0) entries
#
# Given: a store with:
#   - a v1.2.0 defense record with pr_number=42
#   - a legacy/sentinel DEFENSE_RECORD comment with no pr_number field (=> 0)
# When: defense_store_list_by_pr 42 is called
# Then: returns both the pr=42 record AND the sentinel/legacy record
# =============================================================================
echo ""
echo "--- test_defense_store_list_by_pr_returns_keyed_and_sentinel ---"

test_defense_store_list_by_pr_returns_keyed_and_sentinel() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_list_by_pr_returns_keyed_and_sentinel\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    # Build a fake ticket JSON with two DEFENSE_RECORD comments:
    #   comment 1: pr_number=42 (v1.2.0 keyed)
    #   comment 2: no pr_number (legacy sentinel, treated as pr_number=0)
    local fake_ticket
    fake_ticket=$(python3 -c "
import json
comments = [
    {
        'body': 'DEFENSE_RECORD: ' + json.dumps({
            'prior_finding_id': 'f-pr42',
            'defense_text': 'defense for pr 42',
            'pr_number': 42,
            'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}]
        })
    },
    {
        'body': 'DEFENSE_RECORD: ' + json.dumps({
            'prior_finding_id': 'f-legacy',
            'defense_text': 'legacy defense no pr_number',
            'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}]
        })
    }
]
print(json.dumps({'comments': comments}))
")

    local output exit_code=0
    output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID=TEST-PR-LIST
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="echo"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        # Inject fake ticket response by overriding _TICKET_CMD
        _TICKET_CMD="python3 -c \"import sys; print(sys.argv[2])\" --"
        # We need to mock the ticket show command; use a subshell trick:
        # Override the ticket cmd to return our fake_ticket
        # shellcheck disable=SC2329
        _ticket_show_mock() {
            printf '%s\n' "$fake_ticket"
        }
        # Temporarily replace _TICKET_CMD
        _TICKET_CMD_ORIG="$_TICKET_CMD"
        _TICKET_CMD="_ticket_show_mock"
        defense_store_list_by_pr 42 2>/dev/null
    ) || exit_code=$?

    assert_eq "test_defense_store_list_by_pr_returns_keyed_and_sentinel: exits 0" "0" "$exit_code"

    # Should return at least 2 records (the pr=42 entry AND the sentinel/legacy)
    local record_count
    record_count=$(echo "$output" | grep -c '"prior_finding_id"' || echo "0")
    local found_keyed=0 found_legacy=0
    if echo "$output" | grep -q '"f-pr42"'; then found_keyed=1; fi
    if echo "$output" | grep -q '"f-legacy"'; then found_legacy=1; fi

    assert_eq "test_defense_store_list_by_pr_returns_keyed_and_sentinel: keyed pr=42 record returned" \
        "1" "$found_keyed"
    assert_eq "test_defense_store_list_by_pr_returns_keyed_and_sentinel: sentinel/legacy record returned" \
        "1" "$found_legacy"

    assert_pass_if_clean "test_defense_store_list_by_pr_returns_keyed_and_sentinel"
}

test_defense_store_list_by_pr_returns_keyed_and_sentinel

# =============================================================================
# Test 3 — defense_store_list_by_pr with pr_number=99 does NOT return pr=42
#           keyed records, but DOES return sentinel/legacy entries
#
# Given: same store (pr=42 keyed + legacy/sentinel)
# When: defense_store_list_by_pr 99 is called
# Then: pr=42 record is excluded; legacy/sentinel record is included
# =============================================================================
echo ""
echo "--- test_defense_store_list_by_pr_excludes_other_pr_keeps_sentinel ---"

test_defense_store_list_by_pr_excludes_other_pr_keeps_sentinel() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_list_by_pr_excludes_other_pr_keeps_sentinel\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local fake_ticket
    fake_ticket=$(python3 -c "
import json
comments = [
    {
        'body': 'DEFENSE_RECORD: ' + json.dumps({
            'prior_finding_id': 'f-pr42',
            'defense_text': 'defense for pr 42',
            'pr_number': 42,
            'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}]
        })
    },
    {
        'body': 'DEFENSE_RECORD: ' + json.dumps({
            'prior_finding_id': 'f-legacy',
            'defense_text': 'legacy defense no pr_number',
            'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}]
        })
    }
]
print(json.dumps({'comments': comments}))
")

    local output exit_code=0
    output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID=TEST-PR-LIST2
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="echo"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        # shellcheck disable=SC2329
        _ticket_show_mock() {
            printf '%s\n' "$fake_ticket"
        }
        _TICKET_CMD="_ticket_show_mock"
        defense_store_list_by_pr 99 2>/dev/null
    ) || exit_code=$?

    assert_eq "test_defense_store_list_by_pr_excludes_other_pr_keeps_sentinel: exits 0" "0" "$exit_code"

    local found_keyed=0 found_legacy=0
    if echo "$output" | grep -q '"f-pr42"'; then found_keyed=1; fi
    if echo "$output" | grep -q '"f-legacy"'; then found_legacy=1; fi

    assert_eq "test_defense_store_list_by_pr_excludes_other_pr_keeps_sentinel: pr=42 record NOT returned for pr_number=99" \
        "0" "$found_keyed"
    assert_eq "test_defense_store_list_by_pr_excludes_other_pr_keeps_sentinel: sentinel/legacy record IS returned for pr_number=99" \
        "1" "$found_legacy"

    assert_pass_if_clean "test_defense_store_list_by_pr_excludes_other_pr_keeps_sentinel"
}

test_defense_store_list_by_pr_excludes_other_pr_keeps_sentinel

# =============================================================================
# Test 4 — defense_store_write without --pr-number falls back to sentinel=0
#           (backward-compat: callers that don't supply --pr-number still work)
#
# Given: a defense record JSON without --pr-number flag
# When: defense_store_write is called (no --pr-number arg)
# Then: exits 0 and output record has pr_number=0 (sentinel)
# =============================================================================
echo ""
echo "--- test_defense_store_write_defaults_to_sentinel_pr_number ---"

test_defense_store_write_defaults_to_sentinel_pr_number() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_write_defaults_to_sentinel_pr_number\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local captured_output exit_code=0
    captured_output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID=TEST-PR-SENT
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="echo"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        record=$(python3 -c "
import json
print(json.dumps({
    'ticket_id': 'TEST-PR-SENT',
    'prior_finding_id': 'f-sentinel',
    'defense_text': 'backward compat defense',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}]
}))
")
        # Call WITHOUT --pr-number (backward-compat path)
        defense_store_write "$record" 2>/dev/null
    ) || exit_code=$?

    assert_eq "test_defense_store_write_defaults_to_sentinel_pr_number: exits 0" "0" "$exit_code"

    # Output should have pr_number=0 (sentinel)
    local has_sentinel=0
    if python3 -c "
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(1)
# The defense_store_write emits the enriched JSON to stdout
for line in raw.split('\n'):
    try:
        data = json.loads(line)
        if data.get('pr_number') == 0:
            sys.exit(0)
    except (json.JSONDecodeError, ValueError):
        continue
sys.exit(1)
" <<< "$captured_output" 2>/dev/null; then
        has_sentinel=1
    fi
    assert_eq "test_defense_store_write_defaults_to_sentinel_pr_number: output JSON has pr_number=0 (sentinel)" \
        "1" "$has_sentinel"

    assert_pass_if_clean "test_defense_store_write_defaults_to_sentinel_pr_number"
}

test_defense_store_write_defaults_to_sentinel_pr_number

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
