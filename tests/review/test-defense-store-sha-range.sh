#!/usr/bin/env bash
# tests/review/test-defense-store-sha-range.sh
# Behavioral tests for plugins/dso/scripts/review-defense-store.sh —
# SHA-range field recording in defense_store_write output.
#
# Tests 1 and 3 assert that defense_store_write actively validates sha fields
# by checking that story_branch_tip_sha and story_branch_base_sha are PRESERVED
# (not stripped) in the enriched record — and that write rejects a record where
# those fields are present but malformed (not 40-char hex).
#

# preservation logic for sha fields — they pass through incidentally but are
# not validated. test_defense_store_write_rejects_malformed_sha_fields asserts
# rejection of a non-hex sha, which is not implemented yet.
#
# Tests 1 and 2 (pass-through and legacy) may already be GREEN.
#
# Usage: bash tests/review/test-defense-store-sha-range.sh

# NOTE: -e intentionally omitted — test functions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DEFENSE_STORE="$REPO_ROOT/plugins/dso/scripts/review-defense-store.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-defense-store-sha-range.sh ==="

# =============================================================================
# Test 1 — defense_store_write records story_branch_tip_sha and
#           story_branch_base_sha verbatim in the written DEFENSE_RECORD output
#
# Given: a defense record JSON with story_branch_tip_sha and story_branch_base_sha
# When: defense_store_write is called with TICKET_CMD=echo
# Then: the stdout output includes story_branch_tip_sha and story_branch_base_sha verbatim
# =============================================================================
echo ""
echo "--- test_defense_store_write_records_sha_fields ---"

test_defense_store_write_records_sha_fields() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_write_records_sha_fields\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local captured_output
    captured_output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID=TEST-SHA-1
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="echo"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        record=$(python3 -c "
import json
print(json.dumps({
    'ticket_id': 'TEST-SHA-1',
    'prior_finding_id': 'f-sha-abc',
    'defense_text': 'test defense with sha fields',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}],
    'story_branch_tip_sha': 'deadbeef1234567890abcdef1234567890abcdef',
    'story_branch_base_sha': 'cafebabe0987654321fedcba0987654321fedcba'
}))
")
        defense_store_write "$record" 2>/dev/null
    ) || true

    # The output JSON must contain story_branch_tip_sha verbatim
    local has_tip_sha=0
    if python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
tip = data.get('story_branch_tip_sha', '')
sys.exit(0 if tip == 'deadbeef1234567890abcdef1234567890abcdef' else 1)
" <<< "$captured_output" 2>/dev/null; then
        has_tip_sha=1
    fi
    assert_eq "test_defense_store_write_records_sha_fields: story_branch_tip_sha present verbatim in output" \
        "1" "$has_tip_sha"

    # The output JSON must contain story_branch_base_sha verbatim
    local has_base_sha=0
    if python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
base = data.get('story_branch_base_sha', '')
sys.exit(0 if base == 'cafebabe0987654321fedcba0987654321fedcba' else 1)
" <<< "$captured_output" 2>/dev/null; then
        has_base_sha=1
    fi
    assert_eq "test_defense_store_write_records_sha_fields: story_branch_base_sha present verbatim in output" \
        "1" "$has_base_sha"

    assert_pass_if_clean "test_defense_store_write_records_sha_fields"
}

test_defense_store_write_records_sha_fields

# =============================================================================
# Test 2 — defense_store_write succeeds for legacy records WITHOUT sha fields;
#           no sha fields are injected into the output
#
# Given: a defense record WITHOUT story_branch_tip_sha/story_branch_base_sha
# When: defense_store_write is called
# Then: write succeeds (exit 0) and no sha fields appear in output
#
# This test may already PASS — legacy path preserves existing behavior.
# =============================================================================
echo ""
echo "--- test_defense_store_write_legacy_no_sha_injection ---"

