#!/usr/bin/env bash
# tests/review/test-defense-store-legacy-migration.sh
# RED-phase behavioral tests for defense_store_load_for_region SHA-range membership
# and legacy fallback in plugins/dso/scripts/review-defense-store.sh.
#
# All 3 tests MUST FAIL (RED) until defense_store_load_for_region implements:
#   1. Ancestry-path membership check (story_branch_base_sha..story_branch_tip_sha)
#   2. Exclusion of records where query_sha is outside that range
#   3. Legacy fallback (records without SHA fields) with stderr warning
#
# Usage: bash tests/review/test-defense-store-legacy-migration.sh
# Returns: exit 1 (RED) until implementation is present.

# NOTE: -e intentionally omitted — test functions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DEFENSE_STORE="$REPO_ROOT/plugins/dso/scripts/review-defense-store.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-defense-store-legacy-migration.sh ==="

# ---------------------------------------------------------------------------
# Helper: build_ticket_json_with_record record_json
# Wraps a defense record JSON in a fake ticket JSON structure matching the
# shape that defense_store_load_for_region parses (ticket.comments[].body).
# ---------------------------------------------------------------------------
_build_ticket_json() {
    local record_json="$1"
    python3 -c "
import json, sys
record = sys.argv[1]
ticket = {
    'id': 'TEST-TICKET-001',
    'title': 'test ticket',
    'comments': [
        {'body': 'DEFENSE_RECORD: ' + record}
    ]
}
print(json.dumps(ticket))
" "$record_json"
}

# ---------------------------------------------------------------------------
# Helper: make_git_repo tmpdir
# Initialises a bare git repo with a linear commit chain:
#   BASE -- MID -- TIP
# Prints three SHAs: BASE MID TIP
# ---------------------------------------------------------------------------
_make_git_repo() {
    local dir="$1"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"

    # BASE commit
    echo "base" > "$dir/file.txt"
    git -C "$dir" add file.txt
    git -C "$dir" commit -q -m "base"
    local base_sha
    base_sha=$(git -C "$dir" rev-parse HEAD)

    # MID commit (in ancestry between BASE and TIP)
    echo "mid" > "$dir/file.txt"
    git -C "$dir" add file.txt
    git -C "$dir" commit -q -m "mid"
    local mid_sha
    mid_sha=$(git -C "$dir" rev-parse HEAD)

    # TIP commit
    echo "tip" > "$dir/file.txt"
    git -C "$dir" add file.txt
    git -C "$dir" commit -q -m "tip"
    local tip_sha
    tip_sha=$(git -C "$dir" rev-parse HEAD)

    printf '%s %s %s' "$base_sha" "$mid_sha" "$tip_sha"
}

# =============================================================================
# Test 1 — defense_store_load_for_region returns a record when query_sha IS
#           in the git ancestry path between story_branch_base_sha and
#           story_branch_tip_sha.
#
# RED: current code does no ancestry-path checking — it filters only by
# file_paths intersection.  This test asserts that a SHA-gated lookup is
# performed, which is not yet implemented.  The test will PASS once ancestry
# checking is added only if the test itself verifies that ancestral SHAs
# trigger inclusion.  As a RED signal we verify that the function EXCLUDES the
# record for an OUT-OF-RANGE sha, and then fails because the function never
# checks ancestry at all (always includes by file_paths match instead).
#
# Concretely: we call defense_store_load_for_region with a non-matching
# file_path but a matching ancestry SHA.  Current code returns nothing (file
# path mismatch).  Future code should return the record because the SHA is in
# ancestry.  So the assertion "record appears" will fail today (RED).
# =============================================================================
echo ""
echo "--- test_load_for_region_returns_record_when_sha_in_ancestry ---"

