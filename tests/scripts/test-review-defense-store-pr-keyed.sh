#!/usr/bin/env bash
# tests/scripts/test-review-defense-store-pr-keyed.sh
#
# RED test: TrackerDefenseStore (review-defense-store.sh) --pr-number key + sentinel readback
#
# Testing Mode: RED
# Source file:  plugins/dso/scripts/review-defense-store.sh
#
# Tests four behavioral contracts that FAIL before --pr-number support is implemented:
#
#   1. defense_store_write accepts --pr-number 42 + defense JSON; written record
#      embeds pr_number=42 and reads back via the ticket stub.
#   2. defense_store_write accepts --pr-number 0 (sentinel for legacy v1.1.0) and
#      written record embeds pr_number=0.
#   3. Sentinel (pr_number=0) entry MATCHES queries for any --pr-number until a
#      non-sentinel entry supersedes it.
#   4. A non-sentinel entry (pr_number=42) SUPERSEDES a sentinel for the same
#      commit_sha: --pr-number 42 query returns the non-sentinel record and the
#      sentinel; --pr-number 99 returns only the sentinel (no PR-42 leak).
#
# RED rationale: defense_store_write currently accepts only a positional JSON
# argument with no --pr-number flag. defense_store_list has --pr for file-path
# filtering (PR diff set), not for defense-record keying by pr_number. Neither
# function supports the --pr-number keying contract, so all four tests fail.
#
# Usage: bash tests/scripts/test-review-defense-store-pr-keyed.sh
# Returns: exit 1 (RED) until --pr-number keying is implemented.

# NOTE: -e intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner on
# the first expected RED failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DEFENSE_STORE="$REPO_ROOT/plugins/dso/scripts/review-defense-store.sh"

# shellcheck source=tests/lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-review-defense-store-pr-keyed.sh ==="

# ---------------------------------------------------------------------------
# Cleanup registry: all mktemp paths collected here are removed on exit.
# ---------------------------------------------------------------------------
_TEST_TMPS=()
_cleanup_tmps() {
    for _p in "${_TEST_TMPS[@]:-}"; do
        [[ -n "$_p" ]] && rm -f "$_p"
    done
}
trap _cleanup_tmps EXIT

# ---------------------------------------------------------------------------
# Helper: _make_stub_ticket_cmd ticket_json_var
#
# Creates a TICKET_CMD stub executable that:
#   - On "comment <id> <body>" calls: captures body into a temp store file.
#   - On "show <id>" calls: emits the initial ticket JSON PLUS any previously
#     captured DEFENSE_RECORD comments, so readback reflects written records.
#
# This enables write+readback testing without a real ticket tracker.
#
# Prints the path to the created stub.
# ---------------------------------------------------------------------------
_make_stub_ticket_cmd() {
    local initial_ticket_json="$1"

    # Temp file accumulates comment bodies written via "comment <id> <body>"
    local comment_store
    comment_store=$(mktemp /tmp/dso-ticket-stub-comments.XXXXXX)
    _TEST_TMPS+=("$comment_store")

    local stub
    stub=$(mktemp /tmp/dso-ticket-stub.XXXXXX)
    _TEST_TMPS+=("$stub")
    chmod +x "$stub"

    # Escape the initial JSON and the comment store path for embedding in the stub.
    # Use printf %q to produce a shell-safe version of the JSON string.
    local escaped_json
    escaped_json=$(python3 -c "import sys, shlex; print(shlex.quote(sys.argv[1]))" "$initial_ticket_json")

    cat > "$stub" <<STUBEOF
#!/usr/bin/env bash
# Stub TICKET_CMD for review-defense-store tests
COMMENT_STORE=${comment_store@Q}
INITIAL_JSON=${escaped_json}

subcmd="\${1:-}"
shift || true

case "\$subcmd" in
    comment)
        # "comment <ticket_id> <body>"
        # <ticket_id> is argv[1] (already shifted); <body> is argv[2]
        shift || true   # skip ticket_id
        body="\${1:-}"
        if [[ -n "\$body" ]]; then
            printf '%s\n' "\$body" >> "\$COMMENT_STORE"
        fi
        ;;
    show)
        # "show <ticket_id>" — emit ticket JSON with accumulated comments
        # Build the comments array from the stored bodies and merge into JSON.
        python3 - "\$INITIAL_JSON" "\$COMMENT_STORE" <<'PYEOF'
import json, sys