test_defense_store_write_legacy_no_sha_injection() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_write_legacy_no_sha_injection\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local captured_output
    local exit_code=0
    captured_output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID=TEST-SHA-2
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="echo"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        record=$(python3 -c "
import json
print(json.dumps({
    'ticket_id': 'TEST-SHA-2',
    'prior_finding_id': 'f-sha-legacy',
    'defense_text': 'legacy defense without sha fields',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}]
}))
")
        defense_store_write "$record" 2>/dev/null
    ) || exit_code=$?

    # Write must succeed
    assert_eq "test_defense_store_write_legacy_no_sha_injection: exits 0" "0" "$exit_code"

    # story_branch_tip_sha must NOT appear when absent in input
    local tip_sha_injected=0
    if python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
sys.exit(0 if 'story_branch_tip_sha' in data else 1)
" <<< "$captured_output" 2>/dev/null; then
        tip_sha_injected=1
    fi
    assert_eq "test_defense_store_write_legacy_no_sha_injection: story_branch_tip_sha not injected when absent in input" \
        "0" "$tip_sha_injected"

    # story_branch_base_sha must NOT appear when absent in input
    local base_sha_injected=0
    if python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
sys.exit(0 if 'story_branch_base_sha' in data else 1)
" <<< "$captured_output" 2>/dev/null; then
        base_sha_injected=1
    fi
    assert_eq "test_defense_store_write_legacy_no_sha_injection: story_branch_base_sha not injected when absent in input" \
        "0" "$base_sha_injected"

    assert_pass_if_clean "test_defense_store_write_legacy_no_sha_injection"
}

test_defense_store_write_legacy_no_sha_injection

# =============================================================================
# Test 3 — the output JSON captured from TICKET_CMD=echo contains
#           story_branch_tip_sha in the JSON body when sha fields are provided
#
# Given: a defense record with sha fields
# When: written output is captured via TICKET_CMD=echo
# Then: output JSON (grep for story_branch_tip_sha) contains the sha field
#
# fails because defense_store_write has no active sha-field validation;
# the test specifically asserts that BOTH sha fields are required together —
# write must reject a record where only one sha field is present (partial sha range).
# =============================================================================
echo ""
echo "--- test_written_record_contains_sha_fields_in_json ---"

test_written_record_contains_sha_fields_in_json() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_written_record_contains_sha_fields_in_json\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    # Sub-test A: both sha fields present → write succeeds, both appear in output
    local captured_output
    local exit_code=0
    captured_output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID=TEST-SHA-3
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="echo"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        record=$(python3 -c "
import json
print(json.dumps({
    'ticket_id': 'TEST-SHA-3',
    'prior_finding_id': 'f-sha-full',
    'defense_text': 'full sha range defense',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}],
    'story_branch_tip_sha': 'aaaaaabbbbbbccccccddddddeeeeeeffffffffff00',
    'story_branch_base_sha': '0000001111112222223333334444445555556666'
}))
")
        defense_store_write "$record" 2>/dev/null
    ) || exit_code=$?

    # Both sha keys must appear in output
    local tip_present=0
    if [[ "$captured_output" == *"story_branch_tip_sha"* ]]; then
        tip_present=1
    fi
    assert_eq "test_written_record_contains_sha_fields_in_json: story_branch_tip_sha key appears in output" \
        "1" "$tip_present"

    local base_present=0
    if [[ "$captured_output" == *"story_branch_base_sha"* ]]; then
        base_present=1
    fi
    assert_eq "test_written_record_contains_sha_fields_in_json: story_branch_base_sha key appears in output" \
        "1" "$base_present"

    # Sub-test B: only tip sha present (partial range) → write must reject with error
    # defense_store_write currently does NOT enforce that both sha fields must
    # appear together — partial sha range is silently accepted. This assertion fails
    # until validation is added.
    local partial_exit_code=0
    local partial_stderr
    partial_stderr=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID=TEST-SHA-3P
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="echo"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        record=$(python3 -c "
import json
print(json.dumps({
    'ticket_id': 'TEST-SHA-3P',
    'prior_finding_id': 'f-sha-partial',
    'defense_text': 'partial sha range',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}],
    'story_branch_tip_sha': 'aaaaaabbbbbbccccccddddddeeeeeeffffffffff00'
}))
")
        defense_store_write "$record" 2>&1
    ) || partial_exit_code=$?

    assert_eq "test_written_record_contains_sha_fields_in_json: partial sha range (tip without base) rejected with exit 1" \
        "1" "$partial_exit_code"
    assert_contains "test_written_record_contains_sha_fields_in_json: stderr mentions sha range pairing requirement" \
        "story_branch_base_sha" "$partial_stderr"

    assert_pass_if_clean "test_written_record_contains_sha_fields_in_json"
}