test_load_for_region_returns_record_when_sha_in_ancestry() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_load_for_region_returns_record_when_sha_in_ancestry\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    # Build a temp git repo
    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local shas
    shas=$(_make_git_repo "$tmpdir")
    local base_sha mid_sha tip_sha
    base_sha=$(printf '%s' "$shas" | cut -d' ' -f1)
    mid_sha=$(printf '%s' "$shas" | cut -d' ' -f2)
    tip_sha=$(printf '%s' "$shas" | cut -d' ' -f3)

    # Build a defense record with SHA-range fields and a file_path
    local record_json
    record_json=$(python3 -c "
import json
print(json.dumps({
    'prior_finding_id': 'f-sha-test-1',
    'file_paths': ['src/target.py'],
    'defense_text': 'valid defense',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}],
    'story_branch_tip_sha': '$tip_sha',
    'story_branch_base_sha': '$base_sha',
    'diff_hash': 'abc123'
}))
")

    local ticket_json
    ticket_json=$(_build_ticket_json "$record_json")

    # Stub: TICKET_CMD returns our fake ticket JSON
    local stub_ticket_cmd
    stub_ticket_cmd=$(mktemp /tmp/dso-ticket-stub.XXXXXX)
    chmod +x "$stub_ticket_cmd"
    printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' '"'"'%s'"'"'\n' "$ticket_json" > "$stub_ticket_cmd"

    # Call defense_store_load_for_region with:
    #   - query_sha = mid_sha (IS in ancestry BASE..TIP)
    #   - region_files = src/target.py (matches file_paths)
    #   - GIT_DIR set so ancestry check can run
    local output
    # shellcheck disable=SC2030,SC2031
    output=$(
        export DSO_SESSION_TICKET_ID="TEST-TICKET-001"
        export TICKET_CMD="$stub_ticket_cmd"
        export GIT_DIR="$tmpdir/.git"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        # Future interface: defense_store_load_for_region accepts --query-sha
        defense_store_load_for_region --query-sha "$mid_sha" "src/target.py" 2>/dev/null
    ) || true

    rm -f "$stub_ticket_cmd"

    # The record MUST appear in output (SHA is in ancestry)
    local record_found=0
    if printf '%s' "$output" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == 'f-sha-test-1':
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" 2>/dev/null; then
        record_found=1
    fi

    assert_eq "test_load_for_region_returns_record_when_sha_in_ancestry: record returned for in-ancestry SHA" \
        "1" "$record_found"

    assert_pass_if_clean "test_load_for_region_returns_record_when_sha_in_ancestry"
}

test_load_for_region_returns_record_when_sha_in_ancestry

# =============================================================================
# Test 2 — defense_store_load_for_region excludes a record when query_sha is
#           NOT in git ancestry between story_branch_base_sha and
#           story_branch_tip_sha.
#
# RED: current code filters only by file_paths intersection; any file-path match
# will return the record regardless of SHA position.  This test calls the
# CURRENT interface (positional file-path args, no --query-sha flag) but stores
# a record with story_branch_tip_sha / story_branch_base_sha fields.  Once
# ancestry filtering is implemented, the function will need a query_sha and will
# EXCLUDE when that SHA is outside the stored range.
#
# We exercise the upcoming interface: the function must NOT return a record whose
# stored SHA range does not contain the supplied query_sha.  Currently the code
# always returns on file-path match, so the assertion "record absent" fails (RED).
# =============================================================================
echo ""
echo "--- test_load_for_region_excludes_record_when_sha_not_in_ancestry ---"