ticket = json.loads(sys.argv[1])
comment_store = sys.argv[2]

# Load accumulated comment bodies
extra_comments = []
try:
    with open(comment_store, "r") as fh:
        for line in fh:
            body = line.rstrip("\n")
            if body:
                extra_comments.append({"body": body})
except OSError:
    pass

existing = ticket.get("comments", [])
ticket["comments"] = existing + extra_comments
print(json.dumps(ticket))
PYEOF
        ;;
    *)
        # Ignore other subcommands (list-epics, transition, etc.) silently.
        ;;
esac
STUBEOF

    printf '%s' "$stub"
}

# ---------------------------------------------------------------------------
# Helper: _build_base_ticket_json ticket_id
# Returns a minimal ticket JSON with no comments.
# ---------------------------------------------------------------------------
_build_base_ticket_json() {
    local ticket_id="$1"
    python3 -c "
import json, sys
ticket_id = sys.argv[1]
ticket = {
    'id': ticket_id,
    'title': 'test ticket for pr-number keying',
    'comments': []
}
print(json.dumps(ticket))
" "$ticket_id"
}

# ---------------------------------------------------------------------------
# Helper: _make_valid_defense_json pr_number commit_sha prior_finding_id
# Returns a minimal valid defense JSON for use as input to defense_store_write.
# ---------------------------------------------------------------------------
_make_valid_defense_json() {
    local pr_number="$1"
    local commit_sha="$2"
    local prior_finding_id="$3"
    python3 -c "
import json, sys
pr_number = int(sys.argv[1])
commit_sha = sys.argv[2]
prior_finding_id = sys.argv[3]
record = {
    'prior_finding_id': prior_finding_id,
    'defense_text': 'test defense for pr ' + str(pr_number),
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}],
    'file_paths': ['plugins/dso/scripts/review-defense-store.sh'],
    'commit_sha': commit_sha
}
print(json.dumps(record))
" "$pr_number" "$commit_sha" "$prior_finding_id"
}

# =============================================================================
# Test 1 — defense_store_write accepts --pr-number 42 + defense JSON;
#           written record embeds pr_number=42 and reads back correctly.
#
# Given:  a fresh ticket-bound defense store with no prior comments
# When:   defense_store_write --pr-number 42 <defense_json> is called
# Then:   (a) exits 0
#         (b) stdout output JSON contains pr_number=42
#         (c) subsequent defense_store_load reads back a record with pr_number=42
#
# RED: defense_store_write currently does not accept --pr-number flag at all.
#      The function signature is defense_store_write(defense_json) with a single
#      positional argument. Passing --pr-number as a flag either silently
#      misinterprets it as the defense_json arg (causing parse failure) or is
#      treated as positional JSON (causing an exit 1 from JSON parse error).
# =============================================================================
echo ""
echo "--- test_write_with_pr_number_42_embeds_and_reads_back ---"

test_write_with_pr_number_42_embeds_and_reads_back() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_write_with_pr_number_42_embeds_and_reads_back\n  expected: %s to exist\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local ticket_id="TEST-PR42-T1"
    local commit_sha="abc1234567890abcdef1234567890abcdef123456"
    local prior_finding_id="f-pr42-test-1"
    local base_ticket_json
    base_ticket_json=$(_build_base_ticket_json "$ticket_id")
    local stub_cmd
    stub_cmd=$(_make_stub_ticket_cmd "$base_ticket_json")
    local defense_json
    defense_json=$(_make_valid_defense_json 42 "$commit_sha" "$prior_finding_id")

    # Call defense_store_write with --pr-number 42 flag (new interface under test)
    local write_output
    local write_exit=0
    write_output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="$ticket_id"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="$stub_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_write --pr-number 42 "$defense_json" 2>/dev/null
    ) || write_exit=$?

    # Assertion A: write exits 0
    assert_eq "test_write_with_pr_number_42_embeds_and_reads_back: defense_store_write exits 0" \
        "0" "$write_exit"

    # Assertion B: written record contains pr_number=42
    local has_pr_number=0
    if python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    sys.exit(0 if data.get('pr_number') == 42 else 1)
except Exception:
    sys.exit(1)
" "$write_output" 2>/dev/null; then
        has_pr_number=1
    fi
    assert_eq "test_write_with_pr_number_42_embeds_and_reads_back: written record embeds pr_number=42" \
        "1" "$has_pr_number"

    # Assertion C: readback via defense_store_load recovers prior_finding_id and pr_number
    local load_output
    load_output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="$ticket_id"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="$stub_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_load "$prior_finding_id" 2>/dev/null
    ) || true

    local readback_pr_number=0
    if python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    sys.exit(0 if data.get('pr_number') == 42 else 1)