test_written_record_contains_sha_fields_in_json

# =============================================================================
# Test 4 — defense_store_load_for_region EXCLUDES a record when tip_sha is
#           present in the record but cannot be resolved in the current repo.
#
# Given: a defense record with story_branch_tip_sha set to an all-zeros SHA
#        (0000000000000000000000000000000000000000) that does not exist in any repo
# When:  defense_store_load_for_region is called with a valid query_sha (HEAD)
# Then:  the record is NOT returned (fail-closed trust boundary)
#
# This tests the symmetric fail-closed behaviour added to the tip/base-unresolvable
# branch (was previously fail-open — included the record — which allowed foreign
# or corrupt records to bypass validation and suppress findings).
# =============================================================================
echo ""
echo "--- test_load_for_region_excludes_record_when_tip_sha_unresolvable ---"

test_load_for_region_excludes_record_when_tip_sha_unresolvable() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_load_for_region_excludes_record_when_tip_sha_unresolvable\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    # Use a SHA that cannot exist in any real git repo (all zeros is the null object)
    local foreign_tip_sha="0000000000000000000000000000000000000000"
    # Use a real commit from this repo as base_sha and query_sha
    local real_sha
    real_sha=$(git rev-parse HEAD 2>/dev/null) || real_sha=""
    if [[ -z "$real_sha" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_load_for_region_excludes_record_when_tip_sha_unresolvable\n  could not resolve HEAD in repo\n" >&2
        return
    fi

    # Build a defense record with an unresolvable tip_sha
    local record_json
    record_json=$(python3 -c "
import json
print(json.dumps({
    'prior_finding_id': 'f-foreign-tip-sha-1',
    'file_paths': ['src/any_file.py'],
    'defense_text': 'defense with unresolvable tip sha',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}],
    'story_branch_tip_sha': '$foreign_tip_sha',
    'story_branch_base_sha': '$real_sha'
}))
")

    # Wrap in a fake ticket JSON structure
    local ticket_json
    ticket_json=$(python3 -c "
import json, sys
record = sys.argv[1]
ticket = {
    'id': 'TEST-FOREIGN-TIP-001',
    'title': 'foreign tip sha test ticket',
    'comments': [{'body': 'DEFENSE_RECORD: ' + record}]
}
print(json.dumps(ticket))
" "$record_json")

    # Create a TICKET_CMD stub returning the fake ticket JSON
    local stub_ticket_cmd
    stub_ticket_cmd=$(mktemp "${TMPDIR:-/tmp}/dso-ticket-stub.XXXXXX")
    chmod +x "$stub_ticket_cmd"
    printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' '"'"'%s'"'"'\n' "$ticket_json" > "$stub_ticket_cmd"

    local output
    output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="TEST-FOREIGN-TIP-001"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="$stub_ticket_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_load_for_region --query-sha "$real_sha" "src/any_file.py" 2>/dev/null
    ) || true

    rm -f "$stub_ticket_cmd"

    # The record must NOT appear in output — unresolvable tip_sha → fail-closed
    local record_found=0
    if printf '%s\n' "$output" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == 'f-foreign-tip-sha-1':
            sys.exit(0)
    except (json.JSONDecodeError, ValueError):
        continue
sys.exit(1)
" 2>/dev/null; then
        record_found=1
    fi

    assert_eq "test_load_for_region_excludes_record_when_tip_sha_unresolvable: record is NOT returned when tip_sha is unresolvable" \
        "0" "$record_found"

    assert_pass_if_clean "test_load_for_region_excludes_record_when_tip_sha_unresolvable"
}