test_load_for_region_excludes_record_when_sha_not_in_ancestry() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_load_for_region_excludes_record_when_sha_not_in_ancestry\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    # Build two separate git repos so we can get a SHA that is NOT in the
    # ancestry of repo A
    local tmpdir_a tmpdir_b
    tmpdir_a=$(mktemp -d)
    tmpdir_b=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir_a' '$tmpdir_b'" RETURN

    local shas_a
    shas_a=$(_make_git_repo "$tmpdir_a")
    local base_sha_a tip_sha_a
    base_sha_a=$(printf '%s' "$shas_a" | cut -d' ' -f1)
    tip_sha_a=$(printf '%s' "$shas_a" | cut -d' ' -f3)

    local shas_b
    shas_b=$(_make_git_repo "$tmpdir_b")
    # Take the TIP sha from repo B — it does NOT exist in repo A's ancestry
    local foreign_sha
    foreign_sha=$(printf '%s' "$shas_b" | cut -d' ' -f3)

    # Build defense record referencing repo A's range
    local record_json
    record_json=$(python3 -c "
import json
print(json.dumps({
    'prior_finding_id': 'f-sha-test-2',
    'file_paths': ['src/target.py'],
    'defense_text': 'valid defense',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}],
    'story_branch_tip_sha': '$tip_sha_a',
    'story_branch_base_sha': '$base_sha_a',
    'diff_hash': 'def456'
}))
")

    local ticket_json
    ticket_json=$(_build_ticket_json "$record_json")

    local stub_ticket_cmd
    stub_ticket_cmd=$(mktemp /tmp/dso-ticket-stub.XXXXXX)
    chmod +x "$stub_ticket_cmd"
    printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' '"'"'%s'"'"'\n' "$ticket_json" > "$stub_ticket_cmd"

    # Call with --query-sha pointing to a SHA that is NOT in repo A's ancestry.
    # Future implementation: when query_sha is outside the stored BASE..TIP range,
    # the record is excluded even though the file_path matches.
    # Current implementation: ignores --query-sha (unknown flag treated as
    # region_file), so it never matches 'src/target.py' as a positional arg —
    # meaning the output is empty today (record not returned).
    # We assert record_found=0.  Once --query-sha is implemented and ancestry
    # filtering works, the record must STILL be absent (foreign SHA excluded).
    # So this assertion should be GREEN after implementation too — but we are
    # RED if the NEW interface (--query-sha + ancestry check) is absent and the
    # test documents future exclusion intent.
    #
    # To make this genuinely RED we also assert that the function signature
    # accepts --query-sha without error (exits 0); current code will silently
    # treat it as a filename and succeed (exit 0) — so we need an additional
    # assertion that is currently failing.
    #
    # Additional RED assertion: with the future implementation, when we call
    # defense_store_load_for_region with the IN-ancestry SHA from repo A as
    # query_sha AND the file matches, the record SHOULD be found.  We verify
    # that the out-of-ancestry call does NOT return the same record as the
    # in-ancestry call (i.e., ancestry filtering differentiates them).
    # Currently both calls return nothing (no --query-sha support), so:
    #   in_ancestry_found = 0 (no --query-sha support)
    #   out_ancestry_found = 0 (no --query-sha support)
    # And the assertion "in_ancestry_found == 1" will FAIL (RED).
    local mid_sha_a
    mid_sha_a=$(printf '%s' "$shas_a" | cut -d' ' -f2)

    local in_ancestry_output out_ancestry_output
    # shellcheck disable=SC2030,SC2031
    in_ancestry_output=$(
        export DSO_SESSION_TICKET_ID="TEST-TICKET-001"
        export TICKET_CMD="$stub_ticket_cmd"
        export GIT_DIR="$tmpdir_a/.git"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_load_for_region --query-sha "$mid_sha_a" "src/target.py" 2>/dev/null
    ) || true

    # shellcheck disable=SC2030,SC2031
    out_ancestry_output=$(
        export DSO_SESSION_TICKET_ID="TEST-TICKET-001"
        export TICKET_CMD="$stub_ticket_cmd"
        export GIT_DIR="$tmpdir_a/.git"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_load_for_region --query-sha "$foreign_sha" "src/target.py" 2>/dev/null
    ) || true

    rm -f "$stub_ticket_cmd"

    # Ancestry SHA: record MUST appear (RED if --query-sha not implemented)
    local in_found=0
    if printf '%s' "$in_ancestry_output" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == 'f-sha-test-2':
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" 2>/dev/null; then
        in_found=1
    fi

    # Out-of-ancestry SHA: record must NOT appear
    local out_found=0
    if printf '%s' "$out_ancestry_output" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == 'f-sha-test-2':
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" 2>/dev/null; then
        out_found=1
    fi

    # RED: in-ancestry lookup must return the record (currently doesn't — --query-sha unrecognized)
    assert_eq "test_load_for_region_excludes_record_when_sha_not_in_ancestry: in-ancestry SHA returns record" \
        "1" "$in_found"

    # This assertion may pass incidentally today (nothing returned) but will validate
    # post-implementation that out-of-ancestry SHA truly excludes
    assert_eq "test_load_for_region_excludes_record_when_sha_not_in_ancestry: out-of-ancestry SHA excludes record" \
        "0" "$out_found"

    assert_pass_if_clean "test_load_for_region_excludes_record_when_sha_not_in_ancestry"
}