except Exception:
    sys.exit(1)
" "$load_output" 2>/dev/null; then
        readback_pr_number=1
    fi
    assert_eq "test_write_with_pr_number_42_embeds_and_reads_back: readback record contains pr_number=42" \
        "1" "$readback_pr_number"

    assert_pass_if_clean "test_write_with_pr_number_42_embeds_and_reads_back"
}

test_write_with_pr_number_42_embeds_and_reads_back

# =============================================================================
# Test 2 — defense_store_write accepts --pr-number 0 (sentinel for legacy
#           v1.1.0); written record embeds pr_number=0 and reads back correctly.
#
# Given:  a fresh ticket-bound defense store
# When:   defense_store_write --pr-number 0 <defense_json> is called
# Then:   (a) exits 0
#         (b) stdout output JSON contains pr_number=0
#         (c) subsequent defense_store_load reads back pr_number=0
#
# RED: same root cause as Test 1 — --pr-number flag not supported at all.
#      pr_number=0 is the sentinel value used to mark records written before
#      PR-keying was introduced (v1.1.0 legacy records). This test verifies
#      explicit sentinel migration path: a caller may write pr_number=0 to
#      signal "this defense predates PR keying."
# =============================================================================
echo ""
echo "--- test_write_with_pr_number_0_sentinel_embeds_and_reads_back ---"

test_write_with_pr_number_0_sentinel_embeds_and_reads_back() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_write_with_pr_number_0_sentinel_embeds_and_reads_back\n  expected: %s to exist\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local ticket_id="TEST-PR0-T2"
    local commit_sha="def4567890abcdef1234567890abcdef12345678"
    local prior_finding_id="f-pr0-sentinel-test-2"
    local base_ticket_json
    base_ticket_json=$(_build_base_ticket_json "$ticket_id")
    local stub_cmd
    stub_cmd=$(_make_stub_ticket_cmd "$base_ticket_json")
    local defense_json
    defense_json=$(_make_valid_defense_json 0 "$commit_sha" "$prior_finding_id")

    # Call defense_store_write with --pr-number 0 (explicit sentinel)
    local write_output
    local write_exit=0
    write_output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="$ticket_id"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="$stub_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_write --pr-number 0 "$defense_json" 2>/dev/null
    ) || write_exit=$?

    # Assertion A: write exits 0
    assert_eq "test_write_with_pr_number_0_sentinel_embeds_and_reads_back: defense_store_write exits 0" \
        "0" "$write_exit"

    # Assertion B: written record contains pr_number=0 (the sentinel integer)
    local has_sentinel=0
    if python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    # pr_number=0 must be explicitly present (not absent, not None)
    sys.exit(0 if 'pr_number' in data and data['pr_number'] == 0 else 1)
except Exception:
    sys.exit(1)
" "$write_output" 2>/dev/null; then
        has_sentinel=1
    fi
    assert_eq "test_write_with_pr_number_0_sentinel_embeds_and_reads_back: written record embeds pr_number=0 (sentinel)" \
        "1" "$has_sentinel"

    # Assertion C: readback recovers pr_number=0
    local load_output
    load_output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="$ticket_id"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="$stub_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_load "$prior_finding_id" 2>/dev/null
    ) || true

    local readback_sentinel=0
    if python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    sys.exit(0 if 'pr_number' in data and data['pr_number'] == 0 else 1)
except Exception:
    sys.exit(1)
" "$load_output" 2>/dev/null; then
        readback_sentinel=1
    fi
    assert_eq "test_write_with_pr_number_0_sentinel_embeds_and_reads_back: readback record contains pr_number=0" \
        "1" "$readback_sentinel"

    assert_pass_if_clean "test_write_with_pr_number_0_sentinel_embeds_and_reads_back"
}

test_write_with_pr_number_0_sentinel_embeds_and_reads_back