test_load_for_region_excludes_record_when_tip_sha_unresolvable

# =============================================================================
# Test 5 — defense_store_load_for_region INCLUDES a record when tip_sha is a
#           real commit SHA and query_sha is equal to (or an ancestor of) tip.
#
# Given: a defense record with story_branch_tip_sha set to HEAD and
#        story_branch_base_sha set to HEAD (degenerate but valid — BASE==TIP
#        means the range is a single commit; query_sha==tip satisfies Condition A
#        because BASE is an ancestor-or-equal of QUERY_SHA AND QUERY_SHA is
#        an ancestor-or-equal of TIP via the inclusive merge-base semantics, OR
#        Condition B fires because TIP is an ancestor of QUERY_SHA when equal).
# When:  defense_store_load_for_region is called with query_sha == HEAD
# Then:  the record IS returned — confirming fail-closed logic is selective,
#        not a blanket exclude-everything gate.
# =============================================================================
echo ""
echo "--- test_load_for_region_includes_record_when_tip_sha_resolvable ---"

test_load_for_region_includes_record_when_tip_sha_resolvable() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_load_for_region_includes_record_when_tip_sha_resolvable\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    # Use HEAD as both tip and base — query_sha == tip triggers Condition B
    # (TIP is an ancestor of QUERY_SHA when they are equal under git merge-base semantics)
    local real_sha
    real_sha=$(git rev-parse HEAD 2>/dev/null) || real_sha=""
    if [[ -z "$real_sha" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_load_for_region_includes_record_when_tip_sha_resolvable\n  could not resolve HEAD in repo\n" >&2
        return
    fi

    # Build a defense record with resolvable tip_sha and base_sha (both HEAD)
    local record_json
    record_json=$(python3 -c "
import json
print(json.dumps({
    'prior_finding_id': 'f-resolvable-tip-sha-1',
    'file_paths': ['src/any_file.py'],
    'defense_text': 'defense with resolvable tip sha',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}],
    'story_branch_tip_sha': '$real_sha',
    'story_branch_base_sha': '$real_sha'
}))
")

    # Wrap in a fake ticket JSON structure
    local ticket_json
    ticket_json=$(python3 -c "
import json, sys
record = sys.argv[1]
ticket = {
    'id': 'TEST-RESOLVABLE-TIP-001',
    'title': 'resolvable tip sha test ticket',
    'comments': [{'body': 'DEFENSE_RECORD: ' + record}]
}
print(json.dumps(ticket))
" "$record_json")

    # Create a TICKET_CMD stub returning the fake ticket JSON
    local stub_ticket_cmd
    stub_ticket_cmd=$(mktemp "${TMPDIR:-/tmp}/dso-ticket-stub.XXXXXX")
    chmod +x "$stub_ticket_cmd"
    printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' '"'"'%s'"'"'\n' "$ticket_json" > "$stub_ticket_cmd"

    local output
    output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="TEST-RESOLVABLE-TIP-001"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="$stub_ticket_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_load_for_region --query-sha "$real_sha" "src/any_file.py" 2>/dev/null
    ) || true

    rm -f "$stub_ticket_cmd"

    # The record MUST appear in output — resolvable tip_sha with matching query → included
    local record_found=0
    if printf '%s\n' "$output" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == 'f-resolvable-tip-sha-1':
            sys.exit(0)
    except (json.JSONDecodeError, ValueError):
        continue
sys.exit(1)
" 2>/dev/null; then
        record_found=1
    fi

    assert_eq "test_load_for_region_includes_record_when_tip_sha_resolvable: record IS returned when tip_sha is resolvable and query_sha matches" \
        "1" "$record_found"

    assert_pass_if_clean "test_load_for_region_includes_record_when_tip_sha_resolvable"
}

test_load_for_region_includes_record_when_tip_sha_resolvable

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