test_load_for_region_excludes_record_when_sha_not_in_ancestry

# =============================================================================
# Test 3 — defense_store_load_for_region falls back to diff_hash equality for
#           legacy records (those WITHOUT story_branch_tip_sha /
#           story_branch_base_sha) AND emits a warning to stderr containing
#           "legacy" or "diff_hash".
#
# RED: current code returns the legacy record (by file_paths match) but does
# NOT emit any warning to stderr.  The assertion on the warning will fail
# today (RED).
# =============================================================================
echo ""
echo "--- test_legacy_record_falls_back_to_diff_hash_equality ---"

test_legacy_record_falls_back_to_diff_hash_equality() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_legacy_record_falls_back_to_diff_hash_equality\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local target_diff_hash="legacy-hash-aabbccdd"

    # Build a LEGACY defense record — no story_branch_tip_sha / story_branch_base_sha
    local record_json
    record_json=$(python3 -c "
import json
print(json.dumps({
    'prior_finding_id': 'f-legacy-001',
    'file_paths': ['src/legacy.py'],
    'defense_text': 'legacy defense text',
    'severity_history': [{'cycle': 1, 'severity': 'critical', 'relation': None}],
    'diff_hash': '$target_diff_hash'
}))
")

    local ticket_json
    ticket_json=$(_build_ticket_json "$record_json")

    local stub_ticket_cmd
    stub_ticket_cmd=$(mktemp /tmp/dso-ticket-stub.XXXXXX)
    chmod +x "$stub_ticket_cmd"
    printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' '"'"'%s'"'"'\n' "$ticket_json" > "$stub_ticket_cmd"
    # shellcheck disable=SC2064
    trap "rm -f '$stub_ticket_cmd'" RETURN

    # Capture stdout and stderr to separate temp files so both can be inspected
    local out_file stderr_file
    out_file=$(mktemp /tmp/dso-test-out.XXXXXX)
    stderr_file=$(mktemp /tmp/dso-test-err.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -f '$out_file' '$stderr_file' '$stub_ticket_cmd'" RETURN

    # shellcheck disable=SC2030,SC2031
    (
        export DSO_SESSION_TICKET_ID="TEST-TICKET-001"
        export TICKET_CMD="$stub_ticket_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        # Future interface: --diff-hash enables legacy fallback matching
        defense_store_load_for_region --query-sha "" --diff-hash "$target_diff_hash" "src/legacy.py"
    ) >"$out_file" 2>"$stderr_file" || true

    local stdout_capture stderr_capture
    stdout_capture=$(cat "$out_file")
    stderr_capture=$(cat "$stderr_file")

    # Assertion A: the legacy record IS returned (diff_hash matched)
    # RED: --diff-hash flag not yet implemented; current code returns nothing
    local record_found=0
    if printf '%s' "$stdout_capture" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
        if rec.get('prior_finding_id') == 'f-legacy-001':
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" 2>/dev/null; then
        record_found=1
    fi

    assert_eq "test_legacy_record_falls_back_to_diff_hash_equality: legacy record returned on diff_hash match" \
        "1" "$record_found"

    # Assertion B: stderr contains "legacy" or "diff_hash" warning
    # RED: current code emits no such warning
    local has_legacy_warning=0
    if [[ "$stderr_capture" == *"legacy"* || "$stderr_capture" == *"diff_hash"* ]]; then
        has_legacy_warning=1
    fi

    assert_eq "test_legacy_record_falls_back_to_diff_hash_equality: stderr contains legacy or diff_hash warning" \
        "1" "$has_legacy_warning"

    assert_pass_if_clean "test_legacy_record_falls_back_to_diff_hash_equality"
}

test_legacy_record_falls_back_to_diff_hash_equality

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