# =============================================================================
# Test 3 — Sentinel (pr_number=0) entry MATCHES queries for any --pr-number.
#
# Given:  a store containing ONE defense record with pr_number=0 (sentinel)
# When:   defense_store_list_by_pr --pr-number 42 is called
# Then:   the sentinel record IS returned (sentinel matches any PR query)
#
# AND:
# When:   defense_store_list_by_pr --pr-number 99 is called
# Then:   the sentinel record IS also returned (sentinel matches 99 too)
#
# RED: defense_store_list (or a new defense_store_list_by_pr function) does not
#      support --pr-number keying at all. The current defense_store_list uses
#      --pr to fetch a PR's changed-file set from GitHub (requires gh CLI and a
#      real PR), which is completely different from the per-record pr_number key.
#      A new function or flag is required to query stored records by their
#      embedded pr_number field. Until then, all queries return an empty result.
# =============================================================================
echo ""
echo "--- test_sentinel_pr_number_matches_any_pr_query ---"

test_sentinel_pr_number_matches_any_pr_query() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_sentinel_pr_number_matches_any_pr_query\n  expected: %s to exist\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local ticket_id="TEST-SENTINEL-T3"
    local commit_sha="aaa1111111111111111111111111111111111111"
    local prior_finding_id="f-sentinel-any-pr"
    local base_ticket_json
    base_ticket_json=$(_build_base_ticket_json "$ticket_id")
    local stub_cmd
    stub_cmd=$(_make_stub_ticket_cmd "$base_ticket_json")
    local defense_json
    defense_json=$(_make_valid_defense_json 0 "$commit_sha" "$prior_finding_id")

    # Write a sentinel record (pr_number=0)
    (
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="$ticket_id"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="$stub_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_write --pr-number 0 "$defense_json" 2>/dev/null
    ) || true

    # Query with --pr-number 42 — sentinel must match
    local output_pr42
    output_pr42=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="$ticket_id"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="$stub_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_list_by_pr --pr-number 42 2>/dev/null
    ) || true

    local sentinel_found_for_42=0
    if python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    # Strip 'DEFENSE_RECORD: ' prefix if present
    if line.startswith('DEFENSE_RECORD: '):
        line = line[len('DEFENSE_RECORD: '):]
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == '$prior_finding_id':
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" <<< "$output_pr42" 2>/dev/null; then
        sentinel_found_for_42=1
    fi
    assert_eq "test_sentinel_pr_number_matches_any_pr_query: sentinel (pr_number=0) returned for --pr-number 42 query" \
        "1" "$sentinel_found_for_42"

    # Query with --pr-number 99 — sentinel must also match
    local output_pr99
    output_pr99=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="$ticket_id"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="$stub_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_list_by_pr --pr-number 99 2>/dev/null
    ) || true

    local sentinel_found_for_99=0
    if python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    if line.startswith('DEFENSE_RECORD: '):
        line = line[len('DEFENSE_RECORD: '):]
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == '$prior_finding_id':
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" <<< "$output_pr99" 2>/dev/null; then
        sentinel_found_for_99=1
    fi
    assert_eq "test_sentinel_pr_number_matches_any_pr_query: sentinel (pr_number=0) returned for --pr-number 99 query" \
        "1" "$sentinel_found_for_99"

    assert_pass_if_clean "test_sentinel_pr_number_matches_any_pr_query"
}

test_sentinel_pr_number_matches_any_pr_query

# =============================================================================
# Test 4 — Non-sentinel entry (pr_number=42) SUPERSEDES sentinel for same
#           commit_sha when both records exist.
#
# Given:  a store containing:
#           - SENTINEL record: pr_number=0, commit_sha=X, prior_finding_id=f-sentinel
#           - NON-SENTINEL record: pr_number=42, commit_sha=X, prior_finding_id=f-pr42
# When:   defense_store_list_by_pr --pr-number 42 is called
# Then:   BOTH records are returned (non-sentinel + sentinel for same commit_sha)
#         AND non-sentinel record appears (PR-42-specific defense is present)
#
# When:   defense_store_list_by_pr --pr-number 99 is called
# Then:   ONLY the sentinel record is returned (no PR-42 leak to unrelated PR)
#         AND the PR-42 non-sentinel record does NOT appear
#
# RED: same root cause — defense_store_list_by_pr (with pr_number keying) does
#      not exist. The sentinel-supersession and PR-scoped leak-prevention rules
#      cannot be tested until the function is implemented.
# =============================================================================
echo ""
echo "--- test_non_sentinel_supersedes_sentinel_for_same_commit_sha ---"

test_non_sentinel_supersedes_sentinel_for_same_commit_sha() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_non_sentinel_supersedes_sentinel_for_same_commit_sha\n  expected: %s to exist\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local ticket_id="TEST-SUPERSEDE-T4"
    local shared_commit_sha="bbb2222222222222222222222222222222222222"
    local sentinel_finding_id="f-sentinel-supersede"
    local pr42_finding_id="f-pr42-supersede"
    local base_ticket_json
    base_ticket_json=$(_build_base_ticket_json "$ticket_id")
    local stub_cmd
    stub_cmd=$(_make_stub_ticket_cmd "$base_ticket_json")

    # Write sentinel record (pr_number=0, same commit_sha)
    local sentinel_json
    sentinel_json=$(_make_valid_defense_json 0 "$shared_commit_sha" "$sentinel_finding_id")
    (
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="$ticket_id"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="$stub_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_write --pr-number 0 "$sentinel_json" 2>/dev/null
    ) || true

    # Write non-sentinel record (pr_number=42, same commit_sha)
    local pr42_json
    pr42_json=$(_make_valid_defense_json 42 "$shared_commit_sha" "$pr42_finding_id")
    (
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="$ticket_id"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="$stub_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_write --pr-number 42 "$pr42_json" 2>/dev/null
    ) || true

    # Query with --pr-number 42: expect BOTH sentinel + pr42 records
    local output_pr42
    output_pr42=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="$ticket_id"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="$stub_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_list_by_pr --pr-number 42 2>/dev/null
    ) || true

    # PR-42 non-sentinel record must appear in --pr-number 42 query
    local pr42_record_found=0
    if python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    if line.startswith('DEFENSE_RECORD: '):
        line = line[len('DEFENSE_RECORD: '):]
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == '$pr42_finding_id':
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" <<< "$output_pr42" 2>/dev/null; then
        pr42_record_found=1
    fi
    assert_eq "test_non_sentinel_supersedes_sentinel_for_same_commit_sha: pr42 non-sentinel record present in --pr-number 42 query" \
        "1" "$pr42_record_found"

    # Sentinel record must also appear in --pr-number 42 query (sentinel is a wildcard)
    local sentinel_found_in_42=0
    if python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    if line.startswith('DEFENSE_RECORD: '):
        line = line[len('DEFENSE_RECORD: '):]
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == '$sentinel_finding_id':
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" <<< "$output_pr42" 2>/dev/null; then
        sentinel_found_in_42=1
    fi
    assert_eq "test_non_sentinel_supersedes_sentinel_for_same_commit_sha: sentinel record also present in --pr-number 42 query" \
        "1" "$sentinel_found_in_42"

    # Query with --pr-number 99: expect ONLY sentinel, NO pr42 record
    local output_pr99
    output_pr99=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="$ticket_id"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="$stub_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_list_by_pr --pr-number 99 2>/dev/null
    ) || true

    # PR-42 record must NOT appear in --pr-number 99 query (no cross-PR leak)
    local pr42_leaked_to_99=0
    if python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    if line.startswith('DEFENSE_RECORD: '):
        line = line[len('DEFENSE_RECORD: '):]
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == '$pr42_finding_id':
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" <<< "$output_pr99" 2>/dev/null; then
        pr42_leaked_to_99=1
    fi
    assert_eq "test_non_sentinel_supersedes_sentinel_for_same_commit_sha: pr42 non-sentinel record does NOT appear in --pr-number 99 query (no leak)" \
        "0" "$pr42_leaked_to_99"

    # Sentinel record MUST appear in --pr-number 99 query (sentinel is a wildcard)
    local sentinel_found_in_99=0
    if python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    if line.startswith('DEFENSE_RECORD: '):
        line = line[len('DEFENSE_RECORD: '):]
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == '$sentinel_finding_id':
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" <<< "$output_pr99" 2>/dev/null; then
        sentinel_found_in_99=1
    fi
    assert_eq "test_non_sentinel_supersedes_sentinel_for_same_commit_sha: sentinel record present in --pr-number 99 query" \
        "1" "$sentinel_found_in_99"

    assert_pass_if_clean "test_non_sentinel_supersedes_sentinel_for_same_commit_sha"
}

test_non_sentinel_supersedes_sentinel_for_same_commit_sha

# ── RED marker ──────────────────────────────────────────────────────────────
# [test_review_defense_store_pr_keyed]
# This marker is read by .test-index to link these tests to the source file
# plugins/dso/scripts/review-defense-store.sh for coverage tracking.
# The marker MUST remain in place until all four tests pass (GREEN state).

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
